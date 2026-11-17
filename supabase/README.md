# FACE ARENA Supabase setup

The server database for FACE ARENA is the Supabase project `nvvkmjeobnnxlrpiuisf`. Do not point this app at the Vayron project.

## Migrations

Apply the files in `migrations/` in ascending timestamp order. The initial schema and every subsequent policy, RPC, queue, result, and Realtime change are versioned here.

The migration `20261117223700_secure_arena_worker_and_internal_functions.sql` deliberately does **not** insert a worker secret. Secrets must never be stored in migration source or committed to Git.

After applying migrations, provision a fresh cryptographically random secret in:
- Cloudflare Worker secret binding: `WORKER_WAKE_SECRET`
- Supabase private row: `private.arena_worker_config.wake_secret` where `singleton = true`

Keep both values identical. Never use the service-role key in the browser or Worker. The Worker only needs the Supabase publishable key plus its private wake secret.

## Data and synchronization

- Supabase Auth identifies accounts.
- Postgres is authoritative for the queue, 10 lanes, matches, votes, results and server deadlines.
- Supabase Storage bucket `arena-photos` stores uploaded photos.
- Supabase Realtime publishes arena state changes to connected clients.
- Cloudflare Durable Objects schedule the next server deadline and wake the private coordinator.
- Vercel is only a preview/hosting surface; the game backend must continue operating without it.

The 10-second match-cancellation window is separate. After that, the initial wait for a visitor is 70 seconds; once voting starts, voting lasts 70 seconds. Both deadlines are enforced against server time.

## Cloudflare Pages frontend

The independent static frontend is built from the repository root into `dist/` with:
`mkdir -p dist && cp index.html face-arena-sync.js face-arena-audio.js face-arena-game-engine.js _headers dist/`

Only these runtime files are published. The Pages project has automatic preview deployments enabled and production deployments disabled. Vercel is not required for the frontend runtime or backend.
