create table if not exists public.arena_photo_moderation_attempts (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists arena_photo_moderation_attempts_owner_created_idx
  on public.arena_photo_moderation_attempts(owner_id, created_at desc);
alter table public.arena_photo_moderation_attempts enable row level security;
revoke all on table public.arena_photo_moderation_attempts from anon, authenticated;
grant all on table public.arena_photo_moderation_attempts to service_role;

create or replace function public.claim_arena_photo_moderation_attempt(p_owner_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  v_recent integer;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_owner_id is null then raise exception 'Owner required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_owner_id::text || ':photo-moderation', 0));
  delete from public.arena_photo_moderation_attempts
  where created_at < now() - interval '1 day';
  select count(*) into v_recent
  from public.arena_photo_moderation_attempts
  where owner_id = p_owner_id and created_at > now() - interval '10 minutes';
  if v_recent >= 10 then return false; end if;
  insert into public.arena_photo_moderation_attempts(owner_id) values (p_owner_id);
  return true;
end;
$$;
revoke all on function public.claim_arena_photo_moderation_attempt(uuid) from public, anon, authenticated;
grant execute on function public.claim_arena_photo_moderation_attempt(uuid) to service_role;
