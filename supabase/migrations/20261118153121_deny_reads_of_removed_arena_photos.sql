-- A removed photo must not remain readable even by its former owner if
-- the best-effort Storage delete failed. The DELETE policy still permits cleanup.
drop policy if exists "Authenticated users can read visible arena photos" on storage.objects;
create policy "Authenticated users can read visible arena photos"
on storage.objects
for select to authenticated
using (
  bucket_id = 'arena-photos'
  and exists (
    select 1
    from public.arena_photos p
    where p.object_path = objects.name
      and p.status <> 'removed'
      and (
        p.owner_id = (select auth.uid())
        or p.status in ('matched', 'champion')
        or (
          p.status = 'completed'
          and private.arena_user_setting_enabled(p.owner_id, 'history_public')
        )
      )
  )
);
