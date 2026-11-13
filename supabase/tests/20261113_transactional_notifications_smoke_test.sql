-- Transactional notification smoke test.
-- Run in Supabase SQL Editor as one complete script.
-- Every change (temporary profile, appointment, activation toggle, notifications)
-- is rolled back at the end. Do not remove the final ROLLBACK.

begin;

create temporary table _notification_smoke_results (
  test_name text not null,
  expected_count integer,
  actual_count integer,
  result text not null
) on commit drop;

do $test$
declare
  v_doctor_id uuid;
  v_doctor_user_id uuid;
  v_patient_id uuid;
  v_original_active boolean;
  v_appointment_id uuid;
  v_application_user_id uuid;
  v_application_doctor_id uuid;
  v_admin_count integer;
  v_count integer;
begin
  -- Use the existing admin-owned doctor profile and existing customer account.
  select d.id, d.user_id, d.is_active
    into v_doctor_id, v_doctor_user_id, v_original_active
  from public.doctor_profiles d
  join public.profiles p on p.id = d.user_id
  where p.role = 'admin'
  order by d.created_at
  limit 1;

  select p.id into v_patient_id
  from public.profiles p
  where p.role = 'customer'
  order by p.created_at
  limit 1;

  select count(*) into v_admin_count
  from public.profiles
  where role = 'admin';

  if v_doctor_id is null then
    raise exception 'TEST STOPPED: no admin-owned doctor profile was found.';
  end if;
  if v_patient_id is null then
    raise exception 'TEST STOPPED: no customer profile was found.';
  end if;
  if v_admin_count < 1 then
    raise exception 'TEST STOPPED: no administrator profile was found.';
  end if;
  if v_doctor_user_id = v_patient_id then
    raise exception 'TEST STOPPED: doctor and patient test accounts must be different.';
  end if;

  -- Exercise activation and deactivation triggers, then restore original value.
  update public.doctor_profiles
     set is_active = not v_original_active
   where id = v_doctor_id;

  update public.doctor_profiles
     set is_active = v_original_active
   where id = v_doctor_id;

  -- Exercise appointment INSERT notifications.
  insert into public.doctor_appointments (
    doctor_id, patient_id, appointment_at,
    patient_name, patient_phone, notes, status
  ) values (
    v_doctor_id, v_patient_id, now() + interval '30 days',
    'اختبار مؤقت', '01000000000',
    'اختبار إشعارات داخل معاملة سيتم التراجع عنها', 'pending'
  )
  returning id into v_appointment_id;

  -- Exercise every appointment status notification path.
  update public.doctor_appointments set status = 'confirmed' where id = v_appointment_id;
  update public.doctor_appointments set status = 'rejected' where id = v_appointment_id;
  update public.doctor_appointments set status = 'cancelled' where id = v_appointment_id;
  update public.doctor_appointments set status = 'completed' where id = v_appointment_id;

  -- Test the doctor-application INSERT trigger only if an unused profile exists.
  select p.id into v_application_user_id
  from public.profiles p
  where not exists (
    select 1 from public.doctor_profiles d where d.user_id = p.id
  )
  order by p.created_at
  limit 1;

  if v_application_user_id is not null then
    insert into public.doctor_profiles (
      user_id, display_name, specialty, is_active, self_registered
    ) values (
      v_application_user_id, 'اختبار طبيب مؤقت', 'اختبار الإشعارات', false, true
    )
    returning id into v_application_doctor_id;

    select count(*) into v_count
    from public.notifications
    where event_type = 'doctor_application'
      and dedupe_key = 'doctor-application:' || v_application_doctor_id::text;

    insert into _notification_smoke_results
    values ('إشعار طلب انضمام الطبيب للإدارة', v_admin_count, v_count,
            case when v_count = v_admin_count then 'PASS' else 'FAIL' end);
  else
    insert into _notification_smoke_results
    values ('إشعار طلب انضمام الطبيب للإدارة', null, null,
            'SKIPPED - لا يوجد حساب اختبار غير مرتبط بملف طبيب');
  end if;

  -- Activation/deactivation notifications: two distinct state transitions.
  select count(*) into v_count
  from public.notifications
  where user_id = v_doctor_user_id
    and event_type in ('doctor_approved', 'doctor_deactivated')
    and dedupe_key in (
      'doctor-activation:' || v_doctor_id::text || ':true',
      'doctor-activation:' || v_doctor_id::text || ':false'
    );

  insert into _notification_smoke_results
  values ('اعتماد الطبيب وإيقاف تفعيله', 2, v_count,
          case when v_count = 2 then 'PASS' else 'FAIL' end);

  -- Patient receives one submission notice and four status updates.
  select count(*) into v_count
  from public.notifications
  where user_id = v_patient_id
    and related_appointment_id = v_appointment_id
    and event_type in ('appointment_submitted', 'appointment_status');

  insert into _notification_smoke_results
  values ('إشعارات المريض للحجز وتغيّر الحالة', 5, v_count,
          case when v_count = 5 then 'PASS' else 'FAIL' end);

  -- Doctor receives the new-booking notice and cancellation notice.
  select count(*) into v_count
  from public.notifications
  where user_id = v_doctor_user_id
    and related_appointment_id = v_appointment_id
    and event_type in ('appointment_requested', 'appointment_cancelled');

  insert into _notification_smoke_results
  values ('إشعارات الطبيب بطلب الحجز والإلغاء', 2, v_count,
          case when v_count = 2 then 'PASS' else 'FAIL' end);

  -- Every administrator receives the new booking and all four status changes.
  select count(*) into v_count
  from public.notifications n
  join public.profiles p on p.id = n.user_id
  where p.role = 'admin'
    and n.related_appointment_id = v_appointment_id
    and n.event_type in ('appointment_created_admin', 'appointment_status_admin');

  insert into _notification_smoke_results
  values ('إشعارات الإدارة بإنشاء الحجز وتغيّر حالته',
          v_admin_count * 5, v_count,
          case when v_count = v_admin_count * 5 then 'PASS' else 'FAIL' end);

  -- Verify the appointment reached the last test state before rollback.
  select count(*) into v_count
  from public.doctor_appointments
  where id = v_appointment_id and status = 'completed';

  insert into _notification_smoke_results
  values ('تحديث حالات الحجز حتى الاكتمال', 1, v_count,
          case when v_count = 1 then 'PASS' else 'FAIL' end);
end;
$test$;

select test_name, expected_count, actual_count, result
from _notification_smoke_results
order by test_name;

-- Mandatory: undo all test records, temporary profile, appointment and notifications.
rollback;
