# VortexVids - Purple Theme Edition 💜

## What's New

This is a purple-themed version of VortexVids with enhanced visual styling and all features ready to go!

### 🎨 Design Changes

#### Color Scheme
- **Light Theme**: Soft purple backgrounds (`#faf5ff`), vibrant purple accents
- **Dark Theme**: Deep purple backgrounds (`#1a0b2e`, `#2b1b3d`), glowing purple accents
- Purple gradient overlays throughout the interface
- Enhanced purple logo with hover glow effects
- Purple-bordered top navigation bar

#### Visual Enhancements
- Gradient buttons with purple shadows
- Active navigation items have purple gradient backgrounds with glowing borders
- Sidebar icons glow purple when active
- Subscription page icons have purple glow effects
- Subtle gradient overlay at the top of every page

#### Color Palette
**Light Mode:**
- Primary: `#8b5cf6` (Vivid Purple)
- Secondary: `#7c3aed` (Deep Purple)
- Accent: `#6d28d9` (Royal Purple)
- Background: `#faf5ff` (Pale Lavender)

**Dark Mode:**
- Primary: `#a78bfa` (Soft Purple)
- Secondary: `#8b5cf6` (Medium Purple)
- Background: `#1a0b2e` (Deep Space Purple)
- Surface: `#2b1b3d` (Dark Purple)

### ✨ Features

#### Shorts Feed (`/shorts`)
- Vertical video feed for short-form content
- Full-screen immersive viewing experience
- Already built and ready to use
- Enable with the `shorts` feature flag

#### Subscriptions Tab (`/feed/subscriptions`)
- See latest uploads from subscribed channels
- Organized by Today, This week, and Older
- Beautiful purple-themed empty states
- Enable with the `subscriptions` feature flag

### 🚀 Getting Started

1. **Set up environment:**
   ```bash
   cp .env.example .env.local
   ```

2. **Add your Supabase credentials to `.env.local`:**
   ```bash
   NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
   ```

3. **Set up the database:**
   - Create a Supabase project at [supabase.com](https://supabase.com)
   - Enable `pg_cron` extension in Database > Extensions
   - Apply all migrations:
     ```bash
     npm run db:migrations > all-migrations.sql
     ```
   - Paste into Supabase SQL Editor and Run

4. **Configure Auth:**
   - In Supabase: Authentication > URL Configuration
   - Add redirect URL: `http://localhost:3000/auth/callback`

5. **Start the server:**
   ```bash
   npm run dev
   ```
   Server runs at: http://localhost:3000

6. **Enable features:**
   - Sign up for an account
   - Make yourself admin in SQL Editor:
     ```sql
     update public.profiles set role = 'admin' where username = 'your-username';
     ```
   - Press `Ctrl+Shift+S` (or `Cmd+Shift+S` on Mac) to open flag panel
   - Enable features: `shorts`, `subscriptions`, `feed`, etc.

### 🎯 Key URLs

- Home: `http://localhost:3000`
- Shorts: `http://localhost:3000/shorts`
- Subscriptions: `http://localhost:3000/feed/subscriptions`
- Upload: `http://localhost:3000/upload`
- Studio: `http://localhost:3000/studio`

### 🎨 Theme Toggle

The theme automatically follows system preferences, but users can manually toggle between light and dark modes using the theme switcher in the top bar (when accounts are enabled).

### 📝 Notes

- All features are already built but behind feature flags
- The purple theme works in both light and dark modes
- Shorts and subscriptions are fully functional once flags are enabled
- No database? Site still works and shows "database not connected"
- Run `npm run demo` to see filled site with sample data (no setup needed)

### 🛠️ Tech Stack

- **Framework**: Next.js 16 with App Router
- **Database**: Supabase (PostgreSQL)
- **Auth**: Supabase Auth
- **Storage**: Cloudflare R2
- **Video**: HLS with hls.js
- **Styling**: Tailwind CSS 4 with custom purple theme
- **State**: Zustand

### 🎥 Video Processing

For video uploads to work, you'll need:
1. Cloudflare R2 bucket (see docs/features.md)
2. FFmpeg encoder worker running (see worker/README.md)
3. R2 credentials in `.env.local`

Without these, the site works but upload is disabled.

---

**Purple Edition** 💜 | Built with Next.js & Supabase
