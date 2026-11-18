-- Public-profile lookup needs no SECURITY DEFINER: the caller's RLS policies
-- already expose only the owner's profile or profiles explicitly made public.
create or replace function public.get_public_arena_profile(p_user_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  result jsonb;
begin
  if auth.uid() is null or p_user_id is null then
    return null;
  end if;

  if p_user_id <> auth.uid()
     and not private.arena_user_setting_enabled(p_user_id, 'profile_public') then
    return null;
  end if;

  select jsonb_build_object(
    'user_id', p.user_id,
    'display_name', coalesce(nullif(p.display_name, ''), 'Участник'),
    'handle', coalesce(nullif(p.handle, ''), 'user'),
    'photos', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', ph.id,
          'object_path', ph.object_path,
          'status', ph.status,
          'created_at', ph.created_at
        ) order by ph.created_at desc, ph.id desc
      )
      from public.arena_photos ph
      where ph.owner_id = p.user_id
        and ph.status <> 'removed'
    ), '[]'::jsonb)
  )
  into result
  from public.arena_profiles p
  where p.user_id = p_user_id;

  return result;
end;
$$;

-- This helper is used by RLS to check public visibility only. Do not expose
-- the unrelated security-notification preference through this callable helper.
create or replace function private.arena_user_setting_enabled(p_user_id uuid, p_setting text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, private
as $$
  select case
    when auth.uid() is null or p_user_id is null then false
    when p_setting not in ('profile_public', 'history_public') then false
    else coalesce((
      select case p_setting
        when 'profile_public' then s.profile_public
        when 'history_public' then s.history_public
        else false
      end
      from public.arena_user_settings s
      where s.user_id = p_user_id
    ), true)
  end;
$$;
revoke all on function private.arena_user_setting_enabled(uuid,text) from public, anon, authenticated;
grant execute on function private.arena_user_setting_enabled(uuid,text) to authenticated;
