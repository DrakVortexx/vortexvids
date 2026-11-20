-- VortexVids Minimal Schema
-- Optimized for small databases (under 500MB)
-- Only includes essential features: accounts, channels, videos, subscriptions, shorts

-- ===== SETUP =====
-- Enable required extension
create extension if not exists pg_trgm schema extensions;

-- Helper function for timestamps
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

-- ===== FEATURE FLAGS =====
create table if not exists public.feature_flags (
  key text primary key,
  mode text not null default 'off' check (mode in ('off', 'test', 'everyone')),
  users uuid[] not null default '{}'
);

alter table public.feature_flags enable row level security;

create policy "flags_readable" on public.feature_flags for select using (true);

-- ===== PROFILES =====
create or replace function public.username_is_valid(name text)
returns boolean language sql immutable as $$
  select name ~ '^[a-z0-9_]{3,24}$' and name not in (
    'admin', 'api', 'help', 'login', 'settings', 'upload', 'watch'
  );
$$;

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text not null check (public.username_is_valid(username)),
  display_name text default '',
  avatar_url text,
  bio text default '',
  role text default 'user' check (role in ('user', 'admin')),
  created_at timestamptz default now()
);

create unique index if not exists profiles_username_lower_key on public.profiles (lower(username));

alter table public.profiles enable row level security;

create policy "profiles_readable" on public.profiles for select using (true);
create policy "profiles_updatable" on public.profiles for update using (auth.uid() = id);

-- ===== CHANNELS =====
create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles on delete cascade,
  handle text not null unique,
  name text not null,
  description text default '',
  avatar_url text,
  subscriber_count int default 0,
  video_count int default 0,
  created_at timestamptz default now()
);

alter table public.channels enable row level security;

create policy "channels_readable" on public.channels for select using (true);
create policy "channels_updatable" on public.channels for update using (auth.uid() = profile_id);

-- ===== VIDEOS =====
create table if not exists public.videos (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels on delete cascade,
  owner_id uuid not null references public.profiles on delete cascade,
  title text not null check (length(title) between 1 and 100),
  description text default '',
  visibility text default 'private' check (visibility in ('private', 'unlisted', 'public')),
  status text default 'uploading' check (status in ('uploading', 'uploaded', 'processing', 'ready', 'failed')),
  duration_s numeric,
  width int,
  height int,
  thumbnail_url text,
  hls_key text,
  is_short boolean default false,
  views int default 0,
  like_count int default 0,
  comment_count int default 0,
  published_at timestamptz,
  created_at timestamptz default now()
);

create index videos_public_ready_idx on public.videos (published_at desc)
  where visibility = 'public' and status = 'ready';

alter table public.videos enable row level security;

create policy "videos_public_readable" on public.videos for select 
  using (visibility = 'public' and status = 'ready');
create policy "videos_owner_readable" on public.videos for select 
  using (auth.uid() = owner_id);

-- ===== SUBSCRIPTIONS =====
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles on delete cascade,
  channel_id uuid not null references public.channels on delete cascade,
  notify boolean default true,
  created_at timestamptz default now(),
  unique(profile_id, channel_id)
);

alter table public.subscriptions enable row level security;

create policy "subs_readable" on public.subscriptions for select using (auth.uid() = profile_id);
create policy "subs_insertable" on public.subscriptions for insert with check (auth.uid() = profile_id);
create policy "subs_deletable" on public.subscriptions for delete using (auth.uid() = profile_id);

-- ===== FUNCTIONS =====

-- Subscribe to channel
create or replace function public.subscribe(channel_id uuid)
returns void language plpgsql security definer as $$
begin
  insert into public.subscriptions (profile_id, channel_id)
  values (auth.uid(), channel_id)
  on conflict do nothing;
  
  update public.channels set subscriber_count = subscriber_count + 1
  where id = channel_id;
end;
$$;

-- Unsubscribe from channel
create or replace function public.unsubscribe(channel_id uuid)
returns void language plpgsql security definer as $$
begin
  delete from public.subscriptions
  where profile_id = auth.uid() and channel_id = channel_id;
  
  update public.channels set subscriber_count = greatest(0, subscriber_count - 1)
  where id = channel_id;
end;
$$;

-- Get subscription feed
create or replace function public.subscriptions_feed(lim int default 20)
returns table (
  id uuid,
  title text,
  channel_id uuid,
  channel_name text,
  channel_handle text,
  thumbnail_url text,
  duration_s numeric,
  views int,
  published_at timestamptz
) language sql security definer as $$
  select 
    v.id,
    v.title,
    c.id as channel_id,
    c.name as channel_name,
    c.handle as channel_handle,
    v.thumbnail_url,
    v.duration_s,
    v.views,
    v.published_at
  from public.videos v
  join public.channels c on v.channel_id = c.id
  join public.subscriptions s on s.channel_id = c.id
  where s.profile_id = auth.uid()
    and v.visibility = 'public'
    and v.status = 'ready'
  order by v.published_at desc
  limit lim;
$$;

-- Get shorts feed
create or replace function public.list_shorts(lim int default 20)
returns table (
  id uuid,
  title text,
  channel_id uuid,
  channel_name text,
  thumbnail_url text,
  views int
) language sql as $$
  select 
    v.id,
    v.title,
    c.id as channel_id,
    c.name as channel_name,
    v.thumbnail_url,
    v.views
  from public.videos v
  join public.channels c on v.channel_id = c.id
  where v.is_short = true
    and v.visibility = 'public'
    and v.status = 'ready'
  order by v.published_at desc
  limit lim;
$$;

-- Get video feed (home/trending)
create or replace function public.feed_videos(kind text, lim int default 20)
returns table (
  id uuid,
  title text,
  channel_id uuid,
  channel_name text,
  channel_handle text,
  thumbnail_url text,
  duration_s numeric,
  views int,
  published_at timestamptz
) language sql as $$
  select 
    v.id,
    v.title,
    c.id as channel_id,
    c.name as channel_name,
    c.handle as channel_handle,
    v.thumbnail_url,
    v.duration_s,
    v.views,
    v.published_at
  from public.videos v
  join public.channels c on v.channel_id = c.id
  where v.visibility = 'public'
    and v.status = 'ready'
    and v.is_short = false
  order by case
    when kind = 'trending' then v.views
    else 0
  end desc,
  v.published_at desc
  limit lim;
$$;

-- ===== INITIAL DATA =====
insert into public.feature_flags (key, mode) values
  ('accounts', 'everyone'),
  ('channels', 'everyone'),
  ('upload', 'off'),
  ('watch', 'everyone'),
  ('feed', 'everyone'),
  ('subscriptions', 'everyone'),
  ('shorts', 'everyone'),
  ('flag_panel', 'everyone')
on conflict (key) do nothing;

-- ===== GRANTS =====
grant usage on schema public to anon, authenticated;
grant select on public.feature_flags to anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (username, display_name, avatar_url, bio) on public.profiles to authenticated;
grant select on public.channels to anon, authenticated;
grant update (name, description, avatar_url) on public.channels to authenticated;
grant select on public.videos to anon, authenticated;
grant select on public.subscriptions to authenticated;
grant insert, delete on public.subscriptions to authenticated;

grant execute on function public.subscribe to authenticated;
grant execute on function public.unsubscribe to authenticated;
grant execute on function public.subscriptions_feed to authenticated;
grant execute on function public.list_shorts to anon, authenticated;
grant execute on function public.feed_videos to anon, authenticated;
