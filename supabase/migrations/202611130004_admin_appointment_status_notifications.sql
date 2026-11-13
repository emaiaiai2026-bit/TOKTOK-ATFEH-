-- Persist the appointment-status administrator notifications already applied
-- in the live database, so fresh environments receive the same behavior.

create or replace function public.notify_doctor_appointment_events()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_doctor_user_id uuid;
  v_doctor_name text;
  v_admin record;
  v_admin_title text;
  v_admin_body text;
begin
  select d.user_id, d.display_name
    into v_doctor_user_id, v_doctor_name
  from public.doctor_profiles d
  where d.id = new.doctor_id;

  if tg_op = 'INSERT' then
    perform public.create_user_notification(
      new.patient_id, 'appointment_submitted', 'تم استلام طلب الحجز',
      'تم إرسال طلب حجزك إلى العيادة، وستصلك رسالة عند تحديث حالته.',
      './doctors.html', new.id, 'appointment-submitted:' || new.id::text
    );

    perform public.create_user_notification(
      v_doctor_user_id, 'appointment_requested', 'طلب حجز جديد',
      'لديك طلب حجز جديد يحتاج إلى مراجعة.',
      './doctors.html', new.id, 'appointment-requested:' || new.id::text
    );

    for v_admin in select id from public.profiles where role = 'admin'
    loop
      perform public.create_user_notification(
        v_admin.id, 'appointment_created_admin', 'طلب حجز طبي جديد',
        'تم تسجيل طلب حجز جديد في خدمة الأطباء.',
        './admin-v7.html', new.id, 'appointment-admin:' || new.id::text
      );
    end loop;

  elsif old.status is distinct from new.status then
    perform public.create_user_notification(
      new.patient_id,
      'appointment_status',
      case new.status
        when 'confirmed' then 'تم تأكيد الحجز'
        when 'rejected' then 'تعذر قبول الحجز'
        when 'cancelled' then 'تم إلغاء الحجز'
        when 'completed' then 'تم تسجيل اكتمال الموعد'
        else 'تم تحديث حالة الحجز'
      end,
      'تم تحديث حالة حجزك لدى ' || coalesce(v_doctor_name, 'الطبيب') || '.',
      './doctors.html', new.id,
      'appointment-status:' || new.id::text || ':' || new.status
    );

    if v_doctor_user_id is not null and new.status = 'cancelled' then
      perform public.create_user_notification(
        v_doctor_user_id, 'appointment_cancelled', 'تم إلغاء موعد',
        'قام المريض بإلغاء أحد المواعيد المسجلة في العيادة.',
        './doctors.html', new.id, 'appointment-cancelled:' || new.id::text
      );
    end if;

    if new.status in ('confirmed', 'rejected', 'cancelled', 'completed') then
      v_admin_title := case new.status
        when 'confirmed' then 'تم تأكيد حجز طبي'
        when 'rejected' then 'تم رفض حجز طبي'
        when 'cancelled' then 'تم إلغاء حجز طبي'
        when 'completed' then 'اكتمل موعد طبي'
      end;

      v_admin_body := case new.status
        when 'confirmed' then 'قام الطبيب بتأكيد أحد الحجوزات.'
        when 'rejected' then 'قام الطبيب برفض أحد الحجوزات.'
        when 'cancelled' then 'قام المريض بإلغاء أحد الحجوزات.'
        when 'completed' then 'تم تسجيل اكتمال أحد المواعيد.'
      end;

      for v_admin in select id from public.profiles where role = 'admin'
      loop
        perform public.create_user_notification(
          v_admin.id,
          'appointment_status_admin',
          v_admin_title,
          v_admin_body,
          './admin-v7.html',
          new.id,
          'appointment-admin-status:' || new.id::text || ':' || new.status
        );
      end loop;
    end if;
  end if;

  return new;
end;
$function$;

revoke all on function public.notify_doctor_appointment_events()
  from public, anon, authenticated;
