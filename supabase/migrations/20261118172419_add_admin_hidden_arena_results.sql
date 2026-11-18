alter table public.arena_results add column if not exists is_hidden boolean not null default false;
alter table public.arena_results add column if not exists hidden_at timestamptz null;
create index if not exists arena_results_visible_completed_idx on public.arena_results (completed_at desc, id desc) where is_hidden = false;
