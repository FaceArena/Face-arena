-- These two tables need narrowly scoped direct client access. Remove broad
-- table-level and column-level grants first, including TRUNCATE (which bypasses RLS).
revoke all privileges on table public.arena_profiles from anon, authenticated;
revoke all privileges (user_id, display_name, handle, created_at, updated_at)
  on table public.arena_profiles from anon, authenticated;
grant select, update on table public.arena_profiles to authenticated;

revoke all privileges on table public.arena_user_settings from anon, authenticated;
revoke all privileges (user_id, profile_public, history_public, security_notifications, updated_at)
  on table public.arena_user_settings from anon, authenticated;
grant select, insert, update on table public.arena_user_settings to authenticated;
