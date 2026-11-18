
drop policy if exists "Participants can read battle results" on public.arena_results;
create policy "Authenticated users can read arena results" on public.arena_results
for select to authenticated using(true);
