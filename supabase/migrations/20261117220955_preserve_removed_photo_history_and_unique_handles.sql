
drop policy if exists "Authenticated users can read arena photos" on public.arena_photos;
create policy "Authenticated users can read arena photos" on public.arena_photos
for select to authenticated using(status <> 'removed' or owner_id=auth.uid());

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
  v_handle:=left(v_handle,24);
  if exists(select 1 from public.arena_profiles where handle=v_handle) then
    v_handle:=left(v_handle,15)||'_'||left(replace(new.id::text,'-',''),8);
  end if;
  insert into public.arena_profiles(user_id,display_name,handle)
  values(new.id,v_name,v_handle)
  on conflict(user_id) do nothing;
  return new;
end;
$$;
revoke all on function private.handle_new_arena_user() from public,anon,authenticated;
