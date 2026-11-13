-- Allow a doctor to maintain their own clinic profile without changing approval status.
create or replace function public.doctor_update_own_profile(
  p_display_name text,
  p_specialty text,
  p_clinic_name text default null,
  p_address text default null,
  p_phone text default null,
  p_bio text default null
) returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 v_uid uuid:=auth.uid();
 v_phone text:=nullif(trim(coalesce(p_phone,'')),'');
begin
 if v_uid is null then raise exception 'not authenticated' using errcode='42501'; end if;
 if length(trim(coalesce(p_display_name,''))) not between 2 and 120 then
   raise exception 'doctor name must be between 2 and 120 characters';
 end if;
 if length(trim(coalesce(p_specialty,''))) not between 2 and 120 then
   raise exception 'specialty must be between 2 and 120 characters';
 end if;
 if v_phone is null or v_phone !~ '^01[0125][0-9]{8}$' then
   raise exception 'valid Egyptian phone required';
 end if;
 if length(coalesce(p_bio,''))>1000 then raise exception 'bio too long'; end if;
 update public.doctor_profiles set
   display_name=trim(p_display_name),
   specialty=trim(p_specialty),
   clinic_name=nullif(trim(coalesce(p_clinic_name,'')),''),
   address=nullif(trim(coalesce(p_address,'')),''),
   phone=v_phone,
   bio=nullif(trim(coalesce(p_bio,'')),''),
   updated_at=now()
 where user_id=v_uid;
 if not found then raise exception 'doctor profile not found' using errcode='P0002'; end if;
end $$;
revoke all on function public.doctor_update_own_profile(text,text,text,text,text,text) from public,anon;
grant execute on function public.doctor_update_own_profile(text,text,text,text,text,text) to authenticated;
