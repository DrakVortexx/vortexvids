-- Migration: Create function to update profile onboarding status
-- Bypasses column-level grants by using SECURITY DEFINER

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
  -- Update both username and onboarded status
  update profiles
  set 
    username = new_username,
    onboarded = true
  where id = user_id;
end;
$$;

-- Grant execute permission to authenticated users
grant execute on function public.update_profile_onboarding(text, uuid) to authenticated;
