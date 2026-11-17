
create table if not exists private.arena_pair_exclusions (
  photo_low uuid not null references public.arena_photos(id) on delete cascade,
  photo_high uuid not null references public.arena_photos(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(photo_low,photo_high),
  check(photo_low<photo_high)
);
revoke all on private.arena_pair_exclusions from public,anon,authenticated;

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
    if exists(select 1 from public.arena_battles where lane_id=v_lane.lane_id and stage in ('waiting','voting')) then
      continue;
    end if;

    if v_lane.champion_photo_id is not null then
      select owner_id into v_champion_owner from public.arena_photos where id=v_lane.champion_photo_id;
      select p.* into v_first
      from public.arena_photos p
      where p.status='queued' and p.owner_id<>v_champion_owner
        and not exists(
          select 1 from private.arena_pair_exclusions x
          where x.photo_low=least(p.id,v_lane.champion_photo_id)
            and x.photo_high=greatest(p.id,v_lane.champion_photo_id)
        )
      order by p.created_at,p.id
      limit 1 for update skip locked;
      if not found then continue; end if;

      insert into public.arena_battles(lane_id,opening,stage)
      values(v_lane.lane_id,false,'waiting') returning id into v_battle;
      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values(v_battle,v_lane.champion_photo_id,v_champion_owner,'left'),
            (v_battle,v_first.id,v_first.owner_id,'right');
      update public.arena_photos set status='matched',updated_at=now() where id=v_first.id;
      update public.arena_lanes set challenger_photo_id=v_first.id,updated_at=now() where lane_id=v_lane.lane_id;
      delete from private.arena_pair_exclusions where photo_low in (v_first.id) or photo_high in (v_first.id);
    else
      select p1.* into v_first
      from public.arena_photos p1
      where p1.status='queued'
        and exists(
          select 1 from public.arena_photos p2
          where p2.status='queued' and p2.owner_id<>p1.owner_id
            and not exists(
              select 1 from private.arena_pair_exclusions x
              where x.photo_low=least(p1.id,p2.id) and x.photo_high=greatest(p1.id,p2.id)
            )
        )
      order by p1.created_at,p1.id
      limit 1 for update skip locked;
      if not found then continue; end if;

      select p2.* into v_second
      from public.arena_photos p2
      where p2.status='queued' and p2.owner_id<>v_first.owner_id
        and not exists(
          select 1 from private.arena_pair_exclusions x
          where x.photo_low=least(v_first.id,p2.id) and x.photo_high=greatest(v_first.id,p2.id)
        )
      order by p2.created_at,p2.id
      limit 1 for update skip locked;
      if not found then continue; end if;

      insert into public.arena_battles(lane_id,opening,stage)
      values(v_lane.lane_id,true,'waiting') returning id into v_battle;
      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values(v_battle,v_first.id,v_first.owner_id,'left'),(v_battle,v_second.id,v_second.owner_id,'right');
      update public.arena_photos set status='matched',updated_at=now() where id in (v_first.id,v_second.id);
      update public.arena_lanes
        set challenger_photo_id=v_second.id,champion_photo_id=v_first.id,updated_at=now()
        where lane_id=v_lane.lane_id;
      delete from private.arena_pair_exclusions
        where photo_low in (v_first.id,v_second.id) or photo_high in (v_first.id,v_second.id);
    end if;
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;

create or replace function private.advance_arena()
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  b public.arena_battles%rowtype;
  v_left uuid; v_right uuid; v_left_votes integer; v_right_votes integer;
  v_winner uuid; v_draw boolean;
  v_done integer := 0;
begin
  for b in
    select * from public.arena_battles
    where stage in ('waiting','voting') and stage_ends_at<=now()
    order by stage_ends_at
    for update skip locked
  loop
    select photo_id into v_left from public.arena_battle_participants where battle_id=b.id and side='left';
    select photo_id into v_right from public.arena_battle_participants where battle_id=b.id and side='right';

    if b.stage='waiting' then
      insert into private.arena_pair_exclusions(photo_low,photo_high)
      values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
      update public.arena_battles set stage='cancelled',finished_at=now() where id=b.id;
      update public.arena_photos set status='queued',updated_at=now() where id in (v_left,v_right);
      update public.arena_lanes
        set challenger_photo_id=null,
            champion_photo_id=case when b.opening then null else champion_photo_id end,
            updated_at=now()
        where lane_id=b.lane_id;
      v_done:=v_done+1;
      continue;
    end if;

    select count(*) filter(where target_photo_id=v_left),
           count(*) filter(where target_photo_id=v_right)
      into v_left_votes,v_right_votes
      from public.arena_votes where battle_id=b.id;

    if coalesce(v_left_votes,0)+coalesce(v_right_votes,0)=0 then
      insert into private.arena_pair_exclusions(photo_low,photo_high)
      values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
      update public.arena_battles set stage='cancelled',finished_at=now() where id=b.id;
      update public.arena_photos set status='queued',updated_at=now() where id in (v_left,v_right);
      update public.arena_lanes
        set challenger_photo_id=null,
            champion_photo_id=case when b.opening then null else champion_photo_id end,
            updated_at=now()
        where lane_id=b.lane_id;
      v_done:=v_done+1;
      continue;
    end if;

    v_draw:=v_left_votes=v_right_votes;
    v_winner:=case when v_left_votes>v_right_votes then v_left
                   when v_right_votes>v_left_votes then v_right else null end;
    insert into public.arena_results(
      battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,
      left_votes,right_votes,total_votes
    ) values(
      b.id,b.lane_id,v_left,v_right,v_winner,v_draw,
      v_left_votes,v_right_votes,v_left_votes+v_right_votes
    );

    if b.opening then
      if v_winner is null then
        update public.arena_photos set status='completed',updated_at=now() where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=null,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      else
        update public.arena_photos
          set status=case when id=v_winner then 'champion' else 'completed' end,updated_at=now()
          where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=v_winner,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      end if;
    else
      if v_winner=v_right then
        update public.arena_photos
          set status=case when id=v_right then 'champion' else 'completed' end,updated_at=now()
          where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=v_right,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      elsif v_winner=v_left then
        update public.arena_photos set status='completed',updated_at=now() where id=v_right;
        update public.arena_lanes set challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      else
        insert into private.arena_pair_exclusions(photo_low,photo_high)
        values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
        update public.arena_photos set status='queued',updated_at=now() where id=v_right;
        update public.arena_lanes set challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      end if;
    end if;

    update public.arena_battles set stage='completed',finished_at=now() where id=b.id;
    v_done:=v_done+1;
  end loop;
  return v_done;
end;
$$;

revoke all on function private.match_arena_queue() from public,anon,authenticated;
revoke all on function private.advance_arena() from public,anon,authenticated;
grant execute on function private.match_arena_queue() to anon;
grant execute on function private.advance_arena() to anon;
