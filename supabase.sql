-- =====================================================================
--  Income Tracker  -  Supabase database setup
--  Paste this whole file into Supabase > SQL Editor > New query > Run.
--  Safe to run again: it only creates what is missing and refreshes the functions.
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.settings (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  bank       numeric not null default 0,      -- Bank amount (income received)
  income     numeric not null default 0,      -- Expected income
  budget     numeric not null default 0,      -- Monthly budget (0 = off)
  end_day    int     not null default 24 check (end_day between 1 and 31),
  rlkr       numeric not null default 0.05,   -- 1 LKR in MVR
  rusd       numeric not null default 15.42,  -- 1 USD in MVR
  updated_at timestamptz not null default now()
);

create table if not exists public.expenses (
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id             text not null default gen_random_uuid()::text,
  name           text not null default '',
  note           text not null default '',
  amount         numeric not null default 0,         -- always in MVR
  tdate          date not null default current_date, -- Transaction date
  category       text not null default '',
  foreign_amount numeric,                            -- original amount (foreign currency only)
  currency       text,                               -- LKR / USD
  rate           numeric,                            -- rate to MVR used for this entry
  created_at     timestamptz not null default now(),
  primary key (user_id, id)
);

create table if not exists public.income (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null default gen_random_uuid()::text,
  name       text not null default '',
  amount     numeric not null default 0,
  tdate      date not null default current_date,    -- Transaction date
  created_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table if not exists public.ahead (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null default gen_random_uuid()::text,
  name       text not null default '',
  amount     numeric not null default 0,
  repeat     boolean not null default false,        -- repeats monthly
  last_paid  text not null default '',              -- period it was last paid, e.g. 2026-12
  position   int not null default 0,
  created_at timestamptz not null default now(),
  primary key (user_id, id)
);

create index if not exists expenses_user_date on public.expenses (user_id, tdate);
create index if not exists income_user_date   on public.income   (user_id, tdate);

-- ---------- security: each user can only see and change their own rows ----------
alter table public.settings enable row level security;
alter table public.expenses enable row level security;
alter table public.income   enable row level security;
alter table public.ahead    enable row level security;

do $$
declare t text;
begin
  foreach t in array array['settings','expenses','income','ahead'] loop
    execute format('drop policy if exists "own rows" on public.%I', t);
    execute format(
      'create policy "own rows" on public.%I for all to authenticated
         using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;

-- table permissions: logged-in users only (row security above limits them to their own rows)
grant usage on schema public to authenticated;
revoke all on public.settings, public.expenses, public.income, public.ahead from anon;
grant select, insert, update, delete on public.settings, public.expenses, public.income, public.ahead to authenticated;

-- ---------- get_data(): everything the app needs, in one call ----------
create or replace function public.get_data()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  s   public.settings;
begin
  if uid is null then raise exception 'not logged in'; end if;

  insert into public.settings (user_id) values (uid) on conflict (user_id) do nothing;
  select * into s from public.settings where user_id = uid;

  return jsonb_build_object(
    'bank',   s.bank,
    'income', s.income,
    'budget', s.budget,
    'end',    s.end_day,
    'rlkr',   s.rlkr,
    'rusd',   s.rusd,
    'exp', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'n', e.name, 't', e.note, 'a', e.amount,
               'd', to_char(e.tdate, 'YYYY-MM-DD'), 'c', e.category,
               'o', e.foreign_amount, 'cur', e.currency, 'r', e.rate)
             order by e.tdate, e.created_at)
      from public.expenses e where e.user_id = uid), '[]'::jsonb),
    'inc', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'n', i.name, 'a', i.amount, 'd', to_char(i.tdate, 'YYYY-MM-DD'))
             order by i.tdate, i.created_at)
      from public.income i where i.user_id = uid), '[]'::jsonb),
    'up', coalesce((
      select jsonb_agg(jsonb_build_object(
               'n', a.name, 'a', a.amount, 'rep', a.repeat, 'last', a.last_paid)
             order by a.position, a.created_at)
      from public.ahead a where a.user_id = uid), '[]'::jsonb)
  );
end;
$$;

