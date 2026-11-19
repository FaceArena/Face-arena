-- Public, read-only status endpoint for the maintenance banner.
create or replace function public.get_arena_platform_controls()
returns table (battles_paused boolean, publications_blocked boolean, updated_at timestamptz)
language sql
stable
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
  select c.battles_paused, c.publications_blocked, c.updated_at
  from public.arena_platform_controls c
  where c.singleton = true;
$$;
revoke all on function public.get_arena_platform_controls() from public;
grant execute on function public.get_arena_platform_controls() to anon, authenticated, service_role;
