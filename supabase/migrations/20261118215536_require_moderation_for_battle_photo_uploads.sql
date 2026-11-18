drop policy if exists "Users upload own arena photos" on storage.objects;

create policy "Users upload own profile avatars"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'arena-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (storage.foldername(name))[2] = 'profile'
);

revoke all on function public.enqueue_arena_photo(text) from public, anon, authenticated;
grant execute on function public.enqueue_arena_photo(text) to service_role;
