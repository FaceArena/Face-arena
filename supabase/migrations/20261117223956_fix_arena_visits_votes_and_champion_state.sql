
create or replace function private.register_arena_visit(p_battle_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_battle public.arena_battles%rowtype;
  v_end timestamptz;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_battle from public.arena_battles where id=p_battle_id for update;
  if not found or v_battle.stage not in ('waiting','voting') or v_battle.stage_ends_at<=now() then
    raise exception 'Battle is not accepting visits';
  end if;
  if v_battle.stage='waiting' and v_battle.confirm_until is not null and v_battle.confirm_until>now() then
    raise exception 'The 10-second cancellation window is still active';
  end if;
  if exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then
    raise exception 'Participants cannot visit their own battle';
  end if;
  insert into public.arena_battle_visits(battle_id,visitor_id) values(p_battle_id,v_user)
  on conflict (battle_id,visitor_id) do nothing;

  if v_battle.stage='waiting' then
    update public.arena_battles
      set stage='voting',stage_ends_at=now()+interval '70 seconds'
      where id=p_battle_id and stage='waiting'
      returning stage_ends_at into v_end;
  else
    v_end := v_battle.stage_ends_at;
  end if;
  return v_end;
end;
$$;

create or replace function private.submit_arena_vote(p_battle_id uuid,p_target_photo_id uuid,p_comment text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_battle public.arena_battles%rowtype;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_comment is null or char_length(btrim(p_comment)) not between 10 and 300 then
    raise exception 'Comment must contain 10 to 300 characters';
  end if;

  select * into v_battle from public.arena_battles where id=p_battle_id for update;
  if not found or v_battle.stage<>'voting' or v_battle.stage_ends_at<=now() then
    raise exception 'Voting is closed';
  end if;
  if exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then
    raise exception 'Participants cannot vote in their own battle';
  end if;
  if not exists(select 1 from public.arena_battle_visits where battle_id=p_battle_id and visitor_id=v_user) then
    raise exception 'Open the battle before voting';
  end if;
  if not exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and photo_id=p_target_photo_id) then
    raise exception 'Selected photo does not belong to this battle';
  end if;

  insert into public.arena_votes(battle_id,voter_id,target_photo_id,comment)
  values(p_battle_id,v_user,p_target_photo_id,btrim(p_comment));
end;
$$;

create or replace function private.advance_arena()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  b public.arena_battles%rowtype;
  v_left uuid; v_right uuid; v_left_votes integer; v_right_votes integer;
  v_winner uuid; v_draw boolean; v_done integer:=0;
begin
  for b in
    select * from public.arena_battles
    where stage in ('waiting','voting') and stage_ends_at<=now()
    order by stage_ends_at for update skip locked
  loop
    select photo_id into v_left from public.arena_battle_participants where battle_id=b.id and side='left';
    select photo_id into v_right from public.arena_battle_participants where battle_id=b.id and side='right';

    if b.stage='waiting' then
      insert into private.arena_pair_exclusions(photo_low,photo_high)
      values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
      update public.arena_battles set stage='cancelled',finished_at=now() where id=b.id;
      update public.arena_photos
        set status=case when not b.opening and id=v_left then 'champion' else 'queued' end,updated_at=now()
        where id in (v_left,v_right);
      update public.arena_lanes
        set challenger_photo_id=null,champion_photo_id=case when b.opening then null else champion_photo_id end,updated_at=now()
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
      update public.arena_photos
        set status=case when not b.opening and id=v_left then 'champion' else 'queued' end,updated_at=now()
        where id in (v_left,v_right);
      update public.arena_lanes
        set challenger_photo_id=null,champion_photo_id=case when b.opening then null else champion_photo_id end,updated_at=now()
        where lane_id=b.lane_id;
      v_done:=v_done+1;
      continue;
    end if;

    v_draw:=v_left_votes=v_right_votes;
    v_winner:=case when v_left_votes>v_right_votes then v_left
                   when v_right_votes>v_left_votes then v_right else null end;
    insert into public.arena_results(
      battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,
      left_votes,right_votes,total_votes,opening
    )
    values(
      b.id,b.lane_id,v_left,v_right,v_winner,v_draw,
      v_left_votes,v_right_votes,v_left_votes+v_right_votes,b.opening
    );

    if b.opening then
      if v_winner is null then
        update public.arena_photos set status='completed',updated_at=now() where id in (v_left,v_right);
        update public.arena_lanes set champion_photo_id=null,challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
      else
        update public.arena_photos
          set status=case when id=v_winner then 'champion' else 'completed' end,updated_at=now()
          where id in (v_left,v_right);
        update public.arena_lanes
          set champion_photo_id=v_winner,challenger_photo_id=null,updated_at=now()
          where lane_id=b.lane_id;
      end if;
    elsif v_winner=v_right then
      update public.arena_photos
        set status=case when id=v_right then 'champion' else 'completed' end,updated_at=now()
        where id in (v_left,v_right);
      update public.arena_lanes set champion_photo_id=v_right,challenger_photo_id=null,updated_at=now()
        where lane_id=b.lane_id;
    elsif v_winner=v_left then
      update public.arena_photos set status='champion',updated_at=now() where id=v_left;
      update public.arena_photos set status='completed',updated_at=now() where id=v_right;
      update public.arena_lanes set challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
    else
      insert into private.arena_pair_exclusions(photo_low,photo_high)
      values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;
      update public.arena_photos set status='champion',updated_at=now() where id=v_left;
      update public.arena_photos set status='queued',updated_at=now() where id=v_right;
      update public.arena_lanes set challenger_photo_id=null,updated_at=now() where lane_id=b.lane_id;
    end if;

    update public.arena_battles set stage='completed',finished_at=now() where id=b.id;
    v_done:=v_done+1;
  end loop;
  return v_done;
end;
$$;

drop policy if exists "Users can read their own battle visits" on public.arena_battle_visits;
create policy "Users can read their own battle visits" on public.arena_battle_visits
for select to authenticated using (visitor_id=(select auth.uid()));

drop policy if exists "Users update their own arena profile" on public.arena_profiles;
create policy "Users update their own arena profile" on public.arena_profiles
for update to authenticated
using (user_id=(select auth.uid()))
with check (user_id=(select auth.uid()));

drop policy if exists "Authenticated users can read arena photos" on public.arena_photos;
create policy "Authenticated users can read arena photos" on public.arena_photos
for select to authenticated using (status<>'removed' or owner_id=(select auth.uid()));

revoke all on table public.arena_profiles from anon;
revoke insert,delete on table public.arena_profiles from authenticated;
grant select,update on table public.arena_profiles to authenticated;

create index if not exists arena_pair_exclusions_photo_high_idx on private.arena_pair_exclusions(photo_high);
create index if not exists arena_battle_participants_photo_id_idx on public.arena_battle_participants(photo_id);
create index if not exists arena_battle_visits_visitor_id_idx on public.arena_battle_visits(visitor_id);
create index if not exists arena_lanes_challenger_photo_id_idx on public.arena_lanes(challenger_photo_id);
create index if not exists arena_lanes_champion_photo_id_idx on public.arena_lanes(champion_photo_id);
create index if not exists arena_results_lane_id_idx on public.arena_results(lane_id);
create index if not exists arena_results_left_photo_id_idx on public.arena_results(left_photo_id);
create index if not exists arena_results_right_photo_id_idx on public.arena_results(right_photo_id);
create index if not exists arena_results_winner_photo_id_idx on public.arena_results(winner_photo_id);
create index if not exists arena_votes_voter_id_idx on public.arena_votes(voter_id);
