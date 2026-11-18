drop policy if exists "Users can read visible participant arena results" on public.arena_results;
create policy "Users can read visible participant arena results" on public.arena_results
for select to authenticated
using (
  exists (select 1 from public.arena_photos lp where lp.id = arena_results.left_photo_id and lp.owner_id = (select auth.uid()))
  or exists (select 1 from public.arena_photos rp where rp.id = arena_results.right_photo_id and rp.owner_id = (select auth.uid()))
  or (
    exists (select 1 from public.arena_photos lp where lp.id = arena_results.left_photo_id and private.arena_user_setting_enabled(lp.owner_id,'history_public'))
    and exists (select 1 from public.arena_photos rp where rp.id = arena_results.right_photo_id and private.arena_user_setting_enabled(rp.owner_id,'history_public'))
  )
);