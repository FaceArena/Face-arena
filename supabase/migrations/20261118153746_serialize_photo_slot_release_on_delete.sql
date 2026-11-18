create or replace function private.delete_arena_photo(p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  -- Serialize deletion with enqueue_arena_photo so a concurrent upload
  -- cannot observe a stale active-photo count for this account.
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));

  update public.arena_photos
  set status = 'removed',
      updated_at = now()
  where id = p_photo_id
    and owner_id = v_user
    and status in ('queued', 'completed');

  if not found then
    raise exception 'Photo cannot be removed in its current state';
  end if;
end;
$function$;
