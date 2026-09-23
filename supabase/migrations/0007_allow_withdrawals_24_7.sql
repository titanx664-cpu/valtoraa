-- Remove the withdrawal scheduling rule while retaining the hardened,
-- transactionally atomic reservation flow from migration 0005.
create or replace function public.request_withdrawal(
  p_amount numeric,
  p_method text,
  p_account_number text,
  p_account_name text default null,
  p_bank_name text default null,
  p_additional_info text default null
) returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  uid uuid := auth.uid();
  available_balance numeric;
  withdrawal_id uuid;
  details jsonb;
begin
  -- The member row is a per-wallet mutex. Every request locks it before
  -- reading reservations and writing its own, so concurrent requests cannot
  -- collectively reserve more than the server-calculated wallet balance.
  select u.id into uid
  from public.users u
  where u.id = auth.uid() and u.is_active
  for update;
  if not found then
    raise exception using message = 'Account inactive or not registered', errcode = 'P0001';
  end if;

  -- Reject NaN and fractions that would otherwise be rounded by numeric(12,2)
  -- after the balance comparison.
  if p_amount is null or p_amount = 'NaN'::numeric or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception using message = 'Invalid amount', errcode = 'P0001';
  end if;
  if p_method not in ('Easypaisa', 'JazzCash', 'Bank') then
    raise exception using message = 'Unsupported withdrawal method', errcode = 'P0001';
  end if;
  if nullif(trim(coalesce(p_account_number, '')), '') is null then
    raise exception using message = 'Account number is required', errcode = 'P0001';
  end if;
  if p_method = 'Bank' and nullif(trim(coalesce(p_bank_name, '')), '') is null then
    raise exception using message = 'Bank name is required for bank withdrawals', errcode = 'P0001';
  end if;

  select coalesce(sum(case when l.direction = 'credit' then l.amount else -l.amount end), 0)
  into available_balance
  from public.ledger l
  where l.user_id = uid
    and l.wallet_impact
    and (l.status = 'completed' or (l.status = 'pending' and l.type = 'withdrawal_debit'));
  if p_amount > available_balance then
    raise exception using message = 'Insufficient balance', errcode = 'P0001';
  end if;

  details := jsonb_build_object(
    'accountNumber', trim(p_account_number),
    'accountName', nullif(trim(p_account_name), ''),
    'bankName', nullif(trim(p_bank_name), ''),
    'additionalInfo', nullif(trim(p_additional_info), '')
  );
  insert into public.withdrawals(user_id, amount, method, account_details)
  values (uid, p_amount, p_method, details)
  returning id into withdrawal_id;
  insert into public.ledger(user_id, type, direction, amount, status, wallet_impact, reference_id, reference_type, description)
  values (uid, 'withdrawal_debit', 'debit', p_amount, 'pending', true, withdrawal_id, 'withdrawal',
    format('Withdrawal via %s - pending', p_method));
  insert into public.notifications(user_id, type, title, message, reference_id, reference_type)
  values (uid, 'withdrawal_submitted', 'Withdrawal Requested',
    format('Your withdrawal of PKR %s via %s is pending review. Expected processing time: 6–8 hours.', p_amount, p_method),
    withdrawal_id, 'withdrawal');
  return withdrawal_id;
end
$$;

-- This was only an audit flag for the removed Sunday rule and must not remain
-- as a misleading withdrawal-day setting.
alter table public.withdrawals drop column if exists submitted_on_sunday;

-- Preserve the RPC's browser access while keeping all direct table mutations
-- protected by grants, RLS, and the SECURITY DEFINER function above.
revoke execute on function public.request_withdrawal(numeric, text, text, text, text, text) from public;
grant execute on function public.request_withdrawal(numeric, text, text, text, text, text) to authenticated;
