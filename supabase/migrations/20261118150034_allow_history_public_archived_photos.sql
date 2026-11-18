-- Public history is independent of public profile visibility. Completed photo
-- rows must be readable when their owner opted into public history so that
-- history entries can render their images and signed storage URLs.
drop policy if exists "Users can read active arena photos or public archives" on public.arena_photos;
create policy "Users can read active arena photos or public archives" on public.arena_photos
for select to authenticated
using (
  owner_id = (select auth.uid())
  or status in ('queued', 'matched', 'champion')
  or private.arena_user_setting_enabled(owner_id, 'profile_public')
  or (
    status = 'completed'
    and private.arena_user_setting_enabled(owner_id, 'history_public')
  )
);
