
create or replace function private.worker_tick()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare v_matched integer; v_advanced integer; v_next timestamptz;
begin
  v_advanced:=private.advance_arena();
  v_matched:=private.match_arena_queue();
  select min(stage_ends_at) into v_next from public.arena_battles where stage in ('waiting','voting');
  return jsonb_build_object('advanced',v_advanced,'matched',v_matched,'next_deadline',v_next);
end;
$$;
revoke all on function private.worker_tick() from public,anon,authenticated;
grant execute on function private.worker_tick() to anon;
