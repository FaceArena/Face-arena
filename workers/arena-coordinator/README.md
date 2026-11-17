# FACE ARENA Cloudflare coordinator

This Worker is the server-side timer/matchmaking wake-up service. It is independent of Vercel.

## Preview deployment

The preview branch deploys the Worker named `face-arena-preview` using `wrangler.toml`.

The Worker is deployed independently of Vercel. If using GitHub Actions for future deployments, add a repository secret named `CLOUDFLARE_API_TOKEN` with permission to edit Workers scripts and Durable Objects. The account ID is configured in the workflow.

The Worker also requires the Cloudflare secret binding `WORKER_WAKE_SECRET`. Provision the same random value in the private Supabase table `private.arena_worker_config.wake_secret`; never commit it to Git. The current connected environment already has this secret provisioned in Supabase.

After the first deployment, enable the account's `workers.dev` subdomain if it is not enabled, then verify:

- `GET https://face-arena-preview.featuresfaded.workers.dev/health`
- `POST https://face-arena-preview.9mmm77v2jj.workers.dev/wake`

## Runtime behavior

- A single Durable Object named `global-arena` coordinates the 10 lanes.
- The Worker calls the safe `public.worker_tick()` RPC.
- Supabase remains authoritative for all deadlines and results.
- The Durable Object schedules its next alarm at the earliest database deadline.
- If there are no active battles, no recurring alarm is kept.
- The publishable Supabase key is public by design; no service-role key is stored in the Worker.

Do not deploy this preview Worker as the production Worker until the preview flow and CI checks pass.
