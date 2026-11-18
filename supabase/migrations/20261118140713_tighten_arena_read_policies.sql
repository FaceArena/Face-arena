-- Keep the public arena feed readable, but do not expose archived private-profile data.
drop policy if exists "Authenticated users can read arena photos" on public.arena_photos;
create policy "Users can read active arena photos or public archives" on public.arena_photos
for select to authenticated
using (
  owner_id = (select auth.uid())
  or status in ('queued', 'matched', 'champion')
  or private.arena_user_setting_enabled(owner_id, 'profile_public')
);

-- Votes contain user-written comments. They are needed while a battle is active,
-- but completed comments are not part of the public result view.
drop policy if exists "Authenticated users can read arena votes" on public.arena_votes;
create policy "Authenticated users can read active battle votes" on public.arena_votes
for select to authenticated
using (
  exists (
    select 1
    from public.arena_battles b
    where b.id = arena_votes.battle_id
      and b.stage in ('waiting', 'voting')
  )
);

-- Participant rows are only queried to render currently active battles.
drop policy if exists "Authenticated users can read arena participants" on public.arena_battle_participants;
create policy "Authenticated users can read active battle participants" on public.arena_battle_participants
for select to authenticated
using (
  exists (
    select 1
    from public.arena_battles b
    where b.id = arena_battle_participants.battle_id
      and b.stage in ('waiting', 'voting')
  )
);

-- Completed battle rows are represented by arena_results; expose only live battles here.
drop policy if exists "Authenticated users can read arena battles" on public.arena_battles;
create policy "Authenticated users can read active arena battles" on public.arena_battles
for select to authenticated
using (stage in ('waiting', 'voting'));
