-- Patch 01 — run this if you set up the database with a schema.sql from before 2026-10-06.
-- Fixes "function crypt(text, text) does not exist" on sign-in: Supabase keeps the
-- pgcrypto extension in the "extensions" schema, so the three password functions must
-- search there too. Safe to run more than once.

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
