-- =====================================================================
--  Cash in Hand: money exchange (USD -> LKR) support
--  Run once in Supabase > SQL Editor. Safe to run again.
-- =====================================================================
alter table public.cash_entries add column if not exists to_currency text;
alter table public.cash_entries add column if not exists to_amount   numeric;
alter table public.cash_entries add column if not exists rate        numeric;   -- LKR per 1 USD for an exchange
alter table public.cash_entries drop constraint if exists cash_entries_kind_check;
alter table public.cash_entries add constraint cash_entries_kind_check check (kind in ('in', 'out', 'ex'));   -- ex = money exchange

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
             'cur', c.currency, 'a', c.amount, 'n', c.name, 't', c.note,
             'to', c.to_currency, 'ta', c.to_amount, 'r', c.rate)
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
  insert into public.cash_entries (user_id, id, tdate, kind, currency, amount, name, note, to_currency, to_amount, rate)
  values (uid,
          coalesce(nullif(p->>'id', ''), gen_random_uuid()::text),
          coalesce(nullif(p->>'d', '')::date, current_date),
          case when p->>'k' in ('in', 'ex') then p->>'k' else 'out' end,
          coalesce(nullif(upper(p->>'cur'), ''), 'LKR'),
          coalesce(nullif(p->>'a', '')::numeric, 0),
          coalesce(p->>'n', ''),
          coalesce(p->>'t', ''),
          nullif(upper(p->>'to'), ''),
          nullif(p->>'ta', '')::numeric,
          nullif(p->>'r', '')::numeric)
  on conflict (user_id, id) do update set
    tdate = excluded.tdate, kind = excluded.kind, currency = excluded.currency,
    amount = excluded.amount, name = excluded.name, note = excluded.note,
    to_currency = excluded.to_currency, to_amount = excluded.to_amount, rate = excluded.rate;
end;
$$;

revoke execute on function public.cash_get()          from public, anon;
revoke execute on function public.cash_save(jsonb)    from public, anon;
grant  execute on function public.cash_get(), public.cash_save(jsonb) to authenticated;
