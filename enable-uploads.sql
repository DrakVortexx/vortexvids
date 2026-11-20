-- Run this in Supabase SQL Editor to enable the upload button

update public.feature_flags 
  set mode = 'everyone' 
  where key = 'upload';
