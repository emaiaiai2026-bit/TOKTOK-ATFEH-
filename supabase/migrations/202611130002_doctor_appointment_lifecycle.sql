-- Secure lifecycle actions for doctor appointments.
-- Apply after 202611130001_allow_admin_doctor_application.sql.
-- All client writes remain behind SECURITY DEFINER RPCs.

create or replace function public.set_doctor_appointment_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists doctor_appointments_set_updated_at
  on public.doctor_appointments;

create trigger doctor_appointments_set_updated_at
before update on public.doctor_appointments
for each row
execute function public.set_doctor_appointment_updated_at();

-- The doctor who owns the clinic may confirm or reject a pending appointment.
create or replace function public.doctor_respond_to_appointment(
  p_appointment_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_appointment_at timestamptz;
  v_new_status text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if p_action is null or p_action not in ('confirm', 'reject') then
    raise exception 'invalid appointment action';
  end if;

  v_new_status := case p_action
    when 'confirm' then 'confirmed'
    when 'reject' then 'rejected'
  end;

  select a.status, a.appointment_at
    into v_status, v_appointment_at
  from public.doctor_appointments a
  join public.doctor_profiles d on d.id = a.doctor_id
  where a.id = p_appointment_id
    and d.user_id = v_uid
  for update of a;

  if not found then
    raise exception 'appointment not found or access denied'
      using errcode = '42501';
  end if;

  if v_status <> 'pending' then
    raise exception 'only pending appointments can be changed';
  end if;

  if p_action = 'confirm' and v_appointment_at <= now() then
    raise exception 'past appointments cannot be confirmed';
  end if;

  update public.doctor_appointments
  set status = v_new_status
  where id = p_appointment_id;
end;
$function$;

-- A patient may cancel only their own pending/confirmed future appointment.
create or replace function public.patient_cancel_doctor_appointment(
  p_appointment_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_appointment_at timestamptz;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select status, appointment_at
    into v_status, v_appointment_at
  from public.doctor_appointments
  where id = p_appointment_id
    and patient_id = v_uid
  for update;

  if not found then
    raise exception 'appointment not found or access denied'
      using errcode = '42501';
  end if;

  if v_status not in ('pending', 'confirmed') then
    raise exception 'this appointment can no longer be cancelled';
  end if;

  if v_appointment_at <= now() then
    raise exception 'past appointments cannot be cancelled';
  end if;

  update public.doctor_appointments
  set status = 'cancelled'
  where id = p_appointment_id;
end;
$function$;

revoke all on function public.set_doctor_appointment_updated_at() from public, anon, authenticated;
revoke all on function public.doctor_respond_to_appointment(uuid, text) from public, anon;
revoke all on function public.patient_cancel_doctor_appointment(uuid) from public, anon;

grant execute on function public.doctor_respond_to_appointment(uuid, text) to authenticated;
grant execute on function public.patient_cancel_doctor_appointment(uuid) to authenticated;
