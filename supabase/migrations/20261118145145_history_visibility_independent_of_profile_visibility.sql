-- History visibility is independent from profile visibility. SECURITY DEFINER is
-- required here because arena_photos RLS intentionally hides completed photos
-- when profile_public=false; this helper reveals only a boolean after checking
-- both participants' history preferences.
create or replace function private.arena_result_history_visible(
  p_left_photo_id uuid,
  p_right_photo_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, private
as $$
  select case
    when auth.uid() is null or p_left_photo_id is null or p_right_photo_id is null then false
    else coalesce((
      select
        private.arena_user_setting_enabled(lp.owner_id, 'history_public')
        and private.arena_user_setting_enabled(rp.owner_id, 'history_public')
      from public.arena_photos lp
      join public.arena_photos rp on rp.id = p_right_photo_id
      where lp.id = p_left_photo_id
    ), false)
  end;
$$;

revoke all on function private.arena_result_history_visible(uuid, uuid) from public, anon, authenticated;
grant execute on function private.arena_result_history_visible(uuid, uuid) to authenticated;

drop policy if exists "Users can read visible participant arena results" on public.arena_results;
create policy "Users can read visible participant arena results" on public.arena_results
for select to authenticated
using (
  exists (
    select 1 from public.arena_photos lp
    where lp.id = arena_results.left_photo_id
      and lp.owner_id = (select auth.uid())
  )
  or exists (
    select 1 from public.arena_photos rp
    where rp.id = arena_results.right_photo_id
      and rp.owner_id = (select auth.uid())
  )
  or private.arena_result_history_visible(
    arena_results.left_photo_id,
    arena_results.right_photo_id
  )
);
