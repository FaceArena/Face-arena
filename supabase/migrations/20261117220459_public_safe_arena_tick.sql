
drop function if exists public.worker_tick(text);
drop table if exists private.arena_worker_config;
create or replace function public.worker_tick()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_matched integer; v_advanced integer; v_next timestamptz;
begin
  v_advanced:=public.advance_arena();
  v_matched:=public.match_arena_queue();
  select min(stage_ends_at) into v_next from public.arena_battles where stage in ('waiting','voting');
  return jsonb_build_object('advanced',v_advanced,'matched',v_matched,'next_deadline',v_next);
end;
$$;
revoke all on function public.worker_tick() from public,authenticated;
grant execute on function public.worker_tick() to anon;
