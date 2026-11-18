-- Public profile lookup is privacy-gated on the database side.
create or replace function public.get_public_arena_profile(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  result jsonb;
begin
  if auth.uid() is null or p_user_id is null then
    return null;
  end if;

  if p_user_id <> auth.uid()
     and not coalesce((
       select s.profile_public
       from public.arena_user_settings s
       where s.user_id = p_user_id
     ), true) then
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

revoke all on function public.get_public_arena_profile(uuid) from public, anon;
grant execute on function public.get_public_arena_profile(uuid) to authenticated;
