-- Credit an immutable, wallet-impacting bonus only when a user's first plan
-- purchase is successfully approved. Historical approved deposits make a user
-- ineligible, so this feature never retroactively grants bonuses.
create table public.first_purchase_bonuses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users(id) on delete cascade,
  deposit_id uuid not null unique references public.deposits(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  rate numeric(5,4) not null check (rate = 0.0750),
  created_at timestamptz not null default now()
);

alter table public.first_purchase_bonuses enable row level security;

alter table public.ledger drop constraint if exists ledger_type_check;
alter table public.ledger add constraint ledger_type_check
  check (type in ('deposit', 'commission', 'first_purchase_bonus', 'withdrawal_debit', 'withdrawal_refund', 'admin_adjustment'));

create unique index ledger_one_first_purchase_bonus_idx
  on public.ledger(reference_id)
  where type = 'first_purchase_bonus';

create or replace function public.get_my_first_purchase_bonus_status() returns jsonb
language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select jsonb_build_object(
    'isEligible', auth.uid() is not null
      and not exists (select 1 from public.deposits d where d.user_id = auth.uid() and d.status = 'approved')
      and not exists (select 1 from public.first_purchase_bonuses b where b.user_id = auth.uid())
  );
$$;

create or replace function public.admin_approve_deposit(p_deposit_id uuid, p_note text default null) returns void
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  d public.deposits%rowtype;
  depositor public.users%rowtype;
  direct_referrer public.users%rowtype;
  level2_referrer public.users%rowtype;
  nowt timestamptz := now();
  c1 uuid;
  c2 uuid;
  bonus_id uuid;
  level1_amount numeric;
  level2_amount numeric;
  bonus_amount numeric;
  level1_percentage numeric;
  level2_percentage numeric;
  has_prior_successful_purchase boolean;
