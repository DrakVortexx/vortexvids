-- 021_video_storage.sql
-- Supabase Storage bucket for videos (alternative to Cloudflare R2)
-- This allows uploads to work with just Supabase, no external storage needed
-- Safe to run more than once.

-- Create the videos storage bucket
insert into storage.buckets (id, name, public)
values ('videos', 'videos', false)
on conflict (id) do nothing;

-- Allow authenticated users to upload their own videos
drop policy if exists "Users can upload videos" on storage.objects;
create policy "Users can upload videos"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'videos' and
    (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow users to read their own videos
drop policy if exists "Users can read own videos" on storage.objects;
create policy "Users can read own videos"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'videos' and
    (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow public access to videos that are marked as public in the videos table
drop policy if exists "Public videos are readable" on storage.objects;
create policy "Public videos are readable"
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'videos' and
    exists (
      select 1 from public.videos
      where videos.id::text = (storage.foldername(name))[2]
        and videos.visibility = 'public'
        and videos.status = 'ready'
    )
  );

-- Allow users to update their own videos
drop policy if exists "Users can update own videos" on storage.objects;
create policy "Users can update own videos"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'videos' and
    (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow users to delete their own videos
drop policy if exists "Users can delete own videos" on storage.objects;
create policy "Users can delete own videos"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'videos' and
    (storage.foldername(name))[1] = auth.uid()::text
  );
