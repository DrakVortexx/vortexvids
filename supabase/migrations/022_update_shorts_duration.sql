-- 022_update_shorts_duration.sql
-- Update shorts maximum duration from 60 seconds to 40 seconds
-- Safe to run more than once.

-- Update the video_is_short function to check for 40 seconds instead of 60
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
     and floor(duration) <= 40
$$;

-- Recount existing videos with the new 40 second limit
update public.videos
set is_short = public.video_is_short(duration_s, width, height, short_choice)
where status = 'ready' 
  and duration_s is not null 
  and width is not null 
  and height is not null;
