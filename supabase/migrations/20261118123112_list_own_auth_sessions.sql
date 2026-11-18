create or replace function private.list_my_auth_sessions()
returns table (session_id uuid, created_at timestamptz, refreshed_at timestamp, user_agent text, is_current boolean)
language sql stable security definer
set search_path = pg_catalog, auth, private
as $$
  select s.id, s.created_at, s.refreshed_at, s.user_agent,
    s.id = nullif(auth.jwt()->>'session_id','')::uuid
  from auth.sessions s
  where s.user_id = auth.uid()
  order by s.refreshed_at desc nulls last, s.created_at desc;
$$;
revoke all on function private.list_my_auth_sessions() from public, anon, authenticated;
grant execute on function private.list_my_auth_sessions() to authenticated;

create or replace function public.get_my_auth_sessions()
returns table (session_id uuid, created_at timestamptz, refreshed_at timestamp, user_agent text, is_current boolean)
language sql stable security invoker
set search_path = pg_catalog, public, private
as $$ select * from private.list_my_auth_sessions(); $$;
revoke all on function public.get_my_auth_sessions() from public, anon;
grant execute on function public.get_my_auth_sessions() to authenticated;