begin
  perform public.require_admin();

  select * into d from public.deposits where id = p_deposit_id for update;
  if not found then raise exception using message = 'Deposit not found'; end if;
  if d.status <> 'pending' or d.commissions_generated then
    raise exception using message = 'Deposit already processed';
  end if;

  -- Lock the member profile as a per-user approval mutex. This serializes two
  -- concurrent approvals for different deposits from the same member.
  select * into depositor from public.users where id = d.user_id for update;
  if not found then raise exception using message = 'Deposit user not found'; end if;
  select exists(
    select 1 from public.deposits prior
    where prior.user_id = d.user_id and prior.status = 'approved' and prior.id <> d.id
  ) into has_prior_successful_purchase;

  update public.deposits
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = nowt,
      admin_note = p_note, commissions_generated = false
  where id = d.id;

  insert into public.ledger(user_id, type, direction, amount, status, wallet_impact, reference_id, reference_type, description)
  values (d.user_id, 'deposit', 'credit', d.amount, 'completed', false, d.id, 'deposit',
    format('Plan payment approved — %s plan', d.plan_snapshot->>'name'));

  if not has_prior_successful_purchase then
    bonus_amount := round(d.amount * 0.0750, 2);
    insert into public.first_purchase_bonuses(user_id, deposit_id, amount, rate)
    values (d.user_id, d.id, bonus_amount, 0.0750)
    on conflict (user_id) do nothing
    returning id into bonus_id;

    if bonus_id is not null then
      insert into public.ledger(user_id, type, direction, amount, status, wallet_impact, reference_id, reference_type, description, metadata)
      values (d.user_id, 'first_purchase_bonus', 'credit', bonus_amount, 'completed', true, bonus_id, 'first_purchase_bonus',
        format('7.5%% first plan purchase bonus — %s plan', d.plan_snapshot->>'name'),
        jsonb_build_object('depositId', d.id, 'rate', 0.0750));
      insert into public.notifications(user_id, type, title, message, reference_id, reference_type)
      values (d.user_id, 'first_purchase_bonus_credited', 'First Purchase Bonus Credited',
        format('You received a PKR %s (7.5%%) bonus for your first %s plan purchase.', bonus_amount, d.plan_snapshot->>'name'),
        bonus_id, 'first_purchase_bonus');
    end if;
  end if;

  level1_percentage := (d.plan_snapshot->>'level1Commission')::numeric;
  level2_percentage := (d.plan_snapshot->>'level2Commission')::numeric;
  if depositor.referred_by is not null then
    select * into direct_referrer from public.users where id = depositor.referred_by;
    if found then
      level1_amount := round(d.amount * level1_percentage / 100, 2);
      if coalesce(level1_amount, 0) > 0 then
        insert into public.commissions(recipient_id, source_user_id, deposit_id, level, amount, percentage, plan_name, status)
        values (direct_referrer.id, d.user_id, d.id, 1, level1_amount, level1_percentage, d.plan_snapshot->>'name', 'pending') returning id into c1;
        insert into public.ledger(user_id, type, direction, amount, status, wallet_impact, reference_id, reference_type, description)
        values (direct_referrer.id, 'commission', 'credit', level1_amount, 'completed', true, c1, 'commission', format('Level 1 commission from %s — %s', depositor.username, d.plan_snapshot->>'name'));
        update public.commissions set status = 'credited' where id = c1;
        insert into public.notifications(user_id, type, title, message, reference_id, reference_type)
        values (direct_referrer.id, 'commission_received', 'Commission Earned', format('You earned PKR %s Level 1 commission from %s.', level1_amount, depositor.username), c1, 'commission');
      end if;
      if direct_referrer.referred_by is not null then
        select * into level2_referrer from public.users where id = direct_referrer.referred_by;
        if found then
          level2_amount := round(d.amount * level2_percentage / 100, 2);
          if coalesce(level2_amount, 0) > 0 then
            insert into public.commissions(recipient_id, source_user_id, deposit_id, level, amount, percentage, plan_name, status)
            values (level2_referrer.id, d.user_id, d.id, 2, level2_amount, level2_percentage, d.plan_snapshot->>'name', 'pending') returning id into c2;
            insert into public.ledger(user_id, type, direction, amount, status, wallet_impact, reference_id, reference_type, description)
            values (level2_referrer.id, 'commission', 'credit', level2_amount, 'completed', true, c2, 'commission', format('Level 2 commission from %s — %s', depositor.username, d.plan_snapshot->>'name'));
            update public.commissions set status = 'credited' where id = c2;
            insert into public.notifications(user_id, type, title, message, reference_id, reference_type)
            values (level2_referrer.id, 'commission_received', 'Commission Earned', format('You earned PKR %s Level 2 commission from %s.', level2_amount, depositor.username), c2, 'commission');
          end if;
        end if;
      end if;
    end if;
  end if;

  update public.deposits set commissions_generated = true where id = d.id;
  insert into public.notifications(user_id, type, title, message, reference_id, reference_type)
  values
    (d.user_id, 'deposit_approved', 'Deposit Approved', format('Your %s plan deposit of PKR %s has been approved.', d.plan_snapshot->>'name', d.amount), d.id, 'deposit'),
    (d.user_id, 'plan_activated', 'Plan Activated', format('Your %s plan is now active!', d.plan_snapshot->>'name'), null, null);
  insert into public.audit_logs(admin_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'approve_deposit', 'deposit', d.id::text, jsonb_build_object('amount', d.amount, 'plan', d.plan_snapshot->>'name'));
end
$$;

revoke all on public.first_purchase_bonuses from anon, authenticated;
revoke execute on function public.get_my_first_purchase_bonus_status() from public;
grant execute on function public.get_my_first_purchase_bonus_status() to authenticated;
revoke execute on function public.admin_approve_deposit(uuid, text) from public;
grant execute on function public.admin_approve_deposit(uuid, text) to authenticated;
