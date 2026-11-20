# VortexVids Database Schema

## Overview

Complete PostgreSQL schema for VortexVids, designed for Supabase. The schema includes 21 migrations covering all features from accounts to moderation.

**Full schema file**: `schema.sql` (8,869 lines)

## Quick Apply

### Option 1: Supabase Dashboard
```bash
# Generate the complete schema
npm run db:migrations > schema.sql

# Then paste into Supabase SQL Editor and click Run
```

### Option 2: psql Command Line
```bash
npm run db:migrations -- --apply "postgresql://postgres:[password]@[project-ref].supabase.co:5432/postgres"
```

## Prerequisites

1. **Enable pg_cron extension** in Supabase Dashboard:
   - Go to: Database > Extensions
   - Search for `pg_cron`
   - Enable it (required for scheduled stats rollup and trash purge)

2. **Supabase project** with PostgreSQL 15+

## Schema Structure

### Core Tables (21 migrations)

| Migration | Tables Added | Description |
|-----------|-------------|-------------|
| **000_init** | `app_meta` | Key/value settings table |
| **001_feature_flags** | `feature_flags` | Feature toggle system (off/test/everyone) |
| **002_profiles** | `profiles` | User accounts and profiles |
| **003_avatars** | Storage bucket | Avatar storage with policies |
| **004_channels** | `channels` | One channel per user profile |
| **005_videos** | `videos` | Video metadata and upload tracking |
| **006_processing** | `encode_jobs` | Video encoding queue and worker functions |
| **007_watch** | Watch functions | Video playback and view tracking setup |
| **008_feed** | Feed functions | Home feed, trending, related videos |
| **009_subscriptions** | `subscriptions`, `subscription_changes` | Channel subscriptions and notifications |
| **010_search** | Search indexes | Full-text search with pg_trgm |
| **011_engagement** | `video_reactions`, `view_events`, `watch_history` | Likes, views, watch history |
| **012_comments** | `comments`, `comment_likes` | Comment system with replies |
| **013_shorts** | `short_watches`, `shorts_requests` | Short-form vertical videos |
| **014_studio** | Studio functions | Creator dashboard and video management |
| **015_stats** | `*_stats_daily` tables | Analytics and retention data |
| **016_moderation** | `reports`, `channel_strikes` | Moderation, bans, reports |
| **017_launch** | `contact_messages`, sitemap | Contact form and SEO |
| **018_yapin** | `yapin_posts`, `yapin_webhooks` | Yapin integration |
| **019_yapin_facts** | Yapin constraints | Real Yapin validation |
| **020_flag_panel** | Flag management | Admin flag control panel |

## Main Tables Detail

### 1. Profiles & Accounts
```sql
profiles (
  id uuid PRIMARY KEY,
  username text UNIQUE,
  display_name text,
  avatar_url text,
  bio text,
  birthdate date,  -- Not readable via API
  role text DEFAULT 'user',  -- 'user' or 'admin'
  banned_at timestamptz,
  created_at timestamptz
)
```

### 2. Channels
```sql
channels (
  id uuid PRIMARY KEY,
  profile_id uuid REFERENCES profiles,
  handle text UNIQUE,
  name text,
  description text,
  banner_url text,
  subscriber_count int DEFAULT 0,
  video_count int DEFAULT 0,
  suspended_at timestamptz,
  created_at timestamptz
)
```

### 3. Videos
```sql
videos (
  id uuid PRIMARY KEY,
  channel_id uuid REFERENCES channels,
  owner_id uuid REFERENCES profiles,
  title text,
  description text,
  visibility text,  -- 'private', 'unlisted', 'public'
  status text,  -- 'uploading', 'uploaded', 'processing', 'ready', 'failed'
  source_key text,  -- R2 object key
  source_bytes bigint,
  duration_s numeric,
  width int,
  height int,
  thumbnail_url text,
  hls_key text,  -- HLS manifest key
  is_short boolean,
  views int DEFAULT 0,
  like_count int DEFAULT 0,
  comment_count int DEFAULT 0,
  published_at timestamptz,
  deleted_at timestamptz,  -- Trash
  removed_at timestamptz,  -- Moderation removal
  created_at timestamptz
)
```

### 4. Subscriptions
```sql
subscriptions (
  id uuid PRIMARY KEY,
  profile_id uuid REFERENCES profiles,
  channel_id uuid REFERENCES channels,
  notify boolean DEFAULT true,
  created_at timestamptz,
  UNIQUE(profile_id, channel_id)
)
```