-- ---------- save_data(p): saves settings + expenses ahead, and APPENDS new expenses / income ----------
-- Existing expense and income rows are never rewritten, so edits you make in the
-- Supabase table editor are never overwritten by the app. Repeated ids are ignored.
create or replace function public.save_data(p jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  x   jsonb;
  i   int := 0;
  ed  int;
begin
  if uid is null then raise exception 'not logged in'; end if;

  ed := nullif(p->>'end', '')::int;
  if ed is null or ed < 1 or ed > 31 then ed := 24; end if;

  insert into public.settings (user_id, bank, income, budget, end_day, rlkr, rusd, updated_at)
  values (
    uid,
    coalesce(nullif(p->>'bank',   '')::numeric, 0),
    coalesce(nullif(p->>'income', '')::numeric, 0),
    coalesce(nullif(p->>'budget', '')::numeric, 0),
    ed,
    case when coalesce(nullif(p->>'rlkr','')::numeric, 0) > 0 then (p->>'rlkr')::numeric else 0.05 end,
    case when coalesce(nullif(p->>'rusd','')::numeric, 0) > 0 then (p->>'rusd')::numeric else 15.42 end,
    now())
  on conflict (user_id) do update set
    bank = excluded.bank, income = excluded.income, budget = excluded.budget,
    end_day = excluded.end_day, rlkr = excluded.rlkr, rusd = excluded.rusd,
    updated_at = now();

  -- "Expenses ahead" is replaced as a whole list (same as the old sheet)
  delete from public.ahead where user_id = uid;
  for x in select * from jsonb_array_elements(coalesce(p->'up', '[]'::jsonb)) loop
    i := i + 1;
    insert into public.ahead (user_id, name, amount, repeat, last_paid, position)
    values (uid,
            coalesce(x->>'n', ''),
            coalesce(nullif(x->>'a', '')::numeric, 0),
            coalesce((x->>'rep')::boolean, false),
            coalesce(x->>'last', ''),
            i);
  end loop;

  insert into public.expenses (user_id, id, name, note, amount, tdate, category, foreign_amount, currency, rate)
  select uid,
         coalesce(nullif(e->>'id', ''), gen_random_uuid()::text),
         coalesce(e->>'n', ''),
         coalesce(e->>'t', ''),
         coalesce(nullif(e->>'a', '')::numeric, 0),
         coalesce(nullif(e->>'d', '')::date, current_date),
         coalesce(e->>'c', ''),
         nullif(e->>'o', '')::numeric,
         nullif(e->>'cur', ''),
         nullif(e->>'r', '')::numeric
  from jsonb_array_elements(coalesce(p->'add', '[]'::jsonb)) e
  on conflict (user_id, id) do nothing;

  insert into public.income (user_id, id, name, amount, tdate)
  select uid,
         coalesce(nullif(e->>'id', ''), gen_random_uuid()::text),
         coalesce(e->>'n', ''),
         coalesce(nullif(e->>'a', '')::numeric, 0),
         coalesce(nullif(e->>'d', '')::date, current_date)
  from jsonb_array_elements(coalesce(p->'addInc', '[]'::jsonb)) e
  on conflict (user_id, id) do nothing;
end;
$$;

-- only logged-in users may call the functions
revoke execute on function public.get_data()        from public, anon;
revoke execute on function public.save_data(jsonb)  from public, anon;
grant  execute on function public.get_data()        to authenticated;
grant  execute on function public.save_data(jsonb)  to authenticated;

-- ---------- a summary view for the Supabase table editor (read-only, same maths as the app) ----------
create or replace view public.summary with (security_invoker = true) as
select s.user_id,
       s.bank                                                         as bank,
       coalesce((select sum(amount) from public.income   i where i.user_id = s.user_id), 0) as income_entries,
       coalesce((select sum(amount) from public.expenses e where e.user_id = s.user_id), 0) as spent,
       s.bank
         + coalesce((select sum(amount) from public.income   i where i.user_id = s.user_id), 0)
         - coalesce((select sum(amount) from public.expenses e where e.user_id = s.user_id), 0) as balance
from public.settings s;
revoke all on public.summary from anon;
grant select on public.summary to authenticated;

-- =====================================================================
--  Foreign Purchases page (separate from expenses, income and balance)
-- =====================================================================
create table if not exists public.foreign_purchases (
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id          text not null default gen_random_uuid()::text,
  tdate       date not null default current_date,   -- purchase date
  name        text not null default '',              -- what / where
  currency    text not null default 'USD',
  amount      numeric not null default 0,            -- amount in the foreign currency
  bank_amount numeric not null default 0,            -- MVR the bank actually deducted
  bank        text not null default '',              -- bank / card used
  note        text not null default '',
  expense_id  text,                                  -- set when moved to Expenses
  created_at  timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.foreign_purchases add column if not exists expense_id text;
create index if not exists foreign_purchases_user_date on public.foreign_purchases (user_id, tdate);

alter table public.foreign_purchases enable row level security;
drop policy if exists "own rows" on public.foreign_purchases;
create policy "own rows" on public.foreign_purchases for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant usage on schema public to authenticated;
revoke all on public.foreign_purchases from anon;
grant select, insert, update, delete on public.foreign_purchases to authenticated;

create or replace function public.fp_get()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', f.id, 'd', to_char(f.tdate, 'YYYY-MM-DD'), 'n', f.name,
             'cur', f.currency, 'o', f.amount, 'b', f.bank_amount,
             'bk', f.bank, 't', f.note, 'x', f.expense_id)
           order by f.tdate, f.created_at)
    from public.foreign_purchases f where f.user_id = auth.uid()), '[]'::jsonb);
