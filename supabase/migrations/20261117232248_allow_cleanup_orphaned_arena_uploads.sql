drop policy if exists "Users delete only removed arena photos" on storage.objects;

create policy "Users delete inactive or orphaned arena photos"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'arena-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
  and (
    exists (
      select 1
      from public.arena_photos p
      where p.owner_id = auth.uid()
        and p.object_path = name
        and p.status = 'removed'
    )
    or not exists (
      select 1
      from public.arena_photos p
      where p.object_path = name
    )
  )
);