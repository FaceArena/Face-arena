-- Signed photo URLs expire after 15 minutes. Keep browser/CDN object caching
-- much shorter so a cached response does not outlive a privacy change by a year.
update storage.objects
set metadata = jsonb_set(
  coalesce(metadata, '{}'::jsonb),
  '{cacheControl}',
  to_jsonb('max-age=60'::text),
  true
)
where bucket_id = 'arena-photos'
  and coalesce(metadata->>'cacheControl','') <> 'max-age=60';
