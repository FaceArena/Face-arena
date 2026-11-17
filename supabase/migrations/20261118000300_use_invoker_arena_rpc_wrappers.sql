
alter function public.worker_tick() security invoker;
alter function public.cancel_arena_match(uuid) security invoker;
alter function public.delete_arena_photo(uuid) security invoker;
alter function public.enqueue_arena_photo(text) security invoker;
alter function public.register_arena_visit(uuid) security invoker;
alter function public.submit_arena_vote(uuid,uuid,text) security invoker;

revoke all on schema private from public,anon,authenticated;
grant usage on schema private to anon,authenticated;

revoke all on all functions in schema private from public,anon,authenticated;
grant execute on function private.worker_tick() to anon;
grant execute on function private.cancel_arena_match(uuid) to authenticated;
grant execute on function private.delete_arena_photo(uuid) to authenticated;
grant execute on function private.enqueue_arena_photo(text) to authenticated;
grant execute on function private.register_arena_visit(uuid) to authenticated;
grant execute on function private.submit_arena_vote(uuid,uuid,text) to authenticated;

revoke all on function public.worker_tick() from public,authenticated;
grant execute on function public.worker_tick() to anon;
revoke all on function public.cancel_arena_match(uuid) from public,anon;
revoke all on function public.delete_arena_photo(uuid) from public,anon;
revoke all on function public.enqueue_arena_photo(text) from public,anon;
revoke all on function public.register_arena_visit(uuid) from public,anon;
revoke all on function public.submit_arena_vote(uuid,uuid,text) from public,anon;
grant execute on function public.cancel_arena_match(uuid) to authenticated;
grant execute on function public.delete_arena_photo(uuid) to authenticated;
grant execute on function public.enqueue_arena_photo(text) to authenticated;
grant execute on function public.register_arena_visit(uuid) to authenticated;
grant execute on function public.submit_arena_vote(uuid,uuid,text) to authenticated;
