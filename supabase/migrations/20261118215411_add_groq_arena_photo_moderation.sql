create table if not exists public.arena_photo_moderation (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  object_path text not null unique,
  decision text not null default 'pending' check (decision in ('pending','approved','rejected')),
  reason text not null default '',
  categories text[] not null default '{}',
  confidence numeric(4,3),
  photo_id uuid references public.arena_photos(id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null
);

alter table public.arena_photo_moderation enable row level security;
revoke all on table public.arena_photo_moderation from anon, authenticated;
grant all on table public.arena_photo_moderation to service_role;

create or replace function public.enqueue_moderated_arena_photo(p_owner_id uuid, p_object_path text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, private, auth, storage, pg_temp
as $$
declare
  v_photo uuid;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_owner_id is null or p_object_path is null
     or p_object_path !~ ('^' || p_owner_id::text || '/[A-Za-z0-9._-]+$') then
    raise exception 'Invalid moderated photo path';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_owner_id::text, 0));
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'arena-photos' and name = p_object_path
  ) then
    raise exception 'Uploaded photo not found';
  end if;
  if (select count(*) from public.arena_photos
      where owner_id = p_owner_id and status in ('queued','matched','champion')) >= 3 then
    raise exception 'Maximum 3 active photos per account';
  end if;
  insert into public.arena_photos(owner_id, object_path)
  values (p_owner_id, p_object_path)
  returning id into v_photo;
  return v_photo;
end;
$$;

revoke all on function public.enqueue_moderated_arena_photo(uuid,text) from public, anon, authenticated;
grant execute on function public.enqueue_moderated_arena_photo(uuid,text) to service_role;
