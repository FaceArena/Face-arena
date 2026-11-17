# FACE ARENA authentication setup

This branch contains the browser-side Email/Password + Google auth integration and the database migration. It is deliberately not connected to an existing Supabase project: the connected Supabase account currently has a blank project with an ambiguous name and a separate VAYRON project. Do not point FACE ARENA at either without confirming ownership.

## 1. Create/select the dedicated FACE ARENA Supabase project
Use a Free project if available. Do not create paid branches or upgrade a plan without explicit approval.

## 2. Apply the migration
Run `supabase/migrations/20261118000000_face_arena_profiles.sql` in the dedicated project's SQL Editor. It creates:
- `public.profiles` with per-user update RLS and authenticated read access to public profile fields.
- A trigger that creates a profile row for each new Auth user.
- A public avatar bucket with upload/update/delete restricted to the owner's UUID folder.

The migration does not import local demo photos, votes, or demo battle history.

## 3. Configure browser keys
Copy the project URL and publishable key from Supabase Project Settings > API Keys into `face-arena-config.js`.
Only the publishable key belongs in browser code. Never use a secret/service_role key.

## 4. Configure Auth
In Authentication > Providers:
- Enable Email.
- Keep email confirmation enabled for production.
- Enable Google and enter the Google OAuth Web Client ID and Client Secret.
- In Google Cloud Console, configure the authorized JavaScript origin for the deployed site and the Supabase callback URL shown in the Google provider settings.

In Authentication > URL Configuration, add the exact Vercel preview URL and production URL to the redirect allow list. For the current standalone HTML path, the redirect returns to the page URL with `#settings`.

## 5. Deploy and verify
Deploy this branch as a Vercel Preview, then test:
- Email sign-up and confirmation email.
- Email/password sign-in and sign-out.
- Google OAuth round-trip on desktop and iPhone Safari/PWA.
- Profile row creation and owner-only profile updates.
- Avatar upload under the authenticated user's UUID folder.
- Cross-user profile read is limited to the public profile fields.

Google OAuth cannot work until the Google client credentials are configured in Supabase. The auth UI remains disabled while the project URL/key placeholders are unchanged.
