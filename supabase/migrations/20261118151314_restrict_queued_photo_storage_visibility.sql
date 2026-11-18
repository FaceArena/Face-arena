-- Queue metadata remains visible for FIFO position, but queued images stay private.
-- Owners can always access their own images; active battle and public-history
-- images remain available according to the existing visibility controls.
drop policy if exists "Authenticated users can read visible arena photos" on storage.objects;
create policy "Authenticated users can read visible arena photos"
on storage.objects
for select to authenticated
using (
  bucket_id = 'arena-photos'
  and exists (
    select 1
    from public.arena_photos p
    where p.object_path = objects.name
      and (
        p.owner_id = (select auth.uid())
        or p.status in ('matched', 'champion')
        or (
          p.status = 'completed'
          and private.arena_user_setting_enabled(p.owner_id, 'history_public')
        )
      )
  )
);

-- Hide queued images from other users' public-profile payloads.
do $$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef('public.get_public_arena_profile(uuid)'::regprocedure)
    into v_definition;
  v_old := $old$          p.user_id = auth.uid()
          or ph.status <> 'completed'
          or private.arena_user_setting_enabled(p.user_id, 'history_public')$old$;
  v_new := $new$          p.user_id = auth.uid()
          or ph.status in ('matched', 'champion')
          or (
            ph.status = 'completed'
            and private.arena_user_setting_enabled(p.user_id, 'history_public')
          )$new$;
  if position(v_old in v_definition) = 0 then
    raise exception 'Public profile visibility clause did not match expected definition';
  end if;
  execute replace(v_definition, v_old, v_new);

  select pg_get_functiondef('private.get_top_arena_ranking()'::regprocedure)
    into v_definition;
  v_old := $old$or ph.status in ('queued', 'matched', 'champion')$old$;
  v_new := $new$or ph.status in ('matched', 'champion')$new$;
  if position(v_old in v_definition) = 0 then
    raise exception 'TOP ARENA queued-photo clause did not match expected definition';
  end if;
  v_definition := replace(v_definition, v_old, v_new);
  v_old := $old$case ph.status when 'champion' then 0 when 'queued' then 1 when 'matched' then 2 else 3 end$old$;
  v_new := $new$case ph.status when 'champion' then 0 when 'matched' then 1 else 2 end$new$;
  v_definition := replace(v_definition, v_old, v_new);
  execute v_definition;
end $$;
