-- Fix platform-control RPC authorization for modern PostgREST JWT claims.
-- The function is callable only by service_role (EXECUTE privilege); checking
-- request.jwt.claim.role is obsolete and rejects valid service-role RPC calls.
create or replace function public.admin_set_arena_platform_controls(
  p_battles_paused boolean,
  p_publications_blocked boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $function$
declare
  v_cancelled integer := 0;
begin
  perform pg_advisory_xact_lock(746218, 1);

  update public.arena_platform_controls
  set battles_paused = p_battles_paused,
      publications_blocked = p_publications_blocked,
      updated_at = now()
  where singleton = true;

  if p_battles_paused then
    update public.arena_photos p
    set status = case
          when b.opening then 'queued'
          when bp.side = 'left' then 'champion'
          else 'queued'
        end,
        updated_at = now()
    from public.arena_battle_participants bp
    join public.arena_battles b on b.id = bp.battle_id
    where p.id = bp.photo_id
      and b.stage in ('waiting', 'voting');

    update public.arena_lanes l
    set challenger_photo_id = null,
        champion_photo_id = case when b.opening then null else l.champion_photo_id end,
        updated_at = now()
    from public.arena_battles b
    where b.lane_id = l.lane_id
      and b.stage in ('waiting', 'voting');

    update public.arena_battles
    set stage = 'cancelled', finished_at = now()
    where stage in ('waiting', 'voting');
    get diagnostics v_cancelled = row_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'battles_paused', p_battles_paused,
    'publications_blocked', p_publications_blocked,
    'cancelled_battles', v_cancelled
  );
end;
$function$;

revoke all on function public.admin_set_arena_platform_controls(boolean, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_arena_platform_controls(boolean, boolean) to service_role;
