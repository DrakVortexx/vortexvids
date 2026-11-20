-- Run this in Supabase SQL Editor to fix the onboarding loop
-- This makes all users onboarded by default

-- Change default value for new users
alter table public.profiles 
  alter column onboarded set default true;

-- Update existing users to be onboarded
update public.profiles 
  set onboarded = true 
  where onboarded = false;
