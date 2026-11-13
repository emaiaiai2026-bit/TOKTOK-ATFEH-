-- Doctor self-service clinic operations and multi-shift weekly schedules.
-- Additive migration: preserves existing doctor_availability and appointments.
create extension if not exists btree_gist;

create table if not exists public.doctor_work_shifts (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.doctor_profiles(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time time not null,
  slot_minutes integer not null default 30 check (slot_minutes between 10 and 180),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

create index if not exists doctor_work_shifts_lookup
  on public.doctor_work_shifts(doctor_id, weekday, is_active, start_time);

-- Database-level guard: even concurrent requests cannot create overlapping active shifts.
alter table public.doctor_work_shifts
  drop constraint if exists doctor_work_shifts_no_overlap;
alter table public.doctor_work_shifts
  add constraint doctor_work_shifts_no_overlap
  exclude using gist (
    doctor_id with =,
    weekday with =,
    int4range(extract(epoch from start_time)::integer, extract(epoch from end_time)::integer, '[)') with &&
  ) where (is_active);

-- Preserve the already-configured legacy weekly hours as the first shift.
insert into public.doctor_work_shifts(doctor_id,weekday,start_time,end_time,slot_minutes,is_active)
select a.doctor_id,a.weekday,a.start_time,a.end_time,a.slot_minutes,a.is_active
from public.doctor_availability a
where not exists (
  select 1 from public.doctor_work_shifts s
  where s.doctor_id=a.doctor_id and s.weekday=a.weekday
    and s.start_time=a.start_time and s.end_time=a.end_time
);

alter table public.doctor_work_shifts enable row level security;
drop policy if exists doctor_work_shifts_read_active on public.doctor_work_shifts;
create policy doctor_work_shifts_read_active on public.doctor_work_shifts
for select to anon, authenticated using (is_active);
drop policy if exists doctor_work_shifts_owner_read on public.doctor_work_shifts;
create policy doctor_work_shifts_owner_read on public.doctor_work_shifts
for select to authenticated using (
  exists(select 1 from public.doctor_profiles d
         where d.id=doctor_id and d.user_id=auth.uid())
);

create or replace function public.doctor_save_work_shift(
  p_weekday smallint,p_start_time time,p_end_time time,p_slot_minutes integer,
  p_shift_id uuid default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_uid uuid:=auth.uid(); v_doctor uuid; v_id uuid;
begin
 if v_uid is null then raise exception 'not authenticated' using errcode='42501'; end if;
 select id into v_doctor from public.doctor_profiles
 where user_id=v_uid and is_active=true;
 if v_doctor is null then raise exception 'doctor account is not approved'; end if;
 if p_weekday not between 0 and 6 or p_end_time<=p_start_time
    or p_slot_minutes not between 10 and 180 then
   raise exception 'invalid shift details';
 end if;
 if exists(select 1 from public.doctor_work_shifts s
   where s.doctor_id=v_doctor and s.is_active
     and (p_shift_id is null or s.id<>p_shift_id)
     and s.weekday=p_weekday
     and p_start_time<s.end_time and p_end_time>s.start_time) then
   raise exception 'shift overlaps another active shift';
 end if;
 if p_shift_id is null then
   insert into public.doctor_work_shifts(doctor_id,weekday,start_time,end_time,slot_minutes)
   values(v_doctor,p_weekday,p_start_time,p_end_time,p_slot_minutes) returning id into v_id;
 else
   update public.doctor_work_shifts set weekday=p_weekday,start_time=p_start_time,
     end_time=p_end_time,slot_minutes=p_slot_minutes
   where id=p_shift_id and doctor_id=v_doctor returning id into v_id;
   if v_id is null then raise exception 'shift not found'; end if;
 end if;
 return v_id;
end $$;

create or replace function public.doctor_delete_work_shift(p_shift_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if not exists(select 1 from public.doctor_profiles d
   join public.doctor_work_shifts s on s.doctor_id=d.id
   where d.user_id=auth.uid() and d.is_active and s.id=p_shift_id) then
   raise exception 'shift not found or access denied' using errcode='42501';
 end if;
 update public.doctor_work_shifts set is_active=false where id=p_shift_id;
end $$;

-- Appointment requests must match an active shift and an exact slot boundary.
create or replace function public.validate_doctor_appointment_shift()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_local timestamp; v_weekday integer; v_time time; v_match boolean;
begin
 v_local:=new.appointment_at at time zone 'Africa/Cairo';
 v_weekday:=extract(dow from v_local)::integer;
 v_time:=v_local::time;
 select exists(
   select 1 from public.doctor_work_shifts s
   where s.doctor_id=new.doctor_id and s.is_active and s.weekday=v_weekday
     and v_time>=s.start_time and v_time<s.end_time
     and mod(extract(epoch from (v_time-s.start_time))::integer, s.slot_minutes*60)=0
     and v_time + make_interval(mins=>s.slot_minutes)<=s.end_time
 ) into v_match;
 if not v_match then raise exception 'appointment time is outside an active doctor shift'; end if;
 return new;
end $$;
drop trigger if exists doctor_appointment_validate_shift on public.doctor_appointments;
create trigger doctor_appointment_validate_shift
before insert on public.doctor_appointments
for each row execute function public.validate_doctor_appointment_shift();

revoke all on function public.doctor_save_work_shift(smallint,time,time,integer,uuid) from public,anon;
revoke all on function public.doctor_delete_work_shift(uuid) from public,anon;
revoke all on function public.validate_doctor_appointment_shift() from public,anon,authenticated;
grant execute on function public.doctor_save_work_shift(smallint,time,time,integer,uuid) to authenticated;
grant execute on function public.doctor_delete_work_shift(uuid) to authenticated;
