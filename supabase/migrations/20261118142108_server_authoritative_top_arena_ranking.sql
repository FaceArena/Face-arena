-- TOP ARENA is a public aggregate ranking. It must not disappear when a
-- participant hides their detailed battle history from other users.
create or replace function private.get_top_arena_ranking()
returns table (
  name text,
  wins bigint,
  losses bigint,
  defenses bigint,
  streak bigint,
  best bigint,
  is_champion boolean,
  is_legendary boolean,
  lane_id bigint,
  photo_id uuid
)
language sql
stable
security definer
set search_path = pg_catalog, public, private, auth, pg_temp
as $$
with participant_events as (
  select
    lp.owner_id as user_id,
    r.id as result_id,
    r.completed_at,
    case
      when coalesce(r.is_draw, false) then 'draw'
      when r.winner_photo_id = r.left_photo_id then 'win'
      else 'loss'
    end as outcome,
    (not coalesce(r.is_draw, false) and r.winner_photo_id = r.left_photo_id) as defense
  from public.arena_results r
  join public.arena_photos lp on lp.id = r.left_photo_id
  where not coalesce(r.opening, false)
    and not coalesce(r.no_contest, false)
    and (coalesce(r.is_draw, false) or r.winner_photo_id in (r.left_photo_id, r.right_photo_id))

  union all

  select
    rp.owner_id as user_id,
    r.id as result_id,
    r.completed_at,
    case
      when coalesce(r.is_draw, false) then 'draw'
      when r.winner_photo_id = r.right_photo_id then 'win'
      else 'loss'
    end as outcome,
    false as defense
  from public.arena_results r
  join public.arena_photos rp on rp.id = r.right_photo_id
  where not coalesce(r.opening, false)
    and not coalesce(r.no_contest, false)
    and (coalesce(r.is_draw, false) or r.winner_photo_id in (r.left_photo_id, r.right_photo_id))
),
ordered_events as (
  select
    e.*,
    sum(case when e.outcome <> 'win' then 1 else 0 end)
      over (partition by e.user_id order by e.completed_at, e.result_id
            rows between unbounded preceding and current row) as streak_group
  from participant_events e
),
totals as (
  select
    user_id,
    count(*) filter (where outcome = 'win') as wins,
    count(*) filter (where outcome = 'loss') as losses,
    count(*) filter (where defense) as defenses
  from ordered_events
  group by user_id
),
win_runs as (
  select user_id, streak_group, count(*) as streak_length
  from ordered_events
  where outcome = 'win'
  group by user_id, streak_group
),
latest_event as (
  select distinct on (user_id) user_id, outcome, streak_group
  from ordered_events
  order by user_id, completed_at desc, result_id desc
),
streak_stats as (
  select
    t.user_id,
    t.wins,
    t.losses,
    t.defenses,
    coalesce(max(w.streak_length), 0)::bigint as best_streak,
    case
      when l.outcome = 'win'
        then coalesce(max(w.streak_length) filter (where w.streak_group = l.streak_group), 0)
      else 0
    end::bigint as current_streak
  from totals t
  left join latest_event l on l.user_id = t.user_id
  left join win_runs w on w.user_id = t.user_id
  group by t.user_id, t.wins, t.losses, t.defenses, l.outcome, l.streak_group
),
champions as (
  select
    p.owner_id as user_id,
    min(l.lane_id)::bigint as lane_id,
    (array_agg(l.champion_photo_id order by l.lane_id))[1] as photo_id
  from public.arena_lanes l
  join public.arena_photos p on p.id = l.champion_photo_id
  group by p.owner_id
)
select
  case
    when private.arena_user_setting_enabled(s.user_id, 'profile_public')
      then coalesce(nullif(p.display_name, ''), 'Участник')
    else 'Участник'
  end as name,
  s.wins,
  s.losses,
  s.defenses,
  s.current_streak as streak,
  s.best_streak as best,
  (c.user_id is not null) as is_champion,
  (s.current_streak >= 10) as is_legendary,
  c.lane_id,
  picked.photo_id
from streak_stats s
left join public.arena_profiles p on p.user_id = s.user_id
left join champions c on c.user_id = s.user_id
left join lateral (
  select ph.id as photo_id
  from public.arena_photos ph
  where ph.owner_id = s.user_id
    and ph.status <> 'removed'
    and (
      ph.id = c.photo_id
      or ph.status in ('queued', 'matched', 'champion')
      or private.arena_user_setting_enabled(ph.owner_id, 'profile_public')
    )
  order by
    (ph.id = c.photo_id) desc,
    case ph.status when 'champion' then 0 when 'queued' then 1 when 'matched' then 2 else 3 end,
    ph.created_at desc,
    ph.id desc
  limit 1
) picked on true
where auth.uid() is not null
  and s.wins >= 5
  and s.best_streak >= 5
order by s.wins desc, s.current_streak desc, s.best_streak desc, s.user_id;
$$;

revoke all on function private.get_top_arena_ranking() from public, anon, authenticated;
grant execute on function private.get_top_arena_ranking() to authenticated;

create or replace function public.get_top_arena_ranking()
returns table (
  name text,
  wins bigint,
  losses bigint,
  defenses bigint,
  streak bigint,
  best bigint,
  is_champion boolean,
  is_legendary boolean,
  lane_id bigint,
  photo_id uuid
)
language sql
security invoker
set search_path = pg_catalog, public, private, pg_temp
as $$
  select * from private.get_top_arena_ranking();
$$;

revoke all on function public.get_top_arena_ranking() from public, anon;
grant execute on function public.get_top_arena_ranking() to authenticated;
