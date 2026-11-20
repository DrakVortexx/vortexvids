
> vortexvids@0.1.0 db:migrations
> node scripts/db-migrations.mjs

-- sloptube: every migration in supabase/migrations, in order (21 files).

-- ===== 000_init.sql =====
-- 000_init.sql
-- First migration. Creates a small key/value table the app can use for
-- settings and a "the database is alive" check.
-- Safe to run more than once.

create table if not exists public.app_meta (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.app_meta enable row level security;

-- Anyone (signed in or not) may read. Nobody may write through the API;
-- writes happen in the SQL editor or with the service role.
drop policy if exists "app_meta is readable by everyone" on public.app_meta;
create policy "app_meta is readable by everyone"
  on public.app_meta
  for select
  to anon, authenticated
  using (true);

-- ===== 001_feature_flags.sql =====
-- 001_feature_flags.sql
-- Feature flags. Every feature from now on checks a row here so the owner can
-- switch it on step by step:
--   off       hidden for everyone
--   test      only for the user ids listed in "users"
--   everyone  on for all
-- Flip them in the Supabase table editor. Safe to run more than once.

create table if not exists public.feature_flags (
  key text primary key,
  label text not null default '',
  description text not null default '',
  mode text not null default 'off' check (mode in ('off', 'test', 'everyone')),
  users uuid[] not null default '{}',
  updated_at timestamptz not null default now()
);

-- Keep updated_at honest when a flag is flipped.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists feature_flags_touch on public.feature_flags;
create trigger feature_flags_touch
  before update on public.feature_flags
  for each row execute function public.touch_updated_at();

alter table public.feature_flags enable row level security;

-- Everyone may read the flags. There are no insert, update or delete policies,
-- so only the service role (and the dashboard) can change them.
drop policy if exists "feature_flags are readable by everyone" on public.feature_flags;
create policy "feature_flags are readable by everyone"
  on public.feature_flags
  for select
  to anon, authenticated
  using (true);

grant select on public.feature_flags to anon, authenticated;

-- ===== 002_profiles.sql =====
-- 002_profiles.sql
-- Accounts: one public profile per auth user.
--
-- - A trigger creates the profile (with a generated username) when someone signs up.
-- - complete_signup(username, birthdate) confirms the username and records the
--   birthdate. People under 13 are refused.
-- - Everyone can read profiles, but birthdate is not readable through the API.
-- - Owners update their own row (username, display name, avatar, bio only).
-- - Rows are never deleted directly: delete_account() removes the auth user
--   and the profile goes with it.
--
-- Run after 001_feature_flags.sql. Safe to run more than once.

-- Username rules, shared by the table, the trigger and the RPCs.
-- Keep in step with lib/accounts/validation.ts.
create or replace function public.username_is_valid(name text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select name is not null
    and name ~ '^[a-z0-9_]{3,24}$'
    and name not in (
      'admin', 'administrator', 'api', 'auth', 'channel', 'flags', 'help', 'history',
      'library', 'login', 'logout', 'me', 'moderator', 'null', 'root', 'settings',
      'signup', 'sloptube', 'staff', 'subscriptions', 'support', 'system', 'trending',
      'undefined', 'upload', 'watch', 'welcome'
    );
$$;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null,
  display_name text not null default '',
  avatar_url text,
  bio text not null default '',
  birthdate date,
  onboarded boolean not null default false,
  created_at timestamptz not null default now(),
  constraint profiles_username_valid check (public.username_is_valid(username)),
  constraint profiles_display_name_length check (char_length(display_name) <= 50),
  constraint profiles_bio_length check (char_length(bio) <= 1000),
  constraint profiles_avatar_url_https check (avatar_url is null or avatar_url ~ '^https://')
);

-- Usernames are unique without caring about case.
create unique index if not exists profiles_username_lower_key
  on public.profiles (lower(username));

-- Row level security ---------------------------------------------------------

alter table public.profiles enable row level security;

drop policy if exists "profiles are readable by everyone" on public.profiles;
create policy "profiles are readable by everyone"
  on public.profiles
  for select
  to anon, authenticated
  using (true);

drop policy if exists "people update their own profile" on public.profiles;
create policy "people update their own profile"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- No insert or delete policies: the trigger inserts, delete_account() deletes.

-- Column privileges: birthdate and onboarded are never readable or writable
-- through the API, only through the functions below.
revoke all on public.profiles from anon, authenticated;
grant select (id, username, display_name, avatar_url, bio, onboarded, created_at)
  on public.profiles to anon, authenticated;
grant update (username, display_name, avatar_url, bio)
  on public.profiles to authenticated;

-- Helpers --------------------------------------------------------------------

-- Turns an email or a name into a free username like "antic_4821".
create or replace function public.generate_username(seed text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  base text;
  candidate text;
  tries int := 0;
begin
  base := left(regexp_replace(lower(coalesce(seed, '')), '[^a-z0-9_]', '', 'g'), 16);
  if char_length(base) < 3 then
    base := 'user';
  end if;
  loop
    candidate := base || '_' || lpad(floor(random() * 10000)::int::text, 4, '0');
    exit when public.username_is_valid(candidate)
      and not exists (select 1 from public.profiles p where lower(p.username) = candidate);
    tries := tries + 1;
    if tries > 25 then
      candidate := 'user_' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
      exit;
    end if;
  end loop;
  return candidate;
end;
$$;

-- Is this username free for the person asking? Used by the signup and settings forms.
create or replace function public.username_available(name text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select public.username_is_valid(name)
    and not exists (
      select 1 from public.profiles p
      where lower(p.username) = lower(name)
        and p.id is distinct from (select auth.uid())
    );
$$;

grant execute on function public.username_available(text) to anon, authenticated;

-- Age in whole years on a given day.
create or replace function public.age_on(birthdate date, today date default current_date)
returns int
language sql
immutable
set search_path = ''
as $$
  select extract(year from age(today, birthdate))::int;
$$;

-- New user trigger -------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  wanted text := lower(meta ->> 'username');
  claimed_birthdate text := meta ->> 'birthdate';
  chosen text;
  shown text;
  picture text := meta ->> 'avatar_url';
begin
  -- Email sign up sends the birthdate along. Refuse under 13 right away so no
  -- account is created. (Google sign ups confirm it in complete_signup.)
  if claimed_birthdate ~ '^\d{4}-\d{2}-\d{2}$' then
    if public.age_on(claimed_birthdate::date) < 13 then
      raise exception 'too_young' using errcode = 'P0001';
    end if;
  end if;

  if public.username_is_valid(wanted)
     and not exists (select 1 from public.profiles p where lower(p.username) = wanted) then
    chosen := wanted;
  else
    chosen := public.generate_username(
      coalesce(nullif(meta ->> 'full_name', ''), split_part(coalesce(new.email, ''), '@', 1))
    );
  end if;

  shown := left(coalesce(nullif(meta ->> 'full_name', ''), nullif(meta ->> 'name', ''), chosen), 50);

  insert into public.profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    chosen,
    shown,
    case when picture ~ '^https://' then picture else null end
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- RPCs -------------------------------------------------------------------------

-- Finishes sign up: confirms the username and records the birthdate (13+ only).
-- Errors (the message is the code the app shows a friendly text for):
--   not_signed_in, invalid_username, username_taken, birthdate_required,
--   invalid_birthdate, too_young, already_complete
create or replace function public.complete_signup(username text, birthdate date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  wanted text := lower(trim(complete_signup.username));
  current_profile public.profiles;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;

  select * into current_profile from public.profiles p where p.id = me;
  if current_profile.onboarded then
    raise exception 'already_complete' using errcode = 'P0001';
  end if;

  if complete_signup.birthdate is null then
    raise exception 'birthdate_required' using errcode = 'P0001';
  end if;
  if complete_signup.birthdate > current_date or complete_signup.birthdate < date '1900-01-01' then
    raise exception 'invalid_birthdate' using errcode = 'P0001';
  end if;
  if public.age_on(complete_signup.birthdate) < 13 then
    raise exception 'too_young' using errcode = 'P0001';
  end if;

  if not public.username_is_valid(wanted) then
    raise exception 'invalid_username' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles p where lower(p.username) = wanted and p.id <> me) then
    raise exception 'username_taken' using errcode = 'P0001';
  end if;

  if current_profile.id is null then
    -- The trigger did not run (for example a user created before this migration).
    insert into public.profiles (id, username, display_name, birthdate, onboarded)
    values (me, wanted, wanted, complete_signup.birthdate, true);
  else
    update public.profiles p
       set username = wanted,
           birthdate = complete_signup.birthdate,
           onboarded = true
     where p.id = me;
  end if;
end;
$$;

revoke execute on function public.complete_signup(text, date) from public, anon;
grant execute on function public.complete_signup(text, date) to authenticated;

-- Deletes the signed in person's account. The profile row goes with it
-- (on delete cascade). The app removes their avatar files first.
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  delete from auth.users u where u.id = me;
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- Internal helpers are not part of the API.
revoke execute on function public.generate_username(text) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Feature flag ------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'accounts',
  'Accounts',
  'Sign up, sign in, avatar menu and settings. The base for everything else.',
  'everyone'
)
on conflict (key) do nothing;

-- ===== 003_avatars.sql =====
-- 003_avatars.sql
-- Storage bucket for profile pictures.
-- Public read (the files are served from a public URL), 2 MB max,
-- PNG, JPG or WebP. Each person writes only inside their own folder:
--   avatars/<user id>/<file>
-- Run after 002_profiles.sql. Safe to run more than once.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Reading a file by its public URL needs no policy because the bucket is
-- public. This policy only lets people list and replace their own files.
drop policy if exists "avatars: owners can list their files" on storage.objects;
create policy "avatars: owners can list their files"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "avatars: owners can upload" on storage.objects;
create policy "avatars: owners can upload"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "avatars: owners can replace" on storage.objects;
create policy "avatars: owners can replace"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "avatars: owners can delete" on storage.objects;
create policy "avatars: owners can delete"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ===== 004_channels.sql =====
-- 004_channels.sql
-- Channels: every profile owns exactly one channel.
--
-- - A trigger on public.profiles creates the channel, so the sign up path
--   (auth.users -> handle_new_user -> profiles) now also makes a channel.
--   Profiles that already exist get theirs from the backfill below.
-- - Everyone can read channels.
-- - Owners update name, description, links, avatar and banner directly.
-- - The handle only changes through set_channel_handle(), once every 14 days.
-- - subscriber_count and video_count are never writable through the API.
--   Later features update them from security definer functions.
-- - The channel picture follows the profile picture (one picture everywhere).
-- - The public "banners" storage bucket: 6 MB max, PNG, JPG or WebP.
-- - The "channels" feature flag, off until the owner switches it on.
--
-- Run after 003_avatars.sql. Safe to run more than once.

-- Handle rules -----------------------------------------------------------------
-- Keep in step with lib/channels/validation.ts.

-- Returns the rule a handle breaks, or null when it is fine:
-- too_short, too_long, bad_characters, bad_dots, reserved.
create or replace function public.channel_handle_problem(handle text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when handle is null or char_length(handle) < 3 then 'too_short'
    when char_length(handle) > 30 then 'too_long'
    when handle !~ '^[a-z0-9_.]{3,30}$' then 'bad_characters'
    when handle like '.%' or handle like '%.' or position('..' in handle) > 0 then 'bad_dots'
    when handle in (
      'about', 'admin', 'administrator', 'api', 'auth', 'c', 'channel', 'channels', 'embed',
      'feed', 'flags', 'help', 'history', 'home', 'library', 'login', 'logout', 'me',
      'moderator', 'null', 'official', 'playlist', 'results', 'root', 'settings', 'shorts',
      'signup', 'sloptube', 'staff', 'studio', 'subscriptions', 'support', 'system',
      'trending', 'undefined', 'upload', 'user', 'videos', 'watch', 'welcome'
    ) then 'reserved'
    else null
  end;
$$;

create or replace function public.channel_handle_is_valid(handle text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select public.channel_handle_problem(handle) is null;
$$;

-- About links: a JSON array of up to 5 {"title", "url"} objects, https only.
create or replace function public.channel_links_are_valid(links jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(links) = 'array'
    and jsonb_array_length(links) <= 5
    and not exists (
      select 1
      from jsonb_array_elements(links) as l(item)
      where jsonb_typeof(l.item) <> 'object'
         or jsonb_typeof(l.item -> 'title') is distinct from 'string'
         or jsonb_typeof(l.item -> 'url') is distinct from 'string'
         or char_length(l.item ->> 'title') not between 1 and 40
         or char_length(l.item ->> 'url') > 300
         or (l.item ->> 'url') !~* '^https://[^\s/$.?#][^\s]*$'
    );
$$;

-- Table ------------------------------------------------------------------------

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references public.profiles (id) on delete cascade,
  handle text not null,
  name text not null default '',
  description text not null default '',
  links jsonb not null default '[]'::jsonb,
  avatar_url text,
  banner_url text,
  handle_changed_at timestamptz,
  subscriber_count int not null default 0,
  video_count int not null default 0,
  created_at timestamptz not null default now(),
  constraint channels_handle_valid check (public.channel_handle_is_valid(handle)),
  constraint channels_name_length check (char_length(name) <= 50),
  constraint channels_description_length check (char_length(description) <= 1000),
  constraint channels_links_valid check (public.channel_links_are_valid(links)),
  constraint channels_avatar_url_https check (avatar_url is null or avatar_url ~ '^https://'),
  constraint channels_banner_url_https check (banner_url is null or banner_url ~ '^https://'),
  constraint channels_counts_not_negative check (subscriber_count >= 0 and video_count >= 0)
);

-- Handles are unique without caring about case.
create unique index if not exists channels_handle_lower_key
  on public.channels (lower(handle));

-- Row level security -------------------------------------------------------------

alter table public.channels enable row level security;

drop policy if exists "channels are readable by everyone" on public.channels;
create policy "channels are readable by everyone"
  on public.channels
  for select
  to anon, authenticated
  using (true);

drop policy if exists "owners update their own channel" on public.channels;
create policy "owners update their own channel"
  on public.channels
  for update
  to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

-- No insert or delete policies: the trigger inserts, and the channel goes
-- away with the profile (on delete cascade).

-- Column privileges: handle, handle_changed_at and the counts are not
-- writable through the API, only through the functions below.
revoke all on public.channels from anon, authenticated;
grant select (
  id, owner_id, handle, name, description, links, avatar_url, banner_url,
  handle_changed_at, subscriber_count, video_count, created_at
) on public.channels to anon, authenticated;
grant update (name, description, links, avatar_url, banner_url)
  on public.channels to authenticated;

-- Helpers ------------------------------------------------------------------------

-- A free handle based on the seed (usually the username), like "antic" or
-- "antic_4821" when "antic" is taken or reserved.
create or replace function public.generate_channel_handle(seed text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  base text;
  candidate text;
  tries int := 0;
begin
  base := left(regexp_replace(lower(coalesce(seed, '')), '[^a-z0-9_]', '', 'g'), 24);
  if public.channel_handle_is_valid(base)
     and not exists (select 1 from public.channels c where lower(c.handle) = base) then
    return base;
  end if;
  if char_length(base) < 3 then
    base := 'channel';
  end if;
  loop
    candidate := base || '_' || lpad(floor(random() * 10000)::int::text, 4, '0');
    exit when public.channel_handle_is_valid(candidate)
      and not exists (select 1 from public.channels c where lower(c.handle) = candidate);
    tries := tries + 1;
    if tries > 25 then
      candidate := 'channel_' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
      exit;
    end if;
  end loop;
  return candidate;
end;
$$;

-- Creates the channel for a new profile.
create or replace function public.handle_new_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.channels (owner_id, handle, name, avatar_url)
  values (
    new.id,
    public.generate_channel_handle(new.username),
    left(coalesce(nullif(new.display_name, ''), new.username), 50),
    new.avatar_url
  )
  on conflict (owner_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_profile_created on public.profiles;
create trigger on_profile_created
  after insert on public.profiles
  for each row execute function public.handle_new_profile();

-- One picture everywhere: when the profile picture changes, the channel follows.
create or replace function public.sync_channel_avatar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.channels c
     set avatar_url = new.avatar_url
   where c.owner_id = new.id
     and c.avatar_url is distinct from new.avatar_url;
  return new;
end;
$$;

drop trigger if exists on_profile_avatar_changed on public.profiles;
create trigger on_profile_avatar_changed
  after update of avatar_url on public.profiles
  for each row execute function public.sync_channel_avatar();

-- Backfill: a channel for every profile that does not have one yet.
-- One row at a time so each generated handle sees the ones made before it.
do $$
declare
  p record;
begin
  for p in
    select pr.id, pr.username, pr.display_name, pr.avatar_url
    from public.profiles pr
    where not exists (select 1 from public.channels c where c.owner_id = pr.id)
    order by pr.created_at
  loop
    insert into public.channels (owner_id, handle, name, avatar_url)
    values (
      p.id,
      public.generate_channel_handle(p.username),
      left(coalesce(nullif(p.display_name, ''), p.username), 50),
      p.avatar_url
    )
    on conflict (owner_id) do nothing;
  end loop;
end;
$$;

-- RPCs ---------------------------------------------------------------------------

-- Is this handle free for the person asking? Used by the studio form.
create or replace function public.channel_handle_available(handle text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select public.channel_handle_is_valid(lower(handle))
    and not exists (
      select 1 from public.channels c
      where lower(c.handle) = lower(channel_handle_available.handle)
        and c.owner_id is distinct from (select auth.uid())
    );
$$;

grant execute on function public.channel_handle_available(text) to anon, authenticated;

-- Changes the signed in person's handle and returns the new one.
-- The first change is free, then once every 14 days.
-- Errors (the message is the code the app shows a friendly text for):
--   not_signed_in, no_channel, handle_invalid, handle_reserved, handle_taken,
--   handle_cooldown (the detail holds the time of the next allowed change)
create or replace function public.set_channel_handle(new_handle text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  wanted text := lower(trim(both from regexp_replace(coalesce(new_handle, ''), '^\s*@', '')));
  problem text;
  mine public.channels;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;

  select * into mine from public.channels c where c.owner_id = me for update;
  if mine.id is null then
    raise exception 'no_channel' using errcode = 'P0001';
  end if;

  -- Same handle: nothing to do, and no cooldown is used up.
  if lower(mine.handle) = wanted then
    return mine.handle;
  end if;

  problem := public.channel_handle_problem(wanted);
  if problem = 'reserved' then
    raise exception 'handle_reserved' using errcode = 'P0001';
  elsif problem is not null then
    raise exception 'handle_invalid' using errcode = 'P0001', detail = problem;
  end if;

  if mine.handle_changed_at is not null and mine.handle_changed_at + interval '14 days' > now() then
    raise exception 'handle_cooldown' using
      errcode = 'P0001',
      detail = to_char((mine.handle_changed_at + interval '14 days') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;

  if exists (select 1 from public.channels c where lower(c.handle) = wanted and c.id <> mine.id) then
    raise exception 'handle_taken' using errcode = 'P0001';
  end if;

  begin
    update public.channels c
       set handle = wanted,
           handle_changed_at = now()
     where c.id = mine.id;
  exception when unique_violation then
    -- Someone took it in the same moment.
    raise exception 'handle_taken' using errcode = 'P0001';
  end;

  return wanted;
end;
$$;

revoke execute on function public.set_channel_handle(text) from public, anon;
grant execute on function public.set_channel_handle(text) to authenticated;

-- Internal helpers are not part of the API.
revoke execute on function public.generate_channel_handle(text) from public, anon, authenticated;
revoke execute on function public.handle_new_profile() from public, anon, authenticated;
revoke execute on function public.sync_channel_avatar() from public, anon, authenticated;

-- Banners bucket -------------------------------------------------------------------
-- Public read, 6 MB max. Each person writes only inside their own folder:
--   banners/<user id>/<file>

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('banners', 'banners', true, 6291456, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "banners: owners can list their files" on storage.objects;
create policy "banners: owners can list their files"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'banners'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "banners: owners can upload" on storage.objects;
create policy "banners: owners can upload"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'banners'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "banners: owners can replace" on storage.objects;
create policy "banners: owners can replace"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'banners'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'banners'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "banners: owners can delete" on storage.objects;
create policy "banners: owners can delete"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'banners'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'channels',
  'Channels',
  'Channel pages at /@handle and channel editing in /studio/channel.',
  'off'
)
on conflict (key) do nothing;

-- ===== 005_videos.sql =====
-- 005_videos.sql
-- Videos and the upload RPCs.
--
-- - One row per uploaded video. The file itself lives in Cloudflare R2; the
--   row only holds its object key, size and type. The app server never
--   touches the bytes: the browser uploads straight to R2 with presigned URLs.
-- - Public and ready videos are readable by everyone. Owners read all of
--   their own videos, whatever the status or visibility.
-- - There are no insert, update or delete policies. Rows change only through
--   the security definer functions below:
--     create_upload(title, bytes, mime)    starts an upload, returns id and key
--     finish_upload(video_id)              the file is in R2: status uploaded
--     abandon_upload(video_id, reason)     cancelled or broken: status failed
--     update_upload_details(video_id, title, description, visibility)
-- - channels.video_count is not touched here. A later feature bumps it when a
--   video becomes public and ready.
-- - The "upload" feature flag, off until the owner switches it on.
--
-- Run after 004_channels.sql. Safe to run more than once.

-- Rules ------------------------------------------------------------------------
-- Keep in step with lib/upload/rules.ts.

-- The file extension for an accepted video type, or null when the type is not
-- accepted: mp4, mov, webm and mkv only.
create or replace function public.video_extension_for(mime text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case mime
    when 'video/mp4' then 'mp4'
    when 'video/quicktime' then 'mov'
    when 'video/webm' then 'webm'
    when 'video/x-matroska' then 'mkv'
    else null
  end;
$$;

-- Table --------------------------------------------------------------------------

create table if not exists public.videos (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels (id) on delete cascade,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  description text not null default '',
  visibility text not null default 'private',
  status text not null default 'uploading',
  source_key text,
  source_bytes bigint,
  source_mime text,
  duration_s numeric,
  width int,
  height int,
  thumbnail_url text,
  hls_key text,
  error text,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint videos_title_length check (char_length(title) between 1 and 100),
  constraint videos_description_length check (char_length(description) <= 5000),
  constraint videos_visibility_valid check (visibility in ('private', 'unlisted', 'public')),
  constraint videos_status_valid check (status in ('uploading', 'uploaded', 'processing', 'ready', 'failed')),
  constraint videos_source_bytes_range check (source_bytes is null or source_bytes between 1 and 2147483648),
  constraint videos_source_mime_valid check (source_mime is null or public.video_extension_for(source_mime) is not null),
  constraint videos_thumbnail_url_https check (thumbnail_url is null or thumbnail_url ~ '^https://')
);

create index if not exists videos_owner_created_idx on public.videos (owner_id, created_at desc);
create index if not exists videos_channel_created_idx on public.videos (channel_id, created_at desc);
create index if not exists videos_public_ready_idx on public.videos (published_at desc)
  where visibility = 'public' and status = 'ready';

drop trigger if exists videos_touch on public.videos;
create trigger videos_touch
  before update on public.videos
  for each row execute function public.touch_updated_at();

-- Row level security -------------------------------------------------------------

alter table public.videos enable row level security;

drop policy if exists "public ready videos are readable by everyone" on public.videos;
create policy "public ready videos are readable by everyone"
  on public.videos
  for select
  to anon, authenticated
  using (visibility = 'public' and status = 'ready');

drop policy if exists "owners read their own videos" on public.videos;
create policy "owners read their own videos"
  on public.videos
  for select
  to authenticated
  using ((select auth.uid()) = owner_id);

-- Read only through the API. Every change goes through the functions below.
revoke all on public.videos from anon, authenticated;
grant select on public.videos to anon, authenticated;

-- Helpers --------------------------------------------------------------------------

-- Is the upload flag on for this person? Same rules as lib/flags-core.ts.
create or replace function public.upload_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'upload'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- RPCs -------------------------------------------------------------------------------

-- Starts an upload for the signed in person and returns the new video id and
-- the R2 object key the file must be uploaded to:
--   uploads/<owner id>/<video id>/source.<ext>
-- Errors (the message is the code the app shows a friendly text for):
--   not_signed_in, upload_off, not_onboarded, too_young, no_channel,
--   title_invalid, file_empty, file_too_big, bad_type, daily_limit
create or replace function public.create_upload(title text, bytes bigint, mime text)
returns table (video_id uuid, source_key text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  me_profile public.profiles;
  my_channel uuid;
  clean_title text := trim(both from coalesce(create_upload.title, ''));
  ext text := public.video_extension_for(create_upload.mime);
  recent int;
  new_id uuid := gen_random_uuid();
  new_key text;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.upload_flag_on(me) then
    raise exception 'upload_off' using errcode = 'P0001';
  end if;

  select * into me_profile from public.profiles p where p.id = me;
  if me_profile.id is null or not me_profile.onboarded or me_profile.birthdate is null then
    raise exception 'not_onboarded' using errcode = 'P0001';
  end if;
  if public.age_on(me_profile.birthdate) < 13 then
    raise exception 'too_young' using errcode = 'P0001';
  end if;

  select c.id into my_channel from public.channels c where c.owner_id = me;
  if my_channel is null then
    raise exception 'no_channel' using errcode = 'P0001';
  end if;

  if char_length(clean_title) not between 1 and 100 then
    raise exception 'title_invalid' using errcode = 'P0001';
  end if;
  if create_upload.bytes is null or create_upload.bytes < 1 then
    raise exception 'file_empty' using errcode = 'P0001';
  end if;
  if create_upload.bytes > 2147483648 then
    raise exception 'file_too_big' using errcode = 'P0001';
  end if;
  if ext is null then
    raise exception 'bad_type' using errcode = 'P0001';
  end if;

  -- One upload start at a time per person, so the daily count cannot be raced.
  perform pg_advisory_xact_lock(hashtextextended('create_upload:' || me::text, 0));
  select count(*) into recent
    from public.videos v
   where v.owner_id = me
     and v.created_at > now() - interval '24 hours';
  if recent >= 10 then
    raise exception 'daily_limit' using errcode = 'P0001';
  end if;

  new_key := 'uploads/' || me::text || '/' || new_id::text || '/source.' || ext;
  insert into public.videos (id, channel_id, owner_id, title, source_key, source_bytes, source_mime)
  values (new_id, my_channel, me, clean_title, new_key, create_upload.bytes, create_upload.mime);

  return query select new_id, new_key;
end;
$$;

-- The file is complete in R2 (the app checked its size): status uploaded.
-- Errors: not_signed_in, not_found, not_uploading
create or replace function public.finish_upload(video_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  current_status text;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  select v.status into current_status
    from public.videos v
   where v.id = finish_upload.video_id and v.owner_id = me
   for update;
  if current_status is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if current_status = 'uploaded' then
    return 'uploaded';
  end if;
  if current_status <> 'uploading' then
    raise exception 'not_uploading' using errcode = 'P0001';
  end if;
  update public.videos v
     set status = 'uploaded', error = null
   where v.id = finish_upload.video_id;
  return 'uploaded';
end;
$$;

-- The upload was cancelled or broke: status failed, with a short reason.
-- Only an upload that has not finished can be abandoned.
-- Errors: not_signed_in, not_found, not_uploading
create or replace function public.abandon_upload(video_id uuid, reason text default 'cancelled')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  current_status text;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  select v.status into current_status
    from public.videos v
   where v.id = abandon_upload.video_id and v.owner_id = me
   for update;
  if current_status is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if current_status = 'failed' then
    return 'failed';
  end if;
  if current_status <> 'uploading' then
    raise exception 'not_uploading' using errcode = 'P0001';
  end if;
  update public.videos v
     set status = 'failed', error = left(coalesce(nullif(trim(both from reason), ''), 'cancelled'), 200)
   where v.id = abandon_upload.video_id;
  return 'failed';
end;
$$;

-- Title, description and visibility from the upload form.
-- Errors: not_signed_in, not_found, title_invalid, description_too_long, bad_visibility
create or replace function public.update_upload_details(
  video_id uuid,
  title text,
  description text,
  visibility text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  clean_title text := trim(both from coalesce(update_upload_details.title, ''));
  clean_description text := coalesce(update_upload_details.description, '');
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if char_length(clean_title) not between 1 and 100 then
    raise exception 'title_invalid' using errcode = 'P0001';
  end if;
  if char_length(clean_description) > 5000 then
    raise exception 'description_too_long' using errcode = 'P0001';
  end if;
  if update_upload_details.visibility not in ('private', 'unlisted', 'public') then
    raise exception 'bad_visibility' using errcode = 'P0001';
  end if;
  update public.videos v
     set title = clean_title,
         description = clean_description,
         visibility = update_upload_details.visibility
   where v.id = update_upload_details.video_id and v.owner_id = me;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;

revoke execute on function public.create_upload(text, bigint, text) from public, anon;
revoke execute on function public.finish_upload(uuid) from public, anon;
revoke execute on function public.abandon_upload(uuid, text) from public, anon;
revoke execute on function public.update_upload_details(uuid, text, text, text) from public, anon;
grant execute on function public.create_upload(text, bigint, text) to authenticated;
grant execute on function public.finish_upload(uuid) to authenticated;
grant execute on function public.abandon_upload(uuid, text) to authenticated;
grant execute on function public.update_upload_details(uuid, text, text, text) to authenticated;

-- Internal helpers are not part of the API.
revoke execute on function public.upload_flag_on(uuid) from public, anon, authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'upload',
  'Upload',
  'The /upload page, uploads to R2 and the /studio/videos list.',
  'off'
)
on conflict (key) do nothing;

-- ===== 006_processing.sql =====
-- 006_processing.sql
-- Video processing: the encode job queue and the functions the encoder worker
-- (worker/, running on its own box) calls with the service role key.
--
-- - One row in public.encode_jobs per video. A trigger queues a job when a
--   video's status becomes 'uploaded' (finish_upload in 005). Videos that are
--   already 'uploaded' when this file runs get a job from the backfill below.
-- - Owners can read the job of their own videos (the studio shows progress).
--   Nobody can write jobs through the API: only the functions below change them,
--   and only the service role may call them.
--     claim_encode_job(worker)             next queued job, marks it running
--     encode_progress(job_id, pct)         0 to 100 while it runs
--     encode_done(job_id, duration_s, width, height, hls_key, thumbnail_url,
--                 preview_sprite_key, renditions)
--                                          the video is ready
--     encode_failed(job_id, error, retry)  tried again up to 3 attempts, then
--                                          the video is failed
-- - New columns on videos: renditions (jsonb) and preview_sprite_key.
-- - channels.video_count now counts public and ready videos. A trigger keeps it
--   right when a video becomes ready, changes visibility or is deleted, and
--   sets published_at the first time a video is public and ready.
-- - The "processing" feature flag, off until the owner switches it on. While it
--   is off the worker claims nothing. In test mode it only processes videos of
--   the listed users.
--
-- Run after 005_videos.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------
-- Keep in step with worker/lib/limits.mjs.

-- How many times a job is tried before the video is marked failed.
create or replace function public.encode_max_attempts()
returns int
language sql
immutable
set search_path = ''
as $$ select 3 $$;

-- A running job older than this is treated as a crashed worker and tried again.
-- The worker itself stops a job after 2 hours.
create or replace function public.encode_stale_after()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '2 hours 15 minutes' $$;

-- New columns on videos ------------------------------------------------------------

alter table public.videos add column if not exists renditions jsonb;
alter table public.videos add column if not exists preview_sprite_key text;

alter table public.videos drop constraint if exists videos_renditions_array;
alter table public.videos add constraint videos_renditions_array
  check (renditions is null or jsonb_typeof(renditions) = 'array');

-- The new columns are readable like the rest of the row (005 granted select on
-- the whole table, which covers columns added later).

-- Jobs table -------------------------------------------------------------------------

create table if not exists public.encode_jobs (
  id uuid primary key default gen_random_uuid(),
  video_id uuid not null unique references public.videos (id) on delete cascade,
  status text not null default 'queued',
  attempts int not null default 0,
  worker text,
  started_at timestamptz,
  finished_at timestamptz,
  error text,
  progress int not null default 0,
  created_at timestamptz not null default now(),
  constraint encode_jobs_status_valid check (status in ('queued', 'running', 'done', 'failed')),
  constraint encode_jobs_progress_range check (progress between 0 and 100),
  constraint encode_jobs_attempts_range check (attempts >= 0)
);

create index if not exists encode_jobs_queued_idx on public.encode_jobs (created_at)
  where status = 'queued';
create index if not exists encode_jobs_running_idx on public.encode_jobs (worker)
  where status = 'running';

alter table public.encode_jobs enable row level security;

drop policy if exists "owners read the jobs of their own videos" on public.encode_jobs;
create policy "owners read the jobs of their own videos"
  on public.encode_jobs
  for select
  to authenticated
  using (
    exists (
      select 1 from public.videos v
      where v.id = encode_jobs.video_id and v.owner_id = (select auth.uid())
    )
  );

revoke all on public.encode_jobs from anon, authenticated;
grant select on public.encode_jobs to authenticated;

-- Queue a job when a video is uploaded ----------------------------------------------------

create or replace function public.queue_encode_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'uploaded' and (tg_op = 'INSERT' or old.status is distinct from 'uploaded') then
    insert into public.encode_jobs (video_id)
    values (new.id)
    on conflict (video_id) do update
      set status = 'queued',
          attempts = 0,
          progress = 0,
          worker = null,
          error = null,
          started_at = null,
          finished_at = null
      -- Only a finished job starts over. A queued or running one is left alone.
      where public.encode_jobs.status in ('done', 'failed');
  end if;
  return new;
end;
$$;

drop trigger if exists videos_queue_encode on public.videos;
create trigger videos_queue_encode
  after insert or update of status on public.videos
  for each row execute function public.queue_encode_job();

-- Backfill: videos that finished uploading before this migration.
insert into public.encode_jobs (video_id)
select v.id from public.videos v where v.status = 'uploaded'
on conflict (video_id) do nothing;

-- published_at and channels.video_count ----------------------------------------------------

-- The first time a video is public and ready, it gets its published_at.
create or replace function public.videos_set_published_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.visibility = 'public' and new.status = 'ready' and new.published_at is null then
    new.published_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists videos_published_at on public.videos;
create trigger videos_published_at
  before insert or update of status, visibility on public.videos
  for each row execute function public.videos_set_published_at();

-- channels.video_count is the number of public and ready videos.
create or replace function public.videos_count_public()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  was_counted boolean := tg_op <> 'INSERT' and old.visibility = 'public' and old.status = 'ready';
  is_counted boolean := tg_op <> 'DELETE' and new.visibility = 'public' and new.status = 'ready';
begin
  if was_counted and not is_counted then
    update public.channels c set video_count = greatest(c.video_count - 1, 0) where c.id = old.channel_id;
  elsif is_counted and not was_counted then
    update public.channels c set video_count = c.video_count + 1 where c.id = new.channel_id;
  end if;
  return null;
end;
$$;

drop trigger if exists videos_count_public on public.videos;
create trigger videos_count_public
  after insert or update of status, visibility or delete on public.videos
  for each row execute function public.videos_count_public();

-- Recount once, so the counts are right whatever happened before this file.
update public.channels c
   set video_count = coalesce((
     select count(*) from public.videos v
      where v.channel_id = c.id and v.visibility = 'public' and v.status = 'ready'
   ), 0)
 where c.video_count is distinct from coalesce((
     select count(*) from public.videos v
      where v.channel_id = c.id and v.visibility = 'public' and v.status = 'ready'
   ), 0);

-- Helpers ---------------------------------------------------------------------------------

-- Is the processing flag on for this video owner? Same rules as lib/flags-core.ts.
create or replace function public.processing_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'processing'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Ends a running attempt that will not finish: queued again while attempts are
-- left, otherwise the job and its video are failed.
create or replace function public.encode_give_up_attempt(job public.encode_jobs, reason text, retry boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_reason text := left(coalesce(nullif(trim(both from reason), ''), 'encode failed'), 200);
begin
  if retry and job.attempts < public.encode_max_attempts() then
    update public.encode_jobs j
       set status = 'queued', progress = 0, worker = null, error = clean_reason, finished_at = null
     where j.id = job.id;
    -- The video stays 'processing' while it waits for the next attempt.
    return 'queued';
  end if;
  update public.encode_jobs j
     set status = 'failed', error = clean_reason, finished_at = now()
   where j.id = job.id;
  update public.videos v
     set status = 'failed', error = clean_reason
   where v.id = job.video_id;
  return 'failed';
end;
$$;

-- Worker RPCs -------------------------------------------------------------------------------

-- Hands the next queued job to this worker and marks it running, or returns no
-- row when there is nothing to do. Jobs are handed out oldest first, one at a
-- time: two workers never get the same job (for update skip locked).
-- Before that it cleans up:
--   - jobs this worker left running (it only asks when it is idle, so they died
--     with a crash or a restart)
--   - jobs any worker left running longer than encode_stale_after()
create or replace function public.claim_encode_job(worker text)
returns table (
  job_id uuid,
  video_id uuid,
  owner_id uuid,
  source_key text,
  source_bytes bigint,
  source_mime text,
  attempt int
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me text := left(coalesce(nullif(trim(both from claim_encode_job.worker), ''), 'worker'), 100);
  dead public.encode_jobs;
  next_job public.encode_jobs;
  vid public.videos;
begin
  for dead in
    select * from public.encode_jobs j
     where j.status = 'running'
       and (j.worker = me or j.started_at < now() - public.encode_stale_after())
     for update skip locked
  loop
    perform public.encode_give_up_attempt(dead, 'the worker stopped during the encode', true);
  end loop;

  select j.* into next_job
    from public.encode_jobs j
    join public.videos v on v.id = j.video_id
   where j.status = 'queued'
     and v.status in ('uploaded', 'processing')
     and v.source_key is not null
     and public.processing_flag_on(v.owner_id)
   order by j.created_at
   limit 1
   for update of j skip locked;

  if next_job.id is null then
    return;
  end if;

  update public.encode_jobs j
     set status = 'running',
         attempts = j.attempts + 1,
         worker = me,
         started_at = now(),
         finished_at = null,
         progress = 0
   where j.id = next_job.id
  returning * into next_job;

  update public.videos v
     set status = 'processing', error = null
   where v.id = next_job.video_id
  returning * into vid;

  return query select next_job.id, vid.id, vid.owner_id, vid.source_key, vid.source_bytes, vid.source_mime,
                      next_job.attempts;
end;
$$;

-- Progress of a running job, 0 to 100. Returns false when the job is no longer
-- running (for example it was taken back as stale), so the worker can stop.
create or replace function public.encode_progress(job_id uuid, pct int)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.encode_jobs j
     set progress = greatest(0, least(100, coalesce(encode_progress.pct, 0)))
   where j.id = encode_progress.job_id and j.status = 'running';
  return found;
end;
$$;

-- The encode worked: the video is ready. published_at and the channel's
-- video_count follow from the triggers above when the video is public.
-- Errors: not_found, not_running, bad_renditions
create or replace function public.encode_done(
  job_id uuid,
  duration_s numeric,
  width int,
  height int,
  hls_key text,
  thumbnail_url text,
  preview_sprite_key text,
  renditions jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  job public.encode_jobs;
begin
  select * into job from public.encode_jobs j where j.id = encode_done.job_id for update;
  if job.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if job.status = 'done' then
    return 'done';
  end if;
  if job.status <> 'running' then
    raise exception 'not_running' using errcode = 'P0001';
  end if;
  if encode_done.renditions is null or jsonb_typeof(encode_done.renditions) <> 'array'
     or jsonb_array_length(encode_done.renditions) = 0 then
    raise exception 'bad_renditions' using errcode = 'P0001';
  end if;

  update public.encode_jobs j
     set status = 'done', progress = 100, error = null, finished_at = now()
   where j.id = job.id;

  update public.videos v
     set status = 'ready',
         duration_s = encode_done.duration_s,
         width = encode_done.width,
         height = encode_done.height,
         hls_key = encode_done.hls_key,
         thumbnail_url = nullif(encode_done.thumbnail_url, ''),
         preview_sprite_key = encode_done.preview_sprite_key,
         renditions = encode_done.renditions,
         error = null,
         published_at = case
           when v.visibility = 'public' then coalesce(v.published_at, now())
           else v.published_at
         end
   where v.id = job.video_id;
  return 'done';
end;
$$;

-- The encode broke. With retry (the default) the job goes back in the queue
-- until it has had encode_max_attempts() attempts; then, or right away with
-- retry = false (for example a source that does not match its size), the job
-- and the video are failed. Returns 'queued' or 'failed'.
-- Errors: not_found, not_running
create or replace function public.encode_failed(job_id uuid, error text, retry boolean default true)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  job public.encode_jobs;
begin
  select * into job from public.encode_jobs j where j.id = encode_failed.job_id for update;
  if job.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if job.status = 'failed' then
    return 'failed';
  end if;
  if job.status <> 'running' then
    raise exception 'not_running' using errcode = 'P0001';
  end if;
  return public.encode_give_up_attempt(job, encode_failed.error, coalesce(encode_failed.retry, true));
end;
$$;

-- Only the service role (the worker) calls these. Nobody calls the helpers.
revoke execute on function public.claim_encode_job(text) from public, anon, authenticated;
revoke execute on function public.encode_progress(uuid, int) from public, anon, authenticated;
revoke execute on function public.encode_done(uuid, numeric, int, int, text, text, text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.encode_failed(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.encode_give_up_attempt(public.encode_jobs, text, boolean)
  from public, anon, authenticated;
revoke execute on function public.processing_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.queue_encode_job() from public, anon, authenticated;
revoke execute on function public.videos_count_public() from public, anon, authenticated;

grant execute on function public.claim_encode_job(text) to service_role;
grant execute on function public.encode_progress(uuid, int) to service_role;
grant execute on function public.encode_done(uuid, numeric, int, int, text, text, text, jsonb) to service_role;
grant execute on function public.encode_failed(uuid, text, boolean) to service_role;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'processing',
  'Processing',
  'The encoder worker turns uploads into HLS, thumbnails and a preview sprite. Studio shows progress.',
  'off'
)
on conflict (key) do nothing;

-- ===== 007_watch.sql =====
-- 007_watch.sql
-- The watch page: a views column and the watch_video() function.
--
-- - videos.views (bigint, 0 for every video). Counting views arrives with
--   feature 9; the watch page already shows the number.
-- - watch_video(video_id) returns what /watch and /api/media need about one
--   video, in one call, without opening the videos table to more people:
--     - public and unlisted videos: a row for everyone. While the video is
--       not ready the playback fields (hls_key, renditions, the sprite) are
--       null, so the page can say "This video is being processed".
--     - private videos: a row for the owner only. Anybody else gets no row,
--       the same as a video that does not exist.
--     - the owner gets every field in every state, plus is_owner = true.
--   Unlisted videos are not readable through the videos table (005 only
--   opens public and ready ones), so this function is security definer and
--   does the visibility check itself.
-- - The "watch" feature flag, off until the owner switches it on. While it
--   is off /watch keeps the feature 4 stub.
--
-- Run after 006_processing.sql. Safe to run more than once.

-- New column -------------------------------------------------------------------------

alter table public.videos add column if not exists views bigint not null default 0;

alter table public.videos drop constraint if exists videos_views_positive;
alter table public.videos add constraint videos_views_positive check (views >= 0);

-- Readable like the rest of the row (005 granted select on the whole table).

-- RPC ----------------------------------------------------------------------------------

-- The return type changes the function signature, so drop an older shape first.
drop function if exists public.watch_video(uuid);

create function public.watch_video(video_id uuid)
returns table (
  id uuid,
  title text,
  description text,
  visibility text,
  status text,
  is_owner boolean,
  created_at timestamptz,
  published_at timestamptz,
  duration_s numeric,
  width int,
  height int,
  views bigint,
  renditions jsonb,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text,
  channel_subscriber_count int
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    v.id,
    v.title,
    v.description,
    v.visibility,
    v.status,
    mine.yes,
    v.created_at,
    v.published_at,
    v.duration_s,
    v.width,
    v.height,
    v.views,
    case when playable.yes then v.renditions end,
    case when playable.yes then v.thumbnail_url end,
    case when playable.yes then v.hls_key end,
    case when playable.yes then v.preview_sprite_key end,
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url,
    c.subscriber_count
  from public.videos v
  join public.channels c on c.id = v.channel_id
  cross join lateral (select coalesce(v.owner_id = (select auth.uid()), false) as yes) mine
  cross join lateral (select v.status = 'ready' or mine.yes as yes) playable
  where v.id = watch_video.video_id
    and (mine.yes or v.visibility in ('public', 'unlisted'));
$$;

revoke execute on function public.watch_video(uuid) from public;
grant execute on function public.watch_video(uuid) to anon, authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'watch',
  'Watch page',
  'The /watch page with the HLS player, and /api/media for its files.',
  'off'
)
on conflict (key) do nothing;

-- ===== 008_feed.sql =====
-- 008_feed.sql
-- The home feed: feed_videos() and related_videos(), an index, the feed flag.
--
-- - feed_videos(kind, cursor, cursor_id, lim, for_channel) returns video cards
--   for public and ready videos only:
--     'newest'    every channel, newest first
--     'trending'  published in the last 30 days, ranked by
--                 views / hours_since_publish ^ 1.5 (hours at least 1).
--                 Computed on the fly; no cursor, the page shows the top 50.
--     'channel'   one channel (for_channel), newest first
--   'newest' and 'channel' page by keyset on (published_at, id): pass the
--   last card's published_at and id as cursor and cursor_id for the next page.
-- - related_videos(video_id, lim) for Up next on the watch page: the same
--   channel first, then the newest from everybody, never the video itself.
-- - The channel parameter is called for_channel because channel_id is one of
--   the returned columns, and Postgres wants every name to be unique.
-- - Both only return public and ready videos. feed_videos runs as the caller,
--   so the row level security from 005 applies. related_videos is security
--   definer only to read the channel of an unlisted video (the watch page
--   already shows that channel to anybody with the link); private videos of
--   other people give no channel, so nothing about them leaks.
-- - The "feed" feature flag, off until the owner switches it on. While it is
--   off / and /trending keep the placeholder grid.
--
-- Keep the score in step with trendingScore() in lib/feed/score.ts.
--
-- Run after 007_watch.sql. Safe to run more than once.

-- Indexes ------------------------------------------------------------------------------

-- The feed's keyset: newest public and ready videos first.
create index if not exists videos_feed_idx
  on public.videos (visibility, status, published_at desc, id desc);

-- A channel's Videos tab, and "same channel first" in Up next.
create index if not exists videos_channel_feed_idx
  on public.videos (channel_id, published_at desc, id desc)
  where visibility = 'public' and status = 'ready';

-- RPCs ---------------------------------------------------------------------------------

-- The return type is part of the signature, so drop older shapes first.
drop function if exists public.feed_videos(text, timestamptz, uuid, int, uuid);
drop function if exists public.related_videos(uuid, int);

create function public.feed_videos(
  kind text default 'newest',
  cursor timestamptz default null,
  cursor_id uuid default null,
  lim int default 24,
  for_channel uuid default null
)
returns table (
  id uuid,
  title text,
  duration_s numeric,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  published_at timestamptz,
  views bigint,
  score double precision,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with args as (
    select
      coalesce(feed_videos.kind, 'newest') as kind,
      least(greatest(coalesce(feed_videos.lim, 24), 1), 50) as lim
  ),
  cards as (
    select
      v.id,
      v.title,
      v.duration_s,
      v.thumbnail_url,
      v.hls_key,
      v.preview_sprite_key,
      v.published_at,
      v.views,
      v.views::double precision
        / power(greatest(extract(epoch from (now() - v.published_at)) / 3600.0, 1.0), 1.5) as score,
      c.id as channel_id,
      c.handle as channel_handle,
      coalesce(nullif(c.name, ''), c.handle) as channel_name,
      c.avatar_url as channel_avatar_url
    from public.videos v
    join public.channels c on c.id = v.channel_id
    cross join args a
    where v.visibility = 'public'
      and v.status = 'ready'
      and v.published_at is not null
      and case a.kind
        when 'newest' then true
        when 'trending' then v.published_at > now() - interval '30 days'
        when 'channel' then v.channel_id = feed_videos.for_channel
        else false
      end
      and (
        a.kind = 'trending'
        or feed_videos.cursor is null
        or (v.published_at, v.id) < (feed_videos.cursor, coalesce(feed_videos.cursor_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
      )
  )
  select cards.*
  from cards
  cross join args a
  order by
    case when a.kind = 'trending' then cards.score end desc nulls last,
    cards.published_at desc,
    cards.id desc
  limit (select lim from args);
$$;

revoke execute on function public.feed_videos(text, timestamptz, uuid, int, uuid) from public;
grant execute on function public.feed_videos(text, timestamptz, uuid, int, uuid) to anon, authenticated;

create function public.related_videos(video_id uuid, lim int default 12)
returns table (
  id uuid,
  title text,
  duration_s numeric,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  published_at timestamptz,
  views bigint,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text
)
language sql
stable
security definer
set search_path = ''
as $$
  with current_video as (
    -- The channel of the video being watched, when the caller may see it.
    select v.channel_id
    from public.videos v
    where v.id = related_videos.video_id
      and (v.visibility in ('public', 'unlisted') or v.owner_id = (select auth.uid()))
  )
  select
    v.id,
    v.title,
    v.duration_s,
    v.thumbnail_url,
    v.hls_key,
    v.preview_sprite_key,
    v.published_at,
    v.views,
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url
  from public.videos v
  join public.channels c on c.id = v.channel_id
  where v.visibility = 'public'
    and v.status = 'ready'
    and v.published_at is not null
    and v.id <> related_videos.video_id
  order by
    (v.channel_id = (select cv.channel_id from current_video cv)) desc nulls last,
    v.published_at desc,
    v.id desc
  limit least(greatest(coalesce(related_videos.lim, 12), 1), 50);
$$;

revoke execute on function public.related_videos(uuid, int) from public;
grant execute on function public.related_videos(uuid, int) to anon, authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'feed',
  'Home feed',
  'The home grid, /trending, the Videos tab on channel pages and Up next from the feed.',
  'off'
)
on conflict (key) do nothing;

-- ===== 009_subscriptions.sql =====
-- 009_subscriptions.sql
-- Subscriptions: subscribe to channels, the bell, the subscriptions feed.
--
-- - public.subscriptions: one row per (subscriber, channel), with notify (the
--   bell) on by default. A person reads only their own rows. Writes go through
--   the functions below, which check the flag and the rate limit; the policies
--   still only allow a person's own rows, in case direct writes are ever granted.
-- - Nobody subscribes to their own channel (checked by the functions and by a
--   trigger on the table).
-- - channels.subscriber_count is kept right by a trigger on insert and delete,
--   with a one time recount below. Channel owners (and everybody else) only
--   ever see that count, never who subscribed.
-- - subscribe(channel_id), unsubscribe(channel_id), set_notify(channel_id, on)
--   each answer the new state: subscribed, notify, subscriber_count.
--   Errors (the message is the code the app shows a friendly text for):
--     not_signed_in, subscriptions_off, not_found, own_channel, rate_limited,
--     not_subscribed (set_notify only). unsubscribe works with the flag off,
--     so people can always leave.
-- - At most 60 changes (subscribe, unsubscribe, bell) per hour per person,
--   counted in public.subscription_changes. Repeating the current state is free.
-- - my_subscriptions() lists the signed in person's channels for the guide:
--   picture, name, handle, the latest upload time and an unseen count (0 for
--   now, a placeholder for a later feature).
-- - subscriptions_feed(cursor, cursor_id, lim, only_notify) returns public and
--   ready videos from subscribed channels, newest first, with the same keyset
--   on (published_at, id) and the same columns as feed_videos (no score).
--   only_notify keeps channels with the bell on, for the notifications menu.
-- - The "subscriptions" feature flag, off until the owner switches it on.
--
-- Keep the rate limit in step with lib/subscriptions/rules.ts.
--
-- Run after 008_feed.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.subscription_changes_per_hour()
returns int
language sql
immutable
set search_path = ''
as $$ select 60 $$;

create or replace function public.subscriptions_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'subscriptions'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Tables ---------------------------------------------------------------------------------

create table if not exists public.subscriptions (
  subscriber_id uuid not null references public.profiles (id) on delete cascade,
  channel_id uuid not null references public.channels (id) on delete cascade,
  notify boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (subscriber_id, channel_id)
);

-- Counting a channel's subscribers, and deleting a channel.
create index if not exists subscriptions_channel_idx on public.subscriptions (channel_id);

alter table public.subscriptions enable row level security;

drop policy if exists "people read their own subscriptions" on public.subscriptions;
create policy "people read their own subscriptions"
  on public.subscriptions
  for select
  to authenticated
  using (subscriber_id = (select auth.uid()));

drop policy if exists "people add their own subscriptions" on public.subscriptions;
create policy "people add their own subscriptions"
  on public.subscriptions
  for insert
  to authenticated
  with check (subscriber_id = (select auth.uid()));

drop policy if exists "people change their own subscriptions" on public.subscriptions;
create policy "people change their own subscriptions"
  on public.subscriptions
  for update
  to authenticated
  using (subscriber_id = (select auth.uid()))
  with check (subscriber_id = (select auth.uid()));

drop policy if exists "people remove their own subscriptions" on public.subscriptions;
create policy "people remove their own subscriptions"
  on public.subscriptions
  for delete
  to authenticated
  using (subscriber_id = (select auth.uid()));

-- Reads only through the API. Writes go through the functions, so the flag
-- and the rate limit cannot be skipped.
revoke all on public.subscriptions from anon, authenticated;
grant select on public.subscriptions to authenticated;

-- One row per change, for the rate limit. Nobody reads it through the API.
create table if not exists public.subscription_changes (
  subscriber_id uuid not null references public.profiles (id) on delete cascade,
  at timestamptz not null default now()
);

create index if not exists subscription_changes_recent_idx
  on public.subscription_changes (subscriber_id, at desc);

alter table public.subscription_changes enable row level security;
revoke all on public.subscription_changes from anon, authenticated;

-- No subscribing to your own channel -----------------------------------------------------

create or replace function public.subscriptions_not_own_channel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.channels c
    where c.id = new.channel_id and c.owner_id = new.subscriber_id
  ) then
    raise exception 'own_channel' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists subscriptions_not_own_channel on public.subscriptions;
create trigger subscriptions_not_own_channel
  before insert or update of channel_id, subscriber_id on public.subscriptions
  for each row execute function public.subscriptions_not_own_channel();

-- channels.subscriber_count ----------------------------------------------------------------

create or replace function public.subscriptions_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.channels c set subscriber_count = c.subscriber_count + 1 where c.id = new.channel_id;
  elsif tg_op = 'DELETE' then
    update public.channels c set subscriber_count = greatest(c.subscriber_count - 1, 0) where c.id = old.channel_id;
  end if;
  return null;
end;
$$;

drop trigger if exists subscriptions_count on public.subscriptions;
create trigger subscriptions_count
  after insert or delete on public.subscriptions
  for each row execute function public.subscriptions_count();

-- Recount once, so the counts are right whatever happened before this file.
update public.channels c
   set subscriber_count = coalesce((
     select count(*) from public.subscriptions s where s.channel_id = c.id
   ), 0)
 where c.subscriber_count is distinct from coalesce((
     select count(*) from public.subscriptions s where s.channel_id = c.id
   ), 0);

-- Writes -------------------------------------------------------------------------------

-- The checks every change shares: signed in, the flag (unless leaving), the
-- channel exists and is not the caller's own, and, when the call really
-- changes something, the rate limit. Locks per person, so the hourly count
-- cannot be raced. Returns the caller's id.
create or replace function public.subscription_change_guard(target uuid, counts boolean, need_flag boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  owner uuid;
  recent int;
begin
  if me is null or not exists (select 1 from public.profiles p where p.id = me) then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if need_flag and not public.subscriptions_flag_on(me) then
    raise exception 'subscriptions_off' using errcode = 'P0001';
  end if;
  select c.owner_id into owner from public.channels c where c.id = target;
  if owner is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if owner = me then
    raise exception 'own_channel' using errcode = 'P0001';
  end if;
  if counts then
    perform pg_advisory_xact_lock(hashtextextended('subscription_change:' || me::text, 0));
    delete from public.subscription_changes sc
     where sc.subscriber_id = me and sc.at < now() - interval '1 hour';
    select count(*) into recent
      from public.subscription_changes sc
     where sc.subscriber_id = me;
    if recent >= public.subscription_changes_per_hour() then
      raise exception 'rate_limited' using errcode = 'P0001';
    end if;
    insert into public.subscription_changes (subscriber_id) values (me);
  end if;
  return me;
end;
$$;

-- The return type is part of the signature, so drop older shapes first.
drop function if exists public.subscribe(uuid);
drop function if exists public.unsubscribe(uuid);
drop function if exists public.set_notify(uuid, boolean);
drop function if exists public.my_subscriptions();
drop function if exists public.subscriptions_feed(timestamptz, uuid, int, boolean);

create function public.subscribe(channel_id uuid)
returns table (subscribed boolean, notify boolean, subscriber_count int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid;
  already boolean := exists (
    select 1 from public.subscriptions s
    where s.subscriber_id = auth.uid() and s.channel_id = subscribe.channel_id
  );
begin
  me := public.subscription_change_guard(subscribe.channel_id, not already, true);
  insert into public.subscriptions (subscriber_id, channel_id)
  values (me, subscribe.channel_id)
  on conflict on constraint subscriptions_pkey do nothing;
  return query
    select true, s.notify, c.subscriber_count
      from public.subscriptions s
      join public.channels c on c.id = s.channel_id
     where s.subscriber_id = me and s.channel_id = subscribe.channel_id;
end;
$$;

-- Leaving works even with the flag off. Unsubscribing twice is free.
create function public.unsubscribe(channel_id uuid)
returns table (subscribed boolean, notify boolean, subscriber_count int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid;
  there boolean := exists (
    select 1 from public.subscriptions s
    where s.subscriber_id = auth.uid() and s.channel_id = unsubscribe.channel_id
  );
begin
  me := public.subscription_change_guard(unsubscribe.channel_id, there, false);
  delete from public.subscriptions s
   where s.subscriber_id = me and s.channel_id = unsubscribe.channel_id;
  return query
    select false, false, c.subscriber_count
      from public.channels c
     where c.id = unsubscribe.channel_id;
end;
$$;

-- The bell. Errors also: not_subscribed
create function public.set_notify(channel_id uuid, "on" boolean)
returns table (subscribed boolean, notify boolean, subscriber_count int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid;
  current_notify boolean;
  wanted boolean := coalesce(set_notify."on", true);
begin
  select s.notify into current_notify
    from public.subscriptions s
   where s.subscriber_id = auth.uid() and s.channel_id = set_notify.channel_id;
  me := public.subscription_change_guard(
    set_notify.channel_id,
    current_notify is not null and current_notify <> wanted,
    true
  );
  if current_notify is null then
    raise exception 'not_subscribed' using errcode = 'P0001';
  end if;
  update public.subscriptions s
     set notify = wanted
   where s.subscriber_id = me and s.channel_id = set_notify.channel_id;
  return query
    select true, s.notify, c.subscriber_count
      from public.subscriptions s
      join public.channels c on c.id = s.channel_id
     where s.subscriber_id = me and s.channel_id = set_notify.channel_id;
end;
$$;

-- Reads --------------------------------------------------------------------------------

-- The guide's list. Runs as the caller: the policy above keeps it to their rows.
create function public.my_subscriptions()
returns table (
  channel_id uuid,
  handle text,
  name text,
  avatar_url text,
  notify boolean,
  subscribed_at timestamptz,
  latest_upload_at timestamptz,
  unseen int
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url,
    s.notify,
    s.created_at,
    (
      select max(v.published_at) from public.videos v
       where v.channel_id = c.id and v.visibility = 'public' and v.status = 'ready'
    ),
    0
  from public.subscriptions s
  join public.channels c on c.id = s.channel_id
  where s.subscriber_id = (select auth.uid())
  order by 7 desc nulls last, 3, 1;
$$;

-- The subscriptions feed, paged like feed_videos.
create function public.subscriptions_feed(
  cursor timestamptz default null,
  cursor_id uuid default null,
  lim int default 24,
  only_notify boolean default false
)
returns table (
  id uuid,
  title text,
  duration_s numeric,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  published_at timestamptz,
  views bigint,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    v.id,
    v.title,
    v.duration_s,
    v.thumbnail_url,
    v.hls_key,
    v.preview_sprite_key,
    v.published_at,
    v.views,
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url
  from public.subscriptions s
  join public.channels c on c.id = s.channel_id
  join public.videos v on v.channel_id = s.channel_id
  where s.subscriber_id = (select auth.uid())
    and (not coalesce(subscriptions_feed.only_notify, false) or s.notify)
    and v.visibility = 'public'
    and v.status = 'ready'
    and v.published_at is not null
    and (
      subscriptions_feed.cursor is null
      or (v.published_at, v.id) < (subscriptions_feed.cursor, coalesce(subscriptions_feed.cursor_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
    )
  order by v.published_at desc, v.id desc
  limit least(greatest(coalesce(subscriptions_feed.lim, 24), 1), 50);
$$;

-- Who may call what ------------------------------------------------------------------------

revoke execute on function public.subscriptions_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.subscription_change_guard(uuid, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.subscriptions_not_own_channel() from public, anon, authenticated;
revoke execute on function public.subscriptions_count() from public, anon, authenticated;

revoke execute on function public.subscribe(uuid) from public;
revoke execute on function public.unsubscribe(uuid) from public;
revoke execute on function public.set_notify(uuid, boolean) from public;
revoke execute on function public.my_subscriptions() from public;
revoke execute on function public.subscriptions_feed(timestamptz, uuid, int, boolean) from public;
grant execute on function public.subscribe(uuid) to authenticated;
grant execute on function public.unsubscribe(uuid) to authenticated;
grant execute on function public.set_notify(uuid, boolean) to authenticated;
grant execute on function public.my_subscriptions() to authenticated;
grant execute on function public.subscriptions_feed(timestamptz, uuid, int, boolean) to authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'subscriptions',
  'Subscriptions',
  'Subscribe buttons, the bell, the Subscriptions list in the guide, /feed/subscriptions and the notifications menu.',
  'off'
)
on conflict (key) do nothing;

-- ===== 010_search.sql =====
-- 010_search.sql
-- Search: full text and trigram search over videos and channels, suggestions,
-- a per person (or per address) rate limit, the search flag.
--
-- - pg_trgm in the extensions schema (Supabase's usual place for extensions).
--   If it was installed somewhere else before, it is moved there.
-- - videos.search_doc: a generated tsvector, the title with weight A and the
--   description with weight B, with a GIN index. Trigram indexes on
--   videos.title, channels.name and channels.handle.
-- - search_normalize(q): lower case, punctuation to spaces, spaces collapsed,
--   at most 100 characters. Keep in step with normalizeQuery() in
--   lib/search/query.ts (the app normalizes first; this is the safety net).
-- - search_videos(q, cursor_rank, cursor_id, lim, filters) returns video cards
--   with the same columns as feed_videos plus the description and the sort
--   key, public and ready videos only. A video matches when the full text
--   query (every word, as a prefix) matches, or when the query is close to
--   the title by trigram word similarity. Relevance is
--   ts_rank(search_doc) + word_similarity(q, title).
--   filters (jsonb, every key optional):
--     uploaded  hour | today | week | month | year
--     duration  short (under 4 minutes) | medium (4 to 20) | long (over 20)
--     sort      relevance (default) | date | views
--   Pages by keyset on (sort_key, id): pass the last card's sort_key and id
--   as cursor_rank and cursor_id for the next page. sort_key is the
--   relevance, the publish time in microseconds, or the view count.
-- - search_channels(q, lim): channels by trigram similarity on name and
--   handle (or a name or handle that starts with the query), with
--   subscriber_count and video_count.
-- - search_suggest(q, lim): up to 10 lower case suggestions from public video
--   titles and channel names, prefix matches first, then trigram matches,
--   without repeats.
-- - Rate limit: search_videos and search_channels count 60 calls a minute
--   each, search_suggest 240, per signed in person, or per address for
--   people who are signed out. The address is the x-search-client header the
--   app sends (the visitor's address as the app's reverse proxy saw it), else
--   the first x-forwarded-for entry. Calls are logged in
--   public.search_requests and nobody reads that table through the API.
--   Errors: rate_limited
-- - All three run as the caller, so the row level security from 004 and 005
--   applies, and every query also checks public and ready itself.
-- - The "search" feature flag, off until the owner switches it on.
--
-- Keep the limits in step with lib/search/rules.ts.
--
-- Run after 009_subscriptions.sql. Safe to run more than once.

-- pg_trgm ------------------------------------------------------------------------------

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated;

do $$
begin
  if exists (
    select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'pg_trgm' and n.nspname <> 'extensions'
  ) then
    alter extension pg_trgm set schema extensions;
  end if;
end;
$$;

create extension if not exists pg_trgm with schema extensions;

-- Columns and indexes ---------------------------------------------------------------------

alter table public.videos
  add column if not exists search_doc tsvector
  generated always as (
    setweight(to_tsvector('english'::regconfig, coalesce(title, '')), 'A')
    || setweight(to_tsvector('english'::regconfig, coalesce(description, '')), 'B')
  ) stored;

create index if not exists videos_search_doc_idx on public.videos using gin (search_doc);
create index if not exists videos_title_trgm_idx on public.videos using gin (title extensions.gin_trgm_ops);
create index if not exists channels_name_trgm_idx on public.channels using gin (name extensions.gin_trgm_ops);
create index if not exists channels_handle_trgm_idx on public.channels using gin (handle extensions.gin_trgm_ops);

-- Settings and helpers ----------------------------------------------------------------------

create or replace function public.search_limit_per_minute(bucket text)
returns int
language sql
immutable
set search_path = ''
as $$ select case bucket when 'suggest' then 240 else 60 end $$;

create or replace function public.search_normalize(q text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(
    btrim(regexp_replace(
      regexp_replace(lower(coalesce(q, '')), '[''’]', '', 'g'),
      '[[:punct:][:space:]]+', ' ', 'g'
    )),
    100
  )
$$;

-- "pancake rec" becomes 'pancake:* & rec:*', so the last word can still be
-- typed. Only letters, digits and spaces reach to_tsquery, so it cannot fail.
create or replace function public.search_tsquery(q text)
returns tsquery
language sql
immutable
set search_path = ''
as $$
  select case
    when public.search_normalize(q) = '' then null
    else to_tsquery(
      'english'::regconfig,
      (
        select string_agg(w || ':*', ' & ')
        from unnest(regexp_split_to_array(public.search_normalize(q), ' ')) as w
        where w <> ''
      )
    )
  end
$$;

-- One row per counted call, for the rate limit. Nobody reads it through the API.
create table if not exists public.search_requests (
  key text not null,
  bucket text not null,
  at timestamptz not null default now()
);

create index if not exists search_requests_recent_idx
  on public.search_requests (key, bucket, at desc);

alter table public.search_requests enable row level security;
revoke all on public.search_requests from anon, authenticated;

-- Counts one call for the caller and raises rate_limited past the limit.
-- Locks per key, so the count cannot be raced.
create or replace function public.search_throttle(bucket text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  headers json := nullif(current_setting('request.headers', true), '')::json;
  address text;
  who text;
  recent int;
begin
  if bucket not in ('videos', 'channels', 'suggest') then
    raise exception 'bad_bucket' using errcode = 'P0001';
  end if;
  if me is not null then
    who := 'user:' || me::text;
  else
    address := nullif(btrim(coalesce(
      headers ->> 'x-search-client',
      split_part(coalesce(headers ->> 'x-forwarded-for', ''), ',', 1)
    )), '');
    who := 'addr:' || left(coalesce(address, 'unknown'), 64);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('search:' || bucket || ':' || who, 0));
  delete from public.search_requests r
   where r.key = who and r.bucket = search_throttle.bucket and r.at < now() - interval '1 minute';
  -- Now and then, sweep the rows of addresses that never came back.
  if random() < 0.01 then
    delete from public.search_requests r where r.at < now() - interval '1 minute';
  end if;
  select count(*) into recent
    from public.search_requests r
   where r.key = who and r.bucket = search_throttle.bucket;
  if recent >= public.search_limit_per_minute(bucket) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.search_requests (key, bucket) values (who, search_throttle.bucket);
end;
$$;

-- RPCs ---------------------------------------------------------------------------------

-- The return type is part of the signature, so drop older shapes first.
drop function if exists public.search_videos(text, double precision, uuid, int, jsonb);
drop function if exists public.search_channels(text, int);
drop function if exists public.search_suggest(text, int);

create function public.search_videos(
  q text,
  cursor_rank double precision default null,
  cursor_id uuid default null,
  lim int default 20,
  filters jsonb default '{}'::jsonb
)
returns table (
  id uuid,
  title text,
  description text,
  duration_s numeric,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  published_at timestamptz,
  views bigint,
  score double precision,
  sort_key double precision,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text
)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  clean text := public.search_normalize(q);
  tsq tsquery := public.search_tsquery(q);
  f jsonb := coalesce(filters, '{}'::jsonb);
  uploaded text := f ->> 'uploaded';
  duration text := f ->> 'duration';
  sort text := coalesce(f ->> 'sort', 'relevance');
  since timestamptz;
  page int := least(greatest(coalesce(lim, 20), 1), 50);
begin
  if clean = '' then
    return;
  end if;
  perform public.search_throttle('videos');

  since := case uploaded
    when 'hour' then now() - interval '1 hour'
    when 'today' then now() - interval '1 day'
    when 'week' then now() - interval '7 days'
    when 'month' then now() - interval '1 month'
    when 'year' then now() - interval '1 year'
    else null
  end;
  if sort not in ('relevance', 'date', 'views') then
    sort := 'relevance';
  end if;

  return query
  with matches as (
    select
      v.*,
      (
        coalesce(ts_rank(v.search_doc, tsq), 0)
        + extensions.word_similarity(clean, lower(v.title))
      )::double precision as relevance
    from public.videos v
    where v.visibility = 'public'
      and v.status = 'ready'
      and v.published_at is not null
      and (
        (tsq is not null and v.search_doc @@ tsq)
        or clean operator(extensions.<%) v.title
      )
      and (since is null or v.published_at >= since)
      and (
        duration is null
        or (duration = 'short' and v.duration_s < 240)
        or (duration = 'medium' and v.duration_s >= 240 and v.duration_s <= 1200)
        or (duration = 'long' and v.duration_s > 1200)
        or duration not in ('short', 'medium', 'long')
      )
  ),
  keyed as (
    select
      m.*,
      case sort
        when 'date' then floor(extract(epoch from m.published_at) * 1000000)::double precision
        when 'views' then m.views::double precision
        else m.relevance
      end as k
    from matches m
  )
  select
    k.id,
    k.title,
    left(k.description, 500),
    k.duration_s,
    k.thumbnail_url,
    k.hls_key,
    k.preview_sprite_key,
    k.published_at,
    k.views,
    k.relevance,
    k.k,
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url
  from keyed k
  join public.channels c on c.id = k.channel_id
  where search_videos.cursor_rank is null
     or (k.k, k.id) < (search_videos.cursor_rank, coalesce(search_videos.cursor_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
  order by k.k desc, k.id desc
  limit page;
end;
$$;

create function public.search_channels(q text, lim int default 3)
returns table (
  id uuid,
  handle text,
  name text,
  description text,
  avatar_url text,
  subscriber_count int,
  video_count int,
  score double precision
)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  clean text := public.search_normalize(q);
  squashed text := replace(public.search_normalize(q), ' ', '');
begin
  if clean = '' then
    return;
  end if;
  perform public.search_throttle('channels');

  return query
  select
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    left(c.description, 300),
    c.avatar_url,
    c.subscriber_count,
    c.video_count,
    greatest(
      extensions.word_similarity(clean, lower(c.name)),
      extensions.word_similarity(squashed, lower(c.handle)),
      case when lower(c.name) like clean || '%' or lower(c.handle) like squashed || '%' then 1 else 0 end
    )::double precision as score
  from public.channels c
  where clean operator(extensions.<%) c.name
     or squashed operator(extensions.<%) c.handle
     or lower(c.name) like clean || '%'
     or lower(c.handle) like squashed || '%'
  order by score desc, c.subscriber_count desc, c.id
  limit least(greatest(coalesce(lim, 3), 1), 50);
end;
$$;

create function public.search_suggest(q text, lim int default 10)
returns table (suggestion text)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  clean text := public.search_normalize(q);
begin
  if clean = '' then
    return;
  end if;
  perform public.search_throttle('suggest');

  return query
  with candidates as (
    select lower(v.title) as s, extensions.word_similarity(clean, lower(v.title)) as sim, v.views::double precision as pop
    from public.videos v
    where v.visibility = 'public'
      and v.status = 'ready'
      and (lower(v.title) like clean || '%' or clean operator(extensions.<%) v.title)
    union all
    select lower(coalesce(nullif(c.name, ''), c.handle)), extensions.word_similarity(clean, lower(c.name)), c.subscriber_count::double precision
    from public.channels c
    where lower(c.name) like clean || '%' or clean operator(extensions.<%) c.name
  ),
  ranked as (
    select
      btrim(regexp_replace(cd.s, '\s+', ' ', 'g')) as s,
      max(case when cd.s like clean || '%' then 1 else 0 end) as is_prefix,
      max(cd.sim) as sim,
      max(cd.pop) as pop
    from candidates cd
    group by 1
  )
  select r.s
  from ranked r
  where r.s <> ''
  order by r.is_prefix desc, r.sim desc, r.pop desc, r.s
  limit least(greatest(coalesce(lim, 10), 1), 10);
end;
$$;

-- Who may call what ------------------------------------------------------------------------

-- The search functions run as the caller and call the throttle, so callers
-- need it. Calling it directly only uses up the caller's own allowance.
revoke execute on function public.search_throttle(text) from public;
grant execute on function public.search_throttle(text) to anon, authenticated;

revoke execute on function public.search_videos(text, double precision, uuid, int, jsonb) from public;
revoke execute on function public.search_channels(text, int) from public;
revoke execute on function public.search_suggest(text, int) from public;
grant execute on function public.search_videos(text, double precision, uuid, int, jsonb) to anon, authenticated;
grant execute on function public.search_channels(text, int) to anon, authenticated;
grant execute on function public.search_suggest(text, int) to anon, authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'search',
  'Search',
  'The search box with suggestions and recent searches, and /results with filters.',
  'off'
)
on conflict (key) do nothing;

-- ===== 011_engagement.sql =====
-- 011_engagement.sql
-- Likes and dislikes, view counting that cannot be spammed, watch history
-- with resume, the daily stats rollup, the engagement flag.
--
-- Reactions
-- - public.video_reactions: one row per (person, video), kind 'like' or
--   'dislike'. People read only their own rows. Writes go through react().
-- - videos.like_count is public, like the rest of the videos row.
-- - The dislike count is only for the video's owner. The videos table is
--   readable by everyone (005), and several functions select v.* from it as
--   the caller, so a column there could not be hidden. It lives in
--   public.video_dislike_counts instead, readable only by the owner (row
--   level security), and the functions below return it to the owner only.
-- - Both counts are kept right by a trigger on video_reactions (and
--   recounted every time this file runs).
-- - react(video_id, kind) sets the person's reaction: 'like', 'dislike', or
--   null to clear it. The app toggles: clicking the thumb that is already on
--   sends null. Answers reaction, like_count and dislike_count (null unless
--   the caller owns the video). 30 changes a minute per person.
--
-- Views
-- - public.view_events: one row per (video, viewer, UTC day) with the seconds
--   watched that day, first_at and last_at. Nobody reads it through the API.
-- - The viewer is 'u:<user id>' when signed in. Signed out, the app sets a
--   random 'sv' cookie (one year), hashes it and sends the hash in the
--   x-viewer-key header; this file hashes that again before it is stored, so
--   the cookie value is never in the database. Somebody calling the database
--   directly can make up keys; every key still needs real seconds between
--   pings to count (below), so a made up key costs ten seconds per view.
-- - watch_ping(video_id, position_s, played_s) is called by the player every
--   10 seconds while playing, and on pause, end and leaving the page.
--   played_s is the seconds played since the last ping (at most 60 count).
--   The first ping of the day only opens the row, and the day's total never
--   runs ahead of the wall clock time since then (plus one second), so
--   seconds cannot be claimed faster than they pass, however many pings.
-- - A view counts once per viewer per video per UTC day, when the seconds
--   watched reach 10, or the whole video (rounded down) when it is shorter.
--   videos.views goes up by one at that moment, and only then.
-- - 20 pings a minute per viewer key. Errors: engagement_off, no_viewer_key,
--   not_found, rate_limited, not_signed_in, bad_kind.
--
-- History and resume
-- - public.watch_history: (person, video) with the last position, the
--   duration and last_at, written by watch_ping for signed in viewers unless
--   profiles.history_paused is on. People read only their own rows.
-- - my_history(cursor, cursor_id, lim) returns history cards, most recent
--   first, with the progress fraction; keyset pages on (watched_at, id).
-- - clear_history(), remove_from_history(video_id), set_history_paused(on),
--   history_paused(). These work with the flag off, so people can always
--   clean up.
-- - video_engagement(video_id) for the watch page: like_count, dislike_count
--   (owner only), my_reaction, the saved position and duration.
-- - my_progress(video_ids) for the red bars under thumbnails, at most 100 ids.
--
-- Stats groundwork (feature 13 reads it)
-- - public.video_stats_daily: (video, day) with views, watch_s, likes and
--   dislikes (reactions made that day). Owners read their own rows.
-- - rollup_video_stats(days) recomputes the last `days` UTC days. A pg_cron
--   job runs it every hour when the pg_cron extension is on; otherwise this
--   file says so with a notice and the rest still applies.
--
-- The "engagement" feature flag, off until the owner switches it on.
--
-- Keep the numbers in step with lib/engagement/rules.ts.
--
-- Run after 010_search.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.engagement_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'engagement'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Seconds of watching that make a view: 10, or the whole video (rounded down,
-- at least 1) when it is shorter. Keep in step with viewThreshold().
create or replace function public.view_threshold_s(duration numeric)
returns int
language sql
immutable
set search_path = ''
as $$
  select case
    when duration is null or duration <= 0 then 10
    else least(10, greatest(1, floor(duration)::int))
  end
$$;

create or replace function public.engagement_limit_per_minute(bucket text)
returns int
language sql
immutable
set search_path = ''
as $$ select case bucket when 'react' then 30 else 20 end $$;

-- Columns ------------------------------------------------------------------------------

alter table public.videos add column if not exists like_count bigint not null default 0;
alter table public.videos drop constraint if exists videos_like_count_positive;
alter table public.videos add constraint videos_like_count_positive check (like_count >= 0);

-- Not readable through the API: profiles only grants the columns listed in 002.
alter table public.profiles add column if not exists history_paused boolean not null default false;

-- Tables --------------------------------------------------------------------------------

create table if not exists public.video_reactions (
  user_id uuid not null references public.profiles (id) on delete cascade,
  video_id uuid not null references public.videos (id) on delete cascade,
  kind text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id),
  constraint video_reactions_kind_valid check (kind in ('like', 'dislike'))
);

create index if not exists video_reactions_video_idx on public.video_reactions (video_id, kind);
create index if not exists video_reactions_created_idx on public.video_reactions (created_at);

alter table public.video_reactions enable row level security;

drop policy if exists "people read their own reactions" on public.video_reactions;
create policy "people read their own reactions"
  on public.video_reactions
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.video_reactions from anon, authenticated;
grant select on public.video_reactions to authenticated;

create table if not exists public.video_dislike_counts (
  video_id uuid primary key references public.videos (id) on delete cascade,
  dislike_count bigint not null default 0,
  constraint video_dislike_counts_positive check (dislike_count >= 0)
);

alter table public.video_dislike_counts enable row level security;

drop policy if exists "owners read the dislike count of their own videos" on public.video_dislike_counts;
create policy "owners read the dislike count of their own videos"
  on public.video_dislike_counts
  for select
  to authenticated
  using (exists (
    select 1 from public.videos v
    where v.id = video_dislike_counts.video_id and v.owner_id = (select auth.uid())
  ));

revoke all on public.video_dislike_counts from anon, authenticated;
grant select on public.video_dislike_counts to authenticated;

create table if not exists public.view_events (
  video_id uuid not null references public.videos (id) on delete cascade,
  viewer_key text not null,
  day date not null,
  watched_s int not null default 0,
  counted boolean not null default false,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  primary key (video_id, viewer_key, day),
  constraint view_events_watched_positive check (watched_s >= 0)
);

-- The hourly rollup reads a day at a time.
create index if not exists view_events_day_idx on public.view_events (day, video_id);

alter table public.view_events enable row level security;
revoke all on public.view_events from anon, authenticated;

create table if not exists public.watch_history (
  user_id uuid not null references public.profiles (id) on delete cascade,
  video_id uuid not null references public.videos (id) on delete cascade,
  position_s numeric not null default 0,
  duration_s numeric,
  last_at timestamptz not null default now(),
  primary key (user_id, video_id),
  constraint watch_history_position_positive check (position_s >= 0)
);

create index if not exists watch_history_recent_idx on public.watch_history (user_id, last_at desc, video_id desc);
create index if not exists watch_history_video_idx on public.watch_history (video_id);

alter table public.watch_history enable row level security;

drop policy if exists "people read their own history" on public.watch_history;
create policy "people read their own history"
  on public.watch_history
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.watch_history from anon, authenticated;
grant select on public.watch_history to authenticated;

-- One row per counted call, for the rate limits. Nobody reads it through the API.
create table if not exists public.engagement_requests (
  key text not null,
  bucket text not null,
  at timestamptz not null default now()
);

create index if not exists engagement_requests_recent_idx
  on public.engagement_requests (key, bucket, at desc);

alter table public.engagement_requests enable row level security;
revoke all on public.engagement_requests from anon, authenticated;

create table if not exists public.video_stats_daily (
  video_id uuid not null references public.videos (id) on delete cascade,
  day date not null,
  views int not null default 0,
  watch_s bigint not null default 0,
  likes int not null default 0,
  dislikes int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (video_id, day)
);

alter table public.video_stats_daily enable row level security;

drop policy if exists "owners read the stats of their own videos" on public.video_stats_daily;
create policy "owners read the stats of their own videos"
  on public.video_stats_daily
  for select
  to authenticated
  using (exists (
    select 1 from public.videos v
    where v.id = video_stats_daily.video_id and v.owner_id = (select auth.uid())
  ));

revoke all on public.video_stats_daily from anon, authenticated;
grant select on public.video_stats_daily to authenticated;

-- The reaction counts -------------------------------------------------------------------

create or replace function public.video_reactions_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_like int := case when tg_op <> 'INSERT' and old.kind = 'like' then 1 else 0 end;
  old_dislike int := case when tg_op <> 'INSERT' and old.kind = 'dislike' then 1 else 0 end;
  new_like int := case when tg_op <> 'DELETE' and new.kind = 'like' then 1 else 0 end;
  new_dislike int := case when tg_op <> 'DELETE' and new.kind = 'dislike' then 1 else 0 end;
  vid uuid := case when tg_op = 'DELETE' then old.video_id else new.video_id end;
begin
  if new_like <> old_like then
    update public.videos v set like_count = greatest(v.like_count + new_like - old_like, 0) where v.id = vid;
  end if;
  if new_dislike <> old_dislike then
    insert into public.video_dislike_counts as d (video_id, dislike_count)
    values (vid, greatest(new_dislike - old_dislike, 0))
    on conflict (video_id) do update
      set dislike_count = greatest(d.dislike_count + new_dislike - old_dislike, 0);
  end if;
  return null;
end;
$$;

drop trigger if exists video_reactions_count on public.video_reactions;
create trigger video_reactions_count
  after insert or update of kind or delete on public.video_reactions
  for each row execute function public.video_reactions_count();

-- Recount, so the counts are right whatever happened before this run.
update public.videos v
   set like_count = coalesce((select count(*) from public.video_reactions r where r.video_id = v.id and r.kind = 'like'), 0)
 where v.like_count is distinct from coalesce((
     select count(*) from public.video_reactions r where r.video_id = v.id and r.kind = 'like'
   ), 0);

insert into public.video_dislike_counts (video_id, dislike_count)
select r.video_id, count(*) from public.video_reactions r where r.kind = 'dislike' group by r.video_id
on conflict (video_id) do update set dislike_count = excluded.dislike_count;

update public.video_dislike_counts d
   set dislike_count = 0
 where d.dislike_count <> 0
   and not exists (select 1 from public.video_reactions r where r.video_id = d.video_id and r.kind = 'dislike');

-- Helpers ---------------------------------------------------------------------------------

-- Who is watching: the person, or the hashed cookie key the app sent.
-- The app sends sha256 of the 'sv' cookie as 64 hex characters; anything
-- else is ignored. Hashed again here, so the stored value is a hash of a hash.
create or replace function public.engagement_viewer_key()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  headers json := nullif(current_setting('request.headers', true), '')::json;
  sent text;
begin
  if me is not null then
    return 'u:' || me::text;
  end if;
  sent := lower(btrim(coalesce(headers ->> 'x-viewer-key', '')));
  if sent !~ '^[0-9a-f]{64}$' then
    return null;
  end if;
  return 'a:' || encode(sha256(convert_to('sloptube-viewer:' || sent, 'UTF8')), 'hex');
end;
$$;

-- Counts one call for this key and raises rate_limited past the limit.
-- Locks per key, so the count cannot be raced.
create or replace function public.engagement_throttle(who text, bucket text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  recent int;
begin
  perform pg_advisory_xact_lock(hashtextextended('engagement:' || bucket || ':' || who, 0));
  delete from public.engagement_requests r
   where r.key = who and r.bucket = engagement_throttle.bucket and r.at < now() - interval '1 minute';
  -- Now and then, sweep the rows of viewers that never came back.
  if random() < 0.01 then
    delete from public.engagement_requests r where r.at < now() - interval '1 minute';
  end if;
  select count(*) into recent
    from public.engagement_requests r
   where r.key = who and r.bucket = engagement_throttle.bucket;
  if recent >= public.engagement_limit_per_minute(bucket) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.engagement_requests (key, bucket) values (who, engagement_throttle.bucket);
end;
$$;

-- RPCs ---------------------------------------------------------------------------------

-- The return type is part of the signature, so drop older shapes first.
drop function if exists public.react(uuid, text);
drop function if exists public.watch_ping(uuid, numeric, numeric);
drop function if exists public.video_engagement(uuid);
drop function if exists public.my_history(timestamptz, uuid, int);
drop function if exists public.my_progress(uuid[]);
drop function if exists public.clear_history();
drop function if exists public.remove_from_history(uuid);
drop function if exists public.set_history_paused(boolean);
drop function if exists public.history_paused();
drop function if exists public.rollup_video_stats(int);

create function public.react(video_id uuid, kind text)
returns table (reaction text, like_count bigint, dislike_count bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v public.videos;
  mine boolean;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.engagement_flag_on(me) then
    raise exception 'engagement_off' using errcode = 'P0001';
  end if;
  if react.kind is not null and react.kind not in ('like', 'dislike') then
    raise exception 'bad_kind' using errcode = 'P0001';
  end if;
  select * into v from public.videos x where x.id = react.video_id;
  mine := found and v.owner_id = me;
  if not found or not (mine or (v.status = 'ready' and v.visibility in ('public', 'unlisted'))) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  perform public.engagement_throttle('u:' || me::text, 'react');

  if react.kind is null then
    delete from public.video_reactions r where r.user_id = me and r.video_id = react.video_id;
  else
    insert into public.video_reactions as r (user_id, video_id, kind)
    values (me, react.video_id, react.kind)
    -- By constraint name: a column list here would clash with the parameter names.
    on conflict on constraint video_reactions_pkey do update
      set kind = excluded.kind, created_at = now()
      where r.kind is distinct from excluded.kind;
  end if;

  return query
  select
    (select r.kind from public.video_reactions r where r.user_id = me and r.video_id = react.video_id),
    x.like_count,
    case when mine then coalesce((select d.dislike_count from public.video_dislike_counts d where d.video_id = x.id), 0) end
  from public.videos x
  where x.id = react.video_id;
end;
$$;

create function public.watch_ping(video_id uuid, position_s numeric, played_s numeric)
returns table (counted boolean, views bigint, watched_s int)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  who text;
  v public.videos;
  today date := (now() at time zone 'utc')::date;
  ev public.view_events;
  opened boolean := false;
  credit numeric;
  counted_now boolean := false;
  pos numeric;
  total bigint;
begin
  if not public.engagement_flag_on(me) then
    raise exception 'engagement_off' using errcode = 'P0001';
  end if;
  who := public.engagement_viewer_key();
  if who is null then
    raise exception 'no_viewer_key' using errcode = 'P0001';
  end if;
  select * into v from public.videos x where x.id = watch_ping.video_id;
  if not found or v.status <> 'ready'
     or not (v.visibility in ('public', 'unlisted') or v.owner_id = me) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  perform public.engagement_throttle(who, 'ping');

  pos := greatest(0, coalesce(watch_ping.position_s, 0));
  if v.duration_s is not null and v.duration_s > 0 then
    pos := least(pos, v.duration_s);
  end if;

  -- The first ping of the day opens the row and earns nothing: seconds are
  -- only credited against wall clock time that has really passed.
  insert into public.view_events as e (video_id, viewer_key, day)
  values (v.id, who, today)
  on conflict on constraint view_events_pkey do nothing;
  get diagnostics total = row_count;
  opened := total > 0;

  select * into ev from public.view_events e
   where e.video_id = v.id and e.viewer_key = who and e.day = today
   for update;

  -- The day's total never runs ahead of the wall clock since the row opened
  -- (plus one second), however many pings claim how much.
  credit := case when opened then 0 else least(greatest(coalesce(watch_ping.played_s, 0), 0), 60) end;
  ev.watched_s := greatest(
    ev.watched_s,
    least(ev.watched_s + floor(credit)::int, floor(extract(epoch from (now() - ev.first_at)))::int + 1)
  );
  if not ev.counted and ev.watched_s >= public.view_threshold_s(v.duration_s) then
    ev.counted := true;
    counted_now := true;
  end if;

  update public.view_events e
     set watched_s = ev.watched_s, counted = ev.counted, last_at = now()
   where e.video_id = v.id and e.viewer_key = who and e.day = today;

  if counted_now then
    update public.videos x set views = x.views + 1 where x.id = v.id returning x.views into total;
  else
    total := v.views;
  end if;

  if me is not null and not coalesce((select p.history_paused from public.profiles p where p.id = me), false) then
    insert into public.watch_history as h (user_id, video_id, position_s, duration_s, last_at)
    values (me, v.id, pos, v.duration_s, now())
    on conflict on constraint watch_history_pkey do update
      set position_s = excluded.position_s, duration_s = excluded.duration_s, last_at = excluded.last_at;
  end if;

  return query select counted_now, total, ev.watched_s;
end;
$$;

-- What the watch page needs on top of watch_video(). No row for videos the
-- caller may not watch.
create function public.video_engagement(video_id uuid)
returns table (
  like_count bigint,
  dislike_count bigint,
  my_reaction text,
  position_s numeric,
  duration_s numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    v.like_count,
    case when mine.yes then coalesce((select d.dislike_count from public.video_dislike_counts d where d.video_id = v.id), 0) end,
    (select r.kind from public.video_reactions r where r.user_id = (select auth.uid()) and r.video_id = v.id),
    h.position_s,
    coalesce(h.duration_s, v.duration_s)
  from public.videos v
  cross join lateral (select coalesce(v.owner_id = (select auth.uid()), false) as yes) mine
  left join public.watch_history h on h.user_id = (select auth.uid()) and h.video_id = v.id
  where v.id = video_engagement.video_id
    and (mine.yes or (v.status = 'ready' and v.visibility in ('public', 'unlisted')));
$$;

-- The history page, most recently watched first, with feed card columns.
create function public.my_history(
  cursor timestamptz default null,
  cursor_id uuid default null,
  lim int default 20
)
returns table (
  id uuid,
  title text,
  description text,
  duration_s numeric,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  published_at timestamptz,
  views bigint,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text,
  position_s numeric,
  progress double precision,
  watched_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    v.id,
    v.title,
    left(v.description, 500),
    v.duration_s,
    v.thumbnail_url,
    v.hls_key,
    v.preview_sprite_key,
    coalesce(v.published_at, v.created_at),
    v.views,
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url,
    h.position_s,
    case
      when coalesce(h.duration_s, v.duration_s, 0) > 0
        then least(1.0, h.position_s / coalesce(h.duration_s, v.duration_s))::double precision
      else 0
    end,
    h.last_at
  from public.watch_history h
  join public.videos v on v.id = h.video_id
  join public.channels c on c.id = v.channel_id
  where h.user_id = (select auth.uid())
    and v.status = 'ready'
    and (v.visibility in ('public', 'unlisted') or v.owner_id = h.user_id)
    and (
      my_history.cursor is null
      or (h.last_at, h.video_id) < (my_history.cursor, coalesce(my_history.cursor_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
    )
  order by h.last_at desc, h.video_id desc
  limit least(greatest(coalesce(my_history.lim, 20), 1), 50);
$$;

-- Saved positions for the cards on a page, for the red bars.
create function public.my_progress(video_ids uuid[])
returns table (video_id uuid, position_s numeric, duration_s numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select h.video_id, h.position_s, h.duration_s
  from public.watch_history h
  where h.user_id = (select auth.uid())
    and h.video_id = any (my_progress.video_ids[1:100]);
$$;

create function public.clear_history()
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  gone int;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  delete from public.watch_history h where h.user_id = me;
  get diagnostics gone = row_count;
  return gone;
end;
$$;

create function public.remove_from_history(video_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  delete from public.watch_history h where h.user_id = me and h.video_id = remove_from_history.video_id;
  return found;
end;
$$;

create function public.set_history_paused("on" boolean)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  now_paused boolean;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  update public.profiles p set history_paused = coalesce(set_history_paused."on", false)
   where p.id = me
  returning p.history_paused into now_paused;
  return coalesce(now_paused, false);
end;
$$;

create function public.history_paused()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.history_paused from public.profiles p where p.id = (select auth.uid())), false);
$$;

-- Stats rollup -------------------------------------------------------------------------

-- Recomputes video_stats_daily for the last `days` UTC days (today included)
-- from view_events and video_reactions. Safe to run as often as you like.
create function public.rollup_video_stats(days int default 2)
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  since date := (now() at time zone 'utc')::date - (least(greatest(coalesce(days, 2), 1), 400) - 1);
  touched int;
begin
  insert into public.video_stats_daily as s (video_id, day, views, watch_s, likes, dislikes, updated_at)
  select
    coalesce(e.video_id, r.video_id),
    coalesce(e.day, r.day),
    coalesce(e.views, 0),
    coalesce(e.watch_s, 0),
    coalesce(r.likes, 0),
    coalesce(r.dislikes, 0),
    now()
  from (
    select ve.video_id, ve.day, count(*) filter (where ve.counted)::int as views, sum(ve.watched_s)::bigint as watch_s
    from public.view_events ve
    where ve.day >= since
    group by ve.video_id, ve.day
  ) e
  full outer join (
    select vr.video_id, (vr.created_at at time zone 'utc')::date as day,
           count(*) filter (where vr.kind = 'like')::int as likes,
           count(*) filter (where vr.kind = 'dislike')::int as dislikes
    from public.video_reactions vr
    where vr.created_at >= since::timestamp at time zone 'utc'
    group by vr.video_id, (vr.created_at at time zone 'utc')::date
  ) r on r.video_id = e.video_id and r.day = e.day
  on conflict (video_id, day) do update
    set views = excluded.views,
        watch_s = excluded.watch_s,
        likes = excluded.likes,
        dislikes = excluded.dislikes,
        updated_at = excluded.updated_at;
  get diagnostics touched = row_count;
  return touched;
end;
$$;

-- Fill in what is there already, then every hour with pg_cron when it is on.
select public.rollup_video_stats(2);

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- cron.schedule with an existing job name updates that job.
    execute $cron$select cron.schedule('sloptube-video-stats', '7 * * * *', 'select public.rollup_video_stats(2)')$cron$;
  else
    raise notice 'pg_cron is not on: video_stats_daily is not refreshed every hour. Switch it on under Database > Extensions and run this file again.';
  end if;
end;
$$;

-- Who may call what ------------------------------------------------------------------------

revoke execute on function public.engagement_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.engagement_viewer_key() from public, anon, authenticated;
revoke execute on function public.engagement_throttle(text, text) from public, anon, authenticated;
revoke execute on function public.video_reactions_count() from public, anon, authenticated;
revoke execute on function public.rollup_video_stats(int) from public, anon, authenticated;

revoke execute on function public.react(uuid, text) from public;
revoke execute on function public.watch_ping(uuid, numeric, numeric) from public;
revoke execute on function public.video_engagement(uuid) from public;
revoke execute on function public.my_history(timestamptz, uuid, int) from public;
revoke execute on function public.my_progress(uuid[]) from public;
revoke execute on function public.clear_history() from public;
revoke execute on function public.remove_from_history(uuid) from public;
revoke execute on function public.set_history_paused(boolean) from public;
revoke execute on function public.history_paused() from public;

grant execute on function public.react(uuid, text) to authenticated;
grant execute on function public.watch_ping(uuid, numeric, numeric) to anon, authenticated;
grant execute on function public.video_engagement(uuid) to anon, authenticated;
grant execute on function public.my_history(timestamptz, uuid, int) to authenticated;
grant execute on function public.my_progress(uuid[]) to authenticated;
grant execute on function public.clear_history() to authenticated;
grant execute on function public.remove_from_history(uuid) to authenticated;
grant execute on function public.set_history_paused(boolean) to authenticated;
grant execute on function public.history_paused() to authenticated;
grant execute on function public.rollup_video_stats(int) to service_role;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'engagement',
  'Likes, views and history',
  'Like and dislike buttons, counted views, watch history at /feed/history, resume and the red progress bars.',
  'off'
)
on conflict (key) do nothing;

-- ===== 012_comments.sql =====
-- 012_comments.sql
-- Comments on videos: threads one level deep, likes, the creator's pin and
-- heart, soft delete, rate limits, the comments mode per video and per
-- channel, the comments flag.
--
-- Tables
-- - public.comments: one row per comment. parent_id is null for a top level
--   comment, else the top level comment it answers (replies to a reply are
--   attached to the same top level comment, like YouTube). body is 1 to 2000
--   characters. like_count and reply_count are kept by triggers.
--   pinned (one per video, top level only) and hearted are set by the video's
--   owner. Deleting sets deleted_at and empties the body but keeps the row,
--   so the replies under it keep their place ("This comment was deleted").
-- - public.comment_likes: (user, comment). People read only their own rows.
-- - videos.comment_count: comments that are not deleted, replies included.
-- - videos.comments_mode: 'on', 'off' or 'held' (held for review arrives
--   with moderation, feature 14), or null to follow the channel.
--   channels.comments_default is the channel's mode for new videos.
--
-- Reading
-- - Anyone may read comments that are not deleted on public and unlisted
--   ready videos (row level security). The page uses the functions below,
--   which add the author's handle, name and picture and the viewer's like.
-- - list_comments(video_id, sort, cursor, lim): top level comments. sort is
--   'top' (likes, then newest) or 'newest'. cursor is null for the first
--   page, else {"likes", "at", "id"} of the last comment shown (lib/comments
--   /cursor.ts makes it). The pinned comment comes first on the first page
--   and is left out of the rest. Deleted comments only show while they
--   still have replies.
-- - list_replies(parent_id, cursor, lim): replies, oldest first; cursor is
--   {"at", "id"} of the last reply shown.
-- - comments_since(video_id, cursor, lim): top level comments newer than
--   {"at", "id"}, for the "new comments" pill (the page polls it).
-- - comments_info(video_id): the count, the mode and whether the caller
--   owns the video.
-- - studio_comments(lim): the latest comments on the caller's videos.
--
-- Writing, only through these functions
-- - post_comment(video_id, body, parent_id): signed in and finished sign up.
--   10 comments a minute and 100 a day per person; accounts less than a day
--   old 3 a minute. Mode 'off' stops everybody, 'held' everybody but the
--   owner, until moderation arrives.
-- - edit_comment(comment_id, body): the author.
-- - delete_comment(comment_id): the author or the video's owner.
-- - like_comment(comment_id, on): on true or false sets it, null toggles.
-- - pin_comment(comment_id, on), heart_comment(comment_id, on): the video's
--   owner. Pinning one unpins the one before.
-- - set_comments_mode(video_id, mode), set_channel_comments_default(mode).
-- - Likes, edits, deletes, pins and hearts: 60 a minute per person.
-- - Errors: comments_off, comments_disabled, comments_held, not_signed_in,
--   not_onboarded, not_found, not_allowed, bad_body, body_too_long,
--   bad_parent, bad_sort, bad_mode, rate_limited_minute, rate_limited_day,
--   rate_limited_new, rate_limited.
--
-- The "comments" feature flag, off until the owner switches it on.
--
-- Keep the numbers in step with lib/comments/rules.ts.
--
-- Run after 011_engagement.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.comments_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'comments'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Line endings to \n, no blank runs longer than one empty line, no space at
-- the ends. Same as cleanBody() in lib/comments/rules.ts.
create or replace function public.comment_clean_body(body text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(
    regexp_replace(replace(coalesce(body, ''), E'\r\n', E'\n'), E'\n{3,}', E'\n\n', 'g'),
    E' \t\n\r'
  );
$$;

-- Columns ------------------------------------------------------------------------------

alter table public.videos add column if not exists comment_count bigint not null default 0;
alter table public.videos drop constraint if exists videos_comment_count_positive;
alter table public.videos add constraint videos_comment_count_positive check (comment_count >= 0);

alter table public.videos add column if not exists comments_mode text;
alter table public.videos drop constraint if exists videos_comments_mode_valid;
alter table public.videos add constraint videos_comments_mode_valid
  check (comments_mode is null or comments_mode in ('on', 'off', 'held'));

alter table public.channels add column if not exists comments_default text not null default 'on';
alter table public.channels drop constraint if exists channels_comments_default_valid;
alter table public.channels add constraint channels_comments_default_valid
  check (comments_default in ('on', 'off', 'held'));

-- 004 grants channel columns one by one; the default is public, like the rest.
grant select (comments_default) on public.channels to anon, authenticated;

-- Tables --------------------------------------------------------------------------------

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  video_id uuid not null references public.videos (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  parent_id uuid references public.comments (id) on delete cascade,
  body text not null,
  like_count bigint not null default 0,
  reply_count int not null default 0,
  pinned boolean not null default false,
  hearted boolean not null default false,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz,
  constraint comments_body_length check (
    char_length(body) <= 2000 and (deleted_at is not null or char_length(body) >= 1)
  ),
  constraint comments_counts_positive check (like_count >= 0 and reply_count >= 0),
  constraint comments_pin_top_level check (not pinned or parent_id is null)
);

-- Top level pages: newest, and top (likes, then newest).
create index if not exists comments_video_new_idx
  on public.comments (video_id, created_at desc, id desc) where parent_id is null;
create index if not exists comments_video_top_idx
  on public.comments (video_id, like_count desc, created_at desc, id desc) where parent_id is null;
create index if not exists comments_replies_idx on public.comments (parent_id, created_at, id) where parent_id is not null;
create index if not exists comments_author_idx on public.comments (author_id, created_at desc);
-- One pinned comment per video.
create unique index if not exists comments_one_pinned_key on public.comments (video_id) where pinned;

alter table public.comments enable row level security;

drop policy if exists "comments on watchable videos are readable by everyone" on public.comments;
create policy "comments on watchable videos are readable by everyone"
  on public.comments
  for select
  to anon, authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.videos v
      where v.id = comments.video_id and v.status = 'ready' and v.visibility in ('public', 'unlisted')
    )
  );

revoke all on public.comments from anon, authenticated;
grant select on public.comments to anon, authenticated;

create table if not exists public.comment_likes (
  user_id uuid not null references public.profiles (id) on delete cascade,
  comment_id uuid not null references public.comments (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);

create index if not exists comment_likes_comment_idx on public.comment_likes (comment_id);

alter table public.comment_likes enable row level security;

drop policy if exists "people read their own comment likes" on public.comment_likes;
create policy "people read their own comment likes"
  on public.comment_likes
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.comment_likes from anon, authenticated;
grant select on public.comment_likes to authenticated;

-- One row per counted call, for the rate limits. Nobody reads it through the API.
create table if not exists public.comment_requests (
  user_id uuid not null references public.profiles (id) on delete cascade,
  bucket text not null,
  at timestamptz not null default now()
);

create index if not exists comment_requests_recent_idx on public.comment_requests (user_id, bucket, at desc);

alter table public.comment_requests enable row level security;
revoke all on public.comment_requests from anon, authenticated;

-- Counters --------------------------------------------------------------------------------

-- videos.comment_count and the parent's reply_count count comments that are
-- not deleted. A comment counts while deleted_at is null.
create or replace function public.comments_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  was int := case when tg_op <> 'INSERT' and old.deleted_at is null then 1 else 0 end;
  now_alive int := case when tg_op <> 'DELETE' and new.deleted_at is null then 1 else 0 end;
  vid uuid := case when tg_op = 'DELETE' then old.video_id else new.video_id end;
  parent uuid := case when tg_op = 'DELETE' then old.parent_id else new.parent_id end;
begin
  if now_alive = was then
    return null;
  end if;
  update public.videos v set comment_count = greatest(v.comment_count + now_alive - was, 0) where v.id = vid;
  if parent is not null then
    update public.comments c set reply_count = greatest(c.reply_count + now_alive - was, 0) where c.id = parent;
  end if;
  return null;
end;
$$;

drop trigger if exists comments_count on public.comments;
create trigger comments_count
  after insert or update of deleted_at or delete on public.comments
  for each row execute function public.comments_count();

create or replace function public.comment_likes_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.comments c set like_count = c.like_count + 1 where c.id = new.comment_id;
  else
    update public.comments c set like_count = greatest(c.like_count - 1, 0) where c.id = old.comment_id;
  end if;
  return null;
end;
$$;

drop trigger if exists comment_likes_count on public.comment_likes;
create trigger comment_likes_count
  after insert or delete on public.comment_likes
  for each row execute function public.comment_likes_count();

-- Recount, so the counts are right whatever happened before this run.
update public.comments c
   set like_count = coalesce((select count(*) from public.comment_likes l where l.comment_id = c.id), 0)
 where c.like_count is distinct from coalesce((select count(*) from public.comment_likes l where l.comment_id = c.id), 0);

update public.comments c
   set reply_count = coalesce((select count(*) from public.comments r where r.parent_id = c.id and r.deleted_at is null), 0)
 where c.reply_count is distinct from coalesce((
     select count(*) from public.comments r where r.parent_id = c.id and r.deleted_at is null
   ), 0);

update public.videos v
   set comment_count = coalesce((select count(*) from public.comments c where c.video_id = v.id and c.deleted_at is null), 0)
 where v.comment_count is distinct from coalesce((
     select count(*) from public.comments c where c.video_id = v.id and c.deleted_at is null
   ), 0);

-- What the page shows of a comment ---------------------------------------------------------

-- Only the functions below read this (security definer). Deleted comments
-- have no body and no author. liked and mine are for the caller.
create or replace view public.comment_cards
with (security_invoker = true)
as
select
  c.id,
  c.video_id,
  c.parent_id,
  case when c.deleted_at is null then c.body end as body,
  c.like_count,
  c.reply_count,
  c.pinned,
  c.hearted and c.deleted_at is null as hearted,
  c.created_at,
  c.edited_at,
  c.deleted_at is not null as deleted,
  case when c.deleted_at is null then coalesce(ch.handle, p.username) end as author_handle,
  case when c.deleted_at is null then coalesce(nullif(ch.name, ''), nullif(p.display_name, ''), p.username) end as author_name,
  case when c.deleted_at is null then coalesce(ch.avatar_url, p.avatar_url) end as author_avatar_url,
  c.author_id = v.owner_id and c.deleted_at is null as by_owner,
  c.author_id = (select auth.uid()) as mine,
  exists (
    select 1 from public.comment_likes l where l.comment_id = c.id and l.user_id = (select auth.uid())
  ) as liked
from public.comments c
join public.videos v on v.id = c.video_id
join public.profiles p on p.id = c.author_id
left join public.channels ch on ch.owner_id = c.author_id;

revoke all on public.comment_cards from public, anon, authenticated;

-- Helpers ---------------------------------------------------------------------------------

-- The video's comments mode: its own, else its channel's, else 'on'.
create or replace function public.video_comments_mode(video_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(v.comments_mode, c.comments_default, 'on')
  from public.videos v
  left join public.channels c on c.id = v.channel_id
  where v.id = video_comments_mode.video_id;
$$;

-- May the caller see this video's comments? Ready, and public, unlisted or theirs.
create or replace function public.comments_video_visible(video_id uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.videos v
    where v.id = comments_video_visible.video_id
      and v.status = 'ready'
      and (v.visibility in ('public', 'unlisted') or v.owner_id = uid)
  );
$$;

-- Counts one call and raises past the limit. Locks per person, so the count
-- cannot be raced. 'post': 10 a minute (3 for accounts under a day old) and
-- 100 a day. 'act': 60 a minute.
create or replace function public.comment_throttle(who uuid, bucket text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  last_minute int;
  last_day int;
  young boolean;
begin
  perform pg_advisory_xact_lock(hashtextextended('comments:' || bucket || ':' || who::text, 0));
  -- Keep a day of rows for this person; now and then sweep everybody's.
  delete from public.comment_requests r
   where r.user_id = who and r.bucket = comment_throttle.bucket and r.at < now() - interval '1 day';
  if random() < 0.01 then
    delete from public.comment_requests r where r.at < now() - interval '1 day';
  end if;

  select
    count(*) filter (where r.at >= now() - interval '1 minute'),
    count(*)
  into last_minute, last_day
  from public.comment_requests r
  where r.user_id = who and r.bucket = comment_throttle.bucket;

  if bucket = 'post' then
    select p.created_at > now() - interval '1 day' into young from public.profiles p where p.id = who;
    if coalesce(young, false) and last_minute >= 3 then
      raise exception 'rate_limited_new' using errcode = 'P0001';
    end if;
    if last_minute >= 10 then
      raise exception 'rate_limited_minute' using errcode = 'P0001';
    end if;
    if last_day >= 100 then
      raise exception 'rate_limited_day' using errcode = 'P0001';
    end if;
  elsif last_minute >= 60 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.comment_requests (user_id, bucket) values (who, comment_throttle.bucket);
end;
$$;

-- The checks every write starts with: signed in and the flag on. Answers the caller.
create or replace function public.comments_writer()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.comments_flag_on(me) then
    raise exception 'comments_off' using errcode = 'P0001';
  end if;
  return me;
end;
$$;

-- RPCs ---------------------------------------------------------------------------------

-- The return type is part of the signature, so drop older shapes first.
drop function if exists public.comments_info(uuid);
drop function if exists public.list_comments(uuid, text, jsonb, int);
drop function if exists public.list_replies(uuid, jsonb, int);
drop function if exists public.comments_since(uuid, jsonb, int);
drop function if exists public.post_comment(uuid, text, uuid);
drop function if exists public.edit_comment(uuid, text);
drop function if exists public.delete_comment(uuid);
drop function if exists public.like_comment(uuid, boolean);
drop function if exists public.pin_comment(uuid, boolean);
drop function if exists public.heart_comment(uuid, boolean);
drop function if exists public.set_comments_mode(uuid, text);
drop function if exists public.set_channel_comments_default(text);
drop function if exists public.studio_comments(int);

-- The header of the comments section. No row when the caller may not see the video.
create function public.comments_info(video_id uuid)
returns table (comment_count bigint, mode text, is_owner boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select
    v.comment_count,
    public.video_comments_mode(v.id),
    coalesce(v.owner_id = (select auth.uid()), false)
  from public.videos v
  where v.id = comments_info.video_id
    and public.comments_flag_on((select auth.uid()))
    and public.comments_video_visible(v.id, (select auth.uid()));
$$;

create function public.list_comments(
  video_id uuid,
  sort text default 'top',
  cursor jsonb default null,
  lim int default 20
)
returns setof public.comment_cards
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  n int := least(greatest(coalesce(lim, 20), 1), 50);
  c_likes bigint := (list_comments.cursor ->> 'likes')::bigint;
  c_at timestamptz := (list_comments.cursor ->> 'at')::timestamptz;
  c_id uuid := (list_comments.cursor ->> 'id')::uuid;
begin
  if list_comments.sort is null or list_comments.sort not in ('top', 'newest') then
    raise exception 'bad_sort' using errcode = 'P0001';
  end if;
  if not public.comments_flag_on(me)
     or not public.comments_video_visible(list_comments.video_id, me)
     or public.video_comments_mode(list_comments.video_id) = 'off' then
    return;
  end if;

  -- The pinned comment leads the first page, in both sorts.
  if list_comments.cursor is null then
    return query
    select k.* from public.comment_cards k
    where k.video_id = list_comments.video_id and k.parent_id is null and k.pinned and not k.deleted;
  end if;

  if list_comments.sort = 'newest' then
    return query
    select k.* from public.comment_cards k
    where k.video_id = list_comments.video_id
      and k.parent_id is null
      and not k.pinned
      and (not k.deleted or k.reply_count > 0)
      and (c_at is null or (k.created_at, k.id) < (c_at, coalesce(c_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by k.created_at desc, k.id desc
    limit n;
  else
    return query
    select k.* from public.comment_cards k
    where k.video_id = list_comments.video_id
      and k.parent_id is null
      and not k.pinned
      and (not k.deleted or k.reply_count > 0)
      and (
        c_at is null
        or (k.like_count, k.created_at, k.id)
           < (coalesce(c_likes, 0), c_at, coalesce(c_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
      )
    order by k.like_count desc, k.created_at desc, k.id desc
    limit n;
  end if;
end;
$$;

create function public.list_replies(parent_id uuid, cursor jsonb default null, lim int default 10)
returns setof public.comment_cards
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  n int := least(greatest(coalesce(lim, 10), 1), 50);
  c_at timestamptz := (list_replies.cursor ->> 'at')::timestamptz;
  c_id uuid := (list_replies.cursor ->> 'id')::uuid;
  vid uuid;
begin
  select c.video_id into vid from public.comments c where c.id = list_replies.parent_id and c.parent_id is null;
  if vid is null
     or not public.comments_flag_on(me)
     or not public.comments_video_visible(vid, me)
     or public.video_comments_mode(vid) = 'off' then
    return;
  end if;
  return query
  select k.* from public.comment_cards k
  where k.parent_id = list_replies.parent_id
    and not k.deleted
    and (c_at is null or (k.created_at, k.id) > (c_at, coalesce(c_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  order by k.created_at, k.id
  limit n;
end;
$$;

-- Top level comments newer than the newest one the page has, newest first.
create function public.comments_since(video_id uuid, cursor jsonb, lim int default 50)
returns setof public.comment_cards
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  n int := least(greatest(coalesce(lim, 50), 1), 100);
  c_at timestamptz := (comments_since.cursor ->> 'at')::timestamptz;
  c_id uuid := (comments_since.cursor ->> 'id')::uuid;
begin
  if not public.comments_flag_on(me)
     or not public.comments_video_visible(comments_since.video_id, me)
     or public.video_comments_mode(comments_since.video_id) = 'off' then
    return;
  end if;
  return query
  select k.* from public.comment_cards k
  where k.video_id = comments_since.video_id
    and k.parent_id is null
    and not k.deleted
    and (c_at is null or (k.created_at, k.id) > (c_at, coalesce(c_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  order by k.created_at desc, k.id desc
  limit n;
end;
$$;

create function public.post_comment(video_id uuid, body text, parent_id uuid default null)
returns setof public.comment_cards
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
  v public.videos;
  mode text;
  text_in text := public.comment_clean_body(post_comment.body);
  parent public.comments;
  top uuid;
  new_id uuid;
begin
  if not coalesce((select p.onboarded from public.profiles p where p.id = me), false) then
    raise exception 'not_onboarded' using errcode = 'P0001';
  end if;
  select * into v from public.videos x where x.id = post_comment.video_id;
  if not found or not public.comments_video_visible(v.id, me) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  mode := public.video_comments_mode(v.id);
  if mode = 'off' then
    raise exception 'comments_disabled' using errcode = 'P0001';
  end if;
  if mode = 'held' and v.owner_id <> me then
    raise exception 'comments_held' using errcode = 'P0001';
  end if;
  if char_length(text_in) = 0 then
    raise exception 'bad_body' using errcode = 'P0001';
  end if;
  if char_length(text_in) > 2000 then
    raise exception 'body_too_long' using errcode = 'P0001';
  end if;
  if post_comment.parent_id is not null then
    select * into parent from public.comments c where c.id = post_comment.parent_id;
    if not found or parent.video_id <> v.id then
      raise exception 'bad_parent' using errcode = 'P0001';
    end if;
    -- A reply to a reply goes under the same top level comment.
    top := coalesce(parent.parent_id, parent.id);
    if exists (select 1 from public.comments c where c.id = top and c.deleted_at is not null and c.reply_count = 0) then
      raise exception 'bad_parent' using errcode = 'P0001';
    end if;
  end if;
  perform public.comment_throttle(me, 'post');

  insert into public.comments (video_id, author_id, parent_id, body)
  values (v.id, me, top, text_in)
  returning id into new_id;

  return query select k.* from public.comment_cards k where k.id = new_id;
end;
$$;

create function public.edit_comment(comment_id uuid, body text)
returns setof public.comment_cards
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
  c public.comments;
  text_in text := public.comment_clean_body(edit_comment.body);
begin
  select * into c from public.comments x where x.id = edit_comment.comment_id;
  if not found or c.deleted_at is not null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if c.author_id <> me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if char_length(text_in) = 0 then
    raise exception 'bad_body' using errcode = 'P0001';
  end if;
  if char_length(text_in) > 2000 then
    raise exception 'body_too_long' using errcode = 'P0001';
  end if;
  perform public.comment_throttle(me, 'act');
  update public.comments x
     set body = text_in, edited_at = case when x.body = text_in then x.edited_at else now() end
   where x.id = c.id;
  return query select k.* from public.comment_cards k where k.id = c.id;
end;
$$;

-- Soft delete: the row stays for its replies, the body goes.
create function public.delete_comment(comment_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
  c public.comments;
  owner uuid;
begin
  select * into c from public.comments x where x.id = delete_comment.comment_id;
  if not found or c.deleted_at is not null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  select v.owner_id into owner from public.videos v where v.id = c.video_id;
  if c.author_id <> me and owner is distinct from me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  perform public.comment_throttle(me, 'act');
  update public.comments x
     set deleted_at = now(), body = '', pinned = false, hearted = false
   where x.id = c.id;
  return true;
end;
$$;

create function public.like_comment(comment_id uuid, "on" boolean default null)
returns table (liked boolean, like_count bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
  c public.comments;
  want boolean;
begin
  select * into c from public.comments x where x.id = like_comment.comment_id;
  if not found or c.deleted_at is not null or not public.comments_video_visible(c.video_id, me) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  perform public.comment_throttle(me, 'act');
  want := coalesce(
    like_comment."on",
    not exists (select 1 from public.comment_likes l where l.user_id = me and l.comment_id = c.id)
  );
  if want then
    insert into public.comment_likes (user_id, comment_id) values (me, c.id)
    on conflict on constraint comment_likes_pkey do nothing;
  else
    delete from public.comment_likes l where l.user_id = me and l.comment_id = c.id;
  end if;
  return query
  select exists (select 1 from public.comment_likes l where l.user_id = me and l.comment_id = c.id), x.like_count
  from public.comments x where x.id = c.id;
end;
$$;

-- The comment and the video, when the caller owns the video. Else not_allowed.
create or replace function public.comment_for_owner(comment_id uuid, me uuid)
returns public.comments
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.comments;
begin
  select * into c from public.comments x where x.id = comment_for_owner.comment_id;
  if not found or c.deleted_at is not null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.videos v where v.id = c.video_id and v.owner_id = me) then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  return c;
end;
$$;

create function public.pin_comment(comment_id uuid, "on" boolean default true)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
  c public.comments := public.comment_for_owner(pin_comment.comment_id, me);
begin
  if c.parent_id is not null then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  perform public.comment_throttle(me, 'act');
  if coalesce(pin_comment."on", true) then
    update public.comments x set pinned = false where x.video_id = c.video_id and x.pinned and x.id <> c.id;
    update public.comments x set pinned = true where x.id = c.id;
  else
    update public.comments x set pinned = false where x.id = c.id;
  end if;
  return coalesce(pin_comment."on", true);
end;
$$;

create function public.heart_comment(comment_id uuid, "on" boolean default true)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
  c public.comments := public.comment_for_owner(heart_comment.comment_id, me);
begin
  perform public.comment_throttle(me, 'act');
  update public.comments x set hearted = coalesce(heart_comment."on", true) where x.id = c.id;
  return coalesce(heart_comment."on", true);
end;
$$;

-- mode null makes the video follow its channel again.
create function public.set_comments_mode(video_id uuid, mode text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
begin
  if mode is not null and mode not in ('on', 'off', 'held') then
    raise exception 'bad_mode' using errcode = 'P0001';
  end if;
  update public.videos v set comments_mode = set_comments_mode.mode
   where v.id = set_comments_mode.video_id and v.owner_id = me;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  return public.video_comments_mode(set_comments_mode.video_id);
end;
$$;

create function public.set_channel_comments_default(mode text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.comments_writer();
begin
  if mode is null or mode not in ('on', 'off', 'held') then
    raise exception 'bad_mode' using errcode = 'P0001';
  end if;
  update public.channels c set comments_default = set_channel_comments_default.mode where c.owner_id = me;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  return mode;
end;
$$;

-- /studio/comments: the latest comments on the caller's videos, any author.
create function public.studio_comments(lim int default 50)
returns table (
  id uuid,
  video_id uuid,
  video_title text,
  parent_id uuid,
  body text,
  like_count bigint,
  reply_count int,
  pinned boolean,
  hearted boolean,
  created_at timestamptz,
  edited_at timestamptz,
  author_handle text,
  author_name text,
  author_avatar_url text,
  by_owner boolean,
  channel_default text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    k.id, k.video_id, v.title, k.parent_id, k.body, k.like_count, k.reply_count, k.pinned, k.hearted,
    k.created_at, k.edited_at, k.author_handle, k.author_name, k.author_avatar_url, k.by_owner,
    coalesce((select ch.comments_default from public.channels ch where ch.owner_id = (select auth.uid())), 'on')
  from public.comment_cards k
  join public.videos v on v.id = k.video_id
  where v.owner_id = (select auth.uid())
    and not k.deleted
    and public.comments_flag_on((select auth.uid()))
  order by k.created_at desc, k.id desc
  limit least(greatest(coalesce(studio_comments.lim, 50), 1), 50);
$$;

-- Who may call what ------------------------------------------------------------------------

revoke execute on function public.comments_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.comments_count() from public, anon, authenticated;
revoke execute on function public.comment_likes_count() from public, anon, authenticated;
revoke execute on function public.video_comments_mode(uuid) from public, anon, authenticated;
revoke execute on function public.comments_video_visible(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.comment_throttle(uuid, text) from public, anon, authenticated;
revoke execute on function public.comments_writer() from public, anon, authenticated;
revoke execute on function public.comment_for_owner(uuid, uuid) from public, anon, authenticated;

revoke execute on function public.comments_info(uuid) from public;
revoke execute on function public.list_comments(uuid, text, jsonb, int) from public;
revoke execute on function public.list_replies(uuid, jsonb, int) from public;
revoke execute on function public.comments_since(uuid, jsonb, int) from public;
revoke execute on function public.post_comment(uuid, text, uuid) from public;
revoke execute on function public.edit_comment(uuid, text) from public;
revoke execute on function public.delete_comment(uuid) from public;
revoke execute on function public.like_comment(uuid, boolean) from public;
revoke execute on function public.pin_comment(uuid, boolean) from public;
revoke execute on function public.heart_comment(uuid, boolean) from public;
revoke execute on function public.set_comments_mode(uuid, text) from public;
revoke execute on function public.set_channel_comments_default(text) from public;
revoke execute on function public.studio_comments(int) from public;

grant execute on function public.comments_info(uuid) to anon, authenticated;
grant execute on function public.list_comments(uuid, text, jsonb, int) to anon, authenticated;
grant execute on function public.list_replies(uuid, jsonb, int) to anon, authenticated;
grant execute on function public.comments_since(uuid, jsonb, int) to anon, authenticated;
grant execute on function public.post_comment(uuid, text, uuid) to authenticated;
grant execute on function public.edit_comment(uuid, text) to authenticated;
grant execute on function public.delete_comment(uuid) to authenticated;
grant execute on function public.like_comment(uuid, boolean) to authenticated;
grant execute on function public.pin_comment(uuid, boolean) to authenticated;
grant execute on function public.heart_comment(uuid, boolean) to authenticated;
grant execute on function public.set_comments_mode(uuid, text) to authenticated;
grant execute on function public.set_channel_comments_default(text) to authenticated;
grant execute on function public.studio_comments(int) to authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'comments',
  'Comments',
  'The comments section under the watch page: posting, replies, likes, the creator''s pin and heart, and /studio/comments.',
  'off'
)
on conflict (key) do nothing;

-- ===== 013_shorts.sql =====
-- 013_shorts.sql
-- Shorts: vertical videos of a minute or less, the /shorts feed and its
-- ranking, the shelf on the home feed, the Shorts tab on channel pages, a
-- 3 second view for shorts, the shorts flag.
--
-- What a short is
-- - videos.is_short is true when the processed video is vertical (height
--   greater than width) and 60 seconds or under (the duration rounded down,
--   so whatever the player shows as 1:00 or less), unless the uploader said
--   no. A trigger sets it whenever duration_s, width, height or
--   short_choice change, so encode_done (006) needs no change. Rows from
--   before this file are recounted once at the end of the columns section.
-- - videos.short_choice is the uploader's "Upload as a Short" box: null
--   (decide by shape, the default for every video so far), true or false.
--   True never makes a horizontal or long video a short.
-- - set_short_choice(video_id, on) sets it: the owner only, and once the
--   video is processed, on = true is refused with not_a_short when the
--   video does not qualify. 30 changes a minute per person.
--
-- The feed
-- - list_shorts(cursor, lim) for /shorts and the home shelf: public, ready
--   shorts, never the viewer's own. Unwatched shorts first (tier 0), the
--   ones the viewer already watched after them (tier 1); in each tier by
--   score, then id. The score is the trending math of feature 6 (008) with
--   likes and comments added and one point to start, so new shorts without
--   views still rank by how new they are:
--     (1 + views + 2 * likes + 3 * comments) / max(hours since publish, 1) ^ 1.5
--   rounded to 6 decimals so it survives the trip through JSON.
-- - cursor is null for the first page, else {"at", "tier", "score", "id"}
--   of the last short shown (lib/shorts/cursor.ts makes it). "at" is the
--   moment the first page was read: the age in the score, which shorts are
--   in (published by then) and which count as watched (by then) are all
--   measured at "at", never at now(), so the same cursor gives the same page
--   while the counts stand still. When the counts move between two pages a
--   short can cross the page boundary; the page drops ids it already has.
-- - get_short(video_id) for /shorts/<id>: one ready video, public or
--   unlisted (or the caller's own), with the same columns and is_short, so
--   the page can send a regular video on to /watch.
-- - 60 list_shorts calls a minute per person or address, logged in
--   shorts_requests. Errors: shorts_off, rate_limited, not_signed_in,
--   not_found, not_allowed, not_a_short.
--
-- Watched and views
-- - public.short_watches: (person, short) with when it first reached 3
--   seconds. watch_ping writes it for signed in viewers unless their history
--   is paused. People read their own rows.
-- - A short counts a view at 3 seconds watched instead of 10 (the same once
--   per viewer per day rule as 011): view_threshold_s(duration, is_short).
--   watch_ping is the one from 011 with that threshold and the short_watches
--   row; nothing else in it changes.
--
-- Home and channels
-- - feed_videos gains exclude_shorts (the home grid and the Videos tab leave
--   shorts out while the shelf and the Shorts tab show them), kind
--   'channel_shorts' (one channel's shorts, newest first, same keyset as
--   'channel') and an is_short column.
--
-- The "shorts" feature flag, off until the owner switches it on.
--
-- Keep the numbers in step with lib/shorts/rules.ts.
--
-- Run after 012_comments.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.shorts_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'shorts'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Vertical and a minute or less, unless the uploader said no. Same as
-- isShort() in lib/shorts/rules.ts.
create or replace function public.video_is_short(duration numeric, width int, height int, choice boolean)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(choice, true)
     and coalesce(width, 0) > 0
     and coalesce(height, 0) > width
     and coalesce(duration, 0) > 0
     and floor(duration) <= 60
$$;

-- Seconds of watching that make a view: 3 for a short (or the whole short
-- when it is shorter), else the 011 rule. Keep in step with viewThreshold().
create or replace function public.view_threshold_s(duration numeric, is_short boolean)
returns int
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(is_short, false) then
      case when duration is null or duration <= 0 then 3 else least(3, greatest(1, floor(duration)::int)) end
    else public.view_threshold_s(duration)
  end
$$;

-- The score of one short at a given moment. Same as shortsScore().
create or replace function public.shorts_score(
  views bigint,
  likes bigint,
  comments bigint,
  published_at timestamptz,
  as_of timestamptz
)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round((
    (1 + greatest(coalesce(views, 0), 0) + 2 * greatest(coalesce(likes, 0), 0) + 3 * greatest(coalesce(comments, 0), 0))::double precision
    / power(greatest(extract(epoch from (as_of - published_at)) / 3600.0, 1.0), 1.5)
  )::numeric, 6)
$$;

-- Columns ------------------------------------------------------------------------------

alter table public.videos add column if not exists is_short boolean not null default false;
alter table public.videos add column if not exists short_choice boolean;

create or replace function public.videos_set_is_short()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.is_short := public.video_is_short(new.duration_s, new.width, new.height, new.short_choice);
  return new;
end;
$$;

drop trigger if exists videos_set_is_short on public.videos;
create trigger videos_set_is_short
  before insert or update of duration_s, width, height, short_choice on public.videos
  for each row execute function public.videos_set_is_short();

-- Recount, so every video already processed gets the right value.
update public.videos v
   set is_short = public.video_is_short(v.duration_s, v.width, v.height, v.short_choice)
 where v.is_short is distinct from public.video_is_short(v.duration_s, v.width, v.height, v.short_choice);

-- The shorts feed and a channel's Shorts tab.
create index if not exists videos_shorts_idx
  on public.videos (published_at desc, id desc)
  where is_short and visibility = 'public' and status = 'ready';
create index if not exists videos_channel_shorts_idx
  on public.videos (channel_id, published_at desc, id desc)
  where is_short and visibility = 'public' and status = 'ready';

-- Tables --------------------------------------------------------------------------------

create table if not exists public.short_watches (
  user_id uuid not null references public.profiles (id) on delete cascade,
  video_id uuid not null references public.videos (id) on delete cascade,
  watched_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

create index if not exists short_watches_video_idx on public.short_watches (video_id);

alter table public.short_watches enable row level security;

drop policy if exists "people read their own short watches" on public.short_watches;
create policy "people read their own short watches"
  on public.short_watches
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.short_watches from anon, authenticated;
grant select on public.short_watches to authenticated;

-- One row per counted call, for the rate limits. Nobody reads it through the API.
create table if not exists public.shorts_requests (
  key text not null,
  bucket text not null,
  at timestamptz not null default now()
);

create index if not exists shorts_requests_recent_idx on public.shorts_requests (key, bucket, at desc);

alter table public.shorts_requests enable row level security;
revoke all on public.shorts_requests from anon, authenticated;

-- Clearing the history (011) forgets which shorts were watched too.
create or replace function public.short_watches_follow_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.short_watches s where s.user_id = old.user_id and s.video_id = old.video_id;
  return null;
end;
$$;

drop trigger if exists short_watches_follow_history on public.watch_history;
create trigger short_watches_follow_history
  after delete on public.watch_history
  for each row execute function public.short_watches_follow_history();

-- Helpers ---------------------------------------------------------------------------------

-- Counts one call and raises rate_limited past the limit. The person, else
-- the hashed viewer cookie (011), else the address. 'list': 60 a minute,
-- 'choice': 30 a minute. Locks per key, so the count cannot be raced.
create or replace function public.shorts_throttle(bucket text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  headers json := nullif(current_setting('request.headers', true), '')::json;
  who text;
  recent int;
  lim int := case bucket when 'choice' then 30 else 60 end;
begin
  who := public.engagement_viewer_key();
  if who is null then
    who := 'addr:' || left(coalesce(nullif(btrim(split_part(coalesce(headers ->> 'x-forwarded-for', ''), ',', 1)), ''), 'unknown'), 64);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('shorts:' || bucket || ':' || who, 0));
  delete from public.shorts_requests r
   where r.key = who and r.bucket = shorts_throttle.bucket and r.at < now() - interval '1 minute';
  if random() < 0.01 then
    delete from public.shorts_requests r where r.at < now() - interval '1 minute';
  end if;
  select count(*) into recent from public.shorts_requests r where r.key = who and r.bucket = shorts_throttle.bucket;
  if recent >= lim then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.shorts_requests (key, bucket) values (who, shorts_throttle.bucket);
end;
$$;

-- RPCs ---------------------------------------------------------------------------------

-- The return type is part of the signature, so drop older shapes first.
drop function if exists public.list_shorts(jsonb, int);
drop function if exists public.get_short(uuid);
drop function if exists public.set_short_choice(uuid, boolean);
drop function if exists public.feed_videos(text, timestamptz, uuid, int, uuid);
drop function if exists public.feed_videos(text, timestamptz, uuid, int, uuid, boolean);

-- One page of the shorts feed. See the top of this file for the order.
create function public.list_shorts(cursor jsonb default null, lim int default 10)
returns table (
  id uuid,
  title text,
  duration_s numeric,
  width int,
  height int,
  thumbnail_url text,
  hls_key text,
  published_at timestamptz,
  views bigint,
  like_count bigint,
  comment_count bigint,
  comments_mode text,
  my_reaction text,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text,
  tier int,
  score numeric,
  as_of timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  at_time timestamptz;
  c_tier int;
  c_score numeric;
  c_id uuid;
  n int := least(greatest(coalesce(list_shorts.lim, 10), 1), 30);
begin
  if not public.shorts_flag_on(me) then
    raise exception 'shorts_off' using errcode = 'P0001';
  end if;
  perform public.shorts_throttle('list');

  if list_shorts.cursor is not null then
    begin
      at_time := (list_shorts.cursor ->> 'at')::timestamptz;
      c_tier := (list_shorts.cursor ->> 'tier')::int;
      c_score := (list_shorts.cursor ->> 'score')::numeric;
      c_id := (list_shorts.cursor ->> 'id')::uuid;
    exception when others then
      at_time := null;
    end;
    -- A broken cursor or one from the future gives an empty page, never the first one again.
    if at_time is null or c_tier is null or c_score is null or c_id is null or at_time > now() + interval '1 minute' then
      return;
    end if;
  else
    at_time := now();
  end if;

  return query
  with ranked as (
    select
      v.*,
      case when exists (
        select 1 from public.short_watches w
        where w.user_id = me and w.video_id = v.id and w.watched_at <= at_time
      ) then 1 else 0 end as t,
      public.shorts_score(v.views, v.like_count, v.comment_count, v.published_at, at_time) as s
    from public.videos v
    where v.is_short
      and v.visibility = 'public'
      and v.status = 'ready'
      and v.published_at is not null
      and v.published_at <= at_time
      and v.owner_id is distinct from me
  )
  select
    r.id,
    r.title,
    r.duration_s,
    r.width,
    r.height,
    r.thumbnail_url,
    r.hls_key,
    r.published_at,
    r.views,
    r.like_count,
    r.comment_count,
    coalesce(r.comments_mode, c.comments_default, 'on'),
    (select x.kind from public.video_reactions x where x.user_id = me and x.video_id = r.id),
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url,
    r.t,
    r.s,
    at_time
  from ranked r
  join public.channels c on c.id = r.channel_id
  where c_id is null
     or r.t > c_tier
     or (r.t = c_tier and (r.s < c_score or (r.s = c_score and r.id < c_id)))
  order by r.t, r.s desc, r.id desc
  limit n;
end;
$$;

-- One video for /shorts/<id>, with is_short so a regular video can go on to /watch.
create function public.get_short(video_id uuid)
returns table (
  id uuid,
  title text,
  duration_s numeric,
  width int,
  height int,
  thumbnail_url text,
  hls_key text,
  published_at timestamptz,
  views bigint,
  like_count bigint,
  comment_count bigint,
  comments_mode text,
  my_reaction text,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text,
  is_short boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    v.id,
    v.title,
    v.duration_s,
    v.width,
    v.height,
    v.thumbnail_url,
    v.hls_key,
    v.published_at,
    v.views,
    v.like_count,
    v.comment_count,
    coalesce(v.comments_mode, c.comments_default, 'on'),
    (select x.kind from public.video_reactions x where x.user_id = (select auth.uid()) and x.video_id = v.id),
    c.id,
    c.handle,
    coalesce(nullif(c.name, ''), c.handle),
    c.avatar_url,
    v.is_short
  from public.videos v
  join public.channels c on c.id = v.channel_id
  where v.id = get_short.video_id
    and v.status = 'ready'
    and (v.visibility in ('public', 'unlisted') or v.owner_id = (select auth.uid()))
    and public.shorts_flag_on((select auth.uid()));
$$;

-- The "Upload as a Short" box. Answers is_short after the change.
create function public.set_short_choice(video_id uuid, "on" boolean)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v public.videos;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.shorts_flag_on(me) then
    raise exception 'shorts_off' using errcode = 'P0001';
  end if;
  perform public.shorts_throttle('choice');
  select * into v from public.videos x where x.id = set_short_choice.video_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v.owner_id <> me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  -- Before processing the shape is not known yet: the choice waits for it.
  if set_short_choice."on" and v.duration_s is not null
     and not public.video_is_short(v.duration_s, v.width, v.height, true) then
    raise exception 'not_a_short' using errcode = 'P0001';
  end if;
  update public.videos x set short_choice = set_short_choice."on" where x.id = v.id
  returning x.is_short into v.is_short;
  return v.is_short;
end;
$$;

-- feed_videos from 008, with exclude_shorts, kind 'channel_shorts' and is_short.
create function public.feed_videos(
  kind text default 'newest',
  cursor timestamptz default null,
  cursor_id uuid default null,
  lim int default 24,
  for_channel uuid default null,
  exclude_shorts boolean default false
)
returns table (
  id uuid,
  title text,
  duration_s numeric,
  thumbnail_url text,
  hls_key text,
  preview_sprite_key text,
  published_at timestamptz,
  views bigint,
  score double precision,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_avatar_url text,
  is_short boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  with args as (
    select
      coalesce(feed_videos.kind, 'newest') as kind,
      least(greatest(coalesce(feed_videos.lim, 24), 1), 50) as lim
  ),
  cards as (
    select
      v.id,
      v.title,
      v.duration_s,
      v.thumbnail_url,
      v.hls_key,
      v.preview_sprite_key,
      v.published_at,
      v.views,
      v.views::double precision
        / power(greatest(extract(epoch from (now() - v.published_at)) / 3600.0, 1.0), 1.5) as score,
      c.id as channel_id,
      c.handle as channel_handle,
      coalesce(nullif(c.name, ''), c.handle) as channel_name,
      c.avatar_url as channel_avatar_url,
      v.is_short
    from public.videos v
    join public.channels c on c.id = v.channel_id
    cross join args a
    where v.visibility = 'public'
      and v.status = 'ready'
      and v.published_at is not null
      and case a.kind
        when 'newest' then true
        when 'trending' then v.published_at > now() - interval '30 days'
        when 'channel' then v.channel_id = feed_videos.for_channel
        when 'channel_shorts' then v.channel_id = feed_videos.for_channel and v.is_short
        else false
      end
      and not (coalesce(feed_videos.exclude_shorts, false) and a.kind <> 'channel_shorts' and v.is_short)
      and (
        a.kind = 'trending'
        or feed_videos.cursor is null
        or (v.published_at, v.id) < (feed_videos.cursor, coalesce(feed_videos.cursor_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
      )
  )
  select cards.*
  from cards
  cross join args a
  order by
    case when a.kind = 'trending' then cards.score end desc nulls last,
    cards.published_at desc,
    cards.id desc
  limit (select lim from args);
$$;

-- watch_ping from 011: a short counts at 3 seconds, and signed in viewers
-- get a short_watches row when they reach that. Nothing else changes.
create or replace function public.watch_ping(video_id uuid, position_s numeric, played_s numeric)
returns table (counted boolean, views bigint, watched_s int)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  who text;
  v public.videos;
  today date := (now() at time zone 'utc')::date;
  ev public.view_events;
  opened boolean := false;
  credit numeric;
  counted_now boolean := false;
  pos numeric;
  total bigint;
  paused boolean;
begin
  if not public.engagement_flag_on(me) then
    raise exception 'engagement_off' using errcode = 'P0001';
  end if;
  who := public.engagement_viewer_key();
  if who is null then
    raise exception 'no_viewer_key' using errcode = 'P0001';
  end if;
  select * into v from public.videos x where x.id = watch_ping.video_id;
  if not found or v.status <> 'ready'
     or not (v.visibility in ('public', 'unlisted') or v.owner_id = me) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  perform public.engagement_throttle(who, 'ping');

  pos := greatest(0, coalesce(watch_ping.position_s, 0));
  if v.duration_s is not null and v.duration_s > 0 then
    pos := least(pos, v.duration_s);
  end if;

  insert into public.view_events as e (video_id, viewer_key, day)
  values (v.id, who, today)
  on conflict on constraint view_events_pkey do nothing;
  get diagnostics total = row_count;
  opened := total > 0;

  select * into ev from public.view_events e
   where e.video_id = v.id and e.viewer_key = who and e.day = today
   for update;

  credit := case when opened then 0 else least(greatest(coalesce(watch_ping.played_s, 0), 0), 60) end;
  ev.watched_s := greatest(
    ev.watched_s,
    least(ev.watched_s + floor(credit)::int, floor(extract(epoch from (now() - ev.first_at)))::int + 1)
  );
  if not ev.counted and ev.watched_s >= public.view_threshold_s(v.duration_s, v.is_short) then
    ev.counted := true;
    counted_now := true;
  end if;

  update public.view_events e
     set watched_s = ev.watched_s, counted = ev.counted, last_at = now()
   where e.video_id = v.id and e.viewer_key = who and e.day = today;

  if counted_now then
    update public.videos x set views = x.views + 1 where x.id = v.id returning x.views into total;
  else
    total := v.views;
  end if;

  if me is not null then
    paused := coalesce((select p.history_paused from public.profiles p where p.id = me), false);
    if not paused then
      insert into public.watch_history as h (user_id, video_id, position_s, duration_s, last_at)
      values (me, v.id, pos, v.duration_s, now())
      on conflict on constraint watch_history_pkey do update
        set position_s = excluded.position_s, duration_s = excluded.duration_s, last_at = excluded.last_at;
      if v.is_short and ev.watched_s >= public.view_threshold_s(v.duration_s, true) then
        insert into public.short_watches as s (user_id, video_id)
        values (me, v.id)
        on conflict on constraint short_watches_pkey do nothing;
      end if;
    end if;
  end if;

  return query select counted_now, total, ev.watched_s;
end;
$$;

-- Internal helpers are not part of the API.
revoke execute on function public.shorts_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.shorts_throttle(text) from public, anon, authenticated;
revoke execute on function public.videos_set_is_short() from public, anon, authenticated;
revoke execute on function public.short_watches_follow_history() from public, anon, authenticated;

revoke execute on function public.list_shorts(jsonb, int) from public;
revoke execute on function public.get_short(uuid) from public;
revoke execute on function public.set_short_choice(uuid, boolean) from public;
revoke execute on function public.feed_videos(text, timestamptz, uuid, int, uuid, boolean) from public;

grant execute on function public.list_shorts(jsonb, int) to anon, authenticated;
grant execute on function public.get_short(uuid) to anon, authenticated;
grant execute on function public.set_short_choice(uuid, boolean) to authenticated;
grant execute on function public.feed_videos(text, timestamptz, uuid, int, uuid, boolean) to anon, authenticated;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'shorts',
  'Shorts',
  'The /shorts feed and /shorts/<id>, the Shorts shelf on the home feed, the Shorts tab on channel pages and the "Upload as a Short" box.',
  'off'
)
on conflict (key) do nothing;

-- ===== 014_studio.sql =====
-- 014_studio.sql
-- The creator studio: the dashboard numbers, the Content list with the
-- trash, bulk changes, the edit page (title, description, visibility, tags,
-- thumbnail), the purge after 30 days and the R2 cleanup queue, the studio
-- flag.
--
-- The trash (a soft delete)
-- - videos.deleted_at is set when the owner deletes a video. A video in the
--   trash is always private: the visibility it had is kept in
--   videos.trash_visibility and put back on restore. Every page, feed, RPC
--   and policy from 005 to 013 already hides private videos from everybody
--   but the owner, so none of them needs to change, and channels.video_count
--   follows through its trigger (006). The guard trigger refuses any change
--   that would make a video in the trash anything but private (in_trash).
-- - The trash keeps a video for 30 days (studio_trash_days()). purge_trash()
--   then deletes the row for good (comments, likes, views and history go
--   with it through on delete cascade) and queues its R2 folders in
--   storage_cleanup. pg_cron runs it every day at 03:17 UTC when pg_cron is
--   on; otherwise this file says so with a notice.
-- - storage_cleanup is drained by the encoder worker (worker/lib/cleanup.mjs)
--   with claim_cleanup, cleanup_done and cleanup_failed (service role only).
--   Each row is one prefix: hls/<video>/ and uploads/<owner>/<video>/.
--   A failed row is tried again up to 5 times; a running row left behind for
--   15 minutes is taken back.
--
-- RPCs (all need the studio flag; errors are the message, P0001)
-- - studio_overview() for the dashboard: the channel, its totals (views,
--   videos, subscribers, likes, comments, watch time), the last 28 days from
--   video_stats_daily (011), the latest video with its numbers, the trash count.
-- - studio_videos(trash) the caller's videos, the trash with its purge date.
-- - studio_bulk(video_ids, action, visibility) action 'visibility', 'trash'
--   or 'restore' on up to 100 of the caller's own videos at once. All or
--   nothing: one id that is not the caller's (or does not exist) refuses the
--   whole call with not_allowed. 60 calls a minute per person ('bulk').
-- - update_video(video_id, title, description, visibility, tags) the edit
--   page. set_video_thumbnail(video_id, name, url) picks one of the encoder's
--   stills (thumb-1.webp to thumb-3.webp) or a custom upload
--   (custom-<random>.<jpg|png|webp>, under hls/<video>/). url is the public
--   link the app worked out, or null. 60 edits a minute per person ('edit').
-- - Errors: studio_off, not_signed_in, not_found, not_allowed, rate_limited,
--   bad_action, bad_visibility, too_many, in_trash, title_invalid,
--   description_invalid, tags_invalid, thumbnail_invalid, not_ready.
--
-- videos.tags: up to 15 tags of 1 to 30 characters, 500 characters in all.
-- videos.thumbnail_name: the chosen file, null for the default (thumb-1.webp).
--
-- The "studio" feature flag, off until the owner switches it on.
--
-- Keep the numbers in step with lib/studio/rules.ts.
--
-- Run after 013_shorts.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.studio_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'studio'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- How long the trash keeps a video. Same as TRASH_DAYS.
create or replace function public.studio_trash_days()
returns int
language sql
immutable
set search_path = ''
as $$
  select 30
$$;

-- Same as tagsProblem() in lib/studio/rules.ts.
create or replace function public.video_tags_are_valid(tags text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select tags is not null
     and coalesce(array_length(tags, 1), 0) <= 15
     and coalesce(char_length(array_to_string(tags, ',')), 0) <= 500
     and not exists (
       select 1 from unnest(tags) as t(tag)
       where t.tag is null or char_length(t.tag) not between 1 and 30 or t.tag <> btrim(t.tag) or t.tag ~ '[,\n\r\t]'
     )
$$;

-- Same as isThumbnailName() in lib/studio/rules.ts.
create or replace function public.video_thumbnail_name_is_valid(name text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select name ~ '^(thumb-[1-3]\.webp|custom-[a-z0-9]{12,32}\.(jpg|png|webp))$'
$$;

-- Columns ------------------------------------------------------------------------------

alter table public.videos add column if not exists deleted_at timestamptz;
alter table public.videos add column if not exists trash_visibility text;
alter table public.videos add column if not exists tags text[] not null default '{}';
alter table public.videos add column if not exists thumbnail_name text;

alter table public.videos drop constraint if exists videos_trash_visibility_valid;
alter table public.videos add constraint videos_trash_visibility_valid
  check (trash_visibility is null or trash_visibility in ('private', 'unlisted', 'public'));
alter table public.videos drop constraint if exists videos_tags_valid;
alter table public.videos add constraint videos_tags_valid check (public.video_tags_are_valid(tags));
alter table public.videos drop constraint if exists videos_thumbnail_name_valid;
alter table public.videos add constraint videos_thumbnail_name_valid
  check (thumbnail_name is null or public.video_thumbnail_name_is_valid(thumbnail_name));

create index if not exists videos_trash_idx on public.videos (deleted_at) where deleted_at is not null;

-- A video in the trash stays private, whoever changes it.
create or replace function public.videos_trash_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.deleted_at is not null and new.visibility <> 'private' then
    raise exception 'in_trash' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists videos_trash_guard on public.videos;
create trigger videos_trash_guard
  before insert or update of visibility, deleted_at on public.videos
  for each row execute function public.videos_trash_guard();

-- Tables --------------------------------------------------------------------------------

-- One row per counted call, for the rate limits. Nobody reads it through the API.
create table if not exists public.studio_requests (
  user_id uuid not null,
  bucket text not null,
  at timestamptz not null default now()
);

create index if not exists studio_requests_recent_idx on public.studio_requests (user_id, bucket, at desc);

alter table public.studio_requests enable row level security;
revoke all on public.studio_requests from anon, authenticated;

-- R2 folders to delete. No foreign key: the video row is gone by then.
create table if not exists public.storage_cleanup (
  id uuid primary key default gen_random_uuid(),
  video_id uuid not null,
  prefix text not null,
  status text not null default 'queued',
  attempts int not null default 0,
  worker text,
  error text,
  deleted_objects int,
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  constraint storage_cleanup_status_valid check (status in ('queued', 'running', 'done', 'failed')),
  -- Only the two folders a video has, so a bad row can never empty the bucket.
  constraint storage_cleanup_prefix_valid check (
    prefix ~ '^hls/[0-9a-f-]{36}/$' or prefix ~ '^uploads/[0-9a-f-]{36}/[0-9a-f-]{36}/$'
  ),
  constraint storage_cleanup_once unique (prefix)
);

create index if not exists storage_cleanup_todo_idx on public.storage_cleanup (queued_at)
  where status in ('queued', 'failed', 'running');

alter table public.storage_cleanup enable row level security;
revoke all on public.storage_cleanup from anon, authenticated;

-- Helpers ---------------------------------------------------------------------------------

-- Counts one call and raises rate_limited past the limit: 60 a minute for
-- 'bulk' and for 'edit'. Locks per person, so the count cannot be raced.
create or replace function public.studio_throttle(who uuid, bucket text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  recent int;
begin
  perform pg_advisory_xact_lock(hashtextextended('studio:' || bucket || ':' || who::text, 0));
  delete from public.studio_requests r
   where r.user_id = who and r.bucket = studio_throttle.bucket and r.at < now() - interval '1 minute';
  if random() < 0.01 then
    delete from public.studio_requests r where r.at < now() - interval '1 minute';
  end if;
  select count(*) into recent from public.studio_requests r where r.user_id = who and r.bucket = studio_throttle.bucket;
  if recent >= 60 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.studio_requests (user_id, bucket) values (who, studio_throttle.bucket);
end;
$$;

-- Signed in and the flag on. Answers the caller.
create or replace function public.studio_caller()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.studio_flag_on(me) then
    raise exception 'studio_off' using errcode = 'P0001';
  end if;
  return me;
end;
$$;

-- RPCs ---------------------------------------------------------------------------------

drop function if exists public.studio_overview();
drop function if exists public.studio_videos(boolean);
drop function if exists public.studio_bulk(uuid[], text, text);
drop function if exists public.update_video(uuid, text, text, text, text[]);
drop function if exists public.set_video_thumbnail(uuid, text, text);

-- The dashboard, as one JSON object:
--   channel  {id, handle, name, avatar_url, subscribers}, or null
--   totals   {views, videos, public_videos, likes, comments, watch_s}
--   recent   {days: 28, views, watch_s} from video_stats_daily
--   latest   the newest video that is not in the trash, or null:
--            {id, title, visibility, status, thumbnail_url, thumbnail_name,
--             hls_key, created_at, published_at, views, likes, comments, watch_s}
--   trash    how many videos are in the trash
create function public.studio_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := public.studio_caller();
  ch public.channels;
  out jsonb;
begin
  select * into ch from public.channels c where c.owner_id = me;
  select jsonb_build_object(
    'channel', case when ch.id is null then null else jsonb_build_object(
      'id', ch.id, 'handle', ch.handle, 'name', coalesce(nullif(ch.name, ''), ch.handle),
      'avatar_url', ch.avatar_url, 'subscribers', ch.subscriber_count
    ) end,
    'totals', (
      select jsonb_build_object(
        'views', coalesce(sum(v.views), 0),
        'videos', count(*),
        'public_videos', count(*) filter (where v.visibility = 'public' and v.status = 'ready'),
        'likes', coalesce(sum(v.like_count), 0),
        'comments', coalesce(sum(v.comment_count), 0),
        'watch_s', coalesce((
          select sum(e.watched_s) from public.view_events e
          join public.videos w on w.id = e.video_id
          where w.owner_id = me and w.deleted_at is null
        ), 0)
      )
      from public.videos v
      where v.owner_id = me and v.deleted_at is null
    ),
    'recent', (
      select jsonb_build_object('days', 28, 'views', coalesce(sum(s.views), 0), 'watch_s', coalesce(sum(s.watch_s), 0))
      from public.video_stats_daily s
      join public.videos v on v.id = s.video_id
      where v.owner_id = me and v.deleted_at is null
        and s.day > (now() at time zone 'utc')::date - 28
    ),
    'latest', (
      select jsonb_build_object(
        'id', v.id, 'title', v.title, 'visibility', v.visibility, 'status', v.status,
        'thumbnail_url', v.thumbnail_url, 'thumbnail_name', v.thumbnail_name, 'hls_key', v.hls_key,
        'created_at', v.created_at, 'published_at', v.published_at,
        'views', v.views, 'likes', v.like_count, 'comments', v.comment_count,
        'watch_s', coalesce((select sum(e.watched_s) from public.view_events e where e.video_id = v.id), 0)
      )
      from public.videos v
      where v.owner_id = me and v.deleted_at is null
      order by v.created_at desc, v.id desc
      limit 1
    ),
    'trash', (select count(*) from public.videos v where v.owner_id = me and v.deleted_at is not null)
  ) into out;
  return out;
end;
$$;

-- The caller's videos, newest first: the Content list, or with trash = true
-- the trash, with the moment each one goes for good. At most 500.
create function public.studio_videos(trash boolean default false)
returns table (
  id uuid,
  title text,
  description text,
  visibility text,
  status text,
  is_short boolean,
  short_choice boolean,
  duration_s numeric,
  thumbnail_url text,
  thumbnail_name text,
  hls_key text,
  tags text[],
  comments_mode text,
  created_at timestamptz,
  published_at timestamptz,
  views bigint,
  like_count bigint,
  comment_count bigint,
  deleted_at timestamptz,
  trash_visibility text,
  purge_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := public.studio_caller();
begin
  return query
  select
    v.id, v.title, v.description, v.visibility, v.status, v.is_short, v.short_choice, v.duration_s,
    v.thumbnail_url, v.thumbnail_name, v.hls_key, v.tags, v.comments_mode, v.created_at, v.published_at,
    v.views::bigint, v.like_count::bigint, v.comment_count::bigint, v.deleted_at, v.trash_visibility,
    v.deleted_at + make_interval(days => public.studio_trash_days())
  from public.videos v
  where v.owner_id = me
    and (v.deleted_at is not null) = coalesce(studio_videos.trash, false)
  order by coalesce(v.deleted_at, v.created_at) desc, v.id desc
  limit 500;
end;
$$;

-- Bulk changes on the caller's own videos. Answers how many changed.
create function public.studio_bulk(video_ids uuid[], action text, visibility text default null)
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.studio_caller();
  ids uuid[];
  found_n int;
  changed int := 0;
begin
  if studio_bulk.action is null or studio_bulk.action not in ('visibility', 'trash', 'restore') then
    raise exception 'bad_action' using errcode = 'P0001';
  end if;
  if studio_bulk.action = 'visibility'
     and (studio_bulk.visibility is null or studio_bulk.visibility not in ('private', 'unlisted', 'public')) then
    raise exception 'bad_visibility' using errcode = 'P0001';
  end if;
  select coalesce(array_agg(distinct x), '{}') into ids from unnest(coalesce(studio_bulk.video_ids, '{}')) as u(x) where x is not null;
  if cardinality(ids) = 0 then
    return 0;
  end if;
  if cardinality(ids) > 100 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;
  perform public.studio_throttle(me, 'bulk');

  -- Lock the rows, and refuse the whole call unless every one is the caller's.
  perform 1 from public.videos v where v.id = any (ids) order by v.id for update;
  select count(*) into found_n from public.videos v where v.id = any (ids) and v.owner_id = me;
  if found_n <> cardinality(ids) then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;

  if studio_bulk.action = 'visibility' then
    if exists (select 1 from public.videos v where v.id = any (ids) and v.deleted_at is not null) then
      raise exception 'in_trash' using errcode = 'P0001';
    end if;
    update public.videos v set visibility = studio_bulk.visibility
     where v.id = any (ids) and v.visibility <> studio_bulk.visibility;
    get diagnostics changed = row_count;
  elsif studio_bulk.action = 'trash' then
    update public.videos v
       set deleted_at = now(), trash_visibility = v.visibility, visibility = 'private'
     where v.id = any (ids) and v.deleted_at is null;
    get diagnostics changed = row_count;
  else
    update public.videos v
       set deleted_at = null, visibility = coalesce(v.trash_visibility, 'private'), trash_visibility = null
     where v.id = any (ids) and v.deleted_at is not null;
    get diagnostics changed = row_count;
  end if;
  return changed;
end;
$$;

-- The edit page. tags are cleaned by the app; anything the check would
-- refuse is tags_invalid here.
create function public.update_video(
  video_id uuid,
  title text,
  description text,
  visibility text,
  tags text[] default '{}'
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.studio_caller();
  v public.videos;
  clean_title text := btrim(coalesce(update_video.title, ''));
  clean_tags text[] := coalesce(update_video.tags, '{}');
begin
  select * into v from public.videos x where x.id = update_video.video_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v.owner_id <> me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if v.deleted_at is not null then
    raise exception 'in_trash' using errcode = 'P0001';
  end if;
  if char_length(clean_title) not between 1 and 100 then
    raise exception 'title_invalid' using errcode = 'P0001';
  end if;
  if char_length(coalesce(update_video.description, '')) > 5000 then
    raise exception 'description_invalid' using errcode = 'P0001';
  end if;
  if update_video.visibility is null or update_video.visibility not in ('private', 'unlisted', 'public') then
    raise exception 'bad_visibility' using errcode = 'P0001';
  end if;
  if not public.video_tags_are_valid(clean_tags) then
    raise exception 'tags_invalid' using errcode = 'P0001';
  end if;
  perform public.studio_throttle(me, 'edit');
  update public.videos x
     set title = clean_title,
         description = coalesce(update_video.description, ''),
         visibility = update_video.visibility,
         tags = clean_tags
   where x.id = v.id;
end;
$$;

-- Picks the thumbnail. name null goes back to the default still.
create function public.set_video_thumbnail(video_id uuid, name text, url text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.studio_caller();
  v public.videos;
begin
  select * into v from public.videos x where x.id = set_video_thumbnail.video_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v.owner_id <> me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if v.deleted_at is not null then
    raise exception 'in_trash' using errcode = 'P0001';
  end if;
  if v.status <> 'ready' or v.hls_key is null then
    raise exception 'not_ready' using errcode = 'P0001';
  end if;
  if (set_video_thumbnail.name is not null and not public.video_thumbnail_name_is_valid(set_video_thumbnail.name))
     or (set_video_thumbnail.url is not null and (
       set_video_thumbnail.url !~ '^https://'
       or right(set_video_thumbnail.url, char_length(coalesce(set_video_thumbnail.name, 'thumb-1.webp')) + 1) <> '/' || coalesce(set_video_thumbnail.name, 'thumb-1.webp')
     )) then
    raise exception 'thumbnail_invalid' using errcode = 'P0001';
  end if;
  perform public.studio_throttle(me, 'edit');
  update public.videos x
     set thumbnail_name = set_video_thumbnail.name,
         thumbnail_url = set_video_thumbnail.url
   where x.id = v.id;
end;
$$;

-- The purge and the cleanup queue ------------------------------------------------------------

-- Deletes videos that have been in the trash for 30 days and queues their R2
-- folders. Also forgets cleanup rows that finished a month ago. Answers how
-- many videos went. pg_cron (or the service role) only.
create or replace function public.purge_trash(lim int default 500)
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  gone int := 0;
begin
  with old as (
    select v.id, v.owner_id
    from public.videos v
    where v.deleted_at is not null
      and v.deleted_at < now() - make_interval(days => public.studio_trash_days())
    order by v.deleted_at
    limit least(greatest(coalesce(purge_trash.lim, 500), 1), 5000)
    for update skip locked
  ),
  queued as (
    insert into public.storage_cleanup (video_id, prefix)
    select o.id, p.prefix
    from old o
    cross join lateral (values
      ('hls/' || o.id::text || '/'),
      ('uploads/' || o.owner_id::text || '/' || o.id::text || '/')
    ) as p(prefix)
    on conflict on constraint storage_cleanup_once do update
      set status = 'queued', attempts = 0, error = null, queued_at = now()
    returning 1
  ),
  deleted as (
    delete from public.videos v using old o where v.id = o.id
    returning 1
  )
  -- Every part of the statement runs, so the folders are queued as the rows go.
  select count(*) into gone from deleted;

  delete from public.storage_cleanup c where c.status = 'done' and c.finished_at < now() - interval '30 days';
  return gone;
end;
$$;

-- The next folders for the worker. Queued and failed rows (under 5 tries),
-- and running rows left behind for 15 minutes.
create or replace function public.claim_cleanup(worker text, lim int default 20)
returns table (id uuid, prefix text, attempt int)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  return query
  with picked as (
    select c.id
    from public.storage_cleanup c
    where (c.status in ('queued', 'failed') and c.attempts < 5)
       or (c.status = 'running' and c.started_at < now() - interval '15 minutes')
    order by c.queued_at, c.id
    limit least(greatest(coalesce(claim_cleanup.lim, 20), 1), 100)
    for update skip locked
  )
  update public.storage_cleanup c
     set status = 'running', attempts = c.attempts + 1, worker = left(claim_cleanup.worker, 100),
         started_at = now(), error = null
    from picked p
   where c.id = p.id
  returning c.id, c.prefix, c.attempts;
end;
$$;

create or replace function public.cleanup_done(cleanup_id uuid, deleted int default null)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  update public.storage_cleanup c
     set status = 'done', finished_at = now(), error = null, deleted_objects = cleanup_done.deleted
   where c.id = cleanup_done.cleanup_id;
$$;

create or replace function public.cleanup_failed(cleanup_id uuid, error text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  update public.storage_cleanup c
     set status = 'failed', finished_at = now(), error = left(coalesce(cleanup_failed.error, ''), 500)
   where c.id = cleanup_failed.cleanup_id;
$$;

-- Every day at 03:17 UTC with pg_cron when it is on.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- cron.schedule with an existing job name updates that job.
    execute $cron$select cron.schedule('sloptube-trash-purge', '17 3 * * *', 'select public.purge_trash()')$cron$;
  else
    raise notice 'pg_cron is not on: the trash is not emptied after 30 days. Switch it on under Database > Extensions and run this file again.';
  end if;
end;
$$;

-- Who may call what ------------------------------------------------------------------------

revoke execute on function public.studio_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.studio_throttle(uuid, text) from public, anon, authenticated;
revoke execute on function public.studio_caller() from public, anon, authenticated;
revoke execute on function public.videos_trash_guard() from public, anon, authenticated;
revoke execute on function public.purge_trash(int) from public, anon, authenticated;
revoke execute on function public.claim_cleanup(text, int) from public, anon, authenticated;
revoke execute on function public.cleanup_done(uuid, int) from public, anon, authenticated;
revoke execute on function public.cleanup_failed(uuid, text) from public, anon, authenticated;

revoke execute on function public.studio_overview() from public;
revoke execute on function public.studio_videos(boolean) from public;
revoke execute on function public.studio_bulk(uuid[], text, text) from public;
revoke execute on function public.update_video(uuid, text, text, text, text[]) from public;
revoke execute on function public.set_video_thumbnail(uuid, text, text) from public;

grant execute on function public.studio_overview() to authenticated;
grant execute on function public.studio_videos(boolean) to authenticated;
grant execute on function public.studio_bulk(uuid[], text, text) to authenticated;
grant execute on function public.update_video(uuid, text, text, text, text[]) to authenticated;
grant execute on function public.set_video_thumbnail(uuid, text, text) to authenticated;

grant execute on function public.purge_trash(int) to service_role;
grant execute on function public.claim_cleanup(text, int) to service_role;
grant execute on function public.cleanup_done(uuid, int) to service_role;
grant execute on function public.cleanup_failed(uuid, text) to service_role;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'studio',
  'Creator studio',
  'The creator studio at /studio: the dashboard, Content with the trash and bulk changes, the edit page, customization and comments under one left nav.',
  'off'
)
on conflict (key) do nothing;

-- ===== 015_stats.sql =====
-- 015_stats.sql
-- Channel and video analytics for the studio: the daily channel rollup,
-- subscribers gained and lost, the audience retention buckets, traffic
-- sources, hourly views for the realtime card, the stats flag.
--
-- What the view ping now carries (watch_ping, 011 and 013)
-- - watch_ping(video_id, position_s, played_s, source) takes one more,
--   optional argument: where the viewer came from, one of 'home', 'search',
--   'subscriptions', 'channel', 'shorts', 'other' (another page here),
--   'direct' and 'external'. Anything else is stored as null. The first
--   ping of the day sets it on the day's view_events row and later pings
--   leave it alone. Rows from before this file have no source; the traffic
--   card only counts rows that have one and is hidden when there are none.
-- - view_events.reached: which parts of the video the viewer saw, as bits.
--   Bits 0 to 19 are the twenty 5% parts of the video (bit k covers k*5% up
--   to (k+1)*5%), bit 20 is "watched to the end". Each ping marks the
--   stretch it covers: from position_s minus the seconds played since the
--   last ping (at most 60) to position_s. The player does not count seeks
--   as played seconds, so a jump marks nothing it skipped. stats_reached()
--   does the marking; lib/stats/retention.ts is the same in TypeScript.
-- - view_events.counted_at: when the view counted, for the hourly views of
--   the realtime card.
-- - The ping carries no country, so there is no country card.
--
-- Rollups (filled by rollup_video_stats(days) from 011, every hour with
-- pg_cron, which now also does the three below)
-- - public.channel_stats_daily: (channel, day) with views and watch_s (the
--   channel's video_stats_daily rows added up) and subs_gained, subs_lost
--   (kept by a trigger on subscriptions as they happen; the rollup leaves
--   them alone). Subscriptions made before this file are counted as gained
--   on the day they were made, once; unsubscribes from before it are not
--   known. Owners read their own rows.
-- - public.video_retention_daily: (video, day) with viewers (view_events
--   rows that have any part marked) and buckets, 21 counts: how many of
--   them saw part k (0 to 19) and the end (20). Owners read their own rows.
-- - public.video_source_daily: (video, day, source) with views and watch_s.
--   Owners read their own rows.
--
-- RPCs (owner only, need the stats flag, 60 a minute per person in the
-- 'stats' bucket of studio_requests from 014; errors are the message, P0001)
-- - studio_analytics(range) the channel: totals for the range (views,
--   watch_s, subs_gained, subs_lost, viewers: distinct viewer keys with a
--   counted view), the daily series, the top 10 videos by views.
-- - video_analytics(video_id, range) one video: totals (views, watch_s,
--   likes, dislikes, comments, viewers), the daily series, the retention
--   buckets and the traffic sources for the range.
-- - realtime_views(video_id) counted views per hour for the last 48 hours,
--   for one video, or with null for the whole channel.
-- - range is '7d', '28d', '90d' or 'lifetime'. A range of n days ends today
--   (UTC) and starts n - 1 days before. Lifetime starts on the day the
--   channel (or the video) was made.
-- - Errors: stats_off, not_signed_in, not_found, not_allowed, rate_limited,
--   bad_range.
--
-- The "stats" feature flag, off until the owner switches it on.
--
-- Keep the numbers in step with lib/stats/rules.ts and lib/stats/retention.ts.
--
-- Run after 014_studio.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.stats_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'stats'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Same as SOURCES in lib/stats/rules.ts.
create or replace function public.stats_source_is_valid(source text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select source in ('home', 'search', 'subscriptions', 'channel', 'shorts', 'other', 'direct', 'external')
$$;

-- The first day of a range, today included. Same as rangeBounds().
-- 'lifetime' answers null: the caller starts at the channel or the video.
create or replace function public.stats_range_from(range text)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  today date := (now() at time zone 'utc')::date;
begin
  case range
    when '7d' then return today - 6;
    when '28d' then return today - 27;
    when '90d' then return today - 89;
    when 'lifetime' then return null;
    else raise exception 'bad_range' using errcode = 'P0001';
  end case;
end;
$$;

-- Marks the parts of a video that the stretch from_s to to_s covers. Bits 0
-- to 19 are the twenty 5% parts, bit 20 is the end (the last second, or the
-- last 5% of a video under 20 seconds). Same as markReached().
create or replace function public.stats_reached(mask int, from_s numeric, to_s numeric, duration numeric)
returns int
language sql
immutable
set search_path = ''
as $$
  select case
    when duration is null or duration <= 0 or from_s is null or to_s is null then coalesce(mask, 0)
    else coalesce(mask, 0)
      | coalesce((
          select bit_or(1 << k)
          from generate_series(
            least(19, floor(greatest(0, least(from_s, to_s)) * 20 / duration)::int),
            least(19, floor(least(greatest(0, greatest(from_s, to_s)), duration) * 20 / duration)::int)
          ) as g(k)
        ), 0)
      | case when greatest(from_s, to_s) >= duration - least(1, duration * 0.05) then 1 << 20 else 0 end
  end
$$;

-- Columns ------------------------------------------------------------------------------

alter table public.view_events add column if not exists reached int not null default 0;
alter table public.view_events add column if not exists source text;
alter table public.view_events add column if not exists counted_at timestamptz;

alter table public.view_events drop constraint if exists view_events_source_valid;
alter table public.view_events add constraint view_events_source_valid
  check (source is null or public.stats_source_is_valid(source));

-- The realtime card reads the last 48 hours of one video or one channel.
create index if not exists view_events_counted_at_idx on public.view_events (video_id, counted_at)
  where counted_at is not null;

-- Tables --------------------------------------------------------------------------------

create table if not exists public.channel_stats_daily (
  channel_id uuid not null references public.channels (id) on delete cascade,
  day date not null,
  views int not null default 0,
  watch_s bigint not null default 0,
  subs_gained int not null default 0,
  subs_lost int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (channel_id, day)
);

alter table public.channel_stats_daily enable row level security;

drop policy if exists "owners read the stats of their own channel" on public.channel_stats_daily;
create policy "owners read the stats of their own channel"
  on public.channel_stats_daily
  for select
  to authenticated
  using (exists (
    select 1 from public.channels c
    where c.id = channel_stats_daily.channel_id and c.owner_id = (select auth.uid())
  ));

revoke all on public.channel_stats_daily from anon, authenticated;
grant select on public.channel_stats_daily to authenticated;

create table if not exists public.video_retention_daily (
  video_id uuid not null references public.videos (id) on delete cascade,
  day date not null,
  viewers int not null default 0,
  buckets int[] not null default array_fill(0, array[21]),
  updated_at timestamptz not null default now(),
  primary key (video_id, day),
  constraint video_retention_daily_buckets_valid check (cardinality(buckets) = 21)
);

alter table public.video_retention_daily enable row level security;

drop policy if exists "owners read the retention of their own videos" on public.video_retention_daily;
create policy "owners read the retention of their own videos"
  on public.video_retention_daily
  for select
  to authenticated
  using (exists (
    select 1 from public.videos v
    where v.id = video_retention_daily.video_id and v.owner_id = (select auth.uid())
  ));

revoke all on public.video_retention_daily from anon, authenticated;
grant select on public.video_retention_daily to authenticated;

create table if not exists public.video_source_daily (
  video_id uuid not null references public.videos (id) on delete cascade,
  day date not null,
  source text not null,
  views int not null default 0,
  watch_s bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (video_id, day, source),
  constraint video_source_daily_source_valid check (public.stats_source_is_valid(source))
);

alter table public.video_source_daily enable row level security;

drop policy if exists "owners read the traffic sources of their own videos" on public.video_source_daily;
create policy "owners read the traffic sources of their own videos"
  on public.video_source_daily
  for select
  to authenticated
  using (exists (
    select 1 from public.videos v
    where v.id = video_source_daily.video_id and v.owner_id = (select auth.uid())
  ));

revoke all on public.video_source_daily from anon, authenticated;
grant select on public.video_source_daily to authenticated;

-- Subscribers gained and lost ----------------------------------------------------------

create or replace function public.subscriptions_stats()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  today date := (now() at time zone 'utc')::date;
begin
  if tg_op = 'INSERT' then
    insert into public.channel_stats_daily as s (channel_id, day, subs_gained)
    values (new.channel_id, today, 1)
    on conflict on constraint channel_stats_daily_pkey do update
      set subs_gained = s.subs_gained + 1, updated_at = now();
  elsif tg_op = 'DELETE' then
    -- A channel that is being deleted takes its subscriptions with it: nothing to count.
    if exists (select 1 from public.channels c where c.id = old.channel_id) then
      insert into public.channel_stats_daily as s (channel_id, day, subs_lost)
      values (old.channel_id, today, 1)
      on conflict on constraint channel_stats_daily_pkey do update
        set subs_lost = s.subs_lost + 1, updated_at = now();
    end if;
  end if;
  return null;
end;
$$;

-- The subscriptions there already, as gained on their day. Only rows that
-- are not there yet, so running this file again adds nothing.
insert into public.channel_stats_daily (channel_id, day, subs_gained)
select s.channel_id, (s.created_at at time zone 'utc')::date, count(*)::int
from public.subscriptions s
group by s.channel_id, (s.created_at at time zone 'utc')::date
on conflict on constraint channel_stats_daily_pkey do nothing;

drop trigger if exists subscriptions_stats on public.subscriptions;
create trigger subscriptions_stats
  after insert or delete on public.subscriptions
  for each row execute function public.subscriptions_stats();

-- Helpers ---------------------------------------------------------------------------------

-- Signed in and the flag on. Answers the caller.
create or replace function public.stats_caller()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.stats_flag_on(me) then
    raise exception 'stats_off' using errcode = 'P0001';
  end if;
  return me;
end;
$$;

-- The view ping --------------------------------------------------------------------------

-- The return type and the arguments are part of the signature: drop the
-- three argument version so old callers reach this one (source defaults to null).
drop function if exists public.watch_ping(uuid, numeric, numeric);

-- watch_ping from 013, plus the source, the parts reached and counted_at.
create or replace function public.watch_ping(video_id uuid, position_s numeric, played_s numeric, source text default null)
returns table (counted boolean, views bigint, watched_s int)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  who text;
  v public.videos;
  today date := (now() at time zone 'utc')::date;
  ev public.view_events;
  opened boolean := false;
  credit numeric;
  counted_now boolean := false;
  pos numeric;
  total bigint;
  paused boolean;
  src text := case when public.stats_source_is_valid(watch_ping.source) then watch_ping.source end;
begin
  if not public.engagement_flag_on(me) then
    raise exception 'engagement_off' using errcode = 'P0001';
  end if;
  who := public.engagement_viewer_key();
  if who is null then
    raise exception 'no_viewer_key' using errcode = 'P0001';
  end if;
  select * into v from public.videos x where x.id = watch_ping.video_id;
  if not found or v.status <> 'ready'
     or not (v.visibility in ('public', 'unlisted') or v.owner_id = me) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  perform public.engagement_throttle(who, 'ping');

  pos := greatest(0, coalesce(watch_ping.position_s, 0));
  if v.duration_s is not null and v.duration_s > 0 then
    pos := least(pos, v.duration_s);
  end if;

  insert into public.view_events as e (video_id, viewer_key, day, source)
  values (v.id, who, today, src)
  on conflict on constraint view_events_pkey do nothing;
  get diagnostics total = row_count;
  opened := total > 0;

  select * into ev from public.view_events e
   where e.video_id = v.id and e.viewer_key = who and e.day = today
   for update;

  credit := case when opened then 0 else least(greatest(coalesce(watch_ping.played_s, 0), 0), 60) end;
  ev.watched_s := greatest(
    ev.watched_s,
    least(ev.watched_s + floor(credit)::int, floor(extract(epoch from (now() - ev.first_at)))::int + 1)
  );
  if not ev.counted and ev.watched_s >= public.view_threshold_s(v.duration_s, v.is_short) then
    ev.counted := true;
    counted_now := true;
  end if;
  -- The stretch this ping covers, for the retention curve.
  ev.reached := public.stats_reached(
    ev.reached,
    pos - least(greatest(coalesce(watch_ping.played_s, 0), 0), 60),
    pos,
    v.duration_s
  );

  update public.view_events e
     set watched_s = ev.watched_s,
         counted = ev.counted,
         counted_at = case when counted_now then now() else e.counted_at end,
         reached = ev.reached,
         source = coalesce(e.source, src),
         last_at = now()
   where e.video_id = v.id and e.viewer_key = who and e.day = today;

  if counted_now then
    update public.videos x set views = x.views + 1 where x.id = v.id returning x.views into total;
  else
    total := v.views;
  end if;

  if me is not null then
    paused := coalesce((select p.history_paused from public.profiles p where p.id = me), false);
    if not paused then
      insert into public.watch_history as h (user_id, video_id, position_s, duration_s, last_at)
      values (me, v.id, pos, v.duration_s, now())
      on conflict on constraint watch_history_pkey do update
        set position_s = excluded.position_s, duration_s = excluded.duration_s, last_at = excluded.last_at;
      if v.is_short and ev.watched_s >= public.view_threshold_s(v.duration_s, true) then
        insert into public.short_watches as s (user_id, video_id)
        values (me, v.id)
        on conflict on constraint short_watches_pkey do nothing;
      end if;
    end if;
  end if;

  return query select counted_now, total, ev.watched_s;
end;
$$;

-- The rollup ------------------------------------------------------------------------------

-- rollup_video_stats from 011, plus the channel days, the retention buckets
-- and the traffic sources for the same days. Safe to run as often as you like.
create or replace function public.rollup_video_stats(days int default 2)
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  since date := (now() at time zone 'utc')::date - (least(greatest(coalesce(days, 2), 1), 400) - 1);
  touched int;
begin
  insert into public.video_stats_daily as s (video_id, day, views, watch_s, likes, dislikes, updated_at)
  select
    coalesce(e.video_id, r.video_id),
    coalesce(e.day, r.day),
    coalesce(e.views, 0),
    coalesce(e.watch_s, 0),
    coalesce(r.likes, 0),
    coalesce(r.dislikes, 0),
    now()
  from (
    select ve.video_id, ve.day, count(*) filter (where ve.counted)::int as views, sum(ve.watched_s)::bigint as watch_s
    from public.view_events ve
    where ve.day >= since
    group by ve.video_id, ve.day
  ) e
  full outer join (
    select vr.video_id, (vr.created_at at time zone 'utc')::date as day,
           count(*) filter (where vr.kind = 'like')::int as likes,
           count(*) filter (where vr.kind = 'dislike')::int as dislikes
    from public.video_reactions vr
    where vr.created_at >= since::timestamp at time zone 'utc'
    group by vr.video_id, (vr.created_at at time zone 'utc')::date
  ) r on r.video_id = e.video_id and r.day = e.day
  on conflict (video_id, day) do update
    set views = excluded.views,
        watch_s = excluded.watch_s,
        likes = excluded.likes,
        dislikes = excluded.dislikes,
        updated_at = excluded.updated_at;
  get diagnostics touched = row_count;

  -- The channel days: its videos' days added up. Days that lost their rows
  -- (a video deleted for good) go back to 0; the subscriber counts stay.
  insert into public.channel_stats_daily as c (channel_id, day, views, watch_s, updated_at)
  select v.channel_id, s.day, sum(s.views)::int, sum(s.watch_s)::bigint, now()
  from public.video_stats_daily s
  join public.videos v on v.id = s.video_id
  where s.day >= since
  group by v.channel_id, s.day
  on conflict on constraint channel_stats_daily_pkey do update
    set views = excluded.views, watch_s = excluded.watch_s, updated_at = excluded.updated_at;

  update public.channel_stats_daily c
     set views = 0, watch_s = 0, updated_at = now()
   where c.day >= since
     and (c.views <> 0 or c.watch_s <> 0)
     and not exists (
       select 1 from public.video_stats_daily s
       join public.videos v on v.id = s.video_id
       where v.channel_id = c.channel_id and s.day = c.day
     );

  -- Retention: per video and day, the rows with any part marked, and how
  -- many of them marked each of the 21 bits.
  delete from public.video_retention_daily r where r.day >= since;
  insert into public.video_retention_daily (video_id, day, viewers, buckets, updated_at)
  select m.video_id, m.day, max(m.total)::int, array_agg(m.n order by m.k), now()
  from (
    select ve.video_id, ve.day, g.k,
           count(*) filter (where (ve.reached & (1 << g.k)) <> 0)::int as n,
           count(*) as total
    from public.view_events ve
    cross join generate_series(0, 20) as g(k)
    where ve.day >= since and ve.reached <> 0
    group by ve.video_id, ve.day, g.k
  ) m
  group by m.video_id, m.day;

  -- Traffic sources: rows that carry one.
  delete from public.video_source_daily d where d.day >= since;
  insert into public.video_source_daily (video_id, day, source, views, watch_s, updated_at)
  select ve.video_id, ve.day, ve.source, count(*) filter (where ve.counted)::int, sum(ve.watched_s)::bigint, now()
  from public.view_events ve
  where ve.day >= since and ve.source is not null
  group by ve.video_id, ve.day, ve.source;

  return touched;
end;
$$;

-- RPCs ---------------------------------------------------------------------------------

drop function if exists public.studio_analytics(text);
drop function if exists public.video_analytics(uuid, text);
drop function if exists public.realtime_views(uuid);

-- The channel for /studio/analytics, as one JSON object:
--   range, from, to   the range and its first and last day
--   channel           {id, handle, name, subscribers}, or null without a channel
--   totals            {views, watch_s, subs_gained, subs_lost, viewers}
--   daily             [{day, views, watch_s}] days with a row, oldest first
--   top               up to 10 videos by views in the range (not the trash):
--                     [{id, title, status, visibility, is_short, duration_s,
--                       thumbnail_url, thumbnail_name, views, watch_s}]
create function public.studio_analytics(range text default '28d')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.stats_caller();
  since date := public.stats_range_from(studio_analytics.range);
  today date := (now() at time zone 'utc')::date;
  ch public.channels;
  out jsonb;
begin
  perform public.studio_throttle(me, 'stats');
  select * into ch from public.channels c where c.owner_id = me;
  if ch.id is null then
    return jsonb_build_object(
      'range', studio_analytics.range, 'from', coalesce(since, today), 'to', today, 'channel', null,
      'totals', jsonb_build_object('views', 0, 'watch_s', 0, 'subs_gained', 0, 'subs_lost', 0, 'viewers', 0),
      'daily', '[]'::jsonb, 'top', '[]'::jsonb
    );
  end if;
  since := coalesce(since, least((ch.created_at at time zone 'utc')::date, today));

  select jsonb_build_object(
    'range', studio_analytics.range,
    'from', since,
    'to', today,
    'channel', jsonb_build_object(
      'id', ch.id, 'handle', ch.handle, 'name', coalesce(nullif(ch.name, ''), ch.handle), 'subscribers', ch.subscriber_count
    ),
    'totals', (
      select jsonb_build_object(
        'views', coalesce(sum(d.views), 0),
        'watch_s', coalesce(sum(d.watch_s), 0),
        'subs_gained', coalesce(sum(d.subs_gained), 0),
        'subs_lost', coalesce(sum(d.subs_lost), 0),
        'viewers', (
          select count(distinct e.viewer_key)
          from public.view_events e
          join public.videos v on v.id = e.video_id
          where v.channel_id = ch.id and e.counted and e.day >= since
        )
      )
      from public.channel_stats_daily d
      where d.channel_id = ch.id and d.day >= since
    ),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', d.day, 'views', d.views, 'watch_s', d.watch_s) order by d.day)
      from public.channel_stats_daily d
      where d.channel_id = ch.id and d.day >= since
    ), '[]'::jsonb),
    'top', coalesce((
      select jsonb_agg(t.item order by t.views desc, t.watch_s desc, t.id)
      from (
        select v.id, s.views, s.watch_s, jsonb_build_object(
          'id', v.id, 'title', v.title, 'status', v.status, 'visibility', v.visibility, 'is_short', v.is_short,
          'duration_s', v.duration_s, 'thumbnail_url', v.thumbnail_url, 'thumbnail_name', v.thumbnail_name,
          'views', s.views, 'watch_s', s.watch_s
        ) as item
        from (
          select x.video_id, sum(x.views)::bigint as views, sum(x.watch_s)::bigint as watch_s
          from public.video_stats_daily x
          join public.videos w on w.id = x.video_id
          where w.channel_id = ch.id and x.day >= since
          group by x.video_id
        ) s
        join public.videos v on v.id = s.video_id
        where v.deleted_at is null and s.views > 0
        order by s.views desc, s.watch_s desc, v.id
        limit 10
      ) t
    ), '[]'::jsonb)
  ) into out;
  return out;
end;
$$;

-- One video for /studio/video/<id>/analytics, as one JSON object:
--   range, from, to   as above (lifetime starts on the day the video was made)
--   video             {id, title, status, visibility, is_short, duration_s,
--                      thumbnail_url, thumbnail_name, created_at, published_at,
--                      views, likes, dislikes, comments} (all time)
--   totals            {views, watch_s, likes, dislikes, comments, viewers} in the range
--   daily             [{day, views, watch_s}]
--   retention         {viewers, buckets: 21 counts}
--   sources           [{source, views, watch_s}] most views first
create function public.video_analytics(video_id uuid, range text default '28d')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.stats_caller();
  since date := public.stats_range_from(video_analytics.range);
  today date := (now() at time zone 'utc')::date;
  lifetime boolean := video_analytics.range = 'lifetime';
  v public.videos;
  dislike_total bigint;
  out jsonb;
begin
  select * into v from public.videos x where x.id = video_analytics.video_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v.owner_id <> me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  perform public.studio_throttle(me, 'stats');
  since := coalesce(since, least((v.created_at at time zone 'utc')::date, today));
  dislike_total := coalesce((select d.dislike_count from public.video_dislike_counts d where d.video_id = v.id), 0);

  select jsonb_build_object(
    'range', video_analytics.range,
    'from', since,
    'to', today,
    'video', jsonb_build_object(
      'id', v.id, 'title', v.title, 'status', v.status, 'visibility', v.visibility, 'is_short', v.is_short,
      'duration_s', v.duration_s, 'thumbnail_url', v.thumbnail_url, 'thumbnail_name', v.thumbnail_name,
      'created_at', v.created_at, 'published_at', v.published_at,
      'views', v.views, 'likes', v.like_count, 'dislikes', dislike_total, 'comments', v.comment_count
    ),
    'totals', (
      select jsonb_build_object(
        'views', coalesce(sum(s.views), 0),
        'watch_s', coalesce(sum(s.watch_s), 0),
        -- All time, the reactions standing now; in a range, the ones made in it that still stand.
        'likes', case when lifetime then v.like_count else coalesce(sum(s.likes), 0) end,
        'dislikes', case when lifetime then dislike_total else coalesce(sum(s.dislikes), 0) end,
        'comments', (
          select count(*) from public.comments c
          where c.video_id = v.id and c.deleted_at is null
            and c.created_at >= since::timestamp at time zone 'utc'
        ),
        'viewers', (
          select count(distinct e.viewer_key) from public.view_events e
          where e.video_id = v.id and e.counted and e.day >= since
        )
      )
      from public.video_stats_daily s
      where s.video_id = v.id and s.day >= since
    ),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', s.day, 'views', s.views, 'watch_s', s.watch_s) order by s.day)
      from public.video_stats_daily s
      where s.video_id = v.id and s.day >= since
    ), '[]'::jsonb),
    'retention', (
      select jsonb_build_object(
        'viewers', coalesce((select sum(r.viewers) from public.video_retention_daily r where r.video_id = v.id and r.day >= since), 0),
        'buckets', (
          select jsonb_agg(coalesce(b.n, 0) order by g.k)
          from generate_series(1, 21) as g(k)
          left join (
            select u.k, sum(u.n)::bigint as n
            from public.video_retention_daily r
            cross join lateral unnest(r.buckets) with ordinality as u(n, k)
            where r.video_id = v.id and r.day >= since
            group by u.k
          ) b on b.k = g.k
        )
      )
    ),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object('source', x.source, 'views', x.views, 'watch_s', x.watch_s)
                       order by x.views desc, x.watch_s desc, x.source)
      from (
        select d.source, sum(d.views)::bigint as views, sum(d.watch_s)::bigint as watch_s
        from public.video_source_daily d
        where d.video_id = v.id and d.day >= since
        group by d.source
      ) x
    ), '[]'::jsonb)
  ) into out;
  return out;
end;
$$;

-- Counted views per hour for the last 48 hours, oldest first, as
-- [{hour, views}] with only the hours that had views. With video_id, one of
-- the caller's videos; with null, every video on the caller's channel.
create function public.realtime_views(video_id uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.stats_caller();
  v public.videos;
  since timestamptz := date_trunc('hour', now()) - interval '47 hours';
begin
  if realtime_views.video_id is not null then
    select * into v from public.videos x where x.id = realtime_views.video_id;
    if not found then
      raise exception 'not_found' using errcode = 'P0001';
    end if;
    if v.owner_id <> me then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
  end if;
  perform public.studio_throttle(me, 'stats');
  return coalesce((
    select jsonb_agg(jsonb_build_object('hour', h.hour, 'views', h.views) order by h.hour)
    from (
      select date_trunc('hour', e.counted_at) as hour, count(*)::int as views
      from public.view_events e
      join public.videos w on w.id = e.video_id
      where e.counted_at >= since
        and e.day >= (since at time zone 'utc')::date
        and (case when realtime_views.video_id is null then w.owner_id = me and w.deleted_at is null
                  else w.id = realtime_views.video_id end)
      group by 1
    ) h
  ), '[]'::jsonb);
end;
$$;

-- Fill in every day there is (a year at most), then every hour with the
-- pg_cron job from 011, which runs this same function.
select public.rollup_video_stats(400);

-- Who may call what ------------------------------------------------------------------------

revoke execute on function public.stats_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.stats_caller() from public, anon, authenticated;
revoke execute on function public.subscriptions_stats() from public, anon, authenticated;
revoke execute on function public.rollup_video_stats(int) from public, anon, authenticated;

revoke execute on function public.watch_ping(uuid, numeric, numeric, text) from public;
revoke execute on function public.studio_analytics(text) from public;
revoke execute on function public.video_analytics(uuid, text) from public;
revoke execute on function public.realtime_views(uuid) from public;

grant execute on function public.watch_ping(uuid, numeric, numeric, text) to anon, authenticated;
grant execute on function public.studio_analytics(text) to authenticated;
grant execute on function public.video_analytics(uuid, text) to authenticated;
grant execute on function public.realtime_views(uuid) to authenticated;
grant execute on function public.rollup_video_stats(int) to service_role;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'stats',
  'Analytics',
  'Channel analytics at /studio/analytics and per video analytics at /studio/video/<id>/analytics: views, watch time, subscribers, audience retention, traffic sources and the last 48 hours.',
  'off'
)
on conflict (key) do nothing;

-- ===== 016_moderation.sql =====
-- 016_moderation.sql
-- Moderation: reports, the admin role, the queue and its actions, strikes,
-- suspensions, bans, the mod log, the word list and the link cap, removed
-- videos with appeals, the moderation flag.
--
-- People
-- - profiles.role is 'user' or 'admin'. There is no way to change it through
--   the API (the column is not granted): the owner promotes someone in the
--   SQL editor:
--     update public.profiles set role = 'admin' where username = '<name>';
--   is_admin() answers for the caller (an admin who is not banned) and is
--   used by the RPCs and the row level security policies below.
-- - profiles.banned_at and ban_reason: a banned account. Every API request of
--   a banned person is refused with 'banned' before it runs: PostgREST calls
--   moderation_pre_request() first (pgrst.db_pre_request on the
--   authenticator role, set at the end of this file). The ban also deletes
--   the person's auth sessions, and the app signs them out on their next
--   page (proxy.ts). A ban suspends the person's channel too.
-- - channels.suspended_at and suspended_reason: a suspended channel cannot
--   upload or comment, and its videos are hidden: each one that was not
--   private is made private and its visibility kept in
--   videos.held_visibility, put back on unsuspend. Triggers refuse new
--   videos and comments ('suspended', 'banned') and any change that would
--   make a video of a suspended channel anything but private.
-- - channel_strikes: 3 strikes in 90 days suspend the channel (until an
--   admin unsuspends it). Same as lib/moderation/strikes.ts.
--
-- Reports
-- - reports: one row per report. kind 'report' (anyone signed in, on a
--   video, a comment or a channel, reason spam, sexual, violent,
--   harassment, copyright or other, 'other' needs a few words) or 'appeal'
--   (the owner of a removed video asks for it back). One report per person
--   per target, ever; one open appeal per video, and only one per removal.
--   10 reports a day per person. People read their own reports; admins read
--   them all.
-- - report_target(target_kind, target_id, reason, details) and
--   appeal_removal(video_id, details).
--
-- Admins (is_admin() and the flag on, 120 calls a minute)
-- - admin_reports(lim) the open reports with what they point at; the app
--   groups them by target (lib/moderation/queue.ts).
-- - mod_action(action, target_kind, target_id, reason, kind):
--     dismiss    closes the target's open reports (or turns down an appeal)
--     remove     a video: made private and marked removed (the owner sees
--                why in the studio), kept 30 days and then deleted with its
--                files by purge_trash (014); a comment: soft deleted with
--                the "removed by moderation" placeholder
--     restore    gives a removed video back (an upheld appeal)
--     strike     a strike on the channel behind the target
--     suspend, unsuspend   the channel behind the target
--     ban, unban the person behind the target
--   Admin accounts cannot be struck, suspended or banned. dismiss, remove,
--   restore, strike, suspend and ban close the target's open reports of
--   that kind. Every action writes a mod_log row.
-- - admin_log(before, lim), admin_suspended(), admin_words(),
--   admin_set_word(word, on).
--
-- Automod
-- - moderation_words: words and phrases (lowercase letters and digits,
--   single spaces, ' and -, 2 to 40 characters; a trailing * matches any
--   ending). A comment, a video title or a description that contains one as
--   a whole word is refused with 'blocked_words'. A comment with more than
--   5 links is refused with 'too_many_links'. Both only while the flag is on
--   for the writer. Same as lib/moderation/words.ts.
--
-- Errors (the message, P0001): moderation_off, not_signed_in, not_admin,
-- not_found, not_allowed, bad_kind, bad_reason, details_required,
-- details_too_long, already_reported, rate_limited, bad_action,
-- reason_required, reason_too_long, not_removed, already_appealed,
-- bad_word, banned, suspended, removed, blocked_words, too_many_links.
--
-- The "moderation" feature flag, off until the owner switches it on.
--
-- Keep the numbers in step with lib/moderation/rules.ts.
--
-- Run after 015_stats.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.moderation_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'moderation'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Same as lib/moderation/rules.ts.
create or replace function public.moderation_strike_days() returns int language sql immutable set search_path = '' as $$ select 90 $$;
create or replace function public.moderation_strike_limit() returns int language sql immutable set search_path = '' as $$ select 3 $$;
create or replace function public.moderation_link_limit() returns int language sql immutable set search_path = '' as $$ select 5 $$;
create or replace function public.moderation_reports_per_day() returns int language sql immutable set search_path = '' as $$ select 10 $$;

-- Same as isWord() in lib/moderation/words.ts.
create or replace function public.moderation_word_is_valid(word text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select word is not null
     and char_length(word) between 2 and 40
     and word ~ '^[a-z0-9]+([ ''-][a-z0-9]+)*\*?$'
$$;

-- Columns ------------------------------------------------------------------------------

alter table public.profiles add column if not exists role text not null default 'user';
alter table public.profiles add column if not exists banned_at timestamptz;
alter table public.profiles add column if not exists ban_reason text;
alter table public.profiles drop constraint if exists profiles_role_valid;
alter table public.profiles add constraint profiles_role_valid check (role in ('user', 'admin'));

alter table public.channels add column if not exists suspended_at timestamptz;
alter table public.channels add column if not exists suspended_reason text;

alter table public.videos add column if not exists removed_at timestamptz;
alter table public.videos add column if not exists removed_reason text;
alter table public.videos add column if not exists removed_visibility text;
alter table public.videos add column if not exists held_visibility text;
alter table public.videos drop constraint if exists videos_moderation_visibility_valid;
alter table public.videos add constraint videos_moderation_visibility_valid check (
  (removed_visibility is null or removed_visibility in ('private', 'unlisted', 'public'))
  and (held_visibility is null or held_visibility in ('private', 'unlisted', 'public'))
);
create index if not exists videos_removed_idx on public.videos (removed_at) where removed_at is not null;

alter table public.comments add column if not exists removed_at timestamptz;

-- Everyone may see that a channel is suspended (the channel page says so),
-- never why. role, banned_at and ban_reason stay unreadable through the API.
grant select (suspended_at) on public.channels to anon, authenticated;

-- Tables --------------------------------------------------------------------------------

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'report',
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  target_kind text not null,
  target_id uuid not null,
  reason text not null,
  details text not null default '',
  status text not null default 'open',
  resolution text,
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint reports_kind_valid check (kind in ('report', 'appeal')),
  constraint reports_target_kind_valid check (target_kind in ('video', 'comment', 'channel')),
  constraint reports_reason_valid check (
    (kind = 'report' and reason in ('spam', 'sexual', 'violent', 'harassment', 'copyright', 'other'))
    or (kind = 'appeal' and reason = 'appeal' and target_kind = 'video')
  ),
  constraint reports_details_length check (char_length(details) <= 500),
  constraint reports_status_valid check (status in ('open', 'dismissed', 'actioned'))
);

create unique index if not exists reports_once_idx on public.reports (reporter_id, target_kind, target_id) where kind = 'report';
create unique index if not exists reports_open_appeal_idx on public.reports (target_id) where kind = 'appeal' and status = 'open';
create index if not exists reports_open_idx on public.reports (created_at desc) where status = 'open';
create index if not exists reports_target_idx on public.reports (target_kind, target_id, kind);
create index if not exists reports_reporter_recent_idx on public.reports (reporter_id, created_at desc);

create table if not exists public.channel_strikes (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels (id) on delete cascade,
  actor_id uuid references public.profiles (id) on delete set null,
  reason text not null default '',
  target_kind text,
  target_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists channel_strikes_recent_idx on public.channel_strikes (channel_id, created_at desc);

create table if not exists public.mod_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles (id) on delete set null,
  action text not null,
  target_kind text not null,
  target_id uuid,
  target_label text not null default '',
  reason text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists mod_log_recent_idx on public.mod_log (created_at desc, id desc);

create table if not exists public.moderation_words (
  word text primary key,
  added_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint moderation_words_valid check (public.moderation_word_is_valid(word))
);

-- One row per counted admin call, for the rate limit. Nobody reads it through the API.
create table if not exists public.moderation_requests (
  user_id uuid not null,
  bucket text not null,
  at timestamptz not null default now()
);

create index if not exists moderation_requests_recent_idx on public.moderation_requests (user_id, bucket, at desc);

-- Who is an admin ------------------------------------------------------------------------

-- The caller is an admin and not banned. Used by the policies below.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'admin' and p.banned_at is null
  );
$$;

-- Row level security ------------------------------------------------------------------------

alter table public.reports enable row level security;
alter table public.channel_strikes enable row level security;
alter table public.mod_log enable row level security;
alter table public.moderation_words enable row level security;
alter table public.moderation_requests enable row level security;

revoke all on public.reports from anon, authenticated;
revoke all on public.channel_strikes from anon, authenticated;
revoke all on public.mod_log from anon, authenticated;
revoke all on public.moderation_words from anon, authenticated;
revoke all on public.moderation_requests from anon, authenticated;

grant select on public.reports to authenticated;
grant select on public.channel_strikes to authenticated;
grant select on public.mod_log to authenticated;
grant select on public.moderation_words to authenticated;

drop policy if exists "people read their own reports" on public.reports;
create policy "people read their own reports"
  on public.reports for select to authenticated
  using (reporter_id = (select auth.uid()));

drop policy if exists "admins read every report" on public.reports;
create policy "admins read every report"
  on public.reports for select to authenticated
  using ((select public.is_admin()));

drop policy if exists "owners read their channel strikes" on public.channel_strikes;
create policy "owners read their channel strikes"
  on public.channel_strikes for select to authenticated
  using (exists (select 1 from public.channels c where c.id = channel_id and c.owner_id = (select auth.uid())));

drop policy if exists "admins read every strike" on public.channel_strikes;
create policy "admins read every strike"
  on public.channel_strikes for select to authenticated
  using ((select public.is_admin()));

drop policy if exists "admins read the mod log" on public.mod_log;
create policy "admins read the mod log"
  on public.mod_log for select to authenticated
  using ((select public.is_admin()));

drop policy if exists "admins read the word list" on public.moderation_words;
create policy "admins read the word list"
  on public.moderation_words for select to authenticated
  using ((select public.is_admin()));

-- No insert, update or delete policies: only the functions below write.
-- moderation_requests has no policies at all.

-- The removed comment placeholder ---------------------------------------------------------------

-- 012's view with one more column at the end: removed by moderation.
create or replace view public.comment_cards
with (security_invoker = true)
as
select
  c.id,
  c.video_id,
  c.parent_id,
  case when c.deleted_at is null then c.body end as body,
  c.like_count,
  c.reply_count,
  c.pinned,
  c.hearted and c.deleted_at is null as hearted,
  c.created_at,
  c.edited_at,
  c.deleted_at is not null as deleted,
  case when c.deleted_at is null then coalesce(ch.handle, p.username) end as author_handle,
  case when c.deleted_at is null then coalesce(nullif(ch.name, ''), nullif(p.display_name, ''), p.username) end as author_name,
  case when c.deleted_at is null then coalesce(ch.avatar_url, p.avatar_url) end as author_avatar_url,
  c.author_id = v.owner_id and c.deleted_at is null as by_owner,
  c.author_id = (select auth.uid()) as mine,
  exists (
    select 1 from public.comment_likes l where l.comment_id = c.id and l.user_id = (select auth.uid())
  ) as liked,
  c.removed_at is not null as removed
from public.comments c
join public.videos v on v.id = c.video_id
join public.profiles p on p.id = c.author_id
left join public.channels ch on ch.owner_id = c.author_id;

revoke all on public.comment_cards from public, anon, authenticated;

-- Automod helpers ---------------------------------------------------------------------------

-- The first listed word found in the text as a whole word, or null.
-- Same as findBlockedWord() in lib/moderation/words.ts.
create or replace function public.moderation_blocked_word(body text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select w.word
  from public.moderation_words w
  where regexp_replace(lower(coalesce(moderation_blocked_word.body, '')), '\s+', ' ', 'g')
        ~ ('(^|[^a-z0-9])' || rtrim(w.word, '*') || case when w.word like '%*' then '' else '($|[^a-z0-9])' end)
  order by w.word
  limit 1;
$$;

-- Links in a text: http(s):// or www. up to the next space. Same as countLinks().
create or replace function public.moderation_link_count(body text)
returns int
language sql
immutable
set search_path = ''
as $$
  select count(*)::int from regexp_matches(coalesce(moderation_link_count.body, ''), '(https?://\S+|www\.\S+)', 'gi');
$$;

-- Who is behind what ----------------------------------------------------------------------------

-- The person behind a profile is banned, or their channel is suspended:
-- 'banned', 'suspended' or null.
create or replace function public.moderation_block_for(uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.profiles p where p.id = uid and p.banned_at is not null) then 'banned'
    when exists (select 1 from public.channels c where c.owner_id = uid and c.suspended_at is not null) then 'suspended'
  end;
$$;

-- Triggers ----------------------------------------------------------------------------------

-- New comments and edits: no banned or suspended authors, the word list and
-- the link cap. A removal (deleted_at set) passes.
create or replace function public.comments_moderation_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  block text;
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.body is not distinct from old.body then
    return new;
  end if;
  block := public.moderation_block_for(new.author_id);
  if block is not null then
    raise exception '%', block using errcode = 'P0001';
  end if;
  if public.moderation_flag_on(new.author_id) then
    if public.moderation_blocked_word(new.body) is not null then
      raise exception 'blocked_words' using errcode = 'P0001';
    end if;
    if public.moderation_link_count(new.body) > public.moderation_link_limit() then
      raise exception 'too_many_links' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists comments_moderation_guard on public.comments;
create trigger comments_moderation_guard
  before insert or update of body, deleted_at on public.comments
  for each row execute function public.comments_moderation_guard();

-- New videos: no banned or suspended owners. Titles and descriptions: the
-- word list (only when they change, so an old title never blocks an edit
-- of something else). A removed video, or one of a suspended channel,
-- stays private.
create or replace function public.videos_moderation_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  block text;
begin
  if tg_op = 'INSERT' then
    block := public.moderation_block_for(new.owner_id);
    if block is not null then
      raise exception '%', block using errcode = 'P0001';
    end if;
  end if;
  if (tg_op = 'INSERT' or new.title is distinct from old.title or new.description is distinct from old.description)
     and public.moderation_flag_on(new.owner_id)
     and public.moderation_blocked_word(coalesce(new.title, '') || ' ' || coalesce(new.description, '')) is not null then
    raise exception 'blocked_words' using errcode = 'P0001';
  end if;
  if new.visibility <> 'private' then
    if new.removed_at is not null then
      raise exception 'removed' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.channels c where c.id = new.channel_id and c.suspended_at is not null) then
      raise exception 'suspended' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists videos_moderation_guard on public.videos;
create trigger videos_moderation_guard
  before insert or update of title, description, visibility, removed_at on public.videos
  for each row execute function public.videos_moderation_guard();

-- Every API request: a banned person gets nothing. PostgREST runs this
-- before each request (see the end of this file).
create or replace function public.moderation_pre_request()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is not null and exists (select 1 from public.profiles p where p.id = me and p.banned_at is not null) then
    raise exception 'banned' using errcode = 'P0001';
  end if;
end;
$$;

-- Helpers ---------------------------------------------------------------------------------

-- Counts one call and raises rate_limited past 120 a minute ('admin').
create or replace function public.moderation_throttle(who uuid, bucket text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  recent int;
begin
  perform pg_advisory_xact_lock(hashtextextended('moderation:' || bucket || ':' || who::text, 0));
  delete from public.moderation_requests r
   where r.user_id = who and r.bucket = moderation_throttle.bucket and r.at < now() - interval '1 minute';
  select count(*) into recent from public.moderation_requests r where r.user_id = who and r.bucket = moderation_throttle.bucket;
  if recent >= 120 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.moderation_requests (user_id, bucket) values (who, moderation_throttle.bucket);
end;
$$;

-- Signed in and the flag on. Answers the caller.
create or replace function public.moderation_caller()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.moderation_flag_on(me) then
    raise exception 'moderation_off' using errcode = 'P0001';
  end if;
  return me;
end;
$$;

-- An admin with the flag on. Answers the caller.
create or replace function public.moderation_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := public.moderation_caller();
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = 'P0001';
  end if;
  return me;
end;
$$;

-- Strikes in the last 90 days.
create or replace function public.channel_active_strikes(channel_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.channel_strikes s
  where s.channel_id = channel_active_strikes.channel_id
    and s.created_at > now() - make_interval(days => public.moderation_strike_days());
$$;

create or replace function public.mod_write_log(actor uuid, action text, target_kind text, target_id uuid, label text, reason text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  -- clock_timestamp keeps the order of two rows written by one action.
  insert into public.mod_log (actor_id, action, target_kind, target_id, target_label, reason, created_at)
  values (actor, action, target_kind, target_id, left(coalesce(label, ''), 200), left(coalesce(reason, ''), 500), clock_timestamp());
$$;

-- Hides a channel's videos. Answers false when it was already suspended.
create or replace function public.mod_suspend_channel(ch uuid, why text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.channels c set suspended_at = now(), suspended_reason = left(coalesce(why, ''), 500)
   where c.id = ch and c.suspended_at is null;
  if not found then
    return false;
  end if;
  update public.videos v set held_visibility = v.visibility, visibility = 'private'
   where v.channel_id = ch and v.visibility <> 'private' and v.held_visibility is null;
  return true;
end;
$$;

-- Puts a channel's videos back. Answers false when it was not suspended.
create or replace function public.mod_unsuspend_channel(ch uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.channels c set suspended_at = null, suspended_reason = null
   where c.id = ch and c.suspended_at is not null;
  if not found then
    return false;
  end if;
  -- In the trash, the visibility waits for the restore (014). Removed
  -- videos keep theirs in removed_visibility.
  update public.videos v set trash_visibility = v.held_visibility, held_visibility = null
   where v.channel_id = ch and v.held_visibility is not null and v.deleted_at is not null;
  update public.videos v set visibility = v.held_visibility, held_visibility = null
   where v.channel_id = ch and v.held_visibility is not null and v.deleted_at is null and v.removed_at is null;
  return true;
end;
$$;

-- RPCs for everyone signed in -------------------------------------------------------------------

drop function if exists public.moderation_status();
drop function if exists public.report_target(text, uuid, text, text);
drop function if exists public.appeal_removal(uuid, text);

-- The caller, for the app: {admin, flag, banned, suspended, strikes,
-- strike_limit, strike_days, next_strike_expiry}. Signed out: all false.
create function public.moderation_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'admin', public.is_admin(),
    'flag', public.moderation_flag_on((select auth.uid())),
    'banned', coalesce((select p.banned_at is not null from public.profiles p where p.id = (select auth.uid())), false),
    'suspended', coalesce((select c.suspended_at is not null from public.channels c where c.owner_id = (select auth.uid())), false),
    'suspended_reason', (select c.suspended_reason from public.channels c where c.owner_id = (select auth.uid())),
    'strikes', coalesce((select public.channel_active_strikes(c.id) from public.channels c where c.owner_id = (select auth.uid())), 0),
    'strike_limit', public.moderation_strike_limit(),
    'strike_days', public.moderation_strike_days(),
    'next_strike_expiry', (
      select min(s.created_at) + make_interval(days => public.moderation_strike_days())
      from public.channel_strikes s join public.channels c on c.id = s.channel_id
      where c.owner_id = (select auth.uid())
        and s.created_at > now() - make_interval(days => public.moderation_strike_days())
    )
  );
$$;

-- A report. Answers the new report's id.
create function public.report_target(target_kind text, target_id uuid, reason text, details text default '')
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.moderation_caller();
  clean text := btrim(coalesce(report_target.details, ''));
  owner uuid;
  today int;
  new_id uuid;
begin
  if report_target.target_kind is null or report_target.target_kind not in ('video', 'comment', 'channel') then
    raise exception 'bad_kind' using errcode = 'P0001';
  end if;
  if report_target.reason is null or report_target.reason not in ('spam', 'sexual', 'violent', 'harassment', 'copyright', 'other') then
    raise exception 'bad_reason' using errcode = 'P0001';
  end if;
  if char_length(clean) > 500 then
    raise exception 'details_too_long' using errcode = 'P0001';
  end if;
  if report_target.reason = 'other' and char_length(clean) = 0 then
    raise exception 'details_required' using errcode = 'P0001';
  end if;

  -- The target, as the reporter can see it.
  if report_target.target_kind = 'video' then
    select v.owner_id into owner from public.videos v
     where v.id = report_target.target_id and v.status = 'ready' and v.visibility in ('public', 'unlisted') and v.removed_at is null;
  elsif report_target.target_kind = 'comment' then
    select c.author_id into owner from public.comments c join public.videos v on v.id = c.video_id
     where c.id = report_target.target_id and c.deleted_at is null and v.visibility in ('public', 'unlisted') and v.status = 'ready';
  else
    select c.owner_id into owner from public.channels c where c.id = report_target.target_id;
  end if;
  if owner is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if owner = me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('report:' || me::text, 0));
  if exists (
    select 1 from public.reports r
    where r.reporter_id = me and r.kind = 'report'
      and r.target_kind = report_target.target_kind and r.target_id = report_target.target_id
  ) then
    raise exception 'already_reported' using errcode = 'P0001';
  end if;
  select count(*) into today from public.reports r
   where r.reporter_id = me and r.kind = 'report' and r.created_at > now() - interval '1 day';
  if today >= public.moderation_reports_per_day() then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.reports (kind, reporter_id, target_kind, target_id, reason, details)
  values ('report', me, report_target.target_kind, report_target.target_id, report_target.reason, clean)
  returning id into new_id;
  return new_id;
end;
$$;

-- The owner of a removed video asks for it back. One appeal per removal.
create function public.appeal_removal(video_id uuid, details text default '')
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.moderation_caller();
  clean text := btrim(coalesce(appeal_removal.details, ''));
  v public.videos;
  new_id uuid;
begin
  if char_length(clean) > 500 then
    raise exception 'details_too_long' using errcode = 'P0001';
  end if;
  select * into v from public.videos x where x.id = appeal_removal.video_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v.owner_id <> me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if v.removed_at is null then
    raise exception 'not_removed' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.reports r
    where r.kind = 'appeal' and r.target_id = v.id and (r.status = 'open' or r.created_at >= v.removed_at)
  ) then
    raise exception 'already_appealed' using errcode = 'P0001';
  end if;
  insert into public.reports (kind, reporter_id, target_kind, target_id, reason, details)
  values ('appeal', me, 'video', v.id, 'appeal', clean)
  returning id into new_id;
  return new_id;
end;
$$;

-- The studio's Content list, with the removal (014's shape plus three columns).
drop function if exists public.studio_videos(boolean);
create function public.studio_videos(trash boolean default false)
returns table (
  id uuid,
  title text,
  description text,
  visibility text,
  status text,
  is_short boolean,
  short_choice boolean,
  duration_s numeric,
  thumbnail_url text,
  thumbnail_name text,
  hls_key text,
  tags text[],
  comments_mode text,
  created_at timestamptz,
  published_at timestamptz,
  views bigint,
  like_count bigint,
  comment_count bigint,
  deleted_at timestamptz,
  trash_visibility text,
  purge_at timestamptz,
  removed_at timestamptz,
  removed_reason text,
  appeal text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := public.studio_caller();
begin
  return query
  select
    v.id, v.title, v.description, v.visibility, v.status, v.is_short, v.short_choice, v.duration_s,
    v.thumbnail_url, v.thumbnail_name, v.hls_key, v.tags, v.comments_mode, v.created_at, v.published_at,
    v.views::bigint, v.like_count::bigint, v.comment_count::bigint, v.deleted_at, v.trash_visibility,
    -- least() skips nulls: the earlier of the trash and the removal.
    least(v.deleted_at, v.removed_at) + make_interval(days => public.studio_trash_days()),
    v.removed_at, v.removed_reason,
    -- The appeal since the removal: 'open', 'dismissed' (turned down), or null.
    (select r.status from public.reports r
      where r.kind = 'appeal' and r.target_id = v.id and v.removed_at is not null and r.created_at >= v.removed_at
      order by r.created_at desc limit 1)
  from public.videos v
  where v.owner_id = me
    and (v.deleted_at is not null) = coalesce(studio_videos.trash, false)
  order by coalesce(v.deleted_at, v.created_at) desc, v.id desc
  limit 500;
end;
$$;

-- The trash purge (014) also takes removed videos 30 days after the removal.
create or replace function public.purge_trash(lim int default 500)
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  gone int := 0;
  cutoff timestamptz := now() - make_interval(days => public.studio_trash_days());
begin
  with old as (
    select v.id, v.owner_id
    from public.videos v
    where (v.deleted_at is not null and v.deleted_at < cutoff)
       or (v.removed_at is not null and v.removed_at < cutoff)
    order by least(v.deleted_at, v.removed_at)
    limit least(greatest(coalesce(purge_trash.lim, 500), 1), 5000)
    for update skip locked
  ),
  queued as (
    insert into public.storage_cleanup (video_id, prefix)
    select o.id, p.prefix
    from old o
    cross join lateral (values
      ('hls/' || o.id::text || '/'),
      ('uploads/' || o.owner_id::text || '/' || o.id::text || '/')
    ) as p(prefix)
    on conflict on constraint storage_cleanup_once do update
      set status = 'queued', attempts = 0, error = null, queued_at = now()
    returning 1
  ),
  deleted as (
    delete from public.videos v using old o where v.id = o.id
    returning 1
  )
  select count(*) into gone from deleted;

  delete from public.storage_cleanup c where c.status = 'done' and c.finished_at < now() - interval '30 days';
  return gone;
end;
$$;

-- Admin RPCs ---------------------------------------------------------------------------------

drop function if exists public.admin_reports(int);
drop function if exists public.mod_action(text, text, uuid, text, text);
drop function if exists public.admin_log(timestamptz, int);
drop function if exists public.admin_suspended();
drop function if exists public.admin_words();
drop function if exists public.admin_set_word(text, boolean);

-- The open reports, newest first, with what each one points at.
create function public.admin_reports(lim int default 1000)
returns table (
  id uuid,
  kind text,
  target_kind text,
  target_id uuid,
  reason text,
  details text,
  created_at timestamptz,
  reporter_name text,
  target_label text,
  video_id uuid,
  channel_id uuid,
  channel_handle text,
  channel_name text,
  channel_suspended boolean,
  channel_strikes int,
  owner_banned boolean,
  owner_admin boolean,
  target_removed boolean,
  target_gone boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.moderation_admin();
  return query
  with r as (
    select x.* from public.reports x
    where x.status = 'open'
    order by x.created_at desc, x.id desc
    limit least(greatest(coalesce(admin_reports.lim, 1000), 1), 2000)
  ),
  t as (
    select
      r.id as report_id,
      case r.target_kind
        when 'video' then vv.owner_id
        when 'comment' then cm.author_id
        else cc.owner_id
      end as owner_id,
      case r.target_kind
        when 'video' then vv.title
        when 'comment' then left(cm.body, 200)
        else coalesce(nullif(cc.name, ''), cc.handle)
      end as label,
      case r.target_kind when 'video' then vv.id when 'comment' then cm.video_id end as video_id,
      case r.target_kind
        when 'video' then vv.removed_at is not null
        when 'comment' then cm.removed_at is not null
        else false
      end as removed,
      case r.target_kind
        when 'video' then vv.id is null
        when 'comment' then cm.id is null or (cm.deleted_at is not null and cm.removed_at is null)
        else cc.id is null
      end as gone
    from r
    left join public.videos vv on r.target_kind = 'video' and vv.id = r.target_id
    left join public.comments cm on r.target_kind = 'comment' and cm.id = r.target_id
    left join public.channels cc on r.target_kind = 'channel' and cc.id = r.target_id
  )
  select
    r.id, r.kind, r.target_kind, r.target_id, r.reason, r.details, r.created_at,
    coalesce(nullif(rp.display_name, ''), rp.username),
    t.label, t.video_id,
    ch.id, ch.handle, coalesce(nullif(ch.name, ''), ch.handle),
    ch.suspended_at is not null,
    case when ch.id is null then 0 else public.channel_active_strikes(ch.id) end,
    coalesce(op.banned_at is not null, false),
    coalesce(op.role = 'admin', false),
    t.removed, t.gone
  from r
  join t on t.report_id = r.id
  left join public.profiles rp on rp.id = r.reporter_id
  left join public.profiles op on op.id = t.owner_id
  left join public.channels ch on ch.owner_id = t.owner_id
  order by r.created_at desc, r.id desc;
end;
$$;

-- One moderation action. Answers {closed, suspended}: how many reports it
-- closed, and whether the channel is suspended afterwards.
create function public.mod_action(
  action text,
  target_kind text,
  target_id uuid,
  reason text default '',
  kind text default 'report'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.moderation_admin();
  why text := btrim(coalesce(mod_action.reason, ''));
  owner uuid;
  ch public.channels;
  vid public.videos;
  com public.comments;
  label text;
  closed int := 0;
  now_suspended boolean := false;
begin
  if mod_action.action is null or mod_action.action not in ('dismiss', 'remove', 'restore', 'strike', 'suspend', 'unsuspend', 'ban', 'unban') then
    raise exception 'bad_action' using errcode = 'P0001';
  end if;
  if mod_action.target_kind is null or mod_action.target_kind not in ('video', 'comment', 'channel')
     or mod_action.kind is null or mod_action.kind not in ('report', 'appeal') then
    raise exception 'bad_kind' using errcode = 'P0001';
  end if;
  if char_length(why) > 500 then
    raise exception 'reason_too_long' using errcode = 'P0001';
  end if;
  if mod_action.action in ('remove', 'strike', 'suspend', 'ban') and char_length(why) = 0 then
    raise exception 'reason_required' using errcode = 'P0001';
  end if;
  perform public.moderation_throttle(me, 'admin');

  -- What the target is and who is behind it.
  if mod_action.target_kind = 'video' then
    select * into vid from public.videos v where v.id = mod_action.target_id for update;
    owner := vid.owner_id;
    label := vid.title;
  elsif mod_action.target_kind = 'comment' then
    select * into com from public.comments c where c.id = mod_action.target_id for update;
    owner := com.author_id;
    label := left(com.body, 200);
  else
    select c.owner_id into owner from public.channels c where c.id = mod_action.target_id;
  end if;
  select * into ch from public.channels c where c.owner_id = owner for update;
  if mod_action.target_kind = 'channel' then
    label := coalesce(nullif(ch.name, ''), ch.handle);
  end if;

  -- A dismiss also closes reports whose target is gone.
  if owner is null and mod_action.action <> 'dismiss' then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if mod_action.action in ('strike', 'suspend', 'ban')
     and (owner = me or exists (select 1 from public.profiles p where p.id = owner and p.role = 'admin')) then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;

  if mod_action.action = 'remove' then
    if mod_action.target_kind = 'video' then
      if vid.removed_at is null then
        update public.videos v
           set removed_visibility = coalesce(v.held_visibility, v.visibility), held_visibility = null,
               visibility = 'private', removed_at = now(), removed_reason = why
         where v.id = vid.id;
      end if;
      perform public.mod_write_log(me, 'remove_video', 'video', vid.id, label, why);
    elsif mod_action.target_kind = 'comment' then
      if com.removed_at is null then
        update public.comments c
           set removed_at = now(), deleted_at = coalesce(c.deleted_at, now()), body = '', pinned = false, hearted = false
         where c.id = com.id;
      end if;
      perform public.mod_write_log(me, 'remove_comment', 'comment', com.id, label, why);
    else
      raise exception 'bad_action' using errcode = 'P0001';
    end if;
  elsif mod_action.action = 'restore' then
    if mod_action.target_kind <> 'video' then
      raise exception 'bad_action' using errcode = 'P0001';
    end if;
    if vid.removed_at is null then
      raise exception 'not_removed' using errcode = 'P0001';
    end if;
    if ch.suspended_at is not null then
      update public.videos v
         set removed_at = null, removed_reason = null,
             held_visibility = nullif(v.removed_visibility, 'private'), removed_visibility = null
       where v.id = vid.id;
    else
      update public.videos v
         set removed_at = null, removed_reason = null, removed_visibility = null
       where v.id = vid.id;
      update public.videos v set visibility = coalesce(vid.removed_visibility, 'private')
       where v.id = vid.id and v.deleted_at is null;
      update public.videos v set trash_visibility = coalesce(vid.removed_visibility, 'private')
       where v.id = vid.id and v.deleted_at is not null;
    end if;
    perform public.mod_write_log(me, 'restore_video', 'video', vid.id, label, why);
  elsif mod_action.action = 'strike' then
    insert into public.channel_strikes (channel_id, actor_id, reason, target_kind, target_id)
    values (ch.id, me, why, mod_action.target_kind, mod_action.target_id);
    perform public.mod_write_log(me, 'strike', 'channel', ch.id, coalesce(nullif(ch.name, ''), ch.handle), why);
    if public.channel_active_strikes(ch.id) >= public.moderation_strike_limit()
       and public.mod_suspend_channel(ch.id, why) then
      perform public.mod_write_log(me, 'suspend', 'channel', ch.id, coalesce(nullif(ch.name, ''), ch.handle),
        public.moderation_strike_limit() || ' strikes in ' || public.moderation_strike_days() || ' days');
    end if;
  elsif mod_action.action = 'suspend' then
    perform public.mod_suspend_channel(ch.id, why);
    perform public.mod_write_log(me, 'suspend', 'channel', ch.id, coalesce(nullif(ch.name, ''), ch.handle), why);
  elsif mod_action.action = 'unsuspend' then
    perform public.mod_unsuspend_channel(ch.id);
    perform public.mod_write_log(me, 'unsuspend', 'channel', ch.id, coalesce(nullif(ch.name, ''), ch.handle), why);
  elsif mod_action.action = 'ban' then
    update public.profiles p set banned_at = coalesce(p.banned_at, now()), ban_reason = why where p.id = owner;
    -- Sign them out everywhere: their refresh tokens stop working.
    begin
      execute 'delete from auth.sessions where user_id = $1' using owner;
    exception when others then
      raise notice 'could not delete the auth sessions: %', sqlerrm;
    end;
    perform public.mod_suspend_channel(ch.id, why);
    perform public.mod_write_log(me, 'ban', 'user', owner,
      coalesce((select p.username from public.profiles p where p.id = owner), ''), why);
  elsif mod_action.action = 'unban' then
    update public.profiles p set banned_at = null, ban_reason = null where p.id = owner;
    perform public.mod_write_log(me, 'unban', 'user', owner,
      coalesce((select p.username from public.profiles p where p.id = owner), ''), why);
  else
    perform public.mod_write_log(me, 'dismiss', mod_action.target_kind, mod_action.target_id, coalesce(label, ''), why);
  end if;

  if mod_action.action in ('dismiss', 'remove', 'restore', 'strike', 'suspend', 'ban') then
    update public.reports r
       set status = case when mod_action.action = 'dismiss' then 'dismissed' else 'actioned' end,
           resolution = mod_action.action, resolved_by = me, resolved_at = now()
     where r.status = 'open' and r.kind = mod_action.kind
       and r.target_kind = mod_action.target_kind and r.target_id = mod_action.target_id;
    get diagnostics closed = row_count;
  end if;

  select c.suspended_at is not null into now_suspended from public.channels c where c.id = ch.id;
  return jsonb_build_object('closed', closed, 'suspended', coalesce(now_suspended, false));
end;
$$;

-- The mod log, newest first, in pages of up to 100 before a moment.
create function public.admin_log(before timestamptz default null, lim int default 50)
returns table (
  id uuid,
  created_at timestamptz,
  action text,
  target_kind text,
  target_id uuid,
  target_label text,
  reason text,
  actor_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.moderation_admin();
  return query
  select l.id, l.created_at, l.action, l.target_kind, l.target_id, l.target_label, l.reason,
         coalesce(nullif(p.display_name, ''), p.username, 'deleted account')
  from public.mod_log l
  left join public.profiles p on p.id = l.actor_id
  where admin_log.before is null or l.created_at < admin_log.before
  order by l.created_at desc, l.id desc
  limit least(greatest(coalesce(admin_log.lim, 50), 1), 100);
end;
$$;

-- Suspended channels, newest first.
create function public.admin_suspended()
returns table (
  channel_id uuid,
  handle text,
  name text,
  suspended_at timestamptz,
  reason text,
  strikes int,
  banned boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.moderation_admin();
  return query
  select c.id, c.handle, coalesce(nullif(c.name, ''), c.handle), c.suspended_at, coalesce(c.suspended_reason, ''),
         public.channel_active_strikes(c.id), p.banned_at is not null
  from public.channels c
  join public.profiles p on p.id = c.owner_id
  where c.suspended_at is not null
  order by c.suspended_at desc
  limit 200;
end;
$$;

create function public.admin_words()
returns table (word text, created_at timestamptz, added_by text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.moderation_admin();
  return query
  select w.word, w.created_at, coalesce(p.username, '')
  from public.moderation_words w
  left join public.profiles p on p.id = w.added_by
  order by w.word;
end;
$$;

-- Adds (on) or removes a word. The app lowercases and squeezes it first.
create function public.admin_set_word(word text, "on" boolean default true)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.moderation_admin();
  w text := admin_set_word.word;
begin
  if not public.moderation_word_is_valid(w) then
    raise exception 'bad_word' using errcode = 'P0001';
  end if;
  perform public.moderation_throttle(me, 'admin');
  if coalesce(admin_set_word."on", true) then
    insert into public.moderation_words (word, added_by) values (w, me) on conflict on constraint moderation_words_pkey do nothing;
    if found then
      perform public.mod_write_log(me, 'add_word', 'word', null, w, '');
    end if;
  else
    delete from public.moderation_words x where x.word = w;
    if found then
      perform public.mod_write_log(me, 'remove_word', 'word', null, w, '');
    end if;
  end if;
end;
$$;

-- Who may call what ------------------------------------------------------------------------

revoke execute on function public.moderation_flag_on(uuid) from public, anon, authenticated;
revoke execute on function public.moderation_blocked_word(text) from public, anon, authenticated;
revoke execute on function public.moderation_block_for(uuid) from public, anon, authenticated;
revoke execute on function public.comments_moderation_guard() from public, anon, authenticated;
revoke execute on function public.videos_moderation_guard() from public, anon, authenticated;
revoke execute on function public.moderation_throttle(uuid, text) from public, anon, authenticated;
revoke execute on function public.moderation_caller() from public, anon, authenticated;
revoke execute on function public.moderation_admin() from public, anon, authenticated;
revoke execute on function public.channel_active_strikes(uuid) from public, anon, authenticated;
revoke execute on function public.mod_write_log(uuid, text, text, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.mod_suspend_channel(uuid, text) from public, anon, authenticated;
revoke execute on function public.mod_unsuspend_channel(uuid) from public, anon, authenticated;
revoke execute on function public.purge_trash(int) from public, anon, authenticated;

-- is_admin() is used by the policies, so the API roles need it. It only
-- answers for the caller. The pre request check runs as the caller too.
revoke execute on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;
revoke execute on function public.moderation_pre_request() from public;
grant execute on function public.moderation_pre_request() to anon, authenticated, service_role;

revoke execute on function public.moderation_status() from public;
revoke execute on function public.report_target(text, uuid, text, text) from public;
revoke execute on function public.appeal_removal(uuid, text) from public;
revoke execute on function public.studio_videos(boolean) from public;
revoke execute on function public.admin_reports(int) from public;
revoke execute on function public.mod_action(text, text, uuid, text, text) from public;
revoke execute on function public.admin_log(timestamptz, int) from public;
revoke execute on function public.admin_suspended() from public;
revoke execute on function public.admin_words() from public;
revoke execute on function public.admin_set_word(text, boolean) from public;

grant execute on function public.moderation_status() to anon, authenticated;
grant execute on function public.report_target(text, uuid, text, text) to authenticated;
grant execute on function public.appeal_removal(uuid, text) to authenticated;
grant execute on function public.studio_videos(boolean) to authenticated;
grant execute on function public.admin_reports(int) to authenticated;
grant execute on function public.mod_action(text, text, uuid, text, text) to authenticated;
grant execute on function public.admin_log(timestamptz, int) to authenticated;
grant execute on function public.admin_suspended() to authenticated;
grant execute on function public.admin_words() to authenticated;
grant execute on function public.admin_set_word(text, boolean) to authenticated;

grant execute on function public.purge_trash(int) to service_role;

-- The ban check before every API request --------------------------------------------------------

-- PostgREST runs pgrst.db_pre_request before each request. Supabase allows
-- setting it on the authenticator role; the notify makes PostgREST reload.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    begin
      execute 'alter role authenticator set pgrst.db_pre_request = ''public.moderation_pre_request''';
      perform pg_notify('pgrst', 'reload config');
    exception when insufficient_privilege then
      raise notice 'Could not set pgrst.db_pre_request on authenticator: banned people are refused by the triggers and the app only.';
    end;
  else
    raise notice 'No authenticator role here (not Supabase): the ban check before each request is not set.';
  end if;
end;
$$;

-- Feature flag ---------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'moderation',
  'Moderation',
  'Report buttons on videos, comments and channels, the admin queue at /admin with the mod log and the word list, strikes, suspensions, bans, removed videos with appeals.',
  'off'
)
on conflict (key) do nothing;

-- ===== 017_launch.sql =====
-- 017_launch.sql
-- Launch pack: the contact form, the sitemap lists, the maintenance and
-- launch flags.
--
-- Contact
-- - contact_messages: one row per message from /contact. name (1 to 80),
--   email (a plain address, up to 254), topic (general, press, legal,
--   safety, bug or other), body (10 to 4000), the sender's account when
--   they were signed in, a hash of the sender's network address (never the
--   address itself), and handled_at once an admin has dealt with it.
--   Nobody reads or writes the table through the API: the form goes through
--   contact_send and admins read it through admin_contact_messages.
-- - contact_send(name, email, topic, body): with the launch flag on for the
--   caller. 5 messages a day per email address and 5 a day per network
--   address (the x-contact-client header the app sends, the visitor's
--   address as the app's reverse proxy saw it, else the first
--   x-forwarded-for entry). Signed out people may send.
-- - admin_contact_messages(include_handled, lim) and
--   admin_contact_mark(id, handled): admins only (is_admin() from 016).
--
-- Sitemap
-- - sitemap_counts(), sitemap_videos(page, per) and sitemap_channels(page,
--   per): public, ready, not removed and not trashed videos, and channels
--   that are not suspended, in a stable order so the pages do not shift.
--   Everything they return is already public on the site.
--
-- Errors (the message, P0001): launch_off, bad_name, bad_email, bad_topic,
-- too_short, too_long, rate_limited, not_admin, not_found.
--
-- Flags (both off until the owner switches them on):
-- - maintenance: everyone but admins sees the maintenance page.
-- - launch: the footer, /about, /terms, /privacy, /guidelines, /press,
--   /contact and the Messages tab in /admin.
--
-- Keep the numbers in step with lib/launch/rules.ts.
--
-- Run after 016_moderation.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.launch_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'launch'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Same as lib/launch/rules.ts.
create or replace function public.contact_per_day() returns int language sql immutable set search_path = '' as $$ select 5 $$;

-- Table ----------------------------------------------------------------------------------

create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  topic text not null default 'general',
  body text not null,
  user_id uuid references public.profiles (id) on delete set null,
  sender_key text,
  created_at timestamptz not null default now(),
  handled_at timestamptz,
  handled_by uuid references public.profiles (id) on delete set null,
  constraint contact_name_length check (char_length(name) between 1 and 80),
  constraint contact_email_shape check (char_length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint contact_topic_valid check (topic in ('general', 'press', 'legal', 'safety', 'bug', 'other')),
  constraint contact_body_length check (char_length(body) between 10 and 4000)
);

create index if not exists contact_messages_email_idx on public.contact_messages (lower(email), created_at desc);
create index if not exists contact_messages_sender_idx on public.contact_messages (sender_key, created_at desc);
create index if not exists contact_messages_open_idx on public.contact_messages (created_at desc) where handled_at is null;

alter table public.contact_messages enable row level security;

-- Admins may read the messages; nobody writes through the API (contact_send
-- and admin_contact_mark are security definer).
drop policy if exists "contact_messages are readable by admins" on public.contact_messages;
create policy "contact_messages are readable by admins"
  on public.contact_messages
  for select
  to authenticated
  using (public.is_admin());

revoke all on public.contact_messages from anon, authenticated;
grant select on public.contact_messages to authenticated;

-- Sending ----------------------------------------------------------------------------------

create or replace function public.contact_send(name text, email text, topic text, body text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  headers json := nullif(current_setting('request.headers', true), '')::json;
  address text;
  who text;
  clean_name text := btrim(regexp_replace(coalesce(contact_send.name, ''), '\s+', ' ', 'g'));
  clean_email text := lower(btrim(coalesce(contact_send.email, '')));
  clean_body text := btrim(coalesce(contact_send.body, ''));
  clean_topic text := coalesce(nullif(btrim(coalesce(contact_send.topic, '')), ''), 'general');
  sent int;
  new_id uuid;
begin
  if not public.launch_flag_on(me) then
    raise exception 'launch_off' using errcode = 'P0001';
  end if;
  if char_length(clean_name) = 0 or char_length(clean_name) > 80 then
    raise exception 'bad_name' using errcode = 'P0001';
  end if;
  if char_length(clean_email) > 254 or clean_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'bad_email' using errcode = 'P0001';
  end if;
  if clean_topic not in ('general', 'press', 'legal', 'safety', 'bug', 'other') then
    raise exception 'bad_topic' using errcode = 'P0001';
  end if;
  if char_length(clean_body) < 10 then
    raise exception 'too_short' using errcode = 'P0001';
  end if;
  if char_length(clean_body) > 4000 then
    raise exception 'too_long' using errcode = 'P0001';
  end if;

  address := nullif(btrim(coalesce(
    headers ->> 'x-contact-client',
    split_part(coalesce(headers ->> 'x-forwarded-for', ''), ',', 1)
  )), '');
  who := case when address is null then null else md5('contact:' || left(address, 64)) end;

  -- One sender at a time per address, so two quick sends cannot both pass.
  perform pg_advisory_xact_lock(hashtextextended('contact:' || clean_email, 0));
  select count(*) into sent from public.contact_messages m
   where lower(m.email) = clean_email and m.created_at > now() - interval '1 day';
  if sent >= public.contact_per_day() then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  if who is not null then
    perform pg_advisory_xact_lock(hashtextextended('contact-addr:' || who, 0));
    select count(*) into sent from public.contact_messages m
     where m.sender_key = who and m.created_at > now() - interval '1 day';
    if sent >= public.contact_per_day() then
      raise exception 'rate_limited' using errcode = 'P0001';
    end if;
  end if;

  insert into public.contact_messages (name, email, topic, body, user_id, sender_key)
  values (clean_name, clean_email, clean_topic, clean_body, me, who)
  returning id into new_id;
  return new_id;
end;
$$;

-- Admins ----------------------------------------------------------------------------------

drop function if exists public.admin_contact_messages(boolean, int);
create function public.admin_contact_messages(include_handled boolean default false, lim int default 100)
returns table (
  id uuid,
  name text,
  email text,
  topic text,
  body text,
  created_at timestamptz,
  handled_at timestamptz,
  sender_handle text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = 'P0001';
  end if;
  return query
  select m.id, m.name, m.email, m.topic, m.body, m.created_at, m.handled_at, c.handle
    from public.contact_messages m
    left join public.channels c on c.owner_id = m.user_id
   where coalesce(admin_contact_messages.include_handled, false) or m.handled_at is null
   order by m.created_at desc, m.id desc
   limit least(greatest(coalesce(admin_contact_messages.lim, 100), 1), 500);
end;
$$;

create or replace function public.admin_contact_mark(id uuid, handled boolean default true)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = 'P0001';
  end if;
  update public.contact_messages m
     set handled_at = case when admin_contact_mark.handled then now() else null end,
         handled_by = case when admin_contact_mark.handled then auth.uid() else null end
   where m.id = admin_contact_mark.id;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;

-- Sitemap ------------------------------------------------------------------------------------

create index if not exists videos_sitemap_idx on public.videos (published_at, id)
  where visibility = 'public' and status = 'ready' and removed_at is null and deleted_at is null;

create or replace function public.sitemap_counts()
returns table (videos bigint, channels bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.videos v
      where v.visibility = 'public' and v.status = 'ready' and v.removed_at is null and v.deleted_at is null),
    (select count(*) from public.channels c where c.suspended_at is null);
$$;

drop function if exists public.sitemap_videos(int, int);
create function public.sitemap_videos(page int default 1, per int default 5000)
returns table (
  id uuid,
  title text,
  description text,
  thumbnail_url text,
  hls_key text,
  duration_s numeric,
  published_at timestamptz,
  updated_at timestamptz,
  is_short boolean,
  channel_handle text
)
language sql
stable
security definer
set search_path = ''
as $$
  select v.id, v.title, v.description, v.thumbnail_url, v.hls_key, v.duration_s,
         coalesce(v.published_at, v.created_at), v.updated_at, v.is_short, c.handle
    from public.videos v
    join public.channels c on c.id = v.channel_id
   where v.visibility = 'public' and v.status = 'ready' and v.removed_at is null and v.deleted_at is null
     and c.suspended_at is null
   order by v.published_at nulls last, v.id
   limit least(greatest(coalesce(sitemap_videos.per, 5000), 1), 5000)
  offset (greatest(coalesce(sitemap_videos.page, 1), 1) - 1) * least(greatest(coalesce(sitemap_videos.per, 5000), 1), 5000);
$$;

drop function if exists public.sitemap_channels(int, int);
create function public.sitemap_channels(page int default 1, per int default 5000)
returns table (handle text, name text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select c.handle, c.name, c.created_at
    from public.channels c
   where c.suspended_at is null
   order by c.created_at, c.id
   limit least(greatest(coalesce(sitemap_channels.per, 5000), 1), 5000)
  offset (greatest(coalesce(sitemap_channels.page, 1), 1) - 1) * least(greatest(coalesce(sitemap_channels.per, 5000), 1), 5000);
$$;

-- Grants ---------------------------------------------------------------------------------------

revoke execute on function public.launch_flag_on(uuid) from public;
revoke execute on function public.contact_send(text, text, text, text) from public;
revoke execute on function public.admin_contact_messages(boolean, int) from public;
revoke execute on function public.admin_contact_mark(uuid, boolean) from public;
revoke execute on function public.sitemap_counts() from public;
revoke execute on function public.sitemap_videos(int, int) from public;
revoke execute on function public.sitemap_channels(int, int) from public;

grant execute on function public.contact_send(text, text, text, text) to anon, authenticated;
grant execute on function public.admin_contact_messages(boolean, int) to authenticated;
grant execute on function public.admin_contact_mark(uuid, boolean) to authenticated;
grant execute on function public.sitemap_counts() to anon, authenticated;
grant execute on function public.sitemap_videos(int, int) to anon, authenticated;
grant execute on function public.sitemap_channels(int, int) to anon, authenticated;

-- Feature flags ----------------------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'maintenance',
  'Maintenance mode',
  'Everyone but admins sees the maintenance page, and the API answers 503. Admins can still sign in and use the site.',
  'off'
)
on conflict (key) do nothing;

insert into public.feature_flags (key, label, description, mode)
values (
  'launch',
  'Launch pack',
  'The footer with About, Terms, Privacy, Guidelines, Press and Contact, the contact form and the Messages tab in /admin.',
  'off'
)
on conflict (key) do nothing;

-- ===== 018_yapin.sql =====
-- 018_yapin.sql
-- Yapin' integration: sign in with Yapin', the link on profiles, upload
-- announcements in a Yapin' channel through an incoming webhook, the yapin flag.
--
-- Sign in
-- - profiles.yapin_id (unique, nullable) and profiles.yapin_username: the
--   Yapin' account linked to this profile. Not readable through the API
--   (002 grants select on named columns only); yapin_status() answers the
--   caller about their own link.
-- - link_yapin(user_id, yapin_id, yapin_username) and
--   yapin_find_user(yapin_id, email): service role only. The app calls them
--   from /auth/yapin after it has checked the Yapin' answer itself, so nobody
--   can claim someone else's Yapin' id through the API.
-- - unlink_yapin(): the caller removes their own link.
--
-- Announcements
-- - yapin_webhooks: one incoming webhook URL per channel. The URL is a
--   secret: the owner can read the row (RLS, owner only) but not the url
--   column, only url_hint (the last 4 characters). Written through
--   set_yapin_webhook(url) only; null or '' disconnects.
-- - yapin_posts: one announcement per video, queued by a trigger when a video
--   that was uploaded after the webhook was connected first becomes public
--   and ready, with the yapin flag on for its owner. The encoder box claims
--   them (claim_yapin_posts, service role only), posts the card with 3
--   retries and reports back (yapin_post_result). Owners read their own
--   through RLS or list_yapin_posts(lim).
--
-- Limits: 30 calls a minute per person for unlink_yapin, set_yapin_webhook,
-- list_yapin_posts and yapin_status (logged in yapin_requests).
--
-- Errors (the message, P0001): yapin_off, not_signed_in, no_channel,
-- bad_webhook, yapin_taken, not_found, rate_limited.
--
-- Flag (off until the owner switches it on):
-- - yapin: Continue with Yapin' on /login and /signup and Settings >
--   Connections (both also need YAPIN_CLIENT_ID, YAPIN_CLIENT_SECRET and
--   SUPABASE_SERVICE_ROLE_KEY on the app server), Share to Yapin', /embed/<id>
--   with og:video and twitter:player on watch pages, and announcements in
--   /studio/settings.
--
-- Keep the numbers in step with lib/yapin/rules.ts and worker/lib/yapin.mjs.
--
-- Run after 017_launch.sql. Safe to run more than once.

-- Settings -----------------------------------------------------------------------------

create or replace function public.yapin_flag_on(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feature_flags f
    where f.key = 'yapin'
      and (f.mode = 'everyone' or (f.mode = 'test' and uid = any (f.users)))
  );
$$;

-- Same as lib/yapin/rules.ts.
create or replace function public.yapin_per_minute() returns int language sql immutable set search_path = '' as $$ select 30 $$;

-- An incoming webhook on yapin.gg (or one of its subdomains), https only, no
-- spaces, at most 500 characters. The encoder only ever posts to such a URL.
create or replace function public.yapin_webhook_is_valid(url text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select url is not null
     and char_length(url) <= 500
     and url ~ '^https://([a-z0-9-]+\.)*yapin\.gg/[^\s]+$';
$$;

-- Profiles ---------------------------------------------------------------------------------

alter table public.profiles add column if not exists yapin_id text;
alter table public.profiles add column if not exists yapin_username text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_yapin_id_key') then
    alter table public.profiles add constraint profiles_yapin_id_key unique (yapin_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_yapin_id_shape') then
    alter table public.profiles add constraint profiles_yapin_id_shape
      check (yapin_id is null or (char_length(yapin_id) between 1 and 64 and yapin_id ~ '^[A-Za-z0-9_-]+$'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_yapin_username_length') then
    alter table public.profiles add constraint profiles_yapin_username_length
      check (yapin_username is null or char_length(yapin_username) <= 64);
  end if;
end;
$$;

-- Tables -------------------------------------------------------------------------------------

-- One row per counted call, for the rate limit. Nobody reads it through the API.
create table if not exists public.yapin_requests (
  user_id uuid not null,
  at timestamptz not null default now()
);

create index if not exists yapin_requests_recent_idx on public.yapin_requests (user_id, at desc);

alter table public.yapin_requests enable row level security;
revoke all on public.yapin_requests from anon, authenticated;

create table if not exists public.yapin_webhooks (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null unique references public.channels (id) on delete cascade,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  url text not null,
  url_hint text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint yapin_webhooks_url_valid check (public.yapin_webhook_is_valid(url)),
  constraint yapin_webhooks_hint_length check (char_length(url_hint) <= 8)
);

alter table public.yapin_webhooks enable row level security;

drop policy if exists "yapin_webhooks are readable by their owner" on public.yapin_webhooks;
create policy "yapin_webhooks are readable by their owner"
  on public.yapin_webhooks
  for select
  to authenticated
  using (owner_id = auth.uid());

-- Every column but url. Nobody writes through the API (set_yapin_webhook is security definer).
revoke all on public.yapin_webhooks from anon, authenticated;
grant select (id, channel_id, owner_id, url_hint, created_at, updated_at) on public.yapin_webhooks to authenticated;

create table if not exists public.yapin_posts (
  id uuid primary key default gen_random_uuid(),
  video_id uuid not null references public.videos (id) on delete cascade,
  channel_id uuid not null references public.channels (id) on delete cascade,
  webhook_id uuid references public.yapin_webhooks (id) on delete set null,
  status text not null default 'queued',
  attempts int not null default 0,
  worker text,
  error text,
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  constraint yapin_posts_status_valid check (status in ('queued', 'sending', 'sent', 'failed')),
  constraint yapin_posts_error_length check (error is null or char_length(error) <= 500),
  constraint yapin_posts_once unique (video_id, channel_id)
);

create index if not exists yapin_posts_channel_idx on public.yapin_posts (channel_id, queued_at desc);
create index if not exists yapin_posts_todo_idx on public.yapin_posts (queued_at) where status in ('queued', 'sending');

alter table public.yapin_posts enable row level security;

drop policy if exists "yapin_posts are readable by the channel owner" on public.yapin_posts;
create policy "yapin_posts are readable by the channel owner"
  on public.yapin_posts
  for select
  to authenticated
  using (exists (select 1 from public.channels c where c.id = yapin_posts.channel_id and c.owner_id = auth.uid()));

revoke all on public.yapin_posts from anon, authenticated;
grant select on public.yapin_posts to authenticated;

-- Helpers ---------------------------------------------------------------------------------------

-- Signed in, the flag on and under the limit. Answers the caller.
create or replace function public.yapin_caller()
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  recent int;
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.yapin_flag_on(me) then
    raise exception 'yapin_off' using errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('yapin:' || me::text, 0));
  delete from public.yapin_requests r where r.user_id = me and r.at < now() - interval '1 minute';
  if random() < 0.01 then
    delete from public.yapin_requests r where r.at < now() - interval '1 minute';
  end if;
  select count(*) into recent from public.yapin_requests r where r.user_id = me;
  if recent >= public.yapin_per_minute() then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.yapin_requests (user_id) values (me);
  return me;
end;
$$;

-- Sign in and linking ------------------------------------------------------------------------------

-- Who signs in with this Yapin' account: the linked profile first, else the
-- account with this email address (the app only passes a verified one).
drop function if exists public.yapin_find_user(text, text);
create function public.yapin_find_user(yapin_id text, email text)
returns table (user_id uuid, email text, matched_by text, linked_yapin_id text)
language sql
stable
security definer
set search_path = ''
as $$
  (select p.id, u.email::text, 'yapin'::text, p.yapin_id
     from public.profiles p
     join auth.users u on u.id = p.id
    where p.yapin_id = yapin_find_user.yapin_id
    limit 1)
  union all
  (select u.id, u.email::text, 'email'::text, p.yapin_id
     from auth.users u
     join public.profiles p on p.id = u.id
    where yapin_find_user.email is not null
      and lower(u.email) = lower(yapin_find_user.email)
      and not exists (select 1 from public.profiles q where q.yapin_id = yapin_find_user.yapin_id)
    limit 1);
$$;

create or replace function public.link_yapin(user_id uuid, yapin_id text, yapin_username text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles p where p.yapin_id = link_yapin.yapin_id and p.id <> link_yapin.user_id) then
    raise exception 'yapin_taken' using errcode = 'P0001';
  end if;
  update public.profiles p
     set yapin_id = link_yapin.yapin_id,
         yapin_username = left(nullif(btrim(coalesce(link_yapin.yapin_username, '')), ''), 64)
   where p.id = link_yapin.user_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.unlink_yapin()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.yapin_caller();
begin
  update public.profiles p set yapin_id = null, yapin_username = null where p.id = me;
end;
$$;

drop function if exists public.yapin_status();
create function public.yapin_status()
returns table (linked boolean, yapin_username text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.yapin_caller();
begin
  return query select p.yapin_id is not null, p.yapin_username from public.profiles p where p.id = me;
end;
$$;

-- Announcements ------------------------------------------------------------------------------------

-- Connects (or replaces) the caller's channel webhook, or disconnects it with
-- null or ''. Answers the hint, never the URL.
create or replace function public.set_yapin_webhook(url text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.yapin_caller();
  ch uuid;
  clean text := btrim(coalesce(set_yapin_webhook.url, ''));
  hint text;
begin
  select c.id into ch from public.channels c where c.owner_id = me;
  if ch is null then
    raise exception 'no_channel' using errcode = 'P0001';
  end if;
  if clean = '' then
    delete from public.yapin_webhooks w where w.channel_id = ch;
    return null;
  end if;
  if not public.yapin_webhook_is_valid(clean) then
    raise exception 'bad_webhook' using errcode = 'P0001';
  end if;
  hint := right(clean, 4);
  insert into public.yapin_webhooks (channel_id, owner_id, url, url_hint)
  values (ch, me, clean, hint)
  on conflict (channel_id) do update
    set url = excluded.url, url_hint = excluded.url_hint, updated_at = now();
  return hint;
end;
$$;

drop function if exists public.list_yapin_posts(int);
create function public.list_yapin_posts(lim int default 50)
returns table (
  id uuid,
  video_id uuid,
  title text,
  status text,
  attempts int,
  error text,
  queued_at timestamptz,
  finished_at timestamptz,
  connected boolean,
  url_hint text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.yapin_caller();
  ch uuid;
  hint text;
begin
  select c.id into ch from public.channels c where c.owner_id = me;
  if ch is null then
    raise exception 'no_channel' using errcode = 'P0001';
  end if;
  select w.url_hint into hint from public.yapin_webhooks w where w.channel_id = ch;
  -- One row with no post when there are none yet, so the page still learns about the webhook.
  return query
  select p.id, p.video_id, v.title, p.status, p.attempts, p.error, p.queued_at, p.finished_at, hint is not null, hint
    from public.yapin_posts p
    join public.videos v on v.id = p.video_id
   where p.channel_id = ch
   order by p.queued_at desc, p.id desc
   limit least(greatest(coalesce(list_yapin_posts.lim, 50), 1), 200);
  if not found then
    return query select null::uuid, null::uuid, null::text, null::text, 0, null::text, null::timestamptz, null::timestamptz, hint is not null, hint;
  end if;
end;
$$;

-- Queues the announcement when a video first becomes public and ready.
create or replace function public.yapin_queue_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  hook record;
begin
  if new.status <> 'ready' or new.visibility <> 'public' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'ready' and old.visibility = 'public' then
    return new;
  end if;
  if new.deleted_at is not null or new.removed_at is not null then
    return new;
  end if;
  select w.id, w.created_at into hook from public.yapin_webhooks w where w.channel_id = new.channel_id;
  if hook.id is null or new.created_at < hook.created_at then
    return new;
  end if;
  if not public.yapin_flag_on(new.owner_id) then
    return new;
  end if;
  insert into public.yapin_posts (video_id, channel_id, webhook_id)
  values (new.id, new.channel_id, hook.id)
  on conflict (video_id, channel_id) do nothing;
  return new;
end;
$$;

drop trigger if exists videos_yapin_queue on public.videos;
create trigger videos_yapin_queue
  after insert or update of status, visibility on public.videos
  for each row execute function public.yapin_queue_post();

-- The encoder ----------------------------------------------------------------------------------------

-- The next announcements to post. A post left 'sending' for 10 minutes (a
-- crashed box) is taken again. Answers the webhook URL: service role only.
drop function if exists public.claim_yapin_posts(text, int);
create function public.claim_yapin_posts(worker text, lim int default 5)
returns table (
  id uuid,
  url text,
  video_id uuid,
  title text,
  description text,
  thumbnail_url text,
  hls_key text,
  channel_name text,
  channel_handle text,
  attempts int
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Posts whose webhook was disconnected, or whose video is no longer public, are dropped first.
  update public.yapin_posts p
     set status = 'failed', error = 'no longer public or not connected', finished_at = now()
   where (p.status = 'queued' or (p.status = 'sending' and p.started_at < now() - interval '10 minutes'))
     and (not exists (select 1 from public.yapin_webhooks w where w.channel_id = p.channel_id)
          or not exists (select 1 from public.videos v where v.id = p.video_id and v.visibility = 'public' and v.status = 'ready'
                           and v.deleted_at is null and v.removed_at is null));

  return query
  with picked as (
    select p.id
      from public.yapin_posts p
     where p.status = 'queued'
        or (p.status = 'sending' and p.started_at < now() - interval '10 minutes')
     order by p.queued_at
     limit least(greatest(coalesce(claim_yapin_posts.lim, 5), 1), 20)
     for update skip locked
  ), marked as (
    update public.yapin_posts p
       set status = 'sending', worker = left(claim_yapin_posts.worker, 100), started_at = now()
      from picked
     where p.id = picked.id
    returning p.id, p.video_id, p.channel_id, p.attempts
  )
  select m.id, w.url, v.id, v.title, v.description, v.thumbnail_url, v.hls_key, c.name, c.handle, m.attempts
    from marked m
    join public.videos v on v.id = m.video_id
    join public.channels c on c.id = m.channel_id
    join public.yapin_webhooks w on w.channel_id = m.channel_id;
end;
$$;

create or replace function public.yapin_post_result(post_id uuid, ok boolean, tries int, error text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.yapin_posts p
     set status = case when yapin_post_result.ok then 'sent' else 'failed' end,
         attempts = p.attempts + greatest(coalesce(yapin_post_result.tries, 1), 1),
         error = case when yapin_post_result.ok then null else left(coalesce(yapin_post_result.error, 'failed'), 500) end,
         finished_at = now()
   where p.id = yapin_post_result.post_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;

-- Grants -------------------------------------------------------------------------------------------

revoke execute on function public.yapin_flag_on(uuid) from public;
revoke execute on function public.yapin_caller() from public;
revoke execute on function public.yapin_find_user(text, text) from public, anon, authenticated;
revoke execute on function public.link_yapin(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.unlink_yapin() from public;
revoke execute on function public.yapin_status() from public;
revoke execute on function public.set_yapin_webhook(text) from public;
revoke execute on function public.list_yapin_posts(int) from public;
revoke execute on function public.yapin_queue_post() from public, anon, authenticated;
revoke execute on function public.claim_yapin_posts(text, int) from public, anon, authenticated;
revoke execute on function public.yapin_post_result(uuid, boolean, int, text) from public, anon, authenticated;

grant execute on function public.yapin_find_user(text, text) to service_role;
grant execute on function public.link_yapin(uuid, text, text) to service_role;
grant execute on function public.unlink_yapin() to authenticated;
grant execute on function public.yapin_status() to authenticated;
grant execute on function public.set_yapin_webhook(text) to authenticated;
grant execute on function public.list_yapin_posts(int) to authenticated;
grant execute on function public.claim_yapin_posts(text, int) to service_role;
grant execute on function public.yapin_post_result(uuid, boolean, int, text) to service_role;

-- Feature flag -------------------------------------------------------------------------------------

insert into public.feature_flags (key, label, description, mode)
values (
  'yapin',
  'Yapin'' integration',
  'Continue with Yapin'' on sign in and sign up, Settings > Connections, Share to Yapin'', the /embed player for link previews and upload announcements in a Yapin'' channel.',
  'off'
)
on conflict (key) do nothing;

-- ===== 019_yapin_facts.sql =====
-- 019_yapin_facts.sql
-- Yapin' integration, matched to how Yapin' really works (feature 16b).
--
-- Sign in
-- - Yapin' has one OAuth scope, identify, and never shares an email address.
--   So nobody is ever matched by email any more: yapin_find_user(yapin_id)
--   only finds the account linked to that Yapin' id. The old two argument
--   yapin_find_user(yapin_id, email) from 018 is dropped.
-- - A new account made by Sign in with Yapin' gets a placeholder address,
--   yapin_<id>@users.noreply.<site host>, because Supabase auth needs one.
--   profiles.email_placeholder (not readable through the API) marks it, set by
--   yapin_mark_placeholder(user_id) (service role only) and cleared by a
--   trigger on auth.users when the person adds a real address in Settings.
--   Nothing should ever mail an account with email_placeholder = true.
-- - unlink_yapin() refuses with needs_email while the account has only the
--   placeholder: Yapin' is then the only way in. yapin_status() also answers
--   needs_email so Settings can say so.
--
-- Announcements
-- - Yapin' incoming webhooks are https://<host>/api/webhooks/<id>/<token> on
--   yapin.gg, www.yapin.gg, yapper.website or www.yapper.website (one service
--   on two domains). yapin_webhook_is_valid() checks exactly that now, and the
--   check on yapin_webhooks is re-made with it. Saved URLs that do not match
--   (other subdomains or paths, which Yapin' never serves) are removed first,
--   with their queued posts marked failed.
--
-- Errors (the message, P0001): needs_email (new), plus those of 018.
--
-- Keep the checks in step with lib/yapin/rules.ts and worker/lib/yapin.mjs.
--
-- Run after 018_yapin.sql. Safe to run more than once.

-- Webhook URLs ------------------------------------------------------------------------------

create or replace function public.yapin_webhook_is_valid(url text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select url is not null
     and char_length(url) <= 500
     and url ~ '^https://(www\.)?(yapin\.gg|yapper\.website)/api/webhooks/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$';
$$;

-- Queued posts on a webhook that is about to go: failed, with the reason.
update public.yapin_posts p
   set status = 'failed', error = 'not a Yapin'' webhook URL', finished_at = now()
  from public.yapin_webhooks w
 where w.id = p.webhook_id
   and p.status in ('queued', 'sending')
   and not public.yapin_webhook_is_valid(w.url);

delete from public.yapin_webhooks w where not public.yapin_webhook_is_valid(w.url);

-- Re-made so the check is validated again with the function above.
alter table public.yapin_webhooks drop constraint if exists yapin_webhooks_url_valid;
alter table public.yapin_webhooks add constraint yapin_webhooks_url_valid check (public.yapin_webhook_is_valid(url));

-- Placeholder email addresses ------------------------------------------------------------------

-- Same check as isPlaceholderEmail in lib/yapin/rules.ts.
create or replace function public.yapin_is_placeholder_email(email text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select email is not null and email ~* '^yapin_[a-z0-9_-]+@users\.noreply\.[^@[:space:]]+$';
$$;

-- Not readable through the API: 002 grants select on named columns only.
alter table public.profiles add column if not exists email_placeholder boolean not null default false;

-- Marks a new Sign in with Yapin' account. Only when its address really is a placeholder.
create or replace function public.yapin_mark_placeholder(user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.profiles p
     set email_placeholder = true
    from auth.users u
   where p.id = yapin_mark_placeholder.user_id
     and u.id = p.id
     and public.yapin_is_placeholder_email(u.email::text);
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;

-- A real address (confirmed through Supabase's email change) clears the mark.
create or replace function public.yapin_email_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email and not public.yapin_is_placeholder_email(new.email::text) then
    update public.profiles p set email_placeholder = false where p.id = new.id and p.email_placeholder;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed_yapin on auth.users;
create trigger on_auth_user_email_changed_yapin
  after update of email on auth.users
  for each row execute function public.yapin_email_changed();

-- Sign in and linking ------------------------------------------------------------------------------

-- The account linked to this Yapin' id, if any. Never by email.
drop function if exists public.yapin_find_user(text, text);
drop function if exists public.yapin_find_user(text);
create function public.yapin_find_user(yapin_id text)
returns table (user_id uuid, email text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, u.email::text
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.yapin_id = yapin_find_user.yapin_id
   limit 1;
$$;

create or replace function public.unlink_yapin()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.yapin_caller();
begin
  if exists (select 1 from public.profiles p where p.id = me and p.email_placeholder) then
    raise exception 'needs_email' using errcode = 'P0001';
  end if;
  update public.profiles p set yapin_id = null, yapin_username = null where p.id = me;
end;
$$;

drop function if exists public.yapin_status();
create function public.yapin_status()
returns table (linked boolean, yapin_username text, needs_email boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := public.yapin_caller();
begin
  return query select p.yapin_id is not null, p.yapin_username, p.email_placeholder from public.profiles p where p.id = me;
end;
$$;

-- Grants -------------------------------------------------------------------------------------------

revoke execute on function public.yapin_find_user(text) from public, anon, authenticated;
revoke execute on function public.yapin_mark_placeholder(uuid) from public, anon, authenticated;
revoke execute on function public.yapin_email_changed() from public, anon, authenticated;
revoke execute on function public.unlink_yapin() from public;
revoke execute on function public.yapin_status() from public;

grant execute on function public.yapin_find_user(text) to service_role;
grant execute on function public.yapin_mark_placeholder(uuid) to service_role;
grant execute on function public.unlink_yapin() to authenticated;
grant execute on function public.yapin_status() to authenticated;

-- ===== 020_flag_panel.sql =====
-- 020_flag_panel.sql
-- Feature 17: the flag panel. A small floating panel inside the site
-- (Ctrl+Shift+S, admins only) that flips feature flags for the demo, so the
-- owner does not have to open the table editor on camera.
--
-- feature_flags has no update policy on purpose (001): the API roles cannot
-- write to it. The panel goes through one security definer function instead,
-- which checks is_admin() (016) and validates the mode before it touches a row.
-- Every change still goes through the feature_flags_touch trigger, so
-- updated_at stays honest.
--
-- Modes, as in 001:
--   off       hidden for everyone
--   test      only for the user ids listed in "users"; the panel calls it "Me"
--             and this function makes sure the caller is listed
--   everyone  on for all
--
-- Safe to run more than once.

create or replace function public.set_feature_flag(p_key text, p_mode text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  row_users uuid[];
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = 'P0001';
  end if;
  if p_mode is null or p_mode not in ('off', 'test', 'everyone') then
    raise exception 'bad_mode' using errcode = 'P0001';
  end if;

  select f.users into row_users
    from public.feature_flags f
   where f.key = p_key
     for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  -- "Me": test mode with the caller listed. Other listed ids stay, so a test
  -- account added by hand keeps seeing the feature.
  if p_mode = 'test' and not (me = any (coalesce(row_users, '{}'::uuid[]))) then
    row_users := coalesce(row_users, '{}'::uuid[]) || me;
  end if;

  update public.feature_flags f
     set mode = p_mode,
         users = coalesce(row_users, '{}'::uuid[])
   where f.key = p_key;

  return jsonb_build_object(
    'key', p_key,
    'mode', p_mode,
    'users', to_jsonb(coalesce(row_users, '{}'::uuid[]))
  );
end;
$$;

revoke execute on function public.set_feature_flag(text, text) from public;
revoke execute on function public.set_feature_flag(text, text) from anon;
grant execute on function public.set_feature_flag(text, text) to authenticated;

-- The panel's own flag. It starts on: the panel only ever shows for admins
-- (is_admin()), and it is the tool that flips the other flags, so a switched
-- off panel would send the owner back to the table editor. Turn it off here
-- to hide the panel and its shortcut for every admin.
insert into public.feature_flags (key, label, description, mode)
values (
  'flag_panel',
  'Flag panel',
  'The floating flags panel for admins, Ctrl+Shift+S (Cmd+Shift+S on a Mac). Each switch changes the real flag in this table.',
  'everyone'
)
on conflict (key) do nothing;

