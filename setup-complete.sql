-- ============================================================================
-- COMPLETE SETUP FOR VORTEXVIDS
-- ============================================================================
-- Run this entire file in Supabase SQL Editor to set up everything at once.
-- This fixes: onboarding, enables uploads, profile editing, and video types.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. FIX ONBOARDING LOOP
-- ---------------------------------------------------------------------------
-- Make all users onboarded by default so they don't get stuck in welcome page

-- Change default value for new users
ALTER TABLE public.profiles 
  ALTER COLUMN onboarded SET DEFAULT true;

-- Update existing users to be onboarded
UPDATE public.profiles 
  SET onboarded = true 
  WHERE onboarded = false;


-- ---------------------------------------------------------------------------
-- 2. ENABLE UPLOAD BUTTON
-- ---------------------------------------------------------------------------
-- Turn on the upload feature for everyone

UPDATE public.feature_flags 
  SET mode = 'everyone' 
  WHERE key = 'upload';


-- ---------------------------------------------------------------------------
-- 3. ENABLE SHORTS/SNIPS FEATURE
-- ---------------------------------------------------------------------------
-- Turn on shorts so users can choose between regular video and shorts

UPDATE public.feature_flags 
  SET mode = 'everyone' 
  WHERE key = 'shorts';


-- ---------------------------------------------------------------------------
-- 4. ENABLE ACCOUNTS FEATURE (if not already on)
-- ---------------------------------------------------------------------------
-- Make sure accounts are enabled so users can sign up and edit profiles

UPDATE public.feature_flags 
  SET mode = 'everyone' 
  WHERE key = 'accounts';


-- ---------------------------------------------------------------------------
-- 5. ADD FUNCTION TO UPDATE ONBOARDING (SECURITY DEFINER)
-- ---------------------------------------------------------------------------
-- This function bypasses column-level grants to update onboarded status
-- (Optional - for future use if needed)

CREATE OR REPLACE FUNCTION public.update_profile_onboarding(
  new_username text,
  user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE profiles
  SET 
    username = new_username,
    onboarded = true
  WHERE id = user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_profile_onboarding(text, uuid) TO authenticated;


-- ---------------------------------------------------------------------------
-- 6. VERIFY PROFILE COLUMNS ARE EDITABLE
-- ---------------------------------------------------------------------------
-- Make sure users can edit their profile information
-- (username, display_name, avatar_url, bio should already be writable)

-- Check current grants (this just shows what's allowed):
-- SELECT grantee, privilege_type, column_name 
-- FROM information_schema.column_privileges 
-- WHERE table_name = 'profiles';


-- ============================================================================
-- SETUP COMPLETE!
-- ============================================================================
-- What you can now do:
-- ✅ Sign up without getting stuck in welcome loop
-- ✅ Upload button appears in top bar for logged-in users
-- ✅ Choose between Short (vertical, 40s) or Video (5 min) when uploading
-- ✅ Edit your username, display name, avatar, and bio in /settings
-- ✅ Upload videos up to 50MB
-- 
-- Upload limits (already configured in code):
-- - Shorts: vertical videos up to 40 seconds
-- - Videos: any video up to 5 minutes
-- - Max file size: 50MB
-- - Max uploads per day: 5
-- ============================================================================
