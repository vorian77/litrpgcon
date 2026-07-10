-- LitRPG Con — link author accounts to roster names.
--
-- PREREQUISITE: the accounts must already exist in auth.users.
-- Do NOT insert into auth.users directly; passwords, identities and
-- confirmation columns must be written the way GoTrue expects. Create them via
-- Dashboard -> Authentication -> Users -> Invite user, or the Admin API:
--
--   POST https://<project>.supabase.co/auth/v1/invite
--   Authorization: Bearer <SERVICE_ROLE_KEY>
--   { "email": "author@example.com" }
--
-- Invite emails contain a set-password link, which is the "sign up via Forgot
-- Password" flow. It only works once Authentication -> URL Configuration lists
-- https://litrpgcon.vercel.app in Redirect URLs and as the Site URL.
--
-- Invited accounts get no role key in raw_app_meta_data, and the client treats
-- a missing role as "author". Nothing further is needed to make them authors.

begin;

-- participant_name must match the roster name exactly, including the
-- "AKA" forms, e.g. 'Travis Deverell AKA Shirtaloon'. A typo here silently
-- leaves that author unable to schedule anything.
insert into public.guest_accounts (user_id, participant_name)
select u.id, v.participant_name
  from (values
          ('author1@example.com', 'Travis Deverell AKA Shirtaloon'),
          ('author2@example.com', 'Seth Ring')
        -- add one row per invited author
       ) as v(email, participant_name)
  join auth.users u on u.email = v.email
    on conflict (user_id) do update
       set participant_name = excluded.participant_name;

commit;

-- Verify every invited author got mapped. Rows returned here are accounts that
-- exist but cannot schedule anything — usually an email typo above.
select u.email
  from auth.users u
  left join public.guest_accounts ga on ga.user_id = u.id
 where ga.user_id is null
   and coalesce(u.raw_app_meta_data ->> 'role', '') <> 'admin';
