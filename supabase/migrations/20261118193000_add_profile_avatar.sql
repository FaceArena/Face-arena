alter table public.arena_profiles
  add column if not exists avatar_path text;

create index if not exists arena_profiles_avatar_path_idx
  on public.arena_profiles (avatar_path)
  where avatar_path is not null;

drop policy if exists "Users can read permitted arena profile avatars" on storage.objects;
create policy "Users can read permitted arena profile avatars"
on storage.objects for select to authenticated
using (
  bucket_id = 'arena-photos'
  and exists (
    select 1
      from public.arena_profiles p
     where p.avatar_path = storage.objects.name
       and (
         p.user_id = (select auth.uid())
         or private.arena_user_setting_enabled(p.user_id, 'profile_public')
       )
  )
);

create or replace function public.get_public_arena_profile(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
    'is_verified', p.is_verified,
    'avatar_path', p.avatar_path,
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
$function$;
