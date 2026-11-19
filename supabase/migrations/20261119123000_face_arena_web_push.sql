-- FACE ARENA Web Push subscriptions and notification delivery
create schema if not exists extensions;
create extension if not exists pg_net with schema extensions;

create table if not exists public.arena_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique check (endpoint like 'https://%'),
  p256dh text not null,
  auth text not null,
  expiration_time bigint,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists arena_push_subscriptions_user_id_idx
  on public.arena_push_subscriptions(user_id);

alter table public.arena_push_subscriptions enable row level security;
grant select, insert, update, delete on public.arena_push_subscriptions to authenticated;

drop policy if exists "Users read own push subscriptions" on public.arena_push_subscriptions;
create policy "Users read own push subscriptions"
  on public.arena_push_subscriptions for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users create own push subscriptions" on public.arena_push_subscriptions;
create policy "Users create own push subscriptions"
  on public.arena_push_subscriptions for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users update own push subscriptions" on public.arena_push_subscriptions;
create policy "Users update own push subscriptions"
  on public.arena_push_subscriptions for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users delete own push subscriptions" on public.arena_push_subscriptions;
create policy "Users delete own push subscriptions"
  on public.arena_push_subscriptions for delete to authenticated
  using ((select auth.uid()) = user_id);

create or replace function public.get_face_arena_push_config()
returns table(public_key text, private_key text, hook_secret text)
language sql
security definer
set search_path = pg_catalog, vault, pg_temp
as $$
  select
    max(decrypted_secret) filter (where name = 'FACE_ARENA_VAPID_PUBLIC_KEY'),
    max(decrypted_secret) filter (where name = 'FACE_ARENA_VAPID_PRIVATE_KEY'),
    max(decrypted_secret) filter (where name = 'FACE_ARENA_PUSH_HOOK_SECRET')
  from vault.decrypted_secrets
  where name in (
    'FACE_ARENA_VAPID_PUBLIC_KEY',
    'FACE_ARENA_VAPID_PRIVATE_KEY',
    'FACE_ARENA_PUSH_HOOK_SECRET'
  );
$$;

revoke all on function public.get_face_arena_push_config() from public, anon, authenticated;
grant execute on function public.get_face_arena_push_config() to service_role;

create or replace function private.enqueue_face_arena_push()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private, vault, net, pg_temp
as $$
declare
  v_hook_secret text;
begin
  select decrypted_secret into v_hook_secret
  from vault.decrypted_secrets
  where name = 'FACE_ARENA_PUSH_HOOK_SECRET'
  limit 1;

  if v_hook_secret is null then
    raise warning 'FACE ARENA push hook secret is not configured; notification % was not sent', new.id;
    return new;
  end if;

  perform net.http_post(
    url := 'https://nvvkmjeobnnxlrpiuisf.supabase.co/functions/v1/face-arena-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-face-arena-push-secret', v_hook_secret
    ),
    body := jsonb_build_object(
      'notification_id', new.id,
      'user_id', new.user_id
    ),
    timeout_milliseconds := 1000
  );
  return new;
end;
$$;

revoke all on function private.enqueue_face_arena_push() from public, anon, authenticated;

drop trigger if exists arena_notifications_enqueue_push on public.arena_notifications;
create trigger arena_notifications_enqueue_push
  after insert on public.arena_notifications
  for each row execute function private.enqueue_face_arena_push();

create or replace function private.notify_arena_battle_started()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  v_lane_id smallint;
  v_participant_count integer;
begin
  select count(*) into v_participant_count
  from public.arena_battle_participants
  where battle_id = new.battle_id;

  if v_participant_count <> 2 then
    return new;
  end if;

  select lane_id into v_lane_id
  from public.arena_battles
  where id = new.battle_id;

  insert into public.arena_notifications(user_id, event_key, kind, title, body, payload)
  select
    p.owner_id,
    'battle_started:' || new.battle_id::text,
    'battle_started',
    'Твой баттл начался',
    'Соперник найден. Открой FACE ARENA и следи за голосованием.',
    jsonb_build_object('battle_id', new.battle_id, 'lane_id', v_lane_id)
  from public.arena_battle_participants p
  where p.battle_id = new.battle_id
    and coalesce((
      select s.battle_notifications
      from public.arena_user_settings s
      where s.user_id = p.owner_id
    ), true)
  group by p.owner_id
  on conflict (user_id, event_key) do nothing;

  return new;
end;
$$;

revoke all on function private.notify_arena_battle_started() from public, anon, authenticated;

drop trigger if exists arena_battle_started_notifications on public.arena_battle_participants;
create trigger arena_battle_started_notifications
  after insert on public.arena_battle_participants
  for each row execute function private.notify_arena_battle_started();
