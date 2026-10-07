-- Alem — booking notifications (Telegram + email), pure SQL, no server needed.
-- Run ONCE in Supabase → SQL Editor (after schema.sql). Then fill in your keys with the
-- UPDATE statement at the bottom. Safe to run again (it replaces the functions).
--
-- What it does:
--   • New website booking  → Telegram message to the dispatch chat + email to the dispatcher
--                            + "we received your request" email to the customer
--   • Dispatcher clicks Confirm → "your ride is confirmed" email to the customer
-- Notifications are queued by the database (pg_net) and never block or fail a booking.

create extension if not exists pg_net with schema extensions;

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

create or replace function public._send_telegram(p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings;
begin
  select * into s from public.notify_settings where id = 1;
  if s.telegram_token is null or s.telegram_chat_id is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || s.telegram_token || '/sendMessage',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', s.telegram_chat_id, 'text', p_text, 'disable_web_page_preview', true)
  );
end $$;

create or replace function public._send_email(p_to text, p_subject text, p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings;
begin
  select * into s from public.notify_settings where id = 1;
  if s.resend_api_key is null or p_to is null or p_to = '' then return; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || s.resend_api_key),
    body := jsonb_build_object(
      'from', coalesce(s.email_from, 'Alem Dispatch <onboarding@resend.dev>'),
      'to', jsonb_build_array(p_to),
      'subject', p_subject,
      'text', p_text)
  );
end $$;

revoke execute on function public._send_telegram(text) from public, anon, authenticated;
revoke execute on function public._send_email(text, text, text) from public, anon, authenticated;

-- ---------- triggers ----------
create or replace function public._on_booking_insert() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings; body text;
begin
  select * into s from public.notify_settings where id = 1;
  body := public._booking_summary(new);
  perform public._send_telegram('🚘 New ride request ' || new.conf || E'\n' || body || E'\n\nOpen the console to confirm.');
  perform public._send_email(s.email_to, 'New ride request ' || new.conf || ' · ' || public._fmt_when(new.date, new.time), body || E'\n\nOpen the console to confirm.');
  if s.customer_emails and coalesce(new.email, '') <> '' then
    perform public._send_email(new.email,
      'We received your ride request (' || new.conf || ')',
      'Thank you for choosing Alem Luxury Transportation.' || E'\n\n' ||
      'We received your request:' || E'\n' || body || E'\n\n' ||
      'Our dispatcher reviews every request and will confirm with you shortly. Nothing is charged until your ride is confirmed.' || E'\n\n' ||
      'Questions? Call or text (240)-595-2259.');
  end if;
  return new;
exception when others then
  -- a notification problem must never block a customer's booking
  raise warning 'booking notification skipped: %', sqlerrm;
  return new;
end $$;

create or replace function public._on_booking_confirm() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.status = 'confirmed' and coalesce(old.status, '') <> 'confirmed' and coalesce(new.email, '') <> '' and not new.offsite then
    perform public._send_email(new.email,
      'Your ride is confirmed (' || new.conf || ')',
      'Good news, your ride with Alem Luxury Transportation is confirmed.' || E'\n\n' ||
      public._booking_summary(new) || E'\n\n' ||
      'Your chauffeur will be in touch before pickup. Need to change anything? Call or text (240)-595-2259.');
  end if;
  return new;
exception when others then
  raise warning 'confirmation email skipped: %', sqlerrm;
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

-- ---------- test helper: run  select public.notify_test();  to send a test message ----------
create or replace function public.notify_test() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare s public.notify_settings;
begin
  select * into s from public.notify_settings where id = 1;
  perform public._send_telegram('✅ Alem Dispatch alerts are connected. New ride requests will appear here.');
  perform public._send_email(s.email_to, 'Alem Dispatch alerts connected', 'Email alerts for new ride requests are working.');
  return 'queued (check Telegram / inbox in a few seconds)';
end $$;
revoke execute on function public.notify_test() from public, anon, authenticated;

-- ---------- YOUR KEYS (edit, then run just this statement) ----------
-- update public.notify_settings set
--   telegram_token   = 'PASTE_BOT_TOKEN',
--   telegram_chat_id = 'PASTE_CHAT_ID',
--   resend_api_key   = null,                         -- optional: 're_...' from resend.com
--   email_from       = 'Alem Dispatch <dispatch@alemtransportation.com>',
--   email_to         = 'Alemllc@gmail.com',
--   updated_at       = now();
