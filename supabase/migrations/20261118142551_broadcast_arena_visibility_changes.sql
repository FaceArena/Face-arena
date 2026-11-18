-- Broadcast only the fact that public visibility changed. Do not expose
-- history settings, notification preferences, or account identifiers.
create policy "Authenticated users can receive arena visibility broadcasts"
on realtime.messages
for select
to authenticated
using (
  topic = 'arena-visibility-events'
  and auth.uid() is not null
);

create or replace function private.broadcast_arena_visibility_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private, realtime, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    perform realtime.send(
      jsonb_build_object('changed', true),
      'visibility_changed',
      'arena-visibility-events',
      true
    );
  elsif OLD.profile_public is distinct from NEW.profile_public
     or OLD.history_public is distinct from NEW.history_public then
    perform realtime.send(
      jsonb_build_object('changed', true),
      'visibility_changed',
      'arena-visibility-events',
      true
    );
  end if;
  return NEW;
end;
$$;

revoke all on function private.broadcast_arena_visibility_change() from public, anon, authenticated;

drop trigger if exists arena_visibility_change_broadcast on public.arena_user_settings;
create trigger arena_visibility_change_broadcast
after insert or update of profile_public, history_public
on public.arena_user_settings
for each row
execute function private.broadcast_arena_visibility_change();
