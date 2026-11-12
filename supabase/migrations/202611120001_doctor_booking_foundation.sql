-- Doctor booking foundation for the unified Google-auth account model.
-- Doctors are linked to existing profiles; no separate auth account or role is created.
-- Apply after 202611100001_admin_profile_privilege_guard.sql.

create table if not exists public.doctor_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) between 2 and 120),
  specialty text not null check (length(trim(specialty)) between 2 and 120),
  clinic_name text,
  address text,
  phone text,
  bio text,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.doctor_availability (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.doctor_profiles(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time time not null,
  slot_minutes smallint not null default 30 check (slot_minutes between 10 and 180),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint doctor_availability_valid_range check (end_time > start_time),
  constraint doctor_availability_no_duplicate unique (doctor_id, weekday, start_time, end_time)
);

create table if not exists public.doctor_appointments (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.doctor_profiles(id) on delete restrict,
  patient_id uuid not null references public.profiles(id) on delete restrict,
  appointment_at timestamptz not null,
  patient_name text not null check (length(trim(patient_name)) between 2 and 120),
  patient_phone text not null check (patient_phone ~ '^01[0125][0-9]{8}$'),
  notes text,
  status text not null default 'pending'
    check (status in ('pending','confirmed','rejected','cancelled','completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint doctor_appointment_not_past check (appointment_at > created_at - interval '1 minute')
);

create index if not exists doctor_profiles_active_specialty_idx
  on public.doctor_profiles (specialty) where is_active = true;
create index if not exists doctor_availability_doctor_weekday_idx
  on public.doctor_availability (doctor_id, weekday) where is_active = true;
create index if not exists doctor_appointments_patient_created_idx
  on public.doctor_appointments (patient_id, created_at desc);
create index if not exists doctor_appointments_doctor_time_idx
  on public.doctor_appointments (doctor_id, appointment_at);

-- A time can be booked again only after its previous appointment is cancelled/rejected.
create unique index if not exists doctor_appointments_active_slot_uidx
  on public.doctor_appointments (doctor_id, appointment_at)
  where status in ('pending','confirmed','completed');

alter table public.doctor_profiles enable row level security;
alter table public.doctor_availability enable row level security;
alter table public.doctor_appointments enable row level security;

-- Publicly readable only after administrator activation; doctors/admin can see their own records.
drop policy if exists doctor_profiles_read on public.doctor_profiles;
create policy doctor_profiles_read on public.doctor_profiles
for select to authenticated
using (is_active = true or user_id = auth.uid() or public.is_admin());

drop policy if exists doctor_availability_read on public.doctor_availability;
create policy doctor_availability_read on public.doctor_availability
for select to authenticated
using (
  exists (
    select 1 from public.doctor_profiles d
    where d.id = doctor_id
      and (d.is_active = true or d.user_id = auth.uid() or public.is_admin())
  )
);

drop policy if exists doctor_appointments_read on public.doctor_appointments;
create policy doctor_appointments_read on public.doctor_appointments
for select to authenticated
using (
  patient_id = auth.uid()
  or exists (
    select 1 from public.doctor_profiles d
    where d.id = doctor_id and (d.user_id = auth.uid() or public.is_admin())
  )
);

-- No direct client writes. All booking and management writes go through guarded RPCs.
revoke all on public.doctor_profiles from anon, authenticated;
revoke all on public.doctor_availability from anon, authenticated;
revoke all on public.doctor_appointments from anon, authenticated;
grant select on public.doctor_profiles, public.doctor_availability, public.doctor_appointments to authenticated;

create or replace function public.book_doctor_appointment(
  p_doctor_id uuid,
  p_appointment_at timestamptz,
  p_patient_name text,
  p_patient_phone text,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_appointment_id uuid;
  v_local_time timestamp;
  v_weekday integer;
  v_clock time;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_appointment_at is null or p_appointment_at <= now() then
    raise exception 'appointment must be in the future';
  end if;
  if coalesce(trim(p_patient_name), '') = '' then
    raise exception 'patient name required';
  end if;
  if coalesce(trim(p_patient_phone), '') !~ '^01[0125][0-9]{8}$' then
    raise exception 'valid Egyptian phone required';
  end if;
  if length(coalesce(p_notes, '')) > 1000 then
    raise exception 'notes too long';
  end if;

  v_local_time := p_appointment_at at time zone 'Africa/Cairo';
  v_weekday := extract(dow from v_local_time)::integer;
  v_clock := v_local_time::time;

  if not exists (
    select 1
    from public.doctor_profiles d
    join public.doctor_availability a on a.doctor_id = d.id
    where d.id = p_doctor_id
      and d.is_active = true
      and a.is_active = true
      and a.weekday = v_weekday
      and v_clock >= a.start_time
      and v_clock < a.end_time
      and mod(
        extract(epoch from (v_clock - a.start_time))::integer,
        a.slot_minutes * 60
      ) = 0
  ) then
    raise exception 'selected time is not available';
  end if;

  insert into public.doctor_appointments (
    doctor_id, patient_id, appointment_at, patient_name, patient_phone, notes
  ) values (
    p_doctor_id, v_uid, p_appointment_at, trim(p_patient_name),
    trim(p_patient_phone), nullif(trim(coalesce(p_notes, '')), '')
  )
  returning id into v_appointment_id;

  return v_appointment_id;
exception
  when unique_violation then
    raise exception 'appointment slot already booked';
end;
$function$;

-- Administrator-only doctor onboarding and schedule management.
create or replace function public.admin_save_doctor(
  p_user_id uuid,
  p_display_name text,
  p_specialty text,
  p_clinic_name text default null,
  p_address text default null,
  p_phone text default null,
  p_bio text default null,
  p_is_active boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'admins only' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id and role <> 'admin') then
    raise exception 'valid non-admin account required';
  end if;
  insert into public.doctor_profiles (
    user_id, display_name, specialty, clinic_name, address, phone, bio, is_active
  ) values (
    p_user_id, trim(p_display_name), trim(p_specialty),
    nullif(trim(coalesce(p_clinic_name,'')), ''),
    nullif(trim(coalesce(p_address,'')), ''),
    nullif(trim(coalesce(p_phone,'')), ''),
    nullif(trim(coalesce(p_bio,'')), ''), coalesce(p_is_active, false)
  )
  on conflict (user_id) do update set
    display_name = excluded.display_name,
    specialty = excluded.specialty,
    clinic_name = excluded.clinic_name,
    address = excluded.address,
    phone = excluded.phone,
    bio = excluded.bio,
    is_active = excluded.is_active,
    updated_at = now()
  returning id into v_id;
  return v_id;
end;
$function$;

create or replace function public.admin_set_doctor_availability(
  p_doctor_id uuid,
  p_weekday smallint,
  p_start_time time,
  p_end_time time,
  p_slot_minutes smallint default 30,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'admins only' using errcode = '42501';
  end if;
  if not exists (select 1 from public.doctor_profiles where id = p_doctor_id) then
    raise exception 'doctor not found';
  end if;
  insert into public.doctor_availability (
    doctor_id, weekday, start_time, end_time, slot_minutes, is_active
  ) values (
    p_doctor_id, p_weekday, p_start_time, p_end_time,
    coalesce(p_slot_minutes, 30), coalesce(p_is_active, true)
  )
  on conflict (doctor_id, weekday, start_time, end_time)
  do update set slot_minutes = excluded.slot_minutes,
                is_active = excluded.is_active
  returning id into v_id;
  return v_id;
end;
$function$;

revoke all on function public.book_doctor_appointment(uuid,timestamptz,text,text,text) from public, anon;
grant execute on function public.book_doctor_appointment(uuid,timestamptz,text,text,text) to authenticated;
revoke all on function public.admin_save_doctor(uuid,text,text,text,text,text,text,boolean) from public, anon;
grant execute on function public.admin_save_doctor(uuid,text,text,text,text,text,text,boolean) to authenticated;
revoke all on function public.admin_set_doctor_availability(uuid,smallint,time,time,smallint,boolean) from public, anon;
grant execute on function public.admin_set_doctor_availability(uuid,smallint,time,time,smallint,boolean) to authenticated;