end;
$$;

create or replace function public.fp_save(p jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not logged in'; end if;
  insert into public.foreign_purchases (user_id, id, tdate, name, currency, amount, bank_amount, bank, note, expense_id)
  values (uid,
          coalesce(nullif(p->>'id', ''), gen_random_uuid()::text),
          coalesce(nullif(p->>'d', '')::date, current_date),
          coalesce(p->>'n', ''),
          coalesce(nullif(upper(p->>'cur'), ''), 'LKR'),
          coalesce(nullif(p->>'o', '')::numeric, 0),
          coalesce(nullif(p->>'b', '')::numeric, 0),
          coalesce(p->>'bk', ''),
          coalesce(p->>'t', ''),
          nullif(p->>'x', ''))
  on conflict (user_id, id) do update set
    tdate = excluded.tdate, name = excluded.name, currency = excluded.currency,
    amount = excluded.amount, bank_amount = excluded.bank_amount,
    bank = excluded.bank, note = excluded.note, expense_id = excluded.expense_id;
end;
$$;

create or replace function public.fp_delete(pid text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  delete from public.foreign_purchases where user_id = auth.uid() and id = pid;
end;
$$;

revoke execute on function public.fp_get()          from public, anon;
revoke execute on function public.fp_save(jsonb)    from public, anon;
revoke execute on function public.fp_delete(text)   from public, anon;
grant  execute on function public.fp_get(), public.fp_save(jsonb), public.fp_delete(text) to authenticated;

-- ---------- update_entry(p): edit or delete one expense / income from History ----------
create or replace function public.update_entry(p jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  k    text := p->>'kind';          -- 'e' = expense, 'i' = income
  pid  text := p->>'id';
  gone boolean := coalesce((p->>'del')::boolean, false);
begin
  if uid is null then raise exception 'not logged in'; end if;
  if pid is null or pid = '' then raise exception 'missing id'; end if;

  if k = 'e' then
    if gone then
      delete from public.expenses where user_id = uid and id = pid;
    else
      update public.expenses set
        name = coalesce(p->>'n', name),
        note = coalesce(p->>'t', note),
        amount = coalesce(nullif(p->>'a', '')::numeric, amount),
        tdate = coalesce(nullif(p->>'d', '')::date, tdate),
        category = coalesce(p->>'c', category),
        foreign_amount = case when p ? 'o' then nullif(p->>'o', '')::numeric else foreign_amount end,
        rate = case when p ? 'r' then nullif(p->>'r', '')::numeric else rate end
      where user_id = uid and id = pid;
    end if;
  elsif k = 'i' then
    if gone then
      delete from public.income where user_id = uid and id = pid;
    else
      update public.income set
        name = coalesce(p->>'n', name),
        amount = coalesce(nullif(p->>'a', '')::numeric, amount),
        tdate = coalesce(nullif(p->>'d', '')::date, tdate)
      where user_id = uid and id = pid;
    end if;
  else
    raise exception 'unknown kind';
  end if;
end;
$$;

revoke execute on function public.update_entry(jsonb) from public, anon;
grant  execute on function public.update_entry(jsonb) to authenticated;

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
