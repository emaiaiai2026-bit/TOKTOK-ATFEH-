-- Protect privileged profile fields from every ordinary authenticated client.
-- Admin changes remain possible through trusted admin RPCs / service-role operations.
-- This is a database trigger: hiding the admin URL or changing browser code cannot bypass it.

create or replace function public.guard_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  -- Trusted backend/service-role operations have no end-user auth.uid().
  if auth.uid() is null then
    return new;
  end if;

  -- Only an existing administrator may create or modify privileged account flags.
  if not public.is_admin() then
    if tg_op = 'INSERT' then
      if new.role is distinct from 'customer'
         or coalesce(new.is_approved, false)
         or coalesce(new.is_blocked, false) then
        raise exception 'privileged profile fields require administrator approval'
          using errcode = '42501';
      end if;
    else
      if new.role is distinct from old.role
         or new.is_approved is distinct from old.is_approved
         or new.is_blocked is distinct from old.is_blocked then
        raise exception 'privileged profile fields require administrator approval'
          using errcode = '42501';
      end if;
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists guard_profile_privileges on public.profiles;
create trigger guard_profile_privileges
before insert or update on public.profiles
for each row execute function public.guard_profile_privileges();

-- The function is trigger-only; do not expose it as a callable RPC.
revoke all on function public.guard_profile_privileges() from public, anon, authenticated;
