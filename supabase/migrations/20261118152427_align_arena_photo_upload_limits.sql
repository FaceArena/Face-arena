-- Match the storage-side upload limit to the 5 MiB limit enforced by the UI.
-- The bucket remains private and only accepts the image formats used by FACE ARENA.
update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'arena-photos';
