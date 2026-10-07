-- Alem — ride reminders, 1 hour and 30 minutes before each confirmed pickup.
-- Run ONCE in Supabase → SQL Editor, AFTER notifications.sql. Safe to run again.
--
-- A scheduled job (pg_cron) runs every 5 minutes, finds confirmed rides whose pickup is
-- ~60 or ~30 minutes away in Eastern time, posts a reminder to the Telegram dispatch chat
-- (and emails the customer at the 1-hour mark if email is configured), and marks the ride
-- so each reminder is sent exactly once.

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

alter table public.bookings
  add column if not exists reminded_60 boolean not null default false,
  add column if not exists reminded_30 boolean not null default false;

create or replace function public.send_ride_reminders() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare b public.bookings; mins int; n int := 0; local_now timestamp;
begin
  local_now := (now() at time zone 'America/New_York');
  for b in
    select * from public.bookings
    where status = 'confirmed' and not archived
      and date between local_now::date and local_now::date + 1
      and (not reminded_60 or not reminded_30)
  loop
    begin
      mins := floor(extract(epoch from ((b.date + b.time::time) - local_now)) / 60);
    exception when others then
      continue;
    end;
    if mins between 50 and 70 and not b.reminded_60 then
      perform public._send_telegram('Reminder, pickup in 1 hour: ' || b.conf || E'\n' || public._booking_summary(b));
      if coalesce(b.email, '') <> '' and not b.offsite then
        perform public._send_email(b.email,
          'Your chauffeur arrives in about an hour (' || b.conf || ')',
          'A quick reminder from Alem Luxury Transportation: your pickup is at ' || public._fmt_when(b.date, b.time) || '.' || E'\n\n' ||
          public._booking_summary(b) || E'\n\n' || 'Need anything? Call or text (240)-595-2259.');
      end if;
      update public.bookings set reminded_60 = true where id = b.id;
      n := n + 1;
    elsif mins between 20 and 40 and not b.reminded_30 then
      perform public._send_telegram('Reminder, pickup in 30 minutes: ' || b.conf || E'\n' || public._booking_summary(b));
      update public.bookings set reminded_30 = true, reminded_60 = true where id = b.id;
      n := n + 1;
    end if;
  end loop;
  if n > 0 then perform public.process_notify_outbox(); end if;
  return n;
end $$;
revoke execute on function public.send_ride_reminders() from public, anon, authenticated;

-- (re)schedule the job: every 5 minutes
do $$
begin
  if exists (select 1 from cron.job where jobname = 'alem-ride-reminders') then
    perform cron.unschedule('alem-ride-reminders');
  end if;
  perform cron.schedule('alem-ride-reminders', '*/5 * * * *', 'select public.send_ride_reminders()');
end $$;

-- Check it is scheduled:   select jobname, schedule, active from cron.job;
-- Run it by hand once:     select public.send_ride_reminders();
