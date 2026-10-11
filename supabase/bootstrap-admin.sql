-- One-time first-admin setup.
-- Replace the email below with the confirmed email of the account you created
-- through the app, then run this in Supabase SQL Editor as the project owner.
-- Never expose a service-role key or database password in the app.
do $bootstrap$
declare
  v_email text := lower(trim('REPLACE_WITH_CONFIRMED_ADMIN_EMAIL'));
  v_user_id uuid;
begin
  if v_email = '' or v_email = 'replace_with_confirmed_admin_email' then
    raise exception 'Replace the placeholder with the confirmed account email';
  end if;

  if exists (select 1 from public.profiles where role = 'admin') then
    raise exception 'An admin already exists; assign additional roles from the admin panel';
  end if;

  select u.id
  into v_user_id
  from auth.users u
  join public.profiles p on p.id = u.id
  where lower(u.email) = v_email
    and u.email_confirmed_at is not null
    and p.role = 'student';

  if v_user_id is null then
    raise exception 'No confirmed student account found for that email';
  end if;

  update public.profiles
  set role = 'admin'
  where id = v_user_id and role = 'student';

  if not found then
    raise exception 'Could not promote the selected account';
  end if;

  raise notice 'Initial admin account has been promoted';
end;
$bootstrap$;
