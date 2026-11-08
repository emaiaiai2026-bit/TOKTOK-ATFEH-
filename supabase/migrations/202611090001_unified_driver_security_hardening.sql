-- Unified account security hardening.
-- Apply after 202611080001_unified_driver_activation.sql.
-- This migration keeps customer/driver accounts unified and preserves admin approval.

-- Only approved, non-blocked drivers may see new ride requests through is_driver().
create or replace function public.is_driver()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and is_driver = true
      and is_approved = true
      and is_blocked = false
  )
$function$;

-- Blocking any non-admin account also removes it from availability immediately.
create or replace function public.admin_set_blocked(p_user uuid, p_blocked boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not is_admin() then
    raise exception 'admins only';
  end if;

  update public.profiles
  set is_blocked = p_blocked,
      is_available = case when p_blocked then false else is_available end
  where id = p_user
    and role <> 'admin';
end
$function$;

-- A blocked or unapproved driver cannot accept a ride, even if the UI is bypassed.
create or replace function public.accept_ride(p_ride_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  tmo numeric;
begin
  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and is_driver = true
      and is_approved = true
      and is_blocked = false
  ) then
    raise exception 'driver not approved or account blocked';
  end if;

  if not can_driver_work(auth.uid()) then
    raise exception 'balance exceeded';
  end if;

  if exists (
    select 1
    from public.rides
    where driver_id = auth.uid()
      and status in ('accepted', 'arrived', 'started')
  ) then
    raise exception 'finish your current ride first';
  end if;

  select request_timeout_min into tmo
  from public.settings
  where id = 1;

  update public.rides
  set status = 'accepted',
      driver_id = auth.uid(),
      accepted_at = now()
  where id = p_ride_id
    and status = 'requested'
    and customer_id <> auth.uid()
    and vehicle_type = (
      select vehicle_type
      from public.profiles
      where id = auth.uid()
    )
    and not (auth.uid() = any(rejected_drivers))
    and created_at > now() - make_interval(mins => coalesce(tmo, 5)::int);

  return found;
end
$function$;

-- A blocked driver can no longer publish availability or appear online.
create or replace function public.update_driver_location(
  p_lat double precision,
  p_lng double precision,
  p_available boolean
)
returns void
language sql
security definer
set search_path to 'public'
as $function$
  update public.profiles as p
  set lat = p_lat,
      lng = p_lng,
      is_available = (
        p_available
        and p.is_approved
        and not p.is_blocked
        and can_driver_work(p.id)
      ),
      updated_at = now()
  where p.id = auth.uid()
    and p.is_driver = true
$function$;

-- The unified flow uses request_driver_activation(); prevent direct use of
-- the legacy activation RPC by anonymous and authenticated clients.
revoke all on function public.become_driver(text, text) from public;
revoke all on function public.become_driver(text, text) from anon;
revoke all on function public.become_driver(text, text) from authenticated;
