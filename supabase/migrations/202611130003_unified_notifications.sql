-- Unified in-app notification center.
-- Apply after 202611130002_doctor_appointment_lifecycle.sql.
-- Notifications are written only by trusted database triggers and read by their owner.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null check (length(event_type) between 2 and 80),
  title text not null check (length(title) between 1 and 160),
  body text not null default '' check (length(body) <= 1000),
  target_url text not null default './',
  related_appointment_id uuid references public.doctor_appointments(id) on delete set null,
  dedupe_key text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint notifications_target_url_local check (
    target_url = './' or target_url like './%' or target_url like '/%'
  )
);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);
create index if not exists notifications_user_unread_idx
  on public.notifications (user_id, created_at desc)
  where read_at is null;
create unique index if not exists notifications_dedupe_uidx
  on public.notifications (user_id, dedupe_key)
  where dedupe_key is not null;

alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;

drop policy if exists notifications_read_own on public.notifications;
create policy notifications_read_own on public.notifications
for select to authenticated
using (user_id = auth.uid());

create or replace function public.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  update public.notifications
  set read_at = coalesce(read_at, now())
  where id = p_notification_id
    and user_id = auth.uid();
end;
$function$;

create or replace function public.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  update public.notifications
  set read_at = now()
  where user_id = auth.uid()
    and read_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

revoke all on function public.mark_notification_read(uuid) from public, anon;
revoke all on function public.mark_all_notifications_read() from public, anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- Internal helper: never callable directly by browser clients.
create or replace function public.create_user_notification(
  p_user_id uuid,
  p_event_type text,
  p_title text,
  p_body text,
  p_target_url text,
  p_related_appointment_id uuid,
  p_dedupe_key text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if p_user_id is null then return; end if;
  insert into public.notifications (
    user_id, event_type, title, body, target_url,
    related_appointment_id, dedupe_key
  ) values (
    p_user_id, p_event_type, p_title, coalesce(p_body, ''),
    coalesce(p_target_url, './'), p_related_appointment_id, p_dedupe_key
  )
  on conflict (user_id, dedupe_key)
    where dedupe_key is not null
  do nothing;
end;
$function$;

revoke all on function public.create_user_notification(uuid,text,text,text,text,uuid,text)
  from public, anon, authenticated;

-- New doctor application: alert every administrator, without exposing patient/doctor private data.
create or replace function public.notify_admins_of_doctor_application()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_admin record;
begin
  if coalesce(new.is_active, false) = false then
    for v_admin in select id from public.profiles where role = 'admin'
    loop
      perform public.create_user_notification(
        v_admin.id,
        'doctor_application',
        'طلب انضمام طبيب جديد',
        'يوجد طلب طبيب جديد في انتظار مراجعة الإدارة.',
        './admin-v7.html',
        null,
        'doctor-application:' || new.id::text
      );
    end loop;
  end if;
  return new;
end;
$function$;

drop trigger if exists doctor_application_notify_admins on public.doctor_profiles;
create trigger doctor_application_notify_admins
after insert on public.doctor_profiles
for each row execute function public.notify_admins_of_doctor_application();

-- Doctor activation/deactivation: inform the doctor when the review decision changes.
create or replace function public.notify_doctor_activation_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if old.is_active is distinct from new.is_active then
    perform public.create_user_notification(
      new.user_id,
      case when new.is_active then 'doctor_approved' else 'doctor_deactivated' end,
      case when new.is_active then 'تم اعتماد ملف العيادة' else 'تم إيقاف تفعيل ملف العيادة' end,
      case when new.is_active
        then 'أصبح بإمكانك استقبال طلبات الحجز من خلال التطبيق.'
        else 'ملف العيادة غير متاح للحجز حاليًا. راجع الإدارة عند الحاجة.'
      end,
      './doctors.html',
      null,
      'doctor-activation:' || new.id::text || ':' || new.is_active::text
    );
  end if;
  return new;
end;
$function$;

drop trigger if exists doctor_activation_notify_owner on public.doctor_profiles;
create trigger doctor_activation_notify_owner
after update of is_active on public.doctor_profiles
for each row execute function public.notify_doctor_activation_change();

-- Booking created: notify the clinic and administrators; confirm receipt to the patient.
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
begin
  select d.user_id, d.display_name
    into v_doctor_user_id, v_doctor_name
  from public.doctor_profiles d
  where d.id = new.doctor_id;

  if tg_op = 'INSERT' then
    perform public.create_user_notification(
      new.patient_id,
      'appointment_submitted',
      'تم استلام طلب الحجز',
      'تم إرسال طلب حجزك إلى العيادة، وستصلك رسالة عند تحديث حالته.',
      './doctors.html',
      new.id,
      'appointment-submitted:' || new.id::text
    );

    perform public.create_user_notification(
      v_doctor_user_id,
      'appointment_requested',
      'طلب حجز جديد',
      'لديك طلب حجز جديد يحتاج إلى مراجعة.',
      './doctors.html',
      new.id,
      'appointment-requested:' || new.id::text
    );

    for v_admin in select id from public.profiles where role = 'admin'
    loop
      perform public.create_user_notification(
        v_admin.id,
        'appointment_created_admin',
        'طلب حجز طبي جديد',
        'تم تسجيل طلب حجز جديد في خدمة الأطباء.',
        './admin-v7.html',
        new.id,
        'appointment-admin:' || new.id::text
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
      './doctors.html',
      new.id,
      'appointment-status:' || new.id::text || ':' || new.status
    );

    if v_doctor_user_id is not null and new.status = 'cancelled' then
      perform public.create_user_notification(
        v_doctor_user_id,
        'appointment_cancelled',
        'تم إلغاء موعد',
        'قام المريض بإلغاء أحد المواعيد المسجلة في العيادة.',
        './doctors.html',
        new.id,
        'appointment-cancelled:' || new.id::text
      );
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists doctor_appointment_notify_participants on public.doctor_appointments;
create trigger doctor_appointment_notify_participants
after insert or update of status on public.doctor_appointments
for each row execute function public.notify_doctor_appointment_events();

revoke all on function public.notify_admins_of_doctor_application() from public, anon, authenticated;
revoke all on function public.notify_doctor_activation_change() from public, anon, authenticated;
revoke all on function public.notify_doctor_appointment_events() from public, anon, authenticated;
