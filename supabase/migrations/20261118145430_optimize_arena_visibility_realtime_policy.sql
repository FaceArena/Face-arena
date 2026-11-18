drop policy if exists "Authenticated users can receive arena visibility broadcasts" on realtime.messages;
create policy "Authenticated users can receive arena visibility broadcasts"
on realtime.messages
for select
to authenticated
using (
  topic = 'arena-visibility-events'
  and (select auth.uid()) is not null
);
