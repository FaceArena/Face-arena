
create table public.arena_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Участник' check(char_length(display_name) between 1 and 32),
  handle text not null unique check(handle ~ '^[A-Za-z0-9_.]{3,24}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.arena_profiles enable row level security;
create policy "Authenticated users can read arena profiles" on public.arena_profiles for select to authenticated using(true);
create policy "Users update their own arena profile" on public.arena_profiles for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant select on public.arena_profiles to authenticated;
grant update(display_name,handle,updated_at) on public.arena_profiles to authenticated;

create or replace function private.handle_new_arena_user()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare v_name text; v_handle text;
begin
  v_name:=left(coalesce(nullif(btrim(new.raw_user_meta_data->>'display_name'),''),'Участник'),32);
  v_handle:=coalesce(nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'handle',''),'[^A-Za-z0-9_.]','','g'),''),'user_'||left(replace(new.id::text,'-',''),8));
  if char_length(v_handle)<3 then v_handle:='user_'||left(replace(new.id::text,'-',''),8); end if;
  insert into public.arena_profiles(user_id,display_name,handle)
  values(new.id,v_name,left(v_handle,24))
  on conflict(user_id) do nothing;
  return new;
end;
$$;
revoke all on function private.handle_new_arena_user() from public,anon,authenticated;
drop trigger if exists on_auth_user_created_arena_profile on auth.users;
create trigger on_auth_user_created_arena_profile
after insert on auth.users
for each row execute function private.handle_new_arena_user();

alter publication supabase_realtime add table public.arena_profiles;
