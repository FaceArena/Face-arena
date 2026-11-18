
create table if not exists private.arena_vote_guard (
  voter_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  window_count integer not null default 0 check (window_count >= 0),
  daily_date date not null,
  daily_count integer not null default 0 check (daily_count >= 0),
  updated_at timestamptz not null default now()
);

alter table private.arena_vote_guard enable row level security;
revoke all on table private.arena_vote_guard from public, anon, authenticated;

create or replace function private.consume_arena_vote_slot(p_voter_id uuid)
returns void
language plpgsql
security invoker
set search_path = pg_catalog, private, auth, pg_temp
as $$
declare
  v_window_count integer;
  v_daily_count integer;
  v_today date := (now() at time zone 'UTC')::date;
begin
  if p_voter_id is null then
    raise exception 'Authentication required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_voter_id::text, 99117));

  insert into private.arena_vote_guard as g (
    voter_id, window_started_at, window_count, daily_date, daily_count, updated_at
  )
  values (p_voter_id, now(), 1, v_today, 1, now())
  on conflict (voter_id) do update set
    window_started_at = case
      when g.window_started_at <= now() - interval '10 minutes' then now()
      else g.window_started_at
    end,
    window_count = case
      when g.window_started_at <= now() - interval '10 minutes' then 1
      else g.window_count + 1
    end,
    daily_date = case
      when g.daily_date <> v_today then v_today
      else g.daily_date
    end,
    daily_count = case
      when g.daily_date <> v_today then 1
      else g.daily_count + 1
    end,
    updated_at = now()
  returning window_count, daily_count into v_window_count, v_daily_count;

  if v_window_count > 40 then
    raise exception 'Достигнут лимит голосов за 10 минут. Подождите и попробуйте позже.';
  end if;

  if v_daily_count > 200 then
    raise exception 'Достигнут дневной лимит голосов. Попробуйте завтра.';
  end if;
end;
$$;

revoke all on function private.consume_arena_vote_slot(uuid) from public, anon, authenticated;
grant execute on function private.consume_arena_vote_slot(uuid) to postgres;

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
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from auth.users
    where id = v_user
      and email_confirmed_at is not null
      and not coalesce(is_anonymous, false)
  ) then
    raise exception 'Для голосования нужен подтверждённый аккаунт.';
  end if;

  if p_comment is null or char_length(btrim(p_comment)) not between 10 and 300 then
    raise exception 'Comment must contain 10 to 300 characters';
  end if;

  select * into v_battle
  from public.arena_battles
  where id = p_battle_id
  for update;

  if not found or v_battle.stage <> 'voting' or v_battle.stage_ends_at <= now() then
    raise exception 'Voting is closed';
  end if;

  if exists (
    select 1 from public.arena_battle_participants
    where battle_id = p_battle_id and owner_id = v_user
  ) then
    raise exception 'Participants cannot vote in their own battle';
  end if;

  if not exists (
    select 1 from public.arena_battle_visits
    where battle_id = p_battle_id and visitor_id = v_user
  ) then
    raise exception 'Open the battle before voting';
  end if;

  if not exists (
    select 1 from public.arena_battle_participants
    where battle_id = p_battle_id and photo_id = p_target_photo_id
  ) then
    raise exception 'Selected photo does not belong to this battle';
  end if;

  perform private.consume_arena_vote_slot(v_user);

  insert into public.arena_votes(battle_id,voter_id,target_photo_id,comment)
  values(p_battle_id,v_user,p_target_photo_id,btrim(p_comment));
end;
$$;
