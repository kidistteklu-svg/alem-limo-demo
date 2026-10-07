-- Alem — booking notifications (Telegram + email), pure SQL, no server needed.
-- Run ONCE in Supabase → SQL Editor (after schema.sql). Then fill in your keys with the
-- UPDATE statement at the bottom. Safe to run again (it replaces the functions).
--
-- What it does:
--   • New website booking   → Telegram message (with a Confirm ride button) to the dispatch chat,
--                             email to the dispatcher, "we received your request" email to the customer
--   • Ride confirmed        → "Ride confirmed" to Telegram + "your ride is confirmed" email to the customer
--   • Ride completed        → "Ride completed" to Telegram
--
-- Delivery is reliable: every message goes into an outbox table, is sent immediately, and is
-- re-sent automatically (up to 5 attempts, about a minute apart) if Telegram or the email
-- service is slow or fails. Notifications never block or fail a booking.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

-- Private settings row. Row-level security with NO policies = the website can never read it;
-- only the notification functions below (security definer) can.
create table if not exists public.notify_settings (
  id int primary key default 1 check (id = 1),
  telegram_token text,
  telegram_chat_id text,
  resend_api_key text,
  email_from text,
  email_to text,
  customer_emails boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.notify_settings enable row level security;
insert into public.notify_settings (id) values (1) on conflict (id) do nothing;

-- Outbox: one row per message to send. Private, same as above.
create table if not exists public.notify_outbox (
  id bigserial primary key,
  kind text not null check (kind in ('telegram', 'email')),
  payload jsonb not null,
  attempts int not null default 0,
  request_id bigint,
  dispatched_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);
alter table public.notify_outbox enable row level security;
create index if not exists notify_outbox_pending_idx on public.notify_outbox (id) where sent_at is null;

-- ---------- helpers ----------
create or replace function public._fmt_when(p_date date, p_time text)
returns text language sql stable as $$
  select to_char(p_date, 'Dy Mon FMDD') || ' · ' ||
         coalesce(to_char(('2000-01-01 ' || p_time)::timestamp, 'FMHH12:MI AM'), p_time);
$$;

create or replace function public._booking_summary(b public.bookings) returns text
language sql stable as $$
  select concat_ws(E'\n',
    public._fmt_when(b.date, b.time),
    coalesce(b.vehicle, '') || ' · ' || coalesce(b.trip_type, ''),
    coalesce(b.pickup, '-') || ' → ' || coalesce(nullif(b.dropoff, ''), 'as directed'),
    coalesce(b.name, 'Guest') || ' · ' || coalesce(b.phone, '') || ' · ' || coalesce(b.email, ''),
    'Call: +1' || regexp_replace(coalesce(b.phone, ''), '[^0-9]', '', 'g'),
    'Estimate: ' || coalesce(b.est, '-'),
    case when coalesce(b.flight, '') <> '' then 'Flight: ' || b.flight end,
    case when jsonb_array_length(coalesce(b.extras, '[]'::jsonb)) > 0
         then 'Extras: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(b.extras) x) end,
    case when coalesce(b.notes, '') <> '' then 'Notes: ' || b.notes end
  );
$$;

-- ---------- queueing (what the triggers call) ----------
drop function if exists public._send_telegram(text);
create or replace function public._send_telegram(p_text text, p_markup jsonb default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.notify_outbox (kind, payload) values ('telegram', jsonb_build_object('text', p_text, 'markup', p_markup));
end $$;

create or replace function public._send_email(p_to text, p_subject text, p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_to is null or p_to = '' then return; end if;
  insert into public.notify_outbox (kind, payload) values ('email', jsonb_build_object('to', p_to, 'subject', p_subject, 'text', p_text));
end $$;

revoke execute on function public._send_telegram(text, jsonb) from public, anon, authenticated;
revoke execute on function public._send_email(text, text, text) from public, anon, authenticated;

-- ---------- sending (one HTTP request per outbox row) ----------
create or replace function public._dispatch_outbox_row(r public.notify_outbox) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings; rid bigint;
begin
  select * into s from public.notify_settings where id = 1;
  if r.kind = 'telegram' then
    if s.telegram_token is null or s.telegram_chat_id is null then return null; end if;
    select net.http_post(
      url := 'https://api.telegram.org/bot' || s.telegram_token || '/sendMessage',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', s.telegram_chat_id, 'text', r.payload->>'text', 'disable_web_page_preview', true)
              || case when (r.payload->'markup') is null or jsonb_typeof(r.payload->'markup') = 'null' then '{}'::jsonb
                      else jsonb_build_object('reply_markup', r.payload->'markup') end,
      timeout_milliseconds := 15000
    ) into rid;
  elsif r.kind = 'email' then
    if s.resend_api_key is null then return null; end if;
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || s.resend_api_key),
      body := jsonb_build_object(
        'from', coalesce(s.email_from, 'Alem Dispatch <onboarding@resend.dev>'),
        'to', jsonb_build_array(r.payload->>'to'),
        'subject', r.payload->>'subject',
        'text', r.payload->>'text'),
      timeout_milliseconds := 15000
    ) into rid;
  end if;
  return rid;
end $$;
revoke execute on function public._dispatch_outbox_row(public.notify_outbox) from public, anon, authenticated;

-- Reconciles in-flight requests, then sends whatever is pending. Called right after a booking
-- event for immediate delivery, and every minute by the scheduler for retries.
create or replace function public.process_notify_outbox() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r public.notify_outbox; v_status int; v_err text; v_found boolean; rid bigint;
        n_sent int := 0; n_failed int := 0; n_queued int := 0;
begin
  for r in select * from public.notify_outbox where sent_at is null and request_id is not null loop
    select status_code, error_msg into v_status, v_err from net._http_response where id = r.request_id;
    v_found := found;
    if v_found then
      if v_status between 200 and 299 then
        update public.notify_outbox set sent_at = now(), last_error = null where id = r.id;
        n_sent := n_sent + 1;
      else
        update public.notify_outbox set request_id = null, attempts = attempts + 1,
          last_error = coalesce(v_err, 'HTTP ' || coalesce(v_status::text, '?')) where id = r.id;
        n_failed := n_failed + 1;
      end if;
    elsif r.dispatched_at < now() - interval '3 minutes' then
      update public.notify_outbox set request_id = null, attempts = attempts + 1, last_error = 'no response recorded' where id = r.id;
      n_failed := n_failed + 1;
    end if;
  end loop;

  for r in
    select * from public.notify_outbox
    where sent_at is null and request_id is null and attempts < 5
      and (dispatched_at is null or dispatched_at < now() - (interval '1 minute' * attempts))
    order by id limit 25
  loop
    rid := public._dispatch_outbox_row(r);
    if rid is null then
      update public.notify_outbox set sent_at = now(), last_error = 'channel not configured' where id = r.id;
    else
      update public.notify_outbox set request_id = rid, dispatched_at = now() where id = r.id;
      n_queued := n_queued + 1;
    end if;
  end loop;
  return format('sent %s, failed %s, queued %s', n_sent, n_failed, n_queued);
end $$;
revoke execute on function public.process_notify_outbox() from public, anon, authenticated;

-- ---------- triggers ----------
create or replace function public._on_booking_insert() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings; body text;
begin
  select * into s from public.notify_settings where id = 1;
  body := public._booking_summary(new);
  perform public._send_telegram(
    'New ride request ' || new.conf || E'\n' || body || E'\n\nTap Confirm ride to accept it, or open the console.',
    jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('text', 'Confirm ride', 'callback_data', 'confirm:' || new.id::text),
      jsonb_build_object('text', 'Open console', 'url', 'https://www.alemtransportation.com/')))));
  perform public._send_email(s.email_to, 'New ride request ' || new.conf || ' · ' || public._fmt_when(new.date, new.time), body || E'\n\nOpen the console to confirm.');
  if s.customer_emails and coalesce(new.email, '') <> '' then
    perform public._send_email(new.email,
      'We received your ride request (' || new.conf || ')',
      'Thank you for choosing Alem Luxury Transportation.' || E'\n\n' ||
      'We received your request:' || E'\n' || body || E'\n\n' ||
      'Our dispatcher reviews every request and will confirm with you shortly. Nothing is charged until your ride is confirmed.' || E'\n\n' ||
      'Questions? Call or text (240)-595-2259.');
  end if;
  perform public.process_notify_outbox();
  return new;
