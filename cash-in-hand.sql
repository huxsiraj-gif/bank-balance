-- =====================================================================
--  Cash in Hand page (USD / LKR cash: cash in and cash spent)
--  Run once in Supabase > SQL Editor. Safe to run again.
-- =====================================================================
create table if not exists public.cash_entries (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null default gen_random_uuid()::text,
  tdate      date not null default current_date,
  kind       text not null default 'out' check (kind in ('in', 'out')),   -- 'in' = cash received, 'out' = cash spent
  currency   text not null default 'LKR',
  amount     numeric not null default 0,
  name       text not null default '',
  note       text not null default '',
  created_at timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists cash_entries_user_date on public.cash_entries (user_id, tdate);

alter table public.cash_entries enable row level security;
drop policy if exists "own rows" on public.cash_entries;
create policy "own rows" on public.cash_entries for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant usage on schema public to authenticated;
revoke all on public.cash_entries from anon;
grant select, insert, update, delete on public.cash_entries to authenticated;

create or replace function public.cash_get()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'd', to_char(c.tdate, 'YYYY-MM-DD'), 'k', c.kind,
             'cur', c.currency, 'a', c.amount, 'n', c.name, 't', c.note)
           order by c.tdate, c.created_at)
    from public.cash_entries c where c.user_id = auth.uid()), '[]'::jsonb);
end;
$$;

-- adds an entry, or updates it if the id already exists
create or replace function public.cash_save(p jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not logged in'; end if;
  insert into public.cash_entries (user_id, id, tdate, kind, currency, amount, name, note)
  values (uid,
          coalesce(nullif(p->>'id', ''), gen_random_uuid()::text),
          coalesce(nullif(p->>'d', '')::date, current_date),
          case when p->>'k' = 'in' then 'in' else 'out' end,
          coalesce(nullif(upper(p->>'cur'), ''), 'LKR'),
          coalesce(nullif(p->>'a', '')::numeric, 0),
          coalesce(p->>'n', ''),
          coalesce(p->>'t', ''))
  on conflict (user_id, id) do update set
    tdate = excluded.tdate, kind = excluded.kind, currency = excluded.currency,
    amount = excluded.amount, name = excluded.name, note = excluded.note;
end;
$$;

create or replace function public.cash_delete(pid text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  delete from public.cash_entries where user_id = auth.uid() and id = pid;
end;
$$;

revoke execute on function public.cash_get()          from public, anon;
revoke execute on function public.cash_save(jsonb)    from public, anon;
revoke execute on function public.cash_delete(text)   from public, anon;
grant  execute on function public.cash_get(), public.cash_save(jsonb), public.cash_delete(text) to authenticated;
