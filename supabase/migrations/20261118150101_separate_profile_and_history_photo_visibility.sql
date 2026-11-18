-- A public profile does not implicitly publish the battle archive. The two
-- user controls are independent: active arena participation remains visible,
-- completed photos require history_public.
drop policy if exists "Users can read active arena photos or public archives" on public.arena_photos;
create policy "Users can read active arena photos or public archives" on public.arena_photos
for select to authenticated
using (
  owner_id = (select auth.uid())
  or status in ('queued', 'matched', 'champion')
  or (
    status = 'completed'
    and private.arena_user_setting_enabled(owner_id, 'history_public')
  )
);

create or replace function public.get_public_arena_profile(p_user_id uuid)
returns jsonb
language plpgsql
set search_path to 'pg_catalog', 'public', 'private', 'pg_temp'
as $function$
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
        and (
          p.user_id = auth.uid()
          or ph.status <> 'completed'
          or private.arena_user_setting_enabled(p.user_id, 'history_public')
        )
    ), '[]'::jsonb)
  )
  into result
  from public.arena_profiles p
  where p.user_id = p_user_id;

  return result;
end;
$function$;
