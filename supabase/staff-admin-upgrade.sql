-- Apply to projects that already ran schema.sql before the last-admin guard
-- was added. This leaves all existing data and role assignments unchanged.
create or replace function public.advance_order(p_order_id uuid)
returns public.order_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.order_status;
  v_order public.orders%rowtype;
  v_message text;
begin
  if not public.has_staff_access() then
    raise exception 'Staff access required';
  end if;

  update public.orders
  set status = case status
        when 'Placed' then 'Accepted'::public.order_status
        when 'Accepted' then 'Preparing'::public.order_status
        when 'Preparing' then 'Ready'::public.order_status
        when 'Ready' then 'Completed'::public.order_status
        else status
      end,
      payment_status = case
        when status = 'Ready' then 'Paid (cash)'
        else payment_status
      end
  where id = p_order_id
  returning * into v_order;

  if v_order.id is null then
    raise exception 'Order not found';
  end if;

  v_status := v_order.status;
  v_message := case v_status
    when 'Accepted' then 'Your order ' || v_order.token || ' was accepted.'
    when 'Preparing' then 'Your order ' || v_order.token || ' is being prepared.'
    when 'Ready' then 'Your order ' || v_order.token || ' is ready for pickup.'
    when 'Completed' then 'Your order ' || v_order.token || ' is complete.'
    else null
  end;
  if v_message is not null then
    insert into public.notifications (user_id, order_id, message)
    values (v_order.user_id, v_order.id, v_message);
  end if;
  return v_status;
end;
$$;

create or replace function public.set_user_role(p_user_id uuid, p_role public.app_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_role public.app_role;
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if p_role is null then
    raise exception 'A role is required';
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'Admins cannot remove their own admin access';
  end if;

  select role into v_current_role
  from public.profiles
  where id = p_user_id
  for update;
  if not found then
    raise exception 'Profile not found';
  end if;

  if v_current_role = 'admin' and p_role <> 'admin' then
    perform pg_advisory_xact_lock(160041, 1);
    if (select count(*) from public.profiles where role = 'admin') <= 1 then
      raise exception 'The last admin account cannot be demoted';
    end if;
  end if;

  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

revoke all on function public.set_user_role(uuid, public.app_role) from public, anon;
grant execute on function public.set_user_role(uuid, public.app_role) to authenticated;
