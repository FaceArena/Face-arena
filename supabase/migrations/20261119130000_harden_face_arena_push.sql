-- Restrict push subscription table access to the operations the client needs.
revoke all on table public.arena_push_subscriptions from anon;
revoke insert, update on table public.arena_push_subscriptions from authenticated;
grant select, delete on table public.arena_push_subscriptions to authenticated;

drop policy if exists "Users create own push subscriptions" on public.arena_push_subscriptions;
drop policy if exists "Users update own push subscriptions" on public.arena_push_subscriptions;

-- Give the async pg_net request enough time to reach the Edge Function.
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
    timeout_milliseconds := 10000
  );
  return new;
end;
$$;

revoke all on function private.enqueue_face_arena_push() from public, anon, authenticated;
