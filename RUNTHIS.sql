-- ============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR - ONE FILE, FIXES EVERYTHING
-- ============================================================================

-- Step 1: Fix onboarding so users don't get stuck
ALTER TABLE public.profiles ALTER COLUMN onboarded SET DEFAULT true;
UPDATE public.profiles SET onboarded = true WHERE onboarded = false;

-- Step 2: Enable all feature flags (even though code doesn't check them anymore)
UPDATE public.feature_flags SET mode = 'everyone' WHERE key IN ('upload', 'shorts', 'accounts');

-- Step 3: Verify profile update permissions
-- (Should show authenticated can update username, display_name, avatar_url, bio)
DO $$
BEGIN
  RAISE NOTICE 'Profile update permissions:';
END $$;

SELECT grantee, privilege_type, column_name 
FROM information_schema.column_privileges 
WHERE table_name = 'profiles' AND privilege_type = 'UPDATE';

-- Step 4: Check RLS policy on profiles
DO $$
BEGIN
  RAISE NOTICE 'Profile RLS policies:';
END $$;

SELECT policyname, cmd, roles
FROM pg_policies 
WHERE tablename = 'profiles';

-- Step 5: Recreate the update policy to be absolutely sure it exists
DROP POLICY IF EXISTS "people update their own profile" ON public.profiles;
CREATE POLICY "people update their own profile"
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Done! Now redeploy on Render to get commit a5e5574
