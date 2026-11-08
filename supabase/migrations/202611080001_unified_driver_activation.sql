-- Unified account: request driver activation without changing account role.
-- Existing phone accounts and the legacy become_driver() RPC remain untouched.

-- Keep every new account a customer by default; only copy safe display fields.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, role, name, phone)
  values (
    new.id,
    'customer',
    coalesce(
      nullif(trim(new.raw_user_meta_data->>'name'), ''),
      nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'display_name'), '')
    ),
    nullif(trim(new.raw_user_meta_data->>'phone'), '')
  );
  return new;
end
$function$;

create or replace function public.request_driver_activation(
  p_vehicle_type text,
  p_plate text,
  p_name text,
  p_phone text
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'name required';
  end if;

  if coalesce(trim(p_plate), '') = '' then
    raise exception 'plate required';
  end if;

  if coalesce(trim(p_phone), '') !~ '^01[0125][0-9]{8}$' then
    raise exception 'valid Egyptian phone required';
  end if;

  if not exists (
    select 1 from public.vehicle_types
    where code = p_vehicle_type and enabled = true
  ) then
    raise exception 'vehicle type not available';
  end if;

  update public.profiles
  set
    is_driver = true,
    vehicle_type = p_vehicle_type,
    plate_number = trim(p_plate),
    name = trim(p_name),
    phone = trim(p_phone),
    updated_at = now()
  where id = v_uid
    and role <> 'admin'
    and is_blocked = false
    and not (is_driver = true and is_approved = true);

  if not found then
    if exists (select 1 from public.profiles where id = v_uid and role = 'admin') then
      raise exception 'admin cannot request driver activation';
    elsif exists (select 1 from public.profiles where id = v_uid and is_blocked = true) then
      raise exception 'account blocked';
    elsif not exists (select 1 from public.profiles where id = v_uid) then
      raise exception 'profile not found';
    else
      raise exception 'driver already approved';
    end if;
  end if;
end;
$function$;

revoke all on function public.request_driver_activation(text,text,text,text) from public;
revoke all on function public.request_driver_activation(text,text,text,text) from anon;
grant execute on function public.request_driver_activation(text,text,text,text) to authenticated;
