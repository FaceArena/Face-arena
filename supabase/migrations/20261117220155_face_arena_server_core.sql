
create extension if not exists pgcrypto with schema extensions;

create table public.arena_photos (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  object_path text not null unique,
  status text not null default 'queued' check (status in ('queued','matched','champion','completed','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index arena_photos_queue_idx on public.arena_photos(created_at,id) where status='queued';
create index arena_photos_owner_active_idx on public.arena_photos(owner_id,status) where status in ('queued','matched','champion');

create table public.arena_lanes (
  lane_id smallint primary key check (lane_id between 1 and 10),
  champion_photo_id uuid references public.arena_photos(id),
  challenger_photo_id uuid references public.arena_photos(id),
  updated_at timestamptz not null default now(),
  check (champion_photo_id is null or challenger_photo_id is null or champion_photo_id <> challenger_photo_id)
);
insert into public.arena_lanes(lane_id) select generate_series(1,10);

create table public.arena_battles (
  id uuid primary key default gen_random_uuid(),
  lane_id smallint not null references public.arena_lanes(lane_id),
  opening boolean not null default false,
  stage text not null check (stage in ('waiting','voting','completed','cancelled')),
  started_at timestamptz not null default now(),
  stage_ends_at timestamptz not null default (now() + interval '70 seconds'),
  finished_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index arena_one_live_battle_per_lane on public.arena_battles(lane_id) where stage in ('waiting','voting');
create index arena_battles_deadline_idx on public.arena_battles(stage_ends_at) where stage in ('waiting','voting');

create table public.arena_battle_participants (
  battle_id uuid not null references public.arena_battles(id) on delete cascade,
  photo_id uuid not null references public.arena_photos(id),
  owner_id uuid not null references auth.users(id),
  side text not null check (side in ('left','right')),
  primary key (battle_id,photo_id),
  unique (battle_id,owner_id),
  unique (battle_id,side)
);
create index arena_participants_owner_idx on public.arena_battle_participants(owner_id);

create table public.arena_battle_visits (
  battle_id uuid not null references public.arena_battles(id) on delete cascade,
  visitor_id uuid not null references auth.users(id) on delete cascade,
  visited_at timestamptz not null default now(),
  primary key (battle_id,visitor_id)
);

create table public.arena_votes (
  battle_id uuid not null references public.arena_battles(id) on delete cascade,
  voter_id uuid not null references auth.users(id) on delete cascade,
  target_photo_id uuid not null,
  comment text not null check (char_length(btrim(comment)) between 10 and 300),
  created_at timestamptz not null default now(),
  primary key (battle_id,voter_id),
  foreign key (battle_id,target_photo_id) references public.arena_battle_participants(battle_id,photo_id)
);
create index arena_votes_target_idx on public.arena_votes(battle_id,target_photo_id);

create table public.arena_results (
  id uuid primary key default gen_random_uuid(),
  battle_id uuid not null unique references public.arena_battles(id),
  lane_id smallint not null references public.arena_lanes(lane_id),
  left_photo_id uuid not null references public.arena_photos(id),
  right_photo_id uuid not null references public.arena_photos(id),
  winner_photo_id uuid references public.arena_photos(id),
  is_draw boolean not null default false,
  left_votes integer not null default 0,
  right_votes integer not null default 0,
  total_votes integer not null default 0,
  completed_at timestamptz not null default now()
);
create index arena_results_completed_idx on public.arena_results(completed_at desc);

create or replace function public.enqueue_arena_photo(p_object_path text)
returns uuid
language plpgsql
security definer
set search_path = public, auth, storage, pg_temp
as $$
declare v_user uuid := auth.uid(); v_photo uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_object_path is null or p_object_path !~ ('^' || v_user::text || '/[A-Za-z0-9._-]+$') then
    raise exception 'Invalid photo storage path';
  end if;
  if not exists (select 1 from storage.objects where bucket_id='arena-photos' and name=p_object_path) then
    raise exception 'Uploaded photo not found';
  end if;
  if (select count(*) from public.arena_photos where owner_id=v_user and status in ('queued','matched','champion')) >= 3 then
    raise exception 'Maximum 3 active photos per account';
  end if;
  insert into public.arena_photos(owner_id,object_path) values(v_user,p_object_path) returning id into v_photo;
  return v_photo;
end;
$$;

create or replace function public.register_arena_visit(p_battle_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_user uuid := auth.uid(); v_battle public.arena_battles%rowtype; v_end timestamptz;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_battle from public.arena_battles where id=p_battle_id for update;
  if not found or v_battle.stage <> 'waiting' or v_battle.stage_ends_at <= now() then
    raise exception 'Battle is not accepting first visits';
  end if;
  if exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then
    raise exception 'Participants cannot visit their own battle';
  end if;
  insert into public.arena_battle_visits(battle_id,visitor_id) values(p_battle_id,v_user) on conflict do nothing;
  update public.arena_battles set stage='voting', stage_ends_at=now()+interval '70 seconds'
    where id=p_battle_id and stage='waiting'
    returning stage_ends_at into v_end;
  if v_end is null then select stage_ends_at into v_end from public.arena_battles where id=p_battle_id; end if;
  return v_end;
end;
$$;

create or replace function public.submit_arena_vote(p_battle_id uuid,p_target_photo_id uuid,p_comment text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_comment is null or char_length(btrim(p_comment)) not between 10 and 300 then
    raise exception 'Comment must contain 10 to 300 characters';
  end if;
  if not exists(select 1 from public.arena_battles where id=p_battle_id and stage='voting' and stage_ends_at>now()) then
    raise exception 'Voting is closed';
  end if;
  if exists(select 1 from public.arena_battle_participants where battle_id=p_battle_id and owner_id=v_user) then
    raise exception 'Participants cannot vote in their own battle';
  end if;
  insert into public.arena_votes(battle_id,voter_id,target_photo_id,comment)
  values(p_battle_id,v_user,p_target_photo_id,btrim(p_comment));
end;
$$;

create or replace function public.delete_arena_photo(p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update public.arena_photos set status='removed',updated_at=now()
  where id=p_photo_id and owner_id=auth.uid() and status in ('queued','completed');
  if not found then raise exception 'Photo cannot be removed in its current state'; end if;
end;
$$;

create or replace function public.match_arena_queue()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lane public.arena_lanes%rowtype;
  v_first public.arena_photos%rowtype;
  v_second public.arena_photos%rowtype;
  v_battle uuid;
  v_count integer := 0;
begin
  for v_lane in select * from public.arena_lanes order by lane_id for update skip locked loop
    if exists(select 1 from public.arena_battles where lane_id=v_lane.lane_id and stage in ('waiting','voting')) then
      continue;
    end if;
    if v_lane.champion_photo_id is not null then
      select * into v_first from public.arena_photos
      where status='queued' and owner_id<>(select owner_id from public.arena_photos where id=v_lane.champion_photo_id)
      order by created_at,id limit 1 for update skip locked;
      if not found then continue; end if;
      insert into public.arena_battles(lane_id,opening,stage) values(v_lane.lane_id,false,'waiting') returning id into v_battle;
      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values(v_battle,v_lane.champion_photo_id,(select owner_id from public.arena_photos where id=v_lane.champion_photo_id),'left'),
            (v_battle,v_first.id,v_first.owner_id,'right');
      update public.arena_photos set status='matched',updated_at=now() where id=v_first.id;
      update public.arena_lanes set challenger_photo_id=v_first.id,updated_at=now() where lane_id=v_lane.lane_id;
    else
      select * into v_first from public.arena_photos where status='queued' order by created_at,id limit 1 for update skip locked;
      if not found then continue; end if;
      select * into v_second from public.arena_photos
      where status='queued' and owner_id<>v_first.owner_id
      order by created_at,id limit 1 for update skip locked;
      if not found then continue; end if;
      insert into public.arena_battles(lane_id,opening,stage) values(v_lane.lane_id,true,'waiting') returning id into v_battle;
      insert into public.arena_battle_participants(battle_id,photo_id,owner_id,side)
      values(v_battle,v_first.id,v_first.owner_id,'left'),(v_battle,v_second.id,v_second.owner_id,'right');
      update public.arena_photos set status='matched',updated_at=now() where id in (v_first.id,v_second.id);
      update public.arena_lanes set challenger_photo_id=v_second.id,updated_at=now() where lane_id=v_lane.lane_id;
      update public.arena_lanes set champion_photo_id=v_first.id where lane_id=v_lane.lane_id;
    end if;
    v_count := v_count+1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.advance_arena()
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
  for b in select * from public.arena_battles where stage in ('waiting','voting') and stage_ends_at<=now() order by stage_ends_at for update skip locked loop
    select * into v_lane from public.arena_lanes where lane_id=b.lane_id for update;
    select photo_id into v_left from public.arena_battle_participants where battle_id=b.id and side='left';
    select photo_id into v_right from public.arena_battle_participants where battle_id=b.id and side='right';
    if b.stage='waiting' then
      update public.arena_battles set stage='cancelled',finished_at=now() where id=b.id;
      update public.arena_photos set status='queued',updated_at=now() where id in (v_left,v_right);
      update public.arena_lanes set challenger_photo_id=null,champion_photo_id=case when b.opening then null else champion_photo_id end,updated_at=now() where lane_id=b.lane_id;
      v_done:=v_done+1;
      continue;
    end if;
    select count(*) filter(where target_photo_id=v_left),count(*) filter(where target_photo_id=v_right)
      into v_left_votes,v_right_votes from public.arena_votes where battle_id=b.id;
    v_draw := v_left_votes=v_right_votes;
    v_winner := case when v_left_votes>v_right_votes then v_left when v_right_votes>v_left_votes then v_right else null end;
    insert into public.arena_results(battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,left_votes,right_votes,total_votes)
      values(b.id,b.lane_id,v_left,v_right,v_winner,v_draw,v_left_votes,v_right_votes,v_left_votes+v_right_votes);
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

alter table public.arena_photos enable row level security;
alter table public.arena_lanes enable row level security;
alter table public.arena_battles enable row level security;
alter table public.arena_battle_participants enable row level security;
alter table public.arena_battle_visits enable row level security;
alter table public.arena_votes enable row level security;
alter table public.arena_results enable row level security;

create policy "Authenticated users can read arena photos" on public.arena_photos for select to authenticated using (status <> 'removed');
create policy "Authenticated users can read arena lanes" on public.arena_lanes for select to authenticated using (true);
create policy "Authenticated users can read arena battles" on public.arena_battles for select to authenticated using (true);
create policy "Authenticated users can read arena participants" on public.arena_battle_participants for select to authenticated using (true);
create policy "Authenticated users can read arena votes" on public.arena_votes for select to authenticated using (true);
create policy "Users can read their own battle visits" on public.arena_battle_visits for select to authenticated using (visitor_id=auth.uid());
create policy "Participants can read battle results" on public.arena_results for select to authenticated using (
  exists(select 1 from public.arena_battle_participants p where p.battle_id=arena_results.battle_id and p.owner_id=auth.uid())
  or exists(select 1 from public.arena_battle_visits v where v.battle_id=arena_results.battle_id and v.visitor_id=auth.uid())
);

revoke all on public.arena_photos,public.arena_lanes,public.arena_battles,public.arena_battle_participants,public.arena_battle_visits,public.arena_votes,public.arena_results from anon,authenticated;
grant select on public.arena_photos,public.arena_lanes,public.arena_battles,public.arena_battle_participants,public.arena_votes,public.arena_results to authenticated;
grant select on public.arena_battle_visits to authenticated;

revoke all on function public.enqueue_arena_photo(text) from public;
revoke all on function public.register_arena_visit(uuid) from public;
revoke all on function public.submit_arena_vote(uuid,uuid,text) from public;
revoke all on function public.delete_arena_photo(uuid) from public;
revoke all on function public.match_arena_queue() from public;
revoke all on function public.advance_arena() from public;
grant execute on function public.enqueue_arena_photo(text) to authenticated;
grant execute on function public.register_arena_visit(uuid) to authenticated;
grant execute on function public.submit_arena_vote(uuid,uuid,text) to authenticated;
grant execute on function public.delete_arena_photo(uuid) to authenticated;
grant execute on function public.match_arena_queue() to service_role;
grant execute on function public.advance_arena() to service_role;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('arena-photos','arena-photos',true,10485760,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;

create policy "Arena photos are publicly readable" on storage.objects for select using (bucket_id='arena-photos');
create policy "Users upload own arena photos" on storage.objects for insert to authenticated with check (
  bucket_id='arena-photos' and (storage.foldername(name))[1]=auth.uid()::text
);
create policy "Users delete own arena photos" on storage.objects for delete to authenticated using (
  bucket_id='arena-photos' and (storage.foldername(name))[1]=auth.uid()::text
);

alter publication supabase_realtime add table public.arena_photos;
alter publication supabase_realtime add table public.arena_lanes;
alter publication supabase_realtime add table public.arena_battles;
alter publication supabase_realtime add table public.arena_battle_participants;
alter publication supabase_realtime add table public.arena_results;
