-- LitRPG Con — authorization model.
-- Run top to bottom in the Supabase SQL editor. Idempotent: safe to re-run.
--
-- Model:
--   admin  -> may read/write everything
--   author -> may create meetups only for the roster name mapped to their
--             account, and may only edit/delete meetups they own
--   anon   -> read-only, and only what the public schedule needs
--
-- The role lives in auth.users.raw_app_meta_data, which only the service role
-- can write. It must NOT live in raw_user_meta_data: that field is writable by
-- the user via PATCH /auth/v1/user, so an author could promote themselves.

begin;

-- ─────────────────────────────────────────────────────────────
-- 1. Promote the existing account. Do this FIRST: the deployed
--    client treats any session without role='admin' as an author.
-- ─────────────────────────────────────────────────────────────
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                           || '{"role":"admin"}'::jsonb
 where email = 'phall776@gmail.com';

-- Reads the role out of the JWT. STABLE so the planner can cache it per row.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (current_setting('request.jwt.claims', true)::jsonb
      -> 'app_metadata' ->> 'role') = 'admin',
    false
  );
$$;

-- ─────────────────────────────────────────────────────────────
-- 2. Ownership. The default is what makes this safe: the client
--    never sends owner_id, so it cannot forge one.
-- ─────────────────────────────────────────────────────────────
alter table public.meetings
  add column if not exists owner_id uuid
    references auth.users(id) on delete cascade
    default auth.uid();

-- Existing rows predate ownership; attribute them to the admin.
update public.meetings
   set owner_id = (select id from auth.users where email = 'phall776@gmail.com')
 where owner_id is null;

-- ─────────────────────────────────────────────────────────────
-- 3. Account -> roster name. Admins need no row and may schedule
--    for anyone. An author with no row can schedule for nobody.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.guest_accounts (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  participant_name text not null unique
);

alter table public.guest_accounts enable row level security;

drop policy if exists "read own guest_account" on public.guest_accounts;
create policy "read own guest_account"
  on public.guest_accounts for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "admins manage guest_accounts" on public.guest_accounts;
create policy "admins manage guest_accounts"
  on public.guest_accounts for all
  to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- 4. Replace the blanket "auth only" ALL policies. Those granted
--    every authenticated user full write access to every row.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "auth only" on public.meetings;
drop policy if exists "auth only" on public.meeting_participants;
drop policy if exists "auth only" on public.profiles;

alter table public.meetings             enable row level security;
alter table public.meeting_participants enable row level security;
alter table public.profiles             enable row level security;

-- Public read. The schedule is meant to be seen by everyone.
drop policy if exists "public read meetings" on public.meetings;
create policy "public read meetings"
  on public.meetings for select to anon, authenticated using (true);

drop policy if exists "public read meeting_participants" on public.meeting_participants;
create policy "public read meeting_participants"
  on public.meeting_participants for select to anon, authenticated using (true);

drop policy if exists "public read profiles" on public.profiles;
create policy "public read profiles"
  on public.profiles for select to anon, authenticated using (true);

-- Meetings: own or admin.
drop policy if exists "insert own meeting" on public.meetings;
create policy "insert own meeting"
  on public.meetings for insert to authenticated
  with check (owner_id = auth.uid() or public.is_admin());

drop policy if exists "update own meeting" on public.meetings;
create policy "update own meeting"
  on public.meetings for update to authenticated
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());

drop policy if exists "delete own meeting" on public.meetings;
create policy "delete own meeting"
  on public.meetings for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin());

-- Participants: writable only by whoever owns the parent meeting. Without the
-- name check, an author could attach themselves to someone else's meetup.
drop policy if exists "write participants of own meeting" on public.meeting_participants;
create policy "write participants of own meeting"
  on public.meeting_participants for all to authenticated
  using (
    exists (select 1 from public.meetings m
             where m.id = meeting_id
               and (m.owner_id = auth.uid() or public.is_admin()))
  )
  with check (
    exists (select 1 from public.meetings m
             where m.id = meeting_id
               and (m.owner_id = auth.uid() or public.is_admin()))
    and (
      public.is_admin()
      or participant_name = (select ga.participant_name
                               from public.guest_accounts ga
                              where ga.user_id = auth.uid())
    )
  );

-- Profiles: bios and photos stay admin-only to write.
drop policy if exists "admins write profiles" on public.profiles;
create policy "admins write profiles"
  on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

commit;

-- ─────────────────────────────────────────────────────────────
-- After running: sign out and back in. The role is read from the
-- JWT, and your current token was minted before the update above.
-- ─────────────────────────────────────────────────────────────
