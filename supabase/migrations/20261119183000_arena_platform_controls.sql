-- FACE ARENA: administrator-controlled platform maintenance
create table if not exists public.arena_platform_controls (
  singleton boolean primary key default true check (singleton),
  battles_paused boolean not null default false,
  publications_blocked boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.arena_platform_controls(singleton) values (true)
on conflict (singleton) do nothing;

alter table public.arena_platform_controls enable row level security;
drop policy if exists "Public can read arena platform controls" on public.arena_platform_controls;
create policy "Public can read arena platform controls"
  on public.arena_platform_controls for select to anon, authenticated using (true);
revoke insert, update, delete, truncate, references, trigger on public.arena_platform_controls from anon, authenticated;
grant select on public.arena_platform_controls to anon, authenticated;

-- Keep the existing implementations intact; wrap them with a shared maintenance gate.
alter function private.match_arena_queue() rename to match_arena_queue_unpaused;
create function private.match_arena_queue()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(746218, 1);
  if coalesce((select c.battles_paused from public.arena_platform_controls c where c.singleton), false) then
    return 0;
  end if;
  return private.match_arena_queue_unpaused();
end;
$$;

alter function private.advance_arena() rename to advance_arena_unpaused;
create function private.advance_arena()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(746218, 1);
  if coalesce((select c.battles_paused from public.arena_platform_controls c where c.singleton), false) then
    return 0;
  end if;
  return private.advance_arena_unpaused();
end;
$$;

create or replace function public.admin_set_arena_platform_controls(
  p_battles_paused boolean,
  p_publications_blocked boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, pg_temp
as $$
declare
  v_cancelled integer := 0;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Service role required' using errcode = '42501';
  end if;

  -- Synchronize with the queue worker: it cannot create or advance a battle
  -- between the maintenance flag update and cancellation of active matches.
  perform pg_advisory_xact_lock(746218, 1);

  update public.arena_platform_controls
  set battles_paused = p_battles_paused,
      publications_blocked = p_publications_blocked,
      updated_at = now()
  where singleton = true;

  if p_battles_paused then
    update public.arena_photos p
    set status = case
          when b.opening then 'queued'
          when bp.side = 'left' then 'champion'
          else 'queued'
        end,
        updated_at = now()
    from public.arena_battle_participants bp
    join public.arena_battles b on b.id = bp.battle_id
    where p.id = bp.photo_id
      and b.stage in ('waiting', 'voting');

    update public.arena_lanes l
    set challenger_photo_id = null,
        champion_photo_id = case when b.opening then null else l.champion_photo_id end,
        updated_at = now()
    from public.arena_battles b
    where b.lane_id = l.lane_id
      and b.stage in ('waiting', 'voting');

    update public.arena_battles
    set stage = 'cancelled', finished_at = now()
    where stage in ('waiting', 'voting');
    get diagnostics v_cancelled = row_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'battles_paused', p_battles_paused,
    'publications_blocked', p_publications_blocked,
    'cancelled_battles', v_cancelled
  );
end;
$$;

revoke all on function public.admin_set_arena_platform_controls(boolean, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_arena_platform_controls(boolean, boolean) to service_role;
