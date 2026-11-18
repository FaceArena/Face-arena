
alter table public.arena_battles add column if not exists confirm_until timestamptz;

create or replace function private.match_arena_queue()
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_lane public.arena_lanes%rowtype;
  v_first public.arena_photos%rowtype;
  v_second public.arena_photos%rowtype;
  v_champion_owner uuid;
  v_battle uuid;
  v_count integer := 0;
begin
  for v_lane in select * from public.arena_lanes order by lane_id for update skip locked loop
    if exists(select 1 from public.arena_battles where lane_id=v_lane.lane_id and stage in ('waiting','voting')) then continue; end if;

    if v_lane.champion_photo_id is not null then
      select owner_id into v_champion_owner from public.arena_photos where id=v_lane.champion_photo_id;
      select p.* into v_first
      from public.arena_photos p
      where p.status='queued' and p.owner_id<>v_champion_owner
        and not exists(select 1 from private.arena_pair_exclusions x where x.photo_low=least(p.id,v_lane.champion_photo_id) and x.photo_high=greatest(p.id,v_lane.champion_photo_id))
      order by p.created_at,p.id limit 1 for update skip locked;
      if not found then continue; end if;

      insert into public.arena_battles(lane_id,opening,stage,confirm_until,stage_ends_at)
      values(v_lane.lane_id,false,'waiting',now()+interval '10 seconds',now()+interval '80 seconds')
      returning id into v_battle;
      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values(v_battle,v_lane.champion_photo_id,v_champion_owner,'left'),(v_battle,v_first.id,v_first.owner_id,'right');
      update public.arena_photos set status='matched',updated_at=now() where id=v_first.id;
      update public.arena_lanes set challenger_photo_id=v_first.id,updated_at=now() where lane_id=v_lane.lane_id;
      delete from private.arena_pair_exclusions where photo_low=v_first.id or photo_high=v_first.id;
    else
      select p1.* into v_first
      from public.arena_photos p1
      where p1.status='queued'
        and exists(
          select 1 from public.arena_photos p2
          where p2.status='queued' and p2.owner_id<>p1.owner_id
            and not exists(select 1 from private.arena_pair_exclusions x where x.photo_low=least(p1.id,p2.id) and x.photo_high=greatest(p1.id,p2.id))
        )
      order by p1.created_at,p1.id limit 1 for update skip locked;
      if not found then continue; end if;

      select p2.* into v_second
      from public.arena_photos p2
      where p2.status='queued' and p2.owner_id<>v_first.owner_id
        and not exists(select 1 from private.arena_pair_exclusions x where x.photo_low=least(v_first.id,p2.id) and x.photo_high=greatest(v_first.id,p2.id))
      order by p2.created_at,p2.id limit 1 for update skip locked;
      if not found then continue; end if;

      insert into public.arena_battles(lane_id,opening,stage,confirm_until,stage_ends_at)
      values(v_lane.lane_id,true,'waiting',now()+interval '10 seconds',now()+interval '80 seconds')
      returning id into v_battle;
      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values(v_battle,v_first.id,v_first.owner_id,'left'),(v_battle,v_second.id,v_second.owner_id,'right');
      update public.arena_photos set status='matched',updated_at=now() where id in (v_first.id,v_second.id);
      update public.arena_lanes set challenger_photo_id=v_second.id,champion_photo_id=v_first.id,updated_at=now() where lane_id=v_lane.lane_id;
      delete from private.arena_pair_exclusions where photo_low in (v_first.id,v_second.id) or photo_high in (v_first.id,v_second.id);
    end if;
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;

create or replace function private.register_arena_visit(p_battle_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
declare v_user uuid := auth.uid(); v_battle public.arena_battles%rowtype; v_end timestamptz;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_battle from public.arena_battles where id=p_battle_id for update;
  if not found or v_battle.stage<>'waiting' or v_battle.stage_ends_at<=now() then raise exception 'Battle is not accepting first visits'; end if;
  if v_battle.confirm_until is not null and v_battle.confirm_until>now() then raise exception 'The 10-second cancellation window is still active'; end if;
  if exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then raise exception 'Participants cannot visit their own battle'; end if;
  insert into public.arena_battle_visits(battle_id,visitor_id) values(p_battle_id,v_user) on conflict do nothing;
  update public.arena_battles set stage='voting',stage_ends_at=now()+interval '70 seconds'
    where id=p_battle_id and stage='waiting' returning stage_ends_at into v_end;
  if v_end is null then select stage_ends_at into v_end from public.arena_battles where id=p_battle_id; end if;
  return v_end;
end;
$$;

create or replace function private.cancel_arena_match(p_battle_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, private, pg_temp
as $$
declare v_user uuid:=auth.uid(); v_battle public.arena_battles%rowtype; v_left uuid; v_right uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_battle from public.arena_battles where id=p_battle_id for update;
  if not found or v_battle.stage<>'waiting' or v_battle.confirm_until is null or v_battle.confirm_until<=now() then
    raise exception 'Cancellation window has closed';
  end if;
  if not exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then
    raise exception 'Only a participant can cancel this match';
  end if;
  select photo_id into v_left from public.arena_battle_participants where battle_id=p_battle_id and side='left';
  select photo_id into v_right from public.arena_battle_participants where battle_id=p_battle_id and side='right';
  insert into private.arena_pair_exclusions(photo_low,photo_high)
  values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
  update public.arena_battles set stage='cancelled',finished_at=now() where id=p_battle_id;
  update public.arena_photos set status='queued',updated_at=now() where id in (v_left,v_right);
  update public.arena_lanes set challenger_photo_id=null,champion_photo_id=case when v_battle.opening then null else champion_photo_id end,updated_at=now()
  where lane_id=v_battle.lane_id;
end;
$$;

revoke all on function private.match_arena_queue() from public,anon,authenticated;
revoke all on function private.register_arena_visit(uuid) from public,anon,authenticated;
revoke all on function private.cancel_arena_match(uuid) from public,anon,authenticated;
grant execute on function private.match_arena_queue() to anon;
grant execute on function private.register_arena_visit(uuid) to authenticated;
grant execute on function private.cancel_arena_match(uuid) to authenticated;

create or replace function public.cancel_arena_match(p_battle_id uuid)
returns void language sql security invoker set search_path=public,private,pg_temp
as $$ select private.cancel_arena_match(p_battle_id); $$;
revoke all on function public.cancel_arena_match(uuid) from public,anon,authenticated;
grant execute on function public.cancel_arena_match(uuid) to authenticated;
