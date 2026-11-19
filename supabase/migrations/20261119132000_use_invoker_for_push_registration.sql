-- Public API wrapper is SECURITY INVOKER; the ownership-checked helper stays in the unexposed private schema.
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
grant execute on function private.save_arena_push_subscription_internal(text,text,text,bigint,text) to authenticated;
