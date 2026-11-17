
create table if not exists private.arena_worker_config (
  singleton boolean primary key default true check (singleton),
  wake_secret text not null,
  updated_at timestamptz not null default now()
);
revoke all on table private.arena_worker_config from public, anon, authenticated, service_role;
-- Provision private.arena_worker_config.wake_secret out of band; never store the worker secret in migration source.

create or replace function private.worker_tick()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  v_headers jsonb;
  v_provided text;
  v_expected text;
  v_matched integer;
  v_advanced integer;
  v_next timestamptz;
begin
  v_headers := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_provided := v_headers ->> 'x-arena-worker-token';
  select wake_secret into v_expected from private.arena_worker_config where singleton=true;
  if v_expected is null or v_provided is distinct from v_expected then
    raise exception 'Worker authentication failed' using errcode='42501';
  end if;

  v_advanced := private.advance_arena();
  v_matched := private.match_arena_queue();
  select min(stage_ends_at) into v_next
  from public.arena_battles where stage in ('waiting','voting');
  return jsonb_build_object('advanced',v_advanced,'matched',v_matched,'next_deadline',v_next);
end;
$$;

alter function public.worker_tick() security definer;
alter function public.worker_tick() set search_path = pg_catalog, public, private, pg_temp;
alter function public.cancel_arena_match(uuid) security definer;
alter function public.cancel_arena_match(uuid) set search_path = pg_catalog, public, private, auth, pg_temp;
alter function public.delete_arena_photo(uuid) security definer;
alter function public.delete_arena_photo(uuid) set search_path = pg_catalog, public, private, auth, pg_temp;
alter function public.enqueue_arena_photo(text) security definer;
alter function public.enqueue_arena_photo(text) set search_path = pg_catalog, public, private, auth, storage, pg_temp;
alter function public.register_arena_visit(uuid) security definer;
alter function public.register_arena_visit(uuid) set search_path = pg_catalog, public, private, auth, pg_temp;
alter function public.submit_arena_vote(uuid,uuid,text) security definer;
alter function public.submit_arena_vote(uuid,uuid,text) set search_path = pg_catalog, public, private, auth, pg_temp;

revoke all on schema private from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.worker_tick() from public, authenticated;
grant execute on function public.worker_tick() to anon;
revoke all on function public.cancel_arena_match(uuid) from public, anon;
revoke all on function public.delete_arena_photo(uuid) from public, anon;
revoke all on function public.enqueue_arena_photo(text) from public, anon;
revoke all on function public.register_arena_visit(uuid) from public, anon;
revoke all on function public.submit_arena_vote(uuid,uuid,text) from public, anon;
grant execute on function public.cancel_arena_match(uuid) to authenticated;
grant execute on function public.delete_arena_photo(uuid) to authenticated;
grant execute on function public.enqueue_arena_photo(text) to authenticated;
grant execute on function public.register_arena_visit(uuid) to authenticated;
grant execute on function public.submit_arena_vote(uuid,uuid,text) to authenticated;
