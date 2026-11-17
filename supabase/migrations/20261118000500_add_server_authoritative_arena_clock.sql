create or replace function public.get_arena_server_time()
returns bigint
language sql
volatile
security invoker
set search_path = pg_catalog
as $$
  select floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
$$;

revoke all on function public.get_arena_server_time() from public, anon;
grant execute on function public.get_arena_server_time() to authenticated;