exception when others then
  -- a notification problem must never block a customer's booking
  raise warning 'booking notification skipped: %', sqlerrm;
  return new;
end $$;

create or replace function public._on_booking_confirm() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.status = 'confirmed' and coalesce(old.status, '') <> 'confirmed' then
    perform public._send_telegram('Ride confirmed: ' || new.conf || E'\n' || public._booking_summary(new) || E'\n\nReminders will follow 1 hour and 30 minutes before pickup.');
    if coalesce(new.email, '') <> '' and not new.offsite then
      perform public._send_email(new.email,
        'Your ride is confirmed (' || new.conf || ')',
        'Good news, your ride with Alem Luxury Transportation is confirmed.' || E'\n\n' ||
        public._booking_summary(new) || E'\n\n' ||
        'Your chauffeur will be in touch before pickup. Need to change anything? Call or text (240)-595-2259.');
    end if;
  end if;
  if new.status = 'completed' and coalesce(old.status, '') <> 'completed' then
    perform public._send_telegram('Ride completed: ' || new.conf || ' · ' || coalesce(new.name, 'Guest') || ' · ' || coalesce(new.est, ''));
  end if;
  perform public.process_notify_outbox();
  return new;
exception when others then
  raise warning 'confirmation notification skipped: %', sqlerrm;
  return new;
end $$;

drop trigger if exists booking_notify_insert on public.bookings;
create trigger booking_notify_insert
  after insert on public.bookings
  for each row when (new.offsite = false)
  execute function public._on_booking_insert();

drop trigger if exists booking_notify_confirm on public.bookings;
create trigger booking_notify_confirm
  after update of status on public.bookings
  for each row execute function public._on_booking_confirm();

-- ---------- retry scheduler: every minute ----------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'alem-notify-outbox') then
    perform cron.unschedule('alem-notify-outbox');
  end if;
  perform cron.schedule('alem-notify-outbox', '* * * * *', 'select public.process_notify_outbox()');
end $$;

-- ---------- test helper: run  select public.notify_test();  ----------
create or replace function public.notify_test() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings;
begin
  select * into s from public.notify_settings where id = 1;
  perform public._send_telegram('Alem Dispatch alerts are connected. New ride requests will appear here.');
  perform public._send_email(s.email_to, 'Alem Dispatch alerts connected', 'Email alerts for new ride requests are working.');
  return public.process_notify_outbox() || ' (check Telegram / inbox in a few seconds; retries continue automatically)';
end $$;
revoke execute on function public.notify_test() from public, anon, authenticated;

-- ---------- YOUR KEYS (edit, then run just this statement) ----------
-- update public.notify_settings set
--   telegram_token   = 'PASTE_BOT_TOKEN',
--   telegram_chat_id = 'PASTE_CHAT_ID',
--   resend_api_key   = null,                         -- optional: 're_...' from resend.com
--   email_from       = 'Alem Dispatch <dispatch@alemtransportation.com>',
--   email_to         = 'kidistteklu@gmail.com',
--   updated_at       = now();
