-- A removed photo must never remain referenced as a lane champion or challenger.
-- Keep result rows and photo metadata intact; only release live lane pointers.
create or replace function public.clear_removed_arena_photo_from_lanes()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.status = 'removed' and old.status is distinct from new.status then
    update public.arena_lanes
       set champion_photo_id = case when champion_photo_id = new.id then null else champion_photo_id end,
           challenger_photo_id = case when challenger_photo_id = new.id then null else challenger_photo_id end,
           updated_at = now()
     where champion_photo_id = new.id
        or challenger_photo_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_clear_removed_arena_photo_from_lanes on public.arena_photos;
create trigger trg_clear_removed_arena_photo_from_lanes
after update of status on public.arena_photos
for each row
execute function public.clear_removed_arena_photo_from_lanes();

-- Repair existing orphaned lane references left by earlier photo deletions.
update public.arena_lanes lane
   set champion_photo_id = case
         when champion.status = 'removed' then null
         else lane.champion_photo_id
       end,
       challenger_photo_id = case
         when challenger.status = 'removed' then null
         else lane.challenger_photo_id
       end,
       updated_at = now()
  from public.arena_photos champion,
       public.arena_photos challenger
 where (lane.champion_photo_id = champion.id and champion.status = 'removed')
    or (lane.challenger_photo_id = challenger.id and challenger.status = 'removed');
