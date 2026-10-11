-- Upgrade an existing Smart Canteen database without dropping order/user data.
-- Run once in Supabase SQL Editor after confirming the existing schema.

do $preflight$
declare
  v_values text;
begin
  select string_agg(distinct coalesce(payment_status, '<NULL>'), ', ' order by coalesce(payment_status, '<NULL>'))
  into v_values
  from public.orders
  where payment_status is null
    or payment_status not in ('Pay at counter', 'Paid (cash)');
  if v_values is not null then
    raise exception 'Migration stopped before changes: orders contain legacy payment_status values (%). Review and map these values before retrying.', v_values;
  end if;
end;
$preflight$;

alter table public.profiles
  add column if not exists is_active boolean not null default true;

create table if not exists public.menu_categories (
  name text primary key,
  created_at timestamptz not null default now()
);

insert into public.menu_categories (name)
select distinct category
from public.menu_items
where category is not null
on conflict (name) do nothing;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.menu_items'::regclass
      and conname = 'menu_items_category_fkey'
  ) then
    alter table public.menu_items
      add constraint menu_items_category_fkey
      foreign key (category) references public.menu_categories(name)
      on update cascade;
  end if;
end;
$migration$;

do $migration$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.orders'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%payment_status%'
  loop
    execute format('alter table public.orders drop constraint %I', v_constraint.conname);
  end loop;
end;
$migration$;

alter table public.orders
  add constraint orders_payment_status_check
  check (payment_status in ('Pay at counter', 'Paid (cash)'));

create or replace function public.has_staff_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and is_active and role in ('staff', 'admin')
  );
$$;

create or replace function public.has_admin_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and is_active and role = 'admin'
  );
$$;

create or replace function public.has_active_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and is_active
  );
$$;

create or replace function public.advance_order(p_order_id uuid)
returns public.order_status
language plpgsql
security definer
set search_path = ''
as $$
declare
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

  if not found then
    raise exception 'Order not found';
  end if;

  v_message := case v_order.status
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
  return v_order.status;
end;
$$;

