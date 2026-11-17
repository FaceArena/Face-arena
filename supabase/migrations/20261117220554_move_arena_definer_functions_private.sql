
alter function public.enqueue_arena_photo(text) set schema private;
alter function public.register_arena_visit(uuid) set schema private;
alter function public.submit_arena_vote(uuid,uuid,text) set schema private;
alter function public.delete_arena_photo(uuid) set schema private;
alter function public.match_arena_queue() set schema private;
alter function public.advance_arena() set schema private;
alter function public.worker_tick() set schema private;

grant usage on schema private to anon,authenticated,service_role;
revoke all on function private.enqueue_arena_photo(text) from public,anon,authenticated;
revoke all on function private.register_arena_visit(uuid) from public,anon,authenticated;
revoke all on function private.submit_arena_vote(uuid,uuid,text) from public,anon,authenticated;
revoke all on function private.delete_arena_photo(uuid) from public,anon,authenticated;
revoke all on function private.match_arena_queue() from public,anon,authenticated;
revoke all on function private.advance_arena() from public,anon,authenticated;
revoke all on function private.worker_tick() from public,anon,authenticated;
grant execute on function private.enqueue_arena_photo(text) to authenticated;
grant execute on function private.register_arena_visit(uuid) to authenticated;
grant execute on function private.submit_arena_vote(uuid,uuid,text) to authenticated;
grant execute on function private.delete_arena_photo(uuid) to authenticated;
grant execute on function private.match_arena_queue() to anon;
grant execute on function private.advance_arena() to anon;
grant execute on function private.worker_tick() to anon;

create or replace function public.enqueue_arena_photo(p_object_path text)
returns uuid language sql security invoker set search_path=public,private,pg_temp
as $$ select private.enqueue_arena_photo(p_object_path); $$;
create or replace function public.register_arena_visit(p_battle_id uuid)
returns timestamptz language sql security invoker set search_path=public,private,pg_temp
as $$ select private.register_arena_visit(p_battle_id); $$;
create or replace function public.submit_arena_vote(p_battle_id uuid,p_target_photo_id uuid,p_comment text)
returns void language sql security invoker set search_path=public,private,pg_temp
as $$ select private.submit_arena_vote(p_battle_id,p_target_photo_id,p_comment); $$;
create or replace function public.delete_arena_photo(p_photo_id uuid)
returns void language sql security invoker set search_path=public,private,pg_temp
as $$ select private.delete_arena_photo(p_photo_id); $$;
create or replace function public.worker_tick()
returns jsonb language sql security invoker set search_path=public,private,pg_temp
as $$ select private.worker_tick(); $$;

revoke all on function public.enqueue_arena_photo(text) from public,anon,authenticated;
revoke all on function public.register_arena_visit(uuid) from public,anon,authenticated;
revoke all on function public.submit_arena_vote(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.delete_arena_photo(uuid) from public,anon,authenticated;
revoke all on function public.worker_tick() from public,anon,authenticated;
grant execute on function public.enqueue_arena_photo(text) to authenticated;
grant execute on function public.register_arena_visit(uuid) to authenticated;
grant execute on function public.submit_arena_vote(uuid,uuid,text) to authenticated;
grant execute on function public.delete_arena_photo(uuid) to authenticated;
grant execute on function public.worker_tick() to anon;
