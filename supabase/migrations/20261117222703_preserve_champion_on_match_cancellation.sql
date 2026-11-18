
create or replace function private.advance_arena()
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  b public.arena_battles%rowtype;
  v_left uuid; v_right uuid; v_left_votes integer; v_right_votes integer;
  v_winner uuid; v_draw boolean; v_done integer:=0;
begin
  for b in select * from public.arena_battles where stage in ('waiting','voting') and stage_ends_at<=now() order by stage_ends_at for update skip locked loop
    select photo_id into v_left from public.arena_battle_participants where battle_id=b.id and side='left';
    select photo_id into v_right from public.arena_battle_participants where battle_id=b.id and side='right';

    if b.stage='waiting' then
      insert into private.arena_pair_exclusions(photo_low,photo_high) values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
      update public.arena_battles set stage='cancelled',finished_at=now() where id=b.id;
      update public.arena_photos set status=case when not b.opening and id=v_left then 'champion' else 'queued' end,updated_at=now() where id in (v_left,v_right);
      update public.arena_lanes set challenger_photo_id=null,champion_photo_id=case when b.opening then null else champion_photo_id end,updated_at=now() where lane_id=b.lane_id;
      v_done:=v_done+1; continue;
    end if;

    select count(*) filter(where target_photo_id=v_left),count(*) filter(where target_photo_id=v_right)
      into v_left_votes,v_right_votes from public.arena_votes where battle_id=b.id;

    if coalesce(v_left_votes,0)+coalesce(v_right_votes,0)=0 then
      insert into private.arena_pair_exclusions(photo_low,photo_high) values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
      update public.arena_battles set stage='cancelled',finished_at=now() where id=b.id;
      update public.arena_photos set status=case when not b.opening and id=v_left then 'champion' else 'queued' end,updated_at=now() where id in (v_left,v_right);
      update public.arena_lanes set challenger_photo_id=null,champion_photo_id=case when b.opening then null else champion_photo_id end,updated_at=now() where lane_id=b.lane_id;
      v_done:=v_done+1; continue;
    end if;

    v_draw:=v_left_votes=v_right_votes;
    v_winner:=case when v_left_votes>v_right_votes then v_left when v_right_votes>v_left_votes then v_right else null end;
    insert into public.arena_results(battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,left_votes,right_votes,total_votes,opening)
    values(b.id,b.lane_id,v_left,v_right,v_winner,v_draw,v_left_votes,v_right_votes,v_left_votes+v_right_votes,b.opening);

    if b.opening then
      if v_winner is null then
        update public.arena_photos set status='completed',updated_at=now() where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=null,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      else
        update public.arena_photos set status=case when id=v_winner then 'champion' else 'completed' end,updated_at=now() where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=v_winner,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      end if;
    else
      if v_winner=v_right then
        update public.arena_photos set status=case when id=v_right then 'champion' else 'completed' end,updated_at=now() where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=v_right,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      elsif v_winner=v_left then
        update public.arena_photos set status='completed',updated_at=now() where id=v_right;
        update public.arena_lanes set challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      else
        insert into private.arena_pair_exclusions(photo_low,photo_high) values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
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
  if not found or v_battle.stage<>'waiting' or v_battle.confirm_until is null or v_battle.confirm_until<=now() then raise exception 'Cancellation window has closed'; end if;
  if not exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then raise exception 'Only a participant can cancel this match'; end if;
  select photo_id into v_left from public.arena_battle_participants where battle_id=p_battle_id and side='left';
  select photo_id into v_right from public.arena_battle_participants where battle_id=p_battle_id and side='right';
  insert into private.arena_pair_exclusions(photo_low,photo_high) values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
  update public.arena_battles set stage='cancelled',finished_at=now() where id=p_battle_id;
  update public.arena_photos set status=case when not v_battle.opening and id=v_left then 'champion' else 'queued' end,updated_at=now() where id in (v_left,v_right);
  update public.arena_lanes set challenger_photo_id=null,champion_photo_id=case when v_battle.opening then null else champion_photo_id end,updated_at=now() where lane_id=v_battle.lane_id;
end;
$$;
revoke all on function private.advance_arena() from public,anon,authenticated;
revoke all on function private.cancel_arena_match(uuid) from public,anon,authenticated;
grant execute on function private.advance_arena() to anon;
grant execute on function private.cancel_arena_match(uuid) to authenticated;
