
create or replace function private.advance_arena()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b public.arena_battles%rowtype;
  v_left uuid; v_right uuid; v_left_votes integer; v_right_votes integer;
  v_winner uuid; v_draw boolean; v_lane public.arena_lanes%rowtype;
  v_done integer := 0;
begin
  for b in
    select * from public.arena_battles
    where stage in ('waiting','voting') and stage_ends_at<=now()
    order by stage_ends_at
    for update skip locked
  loop
    select * into v_lane from public.arena_lanes where lane_id=b.lane_id for update;
    select photo_id into v_left from public.arena_battle_participants where battle_id=b.id and side='left';
    select photo_id into v_right from public.arena_battle_participants where battle_id=b.id and side='right';

    if b.stage='waiting' then
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

    -- A voting stage with zero votes is a cancellation, not a draw/result.
    if coalesce(v_left_votes,0)+coalesce(v_right_votes,0)=0 then
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

    v_draw := v_left_votes=v_right_votes;
    v_winner := case
      when v_left_votes>v_right_votes then v_left
      when v_right_votes>v_left_votes then v_right
      else null
    end;

    insert into public.arena_results(
      battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,
      left_votes,right_votes,total_votes
    ) values (
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
revoke all on function private.advance_arena() from public,anon,authenticated;
grant execute on function private.advance_arena() to anon;
