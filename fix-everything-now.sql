-- ============================================================================
-- FIX EVERYTHING - Run this in Supabase SQL Editor
-- ============================================================================

-- 1. CHECK CURRENT FEATURE FLAGS
SELECT key, mode FROM public.feature_flags WHERE key IN ('upload', 'shorts', 'accounts');

-- 2. ENABLE ALL FEATURES
UPDATE public.feature_flags SET mode = 'everyone' WHERE key = 'upload';
UPDATE public.feature_flags SET mode = 'everyone' WHERE key = 'shorts';
UPDATE public.feature_flags SET mode = 'everyone' WHERE key = 'accounts';

-- 3. FIX ONBOARDING
ALTER TABLE public.profiles ALTER COLUMN onboarded SET DEFAULT true;
UPDATE public.profiles SET onboarded = true WHERE onboarded = false;

-- 4. CHECK PROFILE UPDATE PERMISSIONS
-- These should show authenticated users can update username, display_name, avatar_url, bio
SELECT grantee, privilege_type, column_name 
FROM information_schema.column_privileges 
WHERE table_name = 'profiles' AND privilege_type = 'UPDATE';

-- 5. CHECK RLS POLICIES ON PROFILES
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies 
WHERE tablename = 'profiles';

-- 6. ENSURE UPDATE POLICY EXISTS
-- Drop old policy if it exists and recreate it
DROP POLICY IF EXISTS "users can update their own profile" ON public.profiles;
CREATE POLICY "users can update their own profile"
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- 7. VERIFY CURRENT USER CAN UPDATE
-- Run this to test (replace with your actual user ID):
-- SELECT auth.uid();
-- UPDATE profiles SET display_name = 'Test' WHERE id = auth.uid();

-- 8. CHECK IF UPLOAD FLAG IS ACTUALLY ON
SELECT key, mode, users FROM public.feature_flags WHERE key = 'upload';
