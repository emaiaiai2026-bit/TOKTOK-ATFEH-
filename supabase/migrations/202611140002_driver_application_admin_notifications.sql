-- Notify every administrator when a unified account requests driver activation.
-- The existing request_driver_activation() RPC flips profiles.is_driver from false to true.
-- This trigger creates durable in-app notifications; Push delivery is handled separately
-- by the notifications INSERT webhook / notify-user-push Edge Function.

create or replace function public.notify_admins_of_driver_application()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_admin record;
  v_dedupe text;
begin
  if coalesce(old.is_driver, false) = false
     and coalesce(new.is_driver, false) = true
     and new.role is distinct from 'admin' then
    v_dedupe := 'driver-application:' || new.id::text || ':' ||
      to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDDHH24MISSMS');

    for v_admin in
      select id from public.profiles where role = 'admin'
    loop
      perform public.create_user_notification(
        v_admin.id,
        'driver_application',
        'طلب تفعيل سائق جديد',
        'يوجد طلب سائق جديد في انتظار مراجعة الإدارة.',
        './admin-v7.html?tab=drivers',
        null,
        v_dedupe
      );
    end loop;
  end if;
  return new;
end;
$function$;

drop trigger if exists driver_application_notify_admins on public.profiles;
create trigger driver_application_notify_admins
after update of is_driver on public.profiles
for each row
execute function public.notify_admins_of_driver_application();

revoke all on function public.notify_admins_of_driver_application()
from public, anon, authenticated;