### 5. Comments
```sql
comments (
  id uuid PRIMARY KEY,
  video_id uuid REFERENCES videos,
  profile_id uuid REFERENCES profiles,
  parent_id uuid REFERENCES comments,  -- For replies
  text text,
  like_count int DEFAULT 0,
  reply_count int DEFAULT 0,
  pinned boolean DEFAULT false,
  hearted boolean DEFAULT false,
  deleted_at timestamptz,
  removed_at timestamptz,
  created_at timestamptz
)
```

### 6. Video Reactions (Engagement)
```sql
video_reactions (
  profile_id uuid REFERENCES profiles,
  video_id uuid REFERENCES videos,
  kind text,  -- 'like' or 'dislike'
  created_at timestamptz,
  PRIMARY KEY (profile_id, video_id)
)
```

### 7. Watch History
```sql
watch_history (
  id uuid PRIMARY KEY,
  profile_id uuid REFERENCES profiles,
  video_id uuid REFERENCES videos,
  watched_at timestamptz,
  position_s int,  -- Last watched position
  completed boolean
)
```

### 8. Feature Flags
```sql
feature_flags (
  key text PRIMARY KEY,
  label text,
  description text,
  mode text,  -- 'off', 'test', 'everyone'
  users uuid[],  -- Test user IDs
  updated_at timestamptz
)
```

## Security Features

### Row Level Security (RLS)
- **Enabled on all tables** by default
- Users can only read/write their own data
- Public content visible to everyone
- Admin-only operations require `role = 'admin'`

### Policies
```sql
-- Example: Videos are readable when public and ready
CREATE POLICY "videos_public_readable"
  ON videos FOR SELECT
  USING (visibility = 'public' AND status = 'ready');

-- Owners can read all their videos
CREATE POLICY "videos_owner_readable"
  ON videos FOR SELECT
  USING (owner_id = auth.uid());
```

### Rate Limiting
Built-in rate limiting via request logging tables:
- Search: 60/minute per user
- Comments: 10/minute, 100/day
- Reactions: 30/minute
- API calls logged in `*_requests` tables

## Storage Buckets

### 1. avatars (Public)
- Max size: 2 MB
- Formats: PNG, JPG, WebP
- Path: `{user_id}/avatar.{ext}`

### 2. banners (Public)
- Max size: 6 MB
- Formats: PNG, JPG, WebP
- Path: `{channel_id}/banner.{ext}`

### 3. Video Storage (External - Cloudflare R2)
- Uploads: `uploads/{video_id}.{ext}`
- HLS output: `hls/{video_id}/`
- Sprites: `sprites/{video_id}.webp`

## Key Functions (RPCs)

### Account Management
- `complete_signup(username, birthdate)` - Finish account setup
- `username_available(name)` - Check username availability
- `delete_account()` - Delete user account

### Channel Management
- `set_channel_handle(handle)` - Change channel handle (14-day cooldown)
- `channel_handle_available(handle)` - Check handle availability

### Video Management
- `create_upload(title, bytes, mime)` - Start video upload
- `finish_upload(video_id)` - Mark upload complete
- `update_video(video_id, title, desc, visibility)` - Update video details
- `studio_bulk(video_ids, action, visibility)` - Bulk operations

### Engagement
- `react(video_id, kind)` - Like/dislike video
- `watch_ping(video_id, position_s, played_s, source)` - Track watch progress
- `my_history()` - Get watch history
- `clear_history()` - Clear watch history

### Comments
- `post_comment(video_id, text, parent_id)` - Post comment/reply
- `edit_comment(comment_id, text)` - Edit comment
- `delete_comment(comment_id)` - Delete comment
- `like_comment(comment_id)` - Like comment
- `pin_comment(comment_id)` - Pin comment (owner only)

### Subscriptions
- `subscribe(channel_id)` - Subscribe to channel
- `unsubscribe(channel_id)` - Unsubscribe
- `set_notify(channel_id, notify)` - Toggle notifications
- `my_subscriptions()` - Get subscription list

### Search
- `search_videos(q, cursor_rank, cursor_id, lim, filters)` - Search videos
- `search_channels(q, lim)` - Search channels
- `search_suggest(q, lim)` - Search suggestions

### Feed
- `feed_videos(kind, cursor, cursor_id, lim)` - Get video feed
  - Kinds: `newest`, `trending`, `channel`, `channel_shorts`
- `subscriptions_feed(cursor, cursor_id, lim)` - Subscription feed
- `related_videos(video_id, lim)` - Related videos

### Shorts
- `list_shorts(cursor, lim)` - Get shorts feed
- `get_short(video_id)` - Get single short

### Moderation
- `report_target(kind, target_id, reason)` - Report content
- `mod_action(action, target_type, target_id, reason)` - Mod actions
- `admin_log()` - View moderation log (admin only)

