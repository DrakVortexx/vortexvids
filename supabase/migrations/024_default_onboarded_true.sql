-- Set onboarded to true by default so users don't get stuck in welcome loop
-- Also update existing users to be onboarded

-- Change default value
alter table public.profiles 
  alter column onboarded set default true;

-- Update existing users who aren't onboarded
update public.profiles 
  set onboarded = true 
  where onboarded = false;
