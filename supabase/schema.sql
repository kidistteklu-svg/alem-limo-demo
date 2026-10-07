-- Alem Luxury Transportation — database schema
-- Run this ONCE in the client's Supabase project: Dashboard → SQL Editor → New query → paste → Run.
-- It creates the tables, locks them down with row-level security, and defines the
-- functions the website calls. Safe to run on a brand-new project.

create extension if not exists pgcrypto;

-- ---------- tables ----------
create table public.site_config (
  id int primary key default 1 check (id = 1),
  rates jsonb not null default '{}'::jsonb,
  flats jsonb not null default '{}'::jsonb,
  service_area jsonb not null default '{}'::jsonb,
  settings jsonb not null default '{}'::jsonb,
  blocked jsonb not null default '{}'::jsonb,
  vehicles_off jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.site_config (id) values (1);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  conf text not null unique,
  status text not null default 'new' check (status in ('new','confirmed','completed')),
  archived boolean not null default false,
  offsite boolean not null default false,
  date date not null,
  time text not null,
  name text, phone text, email text,
  trip_type text, vehicle text, pickup text, dropoff text, flight text, notes text,
  extras jsonb not null default '[]'::jsonb,
  miles numeric, est text, final numeric,
  created_at timestamptz not null default now()
);
create index bookings_date_idx on public.bookings (date);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  stars int not null check (stars between 1 and 5),
  text text not null check (length(text) between 1 and 2000),
  name text not null check (length(name) between 1 and 120),
  tag text,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.team_members (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Team member',
  username text not null unique,
  pass_hash text not null,
  owner boolean not null default false,
  created_at timestamptz not null default now()
);
-- Seed owner login. CHANGE THIS PASSWORD from the console (Team tab → Change my password) right after setup.
insert into public.team_members (name, username, pass_hash, owner)
values ('Owner', 'admin', crypt('alem2259', gen_salt('bf')), true);

create table public.team_sessions (
  token uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.team_members(id) on delete cascade,
  expires_at timestamptz not null
);

-- ---------- row level security ----------
-- The website talks to the database with the public "anon" key. These policies are the
-- whole security model: anonymous visitors can read prices/settings and approved reviews,
-- and can only INSERT a ride request or a review. Everything else goes through the
-- functions below, which require a valid team session token.
alter table public.site_config enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews enable row level security;
alter table public.team_members enable row level security;
alter table public.team_sessions enable row level security;

create policy "public can read config" on public.site_config
  for select to anon, authenticated using (true);

create policy "public can request a ride" on public.bookings
  for insert to anon, authenticated
  with check (
    status = 'new' and archived = false and offsite = false and final is null
    and date >= current_date - 1
    and phone ~ '^\(\d{3}\) \d{3}-\d{4}$'
    and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$'
  );

create policy "public can submit a review" on public.reviews
  for insert to anon, authenticated with check (approved = false);
create policy "public can read approved reviews" on public.reviews
  for select to anon, authenticated using (approved = true);
-- team_members / team_sessions: no policies on purpose (only reachable through the functions below)

-- ---------- internal helpers ----------
create or replace function public._session_member(p_token uuid)
returns public.team_members language plpgsql security definer set search_path = public as $$
declare m public.team_members;
begin
  select tm.* into m from public.team_sessions s join public.team_members tm on tm.id = s.member_id
   where s.token = p_token and s.expires_at > now();
  if m.id is null then raise exception 'not signed in' using errcode = '28000'; end if;
  update public.team_sessions set expires_at = now() + interval '12 hours' where token = p_token;
  return m;
end $$;
revoke execute on function public._session_member(uuid) from public, anon, authenticated;

create or replace function public._booking_json(b public.bookings)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', b.id, 'conf', b.conf, 'status', b.status, 'archived', b.archived, 'offsite', b.offsite,
    'date', to_char(b.date, 'YYYY-MM-DD'), 'time', b.time, 'name', b.name, 'phone', b.phone, 'email', b.email,
    'tripType', b.trip_type, 'vehicle', b.vehicle, 'pickup', b.pickup, 'dropoff', b.dropoff, 'flight', b.flight,
    'notes', b.notes, 'extras', b.extras, 'miles', b.miles, 'est', b.est, 'final', b.final, 'createdAt', b.created_at);
$$;
revoke execute on function public._booking_json(public.bookings) from public, anon, authenticated;

-- ---------- public (customer-facing) ----------
-- Only times and statuses for one day, so the booking form can enforce car capacity. No names or numbers.
create or replace function public.availability(p_date date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('time', b.time, 'status', b.status)), '[]'::jsonb)
  from public.bookings b
  where b.date = p_date and not b.archived and b.status <> 'completed';
$$;

