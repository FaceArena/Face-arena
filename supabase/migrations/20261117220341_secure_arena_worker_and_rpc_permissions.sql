
create schema if not exists private;
revoke all on schema private from public,anon,authenticated;
create table if not exists private.arena_worker_config (
  id boolean primary key default true check(id),
  token_hash bytea not null,
  created_at timestamptz not null default now()
);
insert into private.arena_worker_config(id,token_hash)
values(true,digest('913c1daddf518fb469eb26b00b162f539e6088f951b7d765263caa783b1d9bb9','sha256'))
on conflict(id) do update set token_hash=excluded.token_hash,created_at=now();

create or replace function public.worker_tick(p_token text)
returns jsonb language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare v_matched integer; v_advanced integer; v_next timestamptz;
begin
  if p_token is null or not exists(select 1 from private.arena_worker_config where id=true and token_hash=digest(p_token,'sha256')) then
    raise exception 'Unauthorized worker';
  end if;
  v_advanced:=public.advance_arena();
  v_matched:=public.match_arena_queue();
  select min(stage_ends_at) into v_next from public.arena_battles where stage in ('waiting','voting');
  return jsonb_build_object('advanced',v_advanced,'matched',v_matched,'next_deadline',v_next);
end;
$$;
revoke all on function public.worker_tick(text) from public,authenticated;
grant execute on function public.worker_tick(text) to anon;

revoke all on function public.match_arena_queue() from public,anon,authenticated;
revoke all on function public.advance_arena() from public,anon,authenticated;
grant execute on function public.match_arena_queue() to service_role;
grant execute on function public.advance_arena() to service_role;

revoke all on function public.enqueue_arena_photo(text) from public,anon,authenticated;
revoke all on function public.register_arena_visit(uuid) from public,anon,authenticated;
revoke all on function public.submit_arena_vote(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.delete_arena_photo(uuid) from public,anon,authenticated;
grant execute on function public.enqueue_arena_photo(text) to authenticated;
grant execute on function public.register_arena_visit(uuid) to authenticated;
grant execute on function public.submit_arena_vote(uuid,uuid,text) to authenticated;
grant execute on function public.delete_arena_photo(uuid) to authenticated;

create or replace function public.enqueue_arena_photo(p_object_path text)
returns uuid language plpgsql security definer
set search_path = public, auth, storage, pg_temp
as $$
declare v_user uuid := auth.uid(); v_photo uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user::text,0));
  if p_object_path is null or p_object_path !~ ('^' || v_user::text || '/[A-Za-z0-9._-]+$') then raise exception 'Invalid photo storage path'; end if;
  if not exists(select 1 from storage.objects where bucket_id='arena-photos' and name=p_object_path) then raise exception 'Uploaded photo not found'; end if;
  if (select count(*) from public.arena_photos where owner_id=v_user and status in ('queued','matched','champion')) >= 3 then raise exception 'Maximum 3 active photos per account'; end if;
  insert into public.arena_photos(owner_id,object_path) values(v_user,p_object_path) returning id into v_photo;
  return v_photo;
end;
$$;
