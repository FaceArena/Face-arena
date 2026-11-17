-- FACE ARENA account profiles
-- Safe to apply only to the dedicated FACE ARENA Supabase project.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  handle text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 24),
  constraint profiles_handle_format check (handle is null or handle ~ '^[A-Za-z0-9_.]{3,20}$')
);

create unique index if not exists profiles_handle_lower_unique
  on public.profiles (lower(handle))
  where handle is not null;

alter table public.profiles enable row level security;

drop policy if exists "Authenticated users can read public profile fields" on public.profiles;
create policy "Authenticated users can read public profile fields"
  on public.profiles for select to authenticated
  using (true);

drop policy if exists "Users can insert their own profile" on public.profiles;
create policy "Users can insert their own profile"
  on public.profiles for insert to authenticated
  with check ((select auth.uid()) = id);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create or replace function public.set_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_profile_updated_at();

create schema if not exists private;
revoke all on schema private from public;

create or replace function private.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_name text;
begin
  chosen_name := nullif(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');
  if chosen_name is null then
    chosen_name := split_part(coalesce(new.email, 'player'), '@', 1);
  end if;

  insert into public.profiles (id, display_name)
  values (new.id, left(chosen_name, 24))
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function private.create_profile_for_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_face_arena on auth.users;
create trigger on_auth_user_created_face_arena
after insert on auth.users
for each row execute function private.create_profile_for_new_user();

-- Public avatar URLs are intentional: avatars are profile decoration, not private battle uploads.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('face-arena-avatars', 'face-arena-avatars', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Users can upload their own FACE ARENA avatar" on storage.objects;
create policy "Users can upload their own FACE ARENA avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'face-arena-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Users can read their own FACE ARENA avatar objects" on storage.objects;
create policy "Users can read their own FACE ARENA avatar objects"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'face-arena-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Users can replace their own FACE ARENA avatar" on storage.objects;
create policy "Users can replace their own FACE ARENA avatar"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'face-arena-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'face-arena-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Users can delete their own FACE ARENA avatar" on storage.objects;
create policy "Users can delete their own FACE ARENA avatar"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'face-arena-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
