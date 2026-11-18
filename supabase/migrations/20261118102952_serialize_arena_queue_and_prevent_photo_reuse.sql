create or replace function private.match_arena_queue()
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $function$
declare
  v_lane public.arena_lanes%rowtype;
  v_first public.arena_photos%rowtype;
  v_second public.arena_photos%rowtype;
  v_champion_owner uuid;
  v_battle uuid;
  v_count integer := 0;
begin
  -- Serialize all queue matching so two worker ticks cannot claim the same photo.
  perform pg_advisory_xact_lock(746218, 1);

  for v_lane in
    select * from public.arena_lanes order by lane_id for update skip locked
  loop
    if exists (
      select 1 from public.arena_battles
      where lane_id=v_lane.lane_id and stage in ('waiting','voting')
    ) then
      continue;
    end if;

    if v_lane.champion_photo_id is not null then
      select owner_id into v_champion_owner
      from public.arena_photos where id=v_lane.champion_photo_id;

      select p.* into v_first
      from public.arena_photos p
      where p.status='queued'
        and p.owner_id<>v_champion_owner
        and not exists (
          select 1 from private.arena_pair_exclusions x
          where x.photo_low=least(p.id,v_lane.champion_photo_id)
            and x.photo_high=greatest(p.id,v_lane.champion_photo_id)
        )
        and not exists (
          select 1 from public.arena_battle_participants bp
          join public.arena_battles b on b.id=bp.battle_id
          where bp.photo_id=p.id and b.stage in ('waiting','voting')
        )
        and not exists (
          select 1 from public.arena_lanes l
          where l.champion_photo_id=p.id or l.challenger_photo_id=p.id
        )
      order by p.created_at,p.id
      limit 1 for update skip locked;

      if not found then continue; end if;

      insert into public.arena_battles(lane_id,opening,stage,confirm_until,stage_ends_at)
      values(v_lane.lane_id,false,'waiting',now()+interval '10 seconds',now()+interval '80 seconds')
      returning id into v_battle;

      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values
        (v_battle,v_lane.champion_photo_id,v_champion_owner,'left'),
        (v_battle,v_first.id,v_first.owner_id,'right');

      update public.arena_photos set status='matched',updated_at=now() where id=v_first.id;
      update public.arena_lanes set challenger_photo_id=v_first.id,updated_at=now()
      where lane_id=v_lane.lane_id;

      delete from private.arena_pair_exclusions
      where photo_low=v_first.id or photo_high=v_first.id;
    else
      select p1.* into v_first
      from public.arena_photos p1
      where p1.status='queued'
        and exists (
          select 1 from public.arena_photos p2
          where p2.status='queued'
            and p2.owner_id<>p1.owner_id
            and not exists (
              select 1 from private.arena_pair_exclusions x
              where x.photo_low=least(p1.id,p2.id)
                and x.photo_high=greatest(p1.id,p2.id)
            )
            and not exists (
              select 1 from public.arena_battle_participants bp
              join public.arena_battles b on b.id=bp.battle_id
              where bp.photo_id=p2.id and b.stage in ('waiting','voting')
            )
            and not exists (
              select 1 from public.arena_lanes l
              where l.champion_photo_id=p2.id or l.challenger_photo_id=p2.id
            )
        )
        and not exists (
          select 1 from public.arena_battle_participants bp
          join public.arena_battles b on b.id=bp.battle_id
          where bp.photo_id=p1.id and b.stage in ('waiting','voting')
        )
        and not exists (
          select 1 from public.arena_lanes l
          where l.champion_photo_id=p1.id or l.challenger_photo_id=p1.id
        )
      order by p1.created_at,p1.id
      limit 1 for update skip locked;

      if not found then continue; end if;

      select p2.* into v_second
      from public.arena_photos p2
      where p2.status='queued'
        and p2.owner_id<>v_first.owner_id
        and not exists (
          select 1 from private.arena_pair_exclusions x
          where x.photo_low=least(v_first.id,p2.id)
            and x.photo_high=greatest(v_first.id,p2.id)
        )
        and not exists (
          select 1 from public.arena_battle_participants bp
          join public.arena_battles b on b.id=bp.battle_id
          where bp.photo_id=p2.id and b.stage in ('waiting','voting')
        )
        and not exists (
          select 1 from public.arena_lanes l
          where l.champion_photo_id=p2.id or l.challenger_photo_id=p2.id
        )
      order by p2.created_at,p2.id
      limit 1 for update skip locked;

      if not found then continue; end if;

      insert into public.arena_battles(lane_id,opening,stage,confirm_until,stage_ends_at)
      values(v_lane.lane_id,true,'waiting',now()+interval '10 seconds',now()+interval '80 seconds')
      returning id into v_battle;

      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values
        (v_battle,v_first.id,v_first.owner_id,'left'),
        (v_battle,v_second.id,v_second.owner_id,'right');

      update public.arena_photos set status='matched',updated_at=now()
      where id in (v_first.id,v_second.id);

      update public.arena_lanes
      set challenger_photo_id=v_second.id,champion_photo_id=v_first.id,updated_at=now()
      where lane_id=v_lane.lane_id;

      delete from private.arena_pair_exclusions
      where photo_low in (v_first.id,v_second.id)
         or photo_high in (v_first.id,v_second.id);
    end if;

    v_count:=v_count+1;
  end loop;

  return v_count;
end;
$function$;
