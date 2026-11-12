-- Self-service doctor applications for the unified Google account.
-- A doctor can submit/update their own profile, but cannot activate it.
alter table public.doctor_profiles
  add column if not exists self_registered boolean not null default false;

create or replace function public.doctor_apply_self(
  p_display_name text,
  p_specialty text,
  p_clinic_name text default null,
  p_address text default null,
  p_phone text default null,
  p_bio text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = v_uid and role <> 'admin') then
    raise exception 'valid user account required';
  end if;
  if length(trim(coalesce(p_display_name, ''))) not between 2 and 120 then
    raise exception 'doctor name must be between 2 and 120 characters';
  end if;
  if length(trim(coalesce(p_specialty, ''))) not between 2 and 120 then
    raise exception 'specialty must be between 2 and 120 characters';
  end if;
  if v_phone is not null and v_phone !~ '^01[0125][0-9]{8}$' then
    raise exception 'valid Egyptian phone required';
  end if;
  if length(coalesce(p_bio, '')) > 1000 then
    raise exception 'bio too long';
  end if;

  insert into public.doctor_profiles (
    user_id, display_name, specialty, clinic_name, address, phone, bio,
    is_active, self_registered, updated_at
  ) values (
    v_uid, trim(p_display_name), trim(p_specialty),
    nullif(trim(coalesce(p_clinic_name, '')), ''),
    nullif(trim(coalesce(p_address, '')), ''),
    v_phone,
    nullif(trim(coalesce(p_bio, '')), ''),
    false, true, now()
  )
  on conflict (user_id) do update set
    display_name = excluded.display_name,
    specialty = excluded.specialty,
    clinic_name = excluded.clinic_name,
    address = excluded.address,
    phone = excluded.phone,
    bio = excluded.bio,
    is_active = false,
    self_registered = true,
    updated_at = now()
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.doctor_apply_self(text,text,text,text,text,text) from public, anon;
grant execute on function public.doctor_apply_self(text,text,text,text,text,text) to authenticated;
