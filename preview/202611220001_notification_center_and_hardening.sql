-- خدماتنا: تغييرات القاعدة بتاعت مركز الإشعارات والتأمين (نوفمبر 2026)
-- ده سجل للتغييرات اللي اتنفذت فعلًا على Supabase، بالترتيب.

-- 1) سحب صلاحية التنفيذ من anon/public عن الدوال اللي لازم المستخدم يكون مسجّل لها
revoke execute on function public.request_ride(double precision, double precision, text, double precision, double precision, text, text) from public, anon;
grant execute on function public.request_ride(double precision, double precision, text, double precision, double precision, text, text) to authenticated;
revoke execute on function public.set_ride_status(uuid, text) from public, anon;
grant execute on function public.set_ride_status(uuid, text) to authenticated;
revoke execute on function public.notify_new_ride() from public, anon, authenticated;
revoke execute on function public.notify_ride_requeued() from public, anon, authenticated;
revoke execute on function public.notify_ride_status() from public, anon, authenticated;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- 2) تضييق قراءة profiles: بيانات الطرف التاني متاحة أثناء الرحلة وبعدها بـ 30 دقيقة فقط
alter policy "read profiles" on public.profiles
using (
  (id = auth.uid())
  or is_admin()
  or exists (
    select 1 from public.rides r
    where r.driver_id = profiles.id and r.customer_id = auth.uid()
      and (r.status in ('accepted','arrived','started')
           or (r.status in ('completed','cancelled')
               and coalesce(r.completed_at, r.accepted_at, r.created_at) > now() - interval '30 minutes'))
  )
  or exists (
    select 1 from public.rides r
    where r.customer_id = profiles.id and r.driver_id = auth.uid()
      and (r.status in ('accepted','arrived','started')
           or (r.status in ('completed','cancelled')
               and coalesce(r.completed_at, r.accepted_at, r.created_at) > now() - interval '30 minutes'))
  )
);

-- 3) إلغاء اشتراك جهاز من الحساب الحالي (يُستخدم عند الخروج وتجديد الاشتراك)
create or replace function public.remove_push_subscription(p_endpoint text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
end;
$$;
revoke execute on function public.remove_push_subscription(text) from public, anon;
grant execute on function public.remove_push_subscription(text) to authenticated;

-- 4) Trigger إرسال الـ Push من مركز الإشعارات: السر من app_secrets (مفيش مفاتيح مكتوبة جوه الـ Trigger)
create or replace function public.notify_user_push_fn()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare s text;
begin
  select value into s from public.app_secrets where key = 'webhook_secret';
  if s is null then return new; end if;
  begin
    perform net.http_post(
      url := 'https://nhxenquczoaxytxskdsa.supabase.co/functions/v1/notify-user-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', 'sb_publishable_kQuBBDlxf1Z-6PSwbNBgCw_4F_pRUaT',
        'Authorization', 'Bearer sb_publishable_kQuBBDlxf1Z-6PSwbNBgCw_4F_pRUaT',
        'x-webhook-secret', s),
      body := jsonb_build_object('record', to_jsonb(new)));
  exception when others then null;
  end;
  return new;
end $$;
revoke execute on function public.notify_user_push_fn() from public, anon, authenticated;
drop trigger if exists notify_user_push on public.notifications;
create trigger notify_user_push after insert on public.notifications
for each row execute function public.notify_user_push_fn();

-- 5) تصنيف الإشعارات حسب الخدمة (خدمة جديدة = سطر جديد في CASE)
alter table public.notifications add column if not exists category text not null default 'general';

create or replace function public.notification_category_for(p_event_type text)
returns text language sql immutable set search_path to 'public' as $$
  select case split_part(coalesce(p_event_type, ''), '_', 1)
    when 'ride' then 'rides' when 'driver' then 'drivers'
    when 'doctor' then 'medical' when 'appointment' then 'medical'
    when 'restaurant' then 'restaurants' when 'grocery' then 'grocery'
    when 'test' then 'system' else 'general' end
$$;

create or replace function public.notifications_set_category()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.category is null or new.category = 'general' then
    new.category := public.notification_category_for(new.event_type);
  end if;
  return new;
end $$;
revoke execute on function public.notifications_set_category() from public, anon, authenticated;
drop trigger if exists notifications_set_category on public.notifications;
create trigger notifications_set_category before insert on public.notifications
for each row execute function public.notifications_set_category();
update public.notifications set category = public.notification_category_for(event_type) where category = 'general';

