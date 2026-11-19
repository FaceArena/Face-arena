-- A battle that expires before either participant opens it should only pause this pair briefly.
-- NULL expires_at preserves the existing permanent exclusions (manual cancel / no-contest).
alter table private.arena_pair_exclusions
  add column if not exists expires_at timestamptz;

do $$
declare
  v_def text;
  v_old text;
  v_new text;
  v_count integer;
begin
  -- Make expired exclusions transparent to the queue matcher.
  v_def := pg_get_functiondef('private.match_arena_queue()'::regprocedure);

  v_old := 'and x.photo_high=greatest(p.id,v_lane.champion_photo_id)';
  if position(v_old in v_def)=0 then raise exception 'Expected champion exclusion predicate not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n            and (x.expires_at is null or x.expires_at > now())');

  v_old := 'and x.photo_high=greatest(p1.id,p2.id)';
  if position(v_old in v_def)=0 then raise exception 'Expected opening-first exclusion predicate not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n                and (x.expires_at is null or x.expires_at > now())');

  v_old := 'and x.photo_high=greatest(v_first.id,p2.id)';
  if position(v_old in v_def)=0 then raise exception 'Expected opening-second exclusion predicate not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n            and (x.expires_at is null or x.expires_at > now())');

  execute v_def;

  -- Only the "waiting" timeout (no participant opened the battle) gets a temporary exclusion.
  v_def := pg_get_functiondef('private.advance_arena()'::regprocedure);
  v_old := $old$if b.stage='waiting' then
      insert into private.arena_pair_exclusions(photo_low,photo_high)
      values(least(v_left,v_right),greatest(v_left,v_right)) on conflict do nothing;$old$;
  v_new := $new$if b.stage='waiting' then
      insert into private.arena_pair_exclusions(photo_low,photo_high,expires_at)
      values(least(v_left,v_right),greatest(v_left,v_right),now()+interval '2 minutes')
      on conflict do nothing;$new$;
  if position(v_old in v_def)=0 then raise exception 'Expected no-view timeout exclusion block not found'; end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end;
$$;
 