### Analytics
- `studio_analytics(range)` - Channel analytics
- `video_analytics(video_id, range)` - Video analytics
- `realtime_views(video_id)` - Real-time view count

## Scheduled Jobs (pg_cron)

### Hourly Stats Rollup
```sql
SELECT cron.schedule(
  'rollup-video-stats',
  '5 * * * *',  -- Every hour at :05
  'SELECT public.rollup_video_stats(1)'
);
```

### Daily Trash Purge
```sql
SELECT cron.schedule(
  'purge-trash',
  '0 3 * * *',  -- 3 AM daily
  'SELECT public.purge_trash()'
);
```

## Indexes

### Performance Indexes
```sql
-- Video feed queries
CREATE INDEX videos_public_ready_idx 
  ON videos (published_at DESC)
  WHERE visibility = 'public' AND status = 'ready';

-- Channel videos
CREATE INDEX videos_channel_created_idx 
  ON videos (channel_id, created_at DESC);

-- Search indexes (GIN)
CREATE INDEX videos_search_doc_idx 
  ON videos USING gin(search_doc);

-- Trigram indexes for fuzzy search
CREATE INDEX videos_title_trgm_idx 
  ON videos USING gin(title gin_trgm_ops);
```

## Default Feature Flags

On first setup, these flags are created:

| Flag | Default | Description |
|------|---------|-------------|
| `accounts` | everyone | User registration and login |
| `flag_panel` | everyone | Admin flag control panel (Ctrl+Shift+S) |
| `channels` | off | Channel pages and customization |
| `upload` | off | Video uploads |
| `processing` | off | Video encoding |
| `watch` | off | Video playback |
| `feed` | off | Home feed and trending |
| `subscriptions` | off | Channel subscriptions |
| `search` | off | Video and channel search |
| `engagement` | off | Likes, views, watch history |
| `comments` | off | Comment system |
| `shorts` | off | Short-form vertical videos |
| `studio` | off | Creator studio dashboard |
| `stats` | off | Analytics and insights |
| `moderation` | off | Reports, bans, suspensions |
| `launch` | off | Contact form and public pages |
| `yapin` | off | Yapin integration |
| `maintenance` | off | Maintenance mode |

## Migration Best Practices

### First-Time Setup
1. Enable `pg_cron` extension first
2. Run all migrations in order (000 to 020)
3. All migrations are idempotent (safe to run twice)

### Updating Existing Database
1. Only run NEW migrations (higher numbers)
2. Never re-run earlier migrations on a database that has them
3. Later migrations may modify earlier structures

### Example
```bash
# New database: run all
npm run db:migrations > schema.sql

# Existing database at migration 015: run 016-020 only
npm run db:migrations -- --from 016 > new-migrations.sql
```

## Backup & Recovery

### Export Schema
```bash
npm run db:migrations > backup-schema.sql
```

### Export Data
```bash
pg_dump -h [project-ref].supabase.co -U postgres -d postgres \
  --data-only --no-owner --no-privileges > data-backup.sql
```

### Full Backup (Supabase Dashboard)
- Settings > Database > Database Backups
- Daily automatic backups retained for 7 days (Free tier)

## Troubleshooting

### Migration Fails
- Check if `pg_cron` is enabled
- Verify PostgreSQL version is 15+
- Check for syntax errors in custom functions

### RLS Policies Too Restrictive
- Check user authentication: `SELECT auth.uid();`
- Verify user role: `SELECT role FROM profiles WHERE id = auth.uid();`
- Test as service role to bypass RLS

### Performance Issues
- Check if indexes exist: `\di` in psql
- Analyze query plans: `EXPLAIN ANALYZE SELECT ...`
- Check pg_cron job history: `SELECT * FROM cron.job_run_details;`

## Admin Setup

After running migrations:

1. **Sign up** for an account on your site
2. **Make yourself admin** in SQL editor:
   ```sql
   UPDATE public.profiles 
   SET role = 'admin' 
   WHERE username = 'your-username';
   ```
3. **Enable features** with Ctrl+Shift+S (flag panel)

## Resources

- **Supabase Docs**: https://supabase.com/docs
- **PostgreSQL Docs**: https://www.postgresql.org/docs/
- **pg_cron**: https://github.com/citusdata/pg_cron
- **Full migrations**: `supabase/migrations/` directory
- **Migration README**: `supabase/migrations/README.md`

---

**Schema Version**: 020 (21 migrations)  
**PostgreSQL**: 15+  
**Supabase**: Compatible  
**Last Updated**: 2024