-- 6) أحداث الرحلات تدخل مركز الإشعارات (مسار واحد: جدول notifications ثم Push)
create or replace function public.notify_ride_events()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare drv_name text; acc_key text; who uuid;
begin
  if new.status is not distinct from old.status then return new; end if;
  begin
    who := coalesce(new.driver_id, old.driver_id);
    select coalesce(nullif(trim(name), ''), 'السواق') into drv_name from public.profiles where id = who;
    drv_name := coalesce(drv_name, 'السواق');
    acc_key := coalesce(to_char(new.accepted_at, 'YYYYMMDDHH24MISSUS'), to_char(old.accepted_at, 'YYYYMMDDHH24MISSUS'), '0');
    if new.status = 'accepted' then
      perform public.create_user_notification(new.customer_id, 'ride_accepted', 'السواق قبل طلبك', drv_name || ' في الطريق إليك', './rider-unified.html', null, 'ride:' || new.id || ':accepted:' || acc_key);
    elsif new.status = 'arrived' then
      perform public.create_user_notification(new.customer_id, 'ride_arrived', 'السواق وصل', drv_name || ' عند نقطة الركوب', './rider-unified.html', null, 'ride:' || new.id || ':arrived:' || acc_key);
    elsif new.status = 'started' then
      perform public.create_user_notification(new.customer_id, 'ride_started', 'بدأت رحلتك', 'نتمنى لك رحلة سعيدة', './rider-unified.html', null, 'ride:' || new.id || ':started:' || acc_key);
    elsif new.status = 'completed' then
      perform public.create_user_notification(new.customer_id, 'ride_completed', 'وصلت بالسلامة', 'الأجرة ' || new.price || ' جنيه كاش للسواق', './rider-unified.html', null, 'ride:' || new.id || ':completed:' || acc_key);
    elsif new.status = 'requested' and old.status in ('accepted', 'arrived') then
      perform public.create_user_notification(new.customer_id, 'ride_driver_cancelled', 'السواق ألغى الرحلة', 'بندوّر لك على سواق تاني', './rider-unified.html', null, 'ride:' || new.id || ':requeued:' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'));
    elsif new.status = 'cancelled' then
      if new.cancel_reason = 'timeout' then
        perform public.create_user_notification(new.customer_id, 'ride_no_driver', 'مفيش سواق متاح دلوقتي', 'محدش قبل طلبك. جرّب تاني بعد شوية', './rider-unified.html', null, 'ride:' || new.id || ':timeout');
      elsif old.status in ('accepted', 'arrived', 'started') and old.driver_id is not null then
        perform public.create_user_notification(old.driver_id, 'ride_customer_cancelled', 'العميل ألغى الرحلة', 'تم إلغاء الرحلة من العميل', './driver-v22.html', null, 'ride:' || new.id || ':cancelled');
      end if;
    end if;
  exception when others then null; -- الإشعار ما يوقفش تحديث الرحلة أبدًا
  end;
  return new;
end $$;
revoke execute on function public.notify_ride_events() from public, anon, authenticated;
drop trigger if exists rides_notify_events on public.rides;
create trigger rides_notify_events after update of status on public.rides
for each row execute function public.notify_ride_events();
drop trigger if exists rides_status_notify on public.rides; -- المسار القديم المباشر

-- 7) التحديث اللحظي لجدول الإشعارات
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- 8) إشعار السواق لما الإدارة تعتمده أو توقفه
create or replace function public.notify_driver_approval_change()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if coalesce(new.is_driver, false) = true and old.is_approved is distinct from new.is_approved then
    begin
      if new.is_approved then
        perform public.create_user_notification(new.id, 'driver_approved', 'تم اعتماد حسابك كسواق', 'تقدر دلوقتي تبدأ استقبال الطلبات من صفحة السواقين.', './driver-v22.html', null, 'driver-approved:' || new.id::text || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'));
      else
        perform public.create_user_notification(new.id, 'driver_suspended', 'تم إيقاف حسابك كسواق', 'تواصل مع الإدارة لمعرفة السبب.', './driver-v22.html', null, 'driver-suspended:' || new.id::text || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'));
      end if;
    exception when others then null;
    end;
  end if;
  return new;
end $$;
revoke execute on function public.notify_driver_approval_change() from public, anon, authenticated;
drop trigger if exists driver_approval_notify on public.profiles;
create trigger driver_approval_notify after update of is_approved on public.profiles
for each row execute function public.notify_driver_approval_change();
