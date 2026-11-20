-- Run this in Supabase SQL Editor to fix everything at once
-- This fixes: onboarding loop, enables uploads, adds onboarding function

-- 1. Fix onboarding loop - make all users onboarded by default
alter table public.profiles 
  alter column onboarded set default true;

update public.profiles 
  set onboarded = true 
  where onboarded = false;

-- 2. Enable upload button for everyone
update public.feature_flags 
  set mode = 'everyone' 
  where key = 'upload';

-- 3. Add function to update onboarding (optional - for future use)
create or replace function public.update_profile_onboarding(
  new_username text,
  user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update profiles
  set 
    username = new_username,
    onboarded = true
  where id = user_id;
end;
$$;

grant execute on function public.update_profile_onboarding(text, uuid) to authenticated;
