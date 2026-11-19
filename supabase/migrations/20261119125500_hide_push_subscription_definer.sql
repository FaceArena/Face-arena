create or replace function private.save_arena_push_subscription_internal(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_expiration_time bigint default null,
  p_user_agent text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 4096 then
    raise exception 'Invalid push endpoint';
  end if;
  if p_p256dh is null or length(p_p256dh) > 256 or p_auth is null or length(p_auth) > 256 then
    raise exception 'Invalid push encryption keys';
  end if;

  insert into public.arena_push_subscriptions(
    user_id, endpoint, p256dh, auth, expiration_time, user_agent, updated_at
  )
  values (
    v_user_id, p_endpoint, p_p256dh, p_auth, p_expiration_time,
    left(coalesce(p_user_agent, ''), 500), now()
  )
  on conflict (endpoint) do update set
    user_id = excluded.user_id,
    p256dh = excluded.p256dh,
    auth = excluded.auth,
    expiration_time = excluded.expiration_time,
    user_agent = excluded.user_agent,
    updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function private.save_arena_push_subscription_internal(text,text,text,bigint,text) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.save_arena_push_subscription_internal(text,text,text,bigint,text) to authenticated;

create or replace function public.save_arena_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_expiration_time bigint default null,
  p_user_agent text default null
)
returns uuid
language sql
security invoker
set search_path = pg_catalog, public, private, pg_temp
as $$
  select private.save_arena_push_subscription_internal(
    p_endpoint, p_p256dh, p_auth, p_expiration_time, p_user_agent
  );
$$;
revoke all on function public.save_arena_push_subscription(text,text,text,bigint,text) from public, anon;
grant execute on function public.save_arena_push_subscription(text,text,text,bigint,text) to authenticated;
