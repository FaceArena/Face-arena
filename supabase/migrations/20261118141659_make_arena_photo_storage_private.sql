-- Stop unauthenticated access to image objects. Authenticated reads must
-- pass the same visibility rules as the arena_photos table.
drop policy if exists "Arena photos are publicly readable" on storage.objects;
create policy "Authenticated users can read visible arena photos"
on storage.objects
for select to authenticated
using (
  bucket_id = 'arena-photos'
  and exists (
    select 1
    from public.arena_photos p
    where p.object_path = objects.name
  )
);

update storage.buckets
set public = false
where id = 'arena-photos';
