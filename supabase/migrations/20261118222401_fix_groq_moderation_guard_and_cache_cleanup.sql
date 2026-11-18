create or replace function public.claim_arena_photo_moderation(
  p_owner_id uuid,
  p_content_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, auth, pg_temp
as $$
declare
  v_cache private.arena_photo_moderation_cache%rowtype;
  v_guard private.arena_photo_moderation_guard%rowtype;
  v_now timestamptz := now();
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_owner_id is null or p_content_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid moderation claim';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_owner_id::text || ':photo-moderation-guard', 0));

  delete from private.arena_photo_moderation_cache
  where owner_id = p_owner_id and expires_at <= v_now;

  select * into v_cache
  from private.arena_photo_moderation_cache
  where owner_id = p_owner_id and content_sha256 = p_content_sha256
  for update;

  if found and v_cache.expires_at > v_now and v_cache.state in ('allow','reject') then
    return jsonb_build_object('status','cached','decision',v_cache.state,'reason',v_cache.reason);
  end if;
  if found and v_cache.state = 'processing' and v_cache.updated_at > v_now - interval '2 minutes' then
    return jsonb_build_object('status','processing');
  end if;
  if found then
    delete from private.arena_photo_moderation_cache
    where owner_id = p_owner_id and content_sha256 = p_content_sha256;
  end if;

  insert into private.arena_photo_moderation_guard(owner_id)
  values (p_owner_id) on conflict (owner_id) do nothing;

  select * into v_guard
  from private.arena_photo_moderation_guard
  where owner_id = p_owner_id
  for update;

  if v_guard.blocked_until is not null and v_guard.blocked_until > v_now then
    return jsonb_build_object('status','blocked','retry_after_seconds',ceil(extract(epoch from (v_guard.blocked_until - v_now)))::integer);
  end if;

  if v_guard.window_started_at <= v_now - interval '10 minutes' then
    v_guard.window_started_at := v_now;
    v_guard.window_count := 0;
  end if;
  if v_guard.daily_date <> timezone('utc', v_now)::date then
    v_guard.daily_date := timezone('utc', v_now)::date;
    v_guard.daily_count := 0;
  end if;

  if v_guard.window_count >= 10 then
    return jsonb_build_object('status','rate_limited','scope','10_minutes');
  end if;
  if v_guard.daily_count >= 20 then
    return jsonb_build_object('status','rate_limited','scope','daily');
  end if;

  update private.arena_photo_moderation_guard
  set window_started_at = v_guard.window_started_at,
      window_count = v_guard.window_count + 1,
      daily_date = v_guard.daily_date,
      daily_count = v_guard.daily_count + 1,
      updated_at = v_now
  where owner_id = p_owner_id;

  insert into private.arena_photo_moderation_cache(owner_id, content_sha256, state, expires_at)
  values (p_owner_id, p_content_sha256, 'processing', v_now + interval '2 minutes');

  return jsonb_build_object('status','claimed');
end;
$$;

create or replace function public.finish_arena_photo_moderation(
  p_owner_id uuid,
  p_content_sha256 text,
  p_decision text,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, auth, pg_temp
as $$
declare
  v_blocked_until timestamptz;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_owner_id is null or p_content_sha256 !~ '^[0-9a-f]{64}$'
     or p_decision not in ('allow','reject','error') then
    raise exception 'Invalid moderation result';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_owner_id::text || ':photo-moderation-guard', 0));

  if p_decision = 'error' then
    delete from private.arena_photo_moderation_cache
    where owner_id = p_owner_id and content_sha256 = p_content_sha256 and state = 'processing';
    return jsonb_build_object('status','released');
  end if;

  insert into private.arena_photo_moderation_cache(owner_id, content_sha256, state, reason, expires_at)
  values (p_owner_id, p_content_sha256, p_decision, left(coalesce(p_reason,''),500), now() + interval '30 days')
  on conflict (owner_id, content_sha256) do update
    set state = excluded.state, reason = excluded.reason,
        expires_at = excluded.expires_at, updated_at = now();

  insert into private.arena_photo_moderation_guard(owner_id)
  values (p_owner_id) on conflict (owner_id) do nothing;

  if p_decision = 'allow' then
    update private.arena_photo_moderation_guard
    set rejected_streak = 0, updated_at = now()
    where owner_id = p_owner_id;
    return jsonb_build_object('status','saved','decision','allow');
  end if;

  update private.arena_photo_moderation_guard
  set rejected_streak = case when rejected_streak + 1 >= 3 then 0 else rejected_streak + 1 end,
      blocked_until = case when rejected_streak + 1 >= 3 then now() + interval '30 minutes' else blocked_until end,
      updated_at = now()
  where owner_id = p_owner_id
  returning blocked_until into v_blocked_until;

  return jsonb_build_object('status','saved','decision','reject','blocked',coalesce(v_blocked_until > now(), false));
end;
$$;
