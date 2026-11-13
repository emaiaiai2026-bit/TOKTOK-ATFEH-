-- Doctor subscriptions: complete billing ledger with a launch promotion switch.
-- Promotion is ON initially; doctors can use the service without payment until admin turns it off.
-- Driver balances/subscriptions are intentionally untouched.

create table if not exists public.doctor_subscription_settings (
  singleton boolean primary key default true check (singleton),
  promotion_enabled boolean not null default true,
  monthly_price numeric(10,2) not null default 0 check (monthly_price >= 0),
  currency text not null default 'EGP' check (currency = 'EGP'),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

insert into public.doctor_subscription_settings(singleton,promotion_enabled,monthly_price)
values (true,true,0)
on conflict (singleton) do nothing;

create table if not exists public.doctor_subscriptions (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null unique references public.doctor_profiles(id) on delete cascade,
  status text not null default 'expired' check (status in ('active','expired','suspended')),
  starts_at timestamptz,
  ends_at timestamptz,
  last_payment_at timestamptz,
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create index if not exists doctor_subscriptions_status_end_idx
  on public.doctor_subscriptions(status,ends_at);

create table if not exists public.doctor_subscription_payments (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.doctor_profiles(id) on delete cascade,
  subscription_id uuid references public.doctor_subscriptions(id) on delete set null,
  amount numeric(10,2) not null check (amount > 0),
  currency text not null default 'EGP' check (currency = 'EGP'),
  months integer not null default 1 check (months between 1 and 24),
  method text not null default 'cash' check (method in ('cash','instapay','bank_transfer','other')),
  reference_note text,
  period_start timestamptz not null,
  period_end timestamptz not null,
  recorded_by uuid not null references public.profiles(id),
  paid_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (period_end > period_start)
);

create index if not exists doctor_subscription_payments_doctor_paid_idx
  on public.doctor_subscription_payments(doctor_id,paid_at desc);

alter table public.doctor_subscription_settings enable row level security;
alter table public.doctor_subscriptions enable row level security;
alter table public.doctor_subscription_payments enable row level security;
revoke all on public.doctor_subscription_settings from anon,authenticated;
revoke all on public.doctor_subscriptions from anon,authenticated;
revoke all on public.doctor_subscription_payments from anon,authenticated;

-- A single entitlement rule is shared by directory and booking validation.
create or replace function public.doctor_can_accept_bookings(p_doctor_id uuid)
returns boolean
language sql stable security definer
set search_path=public,pg_temp
as $$
  select exists (
    select 1
    from public.doctor_profiles d
    cross join public.doctor_subscription_settings cfg
    left join public.doctor_subscriptions s on s.doctor_id=d.id
    where d.id=p_doctor_id
      and d.is_active=true
      and cfg.singleton=true
      and coalesce(s.status,'') <> 'suspended'
      and (
        cfg.promotion_enabled=true
        or (s.status='active' and s.starts_at<=now() and s.ends_at>now())
      )
  );
$$;

-- Directory endpoint: only approved doctors with current booking entitlement are listed.
create or replace function public.list_bookable_doctors()
returns table (
  id uuid,
  display_name text,
  specialty text,
  clinic_name text,
  address text,
  phone text,
  bio text
)
language sql stable security definer
set search_path=public,pg_temp
as $$
  select d.id,d.display_name,d.specialty,d.clinic_name,d.address,d.phone,d.bio
  from public.doctor_profiles d
  where public.doctor_can_accept_bookings(d.id)
  order by d.display_name;
$$;

-- Enforce entitlement even if a client bypasses the directory UI and calls booking RPC directly.
create or replace function public.enforce_doctor_subscription_on_booking()
returns trigger
language plpgsql security definer
set search_path=public,pg_temp
as $$
begin
  if not public.doctor_can_accept_bookings(new.doctor_id) then
    raise exception 'doctor subscription is inactive; new bookings are unavailable';
  end if;
  return new;
end;
$$;

drop trigger if exists doctor_appointment_subscription_guard on public.doctor_appointments;
create trigger doctor_appointment_subscription_guard
before insert on public.doctor_appointments
for each row execute function public.enforce_doctor_subscription_on_booking();

-- Admin-only configuration and billing operations.
create or replace function public.admin_get_doctor_subscription_settings()
returns table(promotion_enabled boolean,monthly_price numeric,currency text)
language plpgsql stable security definer
set search_path=public,pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'admins only' using errcode='42501'; end if;
  return query select c.promotion_enabled,c.monthly_price,c.currency
    from public.doctor_subscription_settings c where c.singleton=true;
end;
$$;

create or replace function public.admin_update_doctor_subscription_settings(
  p_promotion_enabled boolean,
  p_monthly_price numeric
)
returns void
language plpgsql security definer
set search_path=public,pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'admins only' using errcode='42501'; end if;
  if p_monthly_price is null or p_monthly_price < 0 then
    raise exception 'monthly price must be zero or greater';
  end if;
  if p_promotion_enabled=false and p_monthly_price<=0 then
    raise exception 'set a monthly price before ending the promotion';
  end if;
  update public.doctor_subscription_settings
  set promotion_enabled=p_promotion_enabled,monthly_price=p_monthly_price,
      updated_at=now(),updated_by=auth.uid()
  where singleton=true;
end;
$$;

create or replace function public.admin_list_doctor_subscriptions()
returns table(
  doctor_id uuid, user_id uuid, display_name text, specialty text,
  is_approved boolean, subscription_status text, starts_at timestamptz,
  ends_at timestamptz, last_payment_at timestamptz, admin_note text
)
language plpgsql stable security definer
set search_path=public,pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'admins only' using errcode='42501'; end if;
  return query
  select d.id,d.user_id,d.display_name,d.specialty,d.is_active,
         coalesce(s.status,'expired'),s.starts_at,s.ends_at,s.last_payment_at,s.admin_note
  from public.doctor_profiles d
  left join public.doctor_subscriptions s on s.doctor_id=d.id
  order by d.created_at desc;
end;
$$;

create or replace function public.admin_record_doctor_subscription_payment(
  p_doctor_id uuid,
  p_amount numeric,
  p_months integer default 1,
  p_method text default 'cash',
  p_reference_note text default null
)
returns uuid
language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
  v_sub public.doctor_subscriptions%rowtype;
  v_start timestamptz;
  v_end timestamptz;
  v_payment uuid;
  v_price numeric;
begin
  if not public.is_admin() then raise exception 'admins only' using errcode='42501'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'payment amount must be greater than zero'; end if;
  if p_months not between 1 and 24 then raise exception 'months must be between 1 and 24'; end if;
  if p_method not in ('cash','instapay','bank_transfer','other') then raise exception 'invalid payment method'; end if;
  if not exists(select 1 from public.doctor_profiles where id=p_doctor_id) then
    raise exception 'doctor not found';
  end if;

  select monthly_price into v_price from public.doctor_subscription_settings where singleton=true;
  if v_price is null or v_price<=0 then raise exception 'monthly price is not configured'; end if;
  if p_amount < v_price*p_months then raise exception 'payment is below the configured subscription price'; end if;

  insert into public.doctor_subscriptions(doctor_id,status,starts_at,ends_at)
  values(p_doctor_id,'active',now(),null)
  on conflict(doctor_id) do nothing;

  select * into v_sub from public.doctor_subscriptions
  where doctor_id=p_doctor_id for update;

  v_start:=greatest(now(),coalesce(v_sub.ends_at,now()));
  v_end:=v_start + make_interval(months=>p_months);

  update public.doctor_subscriptions
  set status='active',
      starts_at=case when v_sub.ends_at is not null and v_sub.ends_at>now() then v_sub.starts_at else v_start end,
      ends_at=v_end,last_payment_at=now(),updated_at=now()
  where doctor_id=p_doctor_id
  returning * into v_sub;

  insert into public.doctor_subscription_payments(
    doctor_id,subscription_id,amount,months,method,reference_note,
    period_start,period_end,recorded_by
  ) values(
    p_doctor_id,v_sub.id,p_amount,p_months,p_method,
    nullif(trim(coalesce(p_reference_note,'')),''),
    v_start,v_end,auth.uid()
  ) returning id into v_payment;
  return v_payment;
end;
$$;

create or replace function public.admin_set_doctor_subscription_status(
  p_doctor_id uuid,
  p_status text,
  p_ends_at timestamptz default null,
  p_admin_note text default null
)
returns void
language plpgsql security definer
set search_path=public,pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'admins only' using errcode='42501'; end if;
  if p_status not in ('active','expired','suspended') then raise exception 'invalid subscription status'; end if;
  if p_status='active' and (p_ends_at is null or p_ends_at<=now()) then raise exception 'active subscription requires a future end date'; end if;
  if not exists(select 1 from public.doctor_profiles where id=p_doctor_id) then raise exception 'doctor not found'; end if;
  insert into public.doctor_subscriptions(doctor_id,status,starts_at,ends_at,admin_note)
  values(p_doctor_id,p_status,case when p_status='active' then now() else null end,p_ends_at,p_admin_note)
  on conflict(doctor_id) do update
  set status=excluded.status,
      starts_at=case when excluded.status='active' then now() else doctor_subscriptions.starts_at end,
      ends_at=excluded.ends_at,
      admin_note=excluded.admin_note,
      updated_at=now();
end;
$$;

revoke all on function public.doctor_can_accept_bookings(uuid) from public,anon,authenticated;
revoke all on function public.list_bookable_doctors() from public,anon;
revoke all on function public.enforce_doctor_subscription_on_booking() from public,anon,authenticated;
revoke all on function public.admin_get_doctor_subscription_settings() from public,anon;
revoke all on function public.admin_update_doctor_subscription_settings(boolean,numeric) from public,anon;
revoke all on function public.admin_list_doctor_subscriptions() from public,anon;
revoke all on function public.admin_record_doctor_subscription_payment(uuid,numeric,integer,text,text) from public,anon;
revoke all on function public.admin_set_doctor_subscription_status(uuid,text,timestamptz,text) from public,anon;

grant execute on function public.list_bookable_doctors() to authenticated;
grant execute on function public.admin_get_doctor_subscription_settings() to authenticated;
grant execute on function public.admin_update_doctor_subscription_settings(boolean,numeric) to authenticated;
grant execute on function public.admin_list_doctor_subscriptions() to authenticated;
grant execute on function public.admin_record_doctor_subscription_payment(uuid,numeric,integer,text,text) to authenticated;
grant execute on function public.admin_set_doctor_subscription_status(uuid,text,timestamptz,text) to authenticated;