-- ---------- team auth ----------
create or replace function public.team_login(p_user text, p_pass text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m public.team_members; t uuid;
begin
  delete from public.team_sessions where expires_at < now();
  select * into m from public.team_members where lower(username) = lower(trim(p_user));
  if m.id is null or p_pass is null or length(p_pass) = 0 or m.pass_hash <> crypt(p_pass, m.pass_hash) then
    perform pg_sleep(0.4);
    return null;
  end if;
  insert into public.team_sessions (member_id, expires_at) values (m.id, now() + interval '12 hours') returning token into t;
  return jsonb_build_object('token', t, 'name', m.name, 'username', m.username, 'owner', m.owner);
end $$;

create or replace function public.team_check(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.team_members;
begin
  m := public._session_member(p_token);
  return jsonb_build_object('name', m.name, 'username', m.username, 'owner', m.owner);
exception when others then return null;
end $$;

create or replace function public.team_logout(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.team_sessions where token = p_token;
$$;

create or replace function public.team_set_password(p_token uuid, p_pass text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare m public.team_members;
begin
  m := public._session_member(p_token);
  if p_pass is null or length(p_pass) < 6 then raise exception 'Password needs at least 6 characters.'; end if;
  update public.team_members set pass_hash = crypt(p_pass, gen_salt('bf')) where id = m.id;
end $$;

create or replace function public.team_add(p_token uuid, p_name text, p_user text, p_pass text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare m public.team_members; u text;
begin
  m := public._session_member(p_token);
  u := trim(p_user);
  if u is null or u = '' or u ~ '\s' or length(u) > 40 then raise exception 'Pick a username without spaces.'; end if;
  if p_pass is null or length(p_pass) < 6 then raise exception 'Password needs at least 6 characters.'; end if;
  if exists (select 1 from public.team_members where lower(username) = lower(u)) then raise exception 'That username is taken.'; end if;
  insert into public.team_members (name, username, pass_hash) values (coalesce(nullif(trim(p_name), ''), 'Team member'), u, crypt(p_pass, gen_salt('bf')));
end $$;

create or replace function public.team_remove(p_token uuid, p_user text)
returns void language plpgsql security definer set search_path = public as $$
declare m public.team_members;
begin
  m := public._session_member(p_token);
  if exists (select 1 from public.team_members where lower(username) = lower(p_user) and owner) then raise exception 'The owner account cannot be removed.'; end if;
  delete from public.team_members where lower(username) = lower(p_user);
end $$;

-- ---------- console reads & writes ----------
create or replace function public.console_data(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  return jsonb_build_object(
    'bookings', coalesce((select jsonb_agg(public._booking_json(b) order by b.date, b.time) from public.bookings b), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'stars', r.stars, 'text', r.text, 'name', r.name, 'tag', r.tag, 'approved', r.approved) order by r.created_at) from public.reviews r), '[]'::jsonb),
    'team', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'username', t.username, 'owner', t.owner) order by t.created_at) from public.team_members t), '[]'::jsonb)
  );
end $$;

create or replace function public.booking_update(p_token uuid, p_id uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  update public.bookings set
    status = coalesce(p_patch->>'status', status),
    archived = coalesce((p_patch->>'archived')::boolean, archived),
    final = case when p_patch ? 'final' then nullif(p_patch->>'final', '')::numeric else final end
  where id = p_id;
end $$;

create or replace function public.booking_delete(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  delete from public.bookings where id = p_id;
end $$;

create or replace function public.booking_add(p_token uuid, p_b jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  insert into public.bookings (conf, status, archived, offsite, date, time, name, phone, email, trip_type, vehicle, pickup, dropoff, flight, notes, extras, miles, est, final)
  values (p_b->>'conf', coalesce(p_b->>'status', 'confirmed'), false, true, (p_b->>'date')::date, p_b->>'time', p_b->>'name', p_b->>'phone', p_b->>'email',
          coalesce(p_b->>'tripType', 'Point-to-Point'), p_b->>'vehicle', p_b->>'pickup', p_b->>'dropoff', p_b->>'flight', p_b->>'notes',
          coalesce(p_b->'extras', '[]'::jsonb), nullif(p_b->>'miles', '')::numeric, p_b->>'est', nullif(p_b->>'final', '')::numeric);
end $$;

create or replace function public.review_set(p_token uuid, p_id uuid, p_approved boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  update public.reviews set approved = p_approved where id = p_id;
end $$;

create or replace function public.review_delete(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  delete from public.reviews where id = p_id;
end $$;

create or replace function public.config_update(p_token uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._session_member(p_token);
  update public.site_config set
    rates = coalesce(p_patch->'rates', rates),
    flats = coalesce(p_patch->'flats', flats),
    service_area = coalesce(p_patch->'serviceArea', service_area),
    settings = coalesce(p_patch->'settings', settings),
    blocked = coalesce(p_patch->'blocked', blocked),
    vehicles_off = coalesce(p_patch->'vehiclesOff', vehicles_off),
    updated_at = now()
  where id = 1;
end $$;