create or replace function public.admin_save_category(p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if length(v_name) not between 1 and 60 then
    raise exception 'Category name must be between 1 and 60 characters';
  end if;
  insert into public.menu_categories (name) values (v_name)
  on conflict (name) do nothing;
end;
$$;

create or replace function public.admin_rename_category(p_old_name text, p_new_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_name text := trim(coalesce(p_new_name, ''));
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if length(v_new_name) not between 1 and 60 then
    raise exception 'Category name must be between 1 and 60 characters';
  end if;
  update public.menu_categories set name = v_new_name
  where name = trim(coalesce(p_old_name, ''));
  if not found then
    raise exception 'Category not found';
  end if;
end;
$$;

create or replace function public.admin_delete_category(p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if exists (select 1 from public.menu_items where category = trim(coalesce(p_name, ''))) then
    raise exception 'Reassign or archive all menu items in this category first';
  end if;
  delete from public.menu_categories where name = trim(coalesce(p_name, ''));
  if not found then
    raise exception 'Category not found';
  end if;
end;
$$;

create or replace function public.admin_save_menu_item(p_item jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_name text := trim(coalesce(p_item ->> 'name', ''));
  v_category text := trim(coalesce(p_item ->> 'category', ''));
  v_description text := coalesce(p_item ->> 'description', '');
  v_price numeric(10,2);
  v_emoji text := coalesce(nullif(p_item ->> 'emoji', ''), '🍽️');
  v_prep_minutes integer;
  v_vegetarian boolean := coalesce((p_item ->> 'is_vegetarian')::boolean, true);
  v_popular boolean := coalesce((p_item ->> 'is_popular')::boolean, false);
  v_available boolean := coalesce((p_item ->> 'is_available')::boolean, true);
  v_image_url text := nullif(p_item ->> 'image_url', '');
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if length(v_name) not between 1 and 120 or length(v_category) not between 1 and 60
    or length(v_description) > 500 or length(v_emoji) > 16 then
    raise exception 'Invalid menu item fields';
  end if;
  if coalesce(p_item ->> 'price', '') !~ '^[0-9]+(\.[0-9]{1,2})?$'
    or coalesce(p_item ->> 'prep_minutes', '') !~ '^[0-9]+$' then
    raise exception 'Invalid price or preparation time';
  end if;
  v_price := (p_item ->> 'price')::numeric;
  v_prep_minutes := (p_item ->> 'prep_minutes')::integer;
  if v_price <= 0 or v_prep_minutes not between 1 and 240 then
    raise exception 'Price or preparation time is out of range';
  end if;
  if v_image_url is not null and v_image_url !~ '^https://'
    or length(coalesce(v_image_url, '')) > 2048 then
    raise exception 'Image URL must be HTTPS and at most 2048 characters';
  end if;

  insert into public.menu_categories (name)
  values (v_category)
  on conflict (name) do nothing;

  if nullif(p_item ->> 'id', '') is null then
    insert into public.menu_items
      (name, category, description, price, emoji, is_vegetarian, prep_minutes, is_popular, is_available, image_url)
    values
      (v_name, v_category, v_description, v_price, v_emoji, v_vegetarian, v_prep_minutes, v_popular, v_available, v_image_url)
    returning id into v_id;
  else
    v_id := (p_item ->> 'id')::uuid;
    update public.menu_items
    set name = v_name, category = v_category, description = v_description, price = v_price,
        emoji = v_emoji, is_vegetarian = v_vegetarian, prep_minutes = v_prep_minutes,
        is_popular = v_popular, is_available = v_available, image_url = v_image_url
    where id = v_id and is_active;
    if not found then
      raise exception 'Menu item not found';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_set_profile_active(p_user_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
  v_was_active boolean;
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if p_is_active is null then
    raise exception 'An account status is required';
  end if;
  if p_user_id = auth.uid() and not p_is_active then
    raise exception 'Admins cannot disable their own account';
  end if;

  select role, is_active into v_role, v_was_active
  from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'Profile not found';
  end if;

  if v_role = 'admin' and v_was_active and not p_is_active then
    perform pg_advisory_xact_lock(160041, 1);
    if (select count(*) from public.profiles where role = 'admin' and is_active) <= 1 then
      raise exception 'The last active admin account cannot be disabled';
    end if;
  end if;
  update public.profiles set is_active = p_is_active where id = p_user_id;
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
  v_is_active boolean;
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

  select role, is_active into v_current_role, v_is_active
  from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'Profile not found';
  end if;
  if v_current_role = 'admin' and v_is_active and p_role <> 'admin' then
    perform pg_advisory_xact_lock(160041, 1);
    if (select count(*) from public.profiles where role = 'admin' and is_active) <= 1 then
      raise exception 'The last active admin account cannot be demoted';
    end if;
  end if;
  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

create or replace function public.admin_cancel_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  update public.orders set status = 'Cancelled'
  where id = p_order_id and status in ('Placed', 'Accepted', 'Preparing', 'Ready')
  returning * into v_order;
  if not found then
    raise exception 'Order not found or no longer cancellable';
  end if;
  insert into public.notifications (user_id, order_id, message)
  values (v_order.user_id, v_order.id, 'Your order ' || v_order.token || ' was cancelled by the canteen.');
end;
$$;

alter table public.menu_categories enable row level security;
do $policies$
declare
  v_policy record;
begin
  for v_policy in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = any (array[
        'profiles', 'menu_categories', 'menu_items', 'orders',
        'order_items', 'favorites', 'notifications', 'queue_state'
      ])
  loop
    execute format(
      'drop policy %I on %I.%I',
      v_policy.policyname, v_policy.schemaname, v_policy.tablename
    );
  end loop;
end;
$policies$;

alter table public.profiles enable row level security;
alter table public.menu_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.favorites enable row level security;
alter table public.notifications enable row level security;
alter table public.queue_state enable row level security;

create policy "Users can read their profile"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.has_admin_access());
create policy "Authenticated users can read menu categories"
on public.menu_categories for select to authenticated using (public.has_active_access());
create policy "Authenticated users can read active menu items"
on public.menu_items for select to authenticated using (is_active and public.has_active_access());
create policy "Students and staff can read own or operational orders"
on public.orders for select to authenticated
using (public.has_active_access() and (user_id = (select auth.uid()) or public.has_staff_access()));
create policy "Order owners and staff can read order items"
on public.order_items for select to authenticated
using (exists (
  select 1 from public.orders o
  where o.id = order_id and public.has_active_access()
    and (o.user_id = (select auth.uid()) or public.has_staff_access())
));
create policy "Users manage their own favorites"
on public.favorites for all to authenticated
using (user_id = (select auth.uid()) and public.has_active_access())
with check (user_id = (select auth.uid()) and public.has_active_access());
create policy "Users can read their own notifications"
on public.notifications for select to authenticated
using (user_id = (select auth.uid()) and public.has_active_access());
create policy "Users can mark their own notifications read"
on public.notifications for update to authenticated
using (user_id = (select auth.uid()) and public.has_active_access())
with check (user_id = (select auth.uid()) and public.has_active_access());
create policy "Signed-in users can read queue status"
on public.queue_state for select to authenticated using (public.has_active_access());

revoke all on public.profiles, public.menu_items, public.orders, public.order_items,
  public.menu_categories, public.favorites, public.notifications, public.queue_state
  from public, anon, authenticated;
grant select on public.profiles, public.menu_items, public.orders, public.order_items,
  public.menu_categories, public.notifications, public.queue_state to authenticated;
grant select, insert, delete on public.favorites to authenticated;
grant update (is_read) on public.notifications to authenticated;
grant select on public.menu_categories to authenticated;

revoke all on function public.has_active_access() from public, anon;
revoke all on function public.admin_save_category(text) from public, anon;
revoke all on function public.admin_rename_category(text, text) from public, anon;
revoke all on function public.admin_delete_category(text) from public, anon;
revoke all on function public.admin_save_menu_item(jsonb) from public, anon;
revoke all on function public.admin_set_profile_active(uuid, boolean) from public, anon;
revoke all on function public.set_user_role(uuid, public.app_role) from public, anon;
revoke all on function public.admin_cancel_order(uuid) from public, anon;
revoke all on function public.has_staff_access() from public, anon;
revoke all on function public.has_admin_access() from public, anon;
revoke all on function public.place_order(jsonb, text) from public, anon;
revoke all on function public.get_queue_status() from public, anon;
revoke all on function public.set_walk_in_queue_count(integer) from public, anon;
revoke all on function public.admin_archive_menu_item(uuid) from public, anon;
revoke all on function public.set_menu_availability(uuid, boolean) from public, anon;
grant execute on function public.has_active_access() to authenticated;
grant execute on function public.has_staff_access() to authenticated;
grant execute on function public.has_admin_access() to authenticated;
grant execute on function public.place_order(jsonb, text) to authenticated;
grant execute on function public.get_queue_status() to authenticated;
grant execute on function public.set_walk_in_queue_count(integer) to authenticated;
grant execute on function public.admin_archive_menu_item(uuid) to authenticated;
grant execute on function public.set_menu_availability(uuid, boolean) to authenticated;
grant execute on function public.admin_save_category(text) to authenticated;
grant execute on function public.admin_rename_category(text, text) to authenticated;
grant execute on function public.admin_delete_category(text) to authenticated;
grant execute on function public.admin_save_menu_item(jsonb) to authenticated;
grant execute on function public.admin_set_profile_active(uuid, boolean) to authenticated;
grant execute on function public.set_user_role(uuid, public.app_role) to authenticated;
grant execute on function public.admin_cancel_order(uuid) to authenticated;
