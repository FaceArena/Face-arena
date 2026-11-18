-- Keep the public worker endpoint callable by the anonymous publishable-key
-- client, but make the internal implementation inaccessible as a direct RPC.
create or replace function public.worker_tick()
returns jsonb
language sql
security definer
set search_path to 'pg_catalog', 'public', 'private', 'pg_temp'
as $function$
  select private.worker_tick();
$function$;

revoke all on function private.worker_tick() from public, anon, authenticated;
revoke all on function public.worker_tick() from public, authenticated;
grant execute on function public.worker_tick() to anon;
