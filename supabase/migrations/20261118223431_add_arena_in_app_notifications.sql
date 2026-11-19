alter table public.arena_user_settings
  add column if not exists battle_notifications boolean not null default true;

create table if not exists public.arena_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_key text not null,
  kind text not null check (kind in ('battle_started','battle_result')),
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (user_id, event_key)
);

create index if not exists arena_notifications_user_created_idx
  on public.arena_notifications(user_id, created_at desc, id desc);

alter table public.arena_notifications enable row level security;

drop policy if exists "Users read own arena notifications" on public.arena_notifications;
create policy "Users read own arena notifications"
  on public.arena_notifications
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Users mark own arena notifications read" on public.arena_notifications;
create policy "Users mark own arena notifications read"
  on public.arena_notifications
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

revoke all on public.arena_notifications from anon, authenticated;
grant select on public.arena_notifications to authenticated;
grant update (read_at) on public.arena_notifications to authenticated;

create or replace function private.notify_arena_battle_started()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  v_count integer;
  v_battle public.arena_battles%rowtype;
begin
  select count(*) into v_count
  from public.arena_battle_participants
  where battle_id = new.battle_id;

  if v_count <> 2 then
    return new;
  end if;

  select * into v_battle
  from public.arena_battles
  where id = new.battle_id;

  if not found or v_battle.stage not in ('waiting','voting') then
    return new;
  end if;

  insert into public.arena_notifications(user_id, event_key, kind, title, body, payload)
  select
    p.owner_id,
    'battle_started:' || v_battle.id::text,
    'battle_started',
    'Твой баттл начался',
    'Фотография вышла на арену. Голосование уже идёт.',
    jsonb_build_object('battle_id', v_battle.id, 'lane_id', v_battle.lane_id)
  from public.arena_battle_participants p
  left join public.arena_user_settings s on s.user_id = p.owner_id
  where p.battle_id = v_battle.id
    and coalesce(s.battle_notifications, true)
  on conflict (user_id, event_key) do nothing;

  return new;
end;
$$;

revoke all on function private.notify_arena_battle_started() from public, anon, authenticated;

drop trigger if exists arena_battle_started_notifications on public.arena_battle_participants;
create trigger arena_battle_started_notifications
  after insert on public.arena_battle_participants
  for each row execute function private.notify_arena_battle_started();

create or replace function private.notify_arena_battle_result()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  v_left_owner uuid;
  v_right_owner uuid;
  v_left_title text;
  v_left_body text;
  v_right_title text;
  v_right_body text;
begin
  select owner_id into v_left_owner
  from public.arena_photos where id = new.left_photo_id;

  select owner_id into v_right_owner
  from public.arena_photos where id = new.right_photo_id;

  if v_left_owner is null or v_right_owner is null or v_left_owner = v_right_owner then
    return new;
  end if;

  if new.no_contest then
    v_left_title := 'Баттл не засчитан';
    v_left_body := 'Недостаточно голосов. Результат не повлиял на рейтинг.';
    v_right_title := v_left_title;
    v_right_body := v_left_body;
  elsif new.is_draw then
    v_left_title := case when new.opening then 'Первый баттл завершён' else 'Ничья в баттле' end;
    v_left_body := case when new.opening then 'Ничья — первый чемпион пока не определён.' else 'Титул остаётся без изменений.' end;
    v_right_title := v_left_title;
    v_right_body := v_left_body;
  elsif new.winner_photo_id = new.left_photo_id then
    v_left_title := case when new.opening then 'Ты выиграл первый баттл' else 'Ты защитил титул' end;
    v_left_body := case when new.opening then 'Ты стал первым чемпионом этой арены.' else 'Твой титул чемпиона сохранён.' end;
    v_right_title := case when new.opening then 'Первый баттл завершён' else 'Ты проиграл баттл' end;
    v_right_body := case when new.opening then 'В этот раз победил соперник.' else 'Соперник защитил чемпионский титул.' end;
  elsif new.winner_photo_id = new.right_photo_id then
    v_right_title := case when new.opening then 'Ты выиграл первый баттл' else 'Ты стал чемпионом' end;
    v_right_body := case when new.opening then 'Ты стал первым чемпионом этой арены.' else 'Ты победил чемпиона и забрал титул.' end;
    v_left_title := case when new.opening then 'Первый баттл завершён' else 'Ты потерял титул' end;
    v_left_body := case when new.opening then 'В этот раз победил соперник.' else 'Соперник стал новым чемпионом арены.' end;
  else
    return new;
  end if;

  insert into public.arena_notifications(user_id, event_key, kind, title, body, payload)
  select
    v_left_owner,
    'battle_result:' || new.id::text,
    'battle_result',
    v_left_title,
    v_left_body,
    jsonb_build_object('result_id', new.id, 'battle_id', new.battle_id, 'lane_id', new.lane_id)
  where coalesce((select battle_notifications from public.arena_user_settings where user_id = v_left_owner), true)
  on conflict (user_id, event_key) do nothing;

  insert into public.arena_notifications(user_id, event_key, kind, title, body, payload)
  select
    v_right_owner,
    'battle_result:' || new.id::text,
    'battle_result',
    v_right_title,
    v_right_body,
    jsonb_build_object('result_id', new.id, 'battle_id', new.battle_id, 'lane_id', new.lane_id)
  where coalesce((select battle_notifications from public.arena_user_settings where user_id = v_right_owner), true)
  on conflict (user_id, event_key) do nothing;

  return new;
end;
$$;

revoke all on function private.notify_arena_battle_result() from public, anon, authenticated;

drop trigger if exists arena_battle_result_notifications on public.arena_results;
create trigger arena_battle_result_notifications
  after insert on public.arena_results
  for each row execute function private.notify_arena_battle_result();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'arena_notifications'
  ) then
    alter publication supabase_realtime add table public.arena_notifications;
  end if;
end;
$$;
