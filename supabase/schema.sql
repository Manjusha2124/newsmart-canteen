create extension if not exists pgcrypto;

create type public.app_role as enum ('student', 'staff', 'admin');
create type public.order_status as enum ('Placed', 'Accepted', 'Preparing', 'Ready', 'Completed', 'Cancelled');

create sequence public.order_token_seq start with 1001;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 100),
  phone text not null check (phone ~ '^[0-9]{10}$'),
  role public.app_role not null default 'student',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.menu_categories (
  name text primary key check (length(trim(name)) between 1 and 60),
  created_at timestamptz not null default now()
);

create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  category text not null references public.menu_categories(name) on update cascade,
  description text not null default '',
  price numeric(10,2) not null check (price > 0),
  emoji text not null default '🍽️',
  is_vegetarian boolean not null default true,
  prep_minutes integer not null default 5 check (prep_minutes between 1 and 240),
  is_popular boolean not null default false,
  is_available boolean not null default true,
  is_active boolean not null default true,
  image_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  token text not null unique default ('C' || nextval('public.order_token_seq')::text),
  user_id uuid not null references public.profiles(id),
  student_name text not null,
  status public.order_status not null default 'Placed',
  note text not null default '' check (length(note) <= 300),
  payment_method text not null default 'Cash at Counter' check (payment_method = 'Cash at Counter'),
  payment_status text not null default 'Pay at counter'
    check (payment_status in ('Pay at counter', 'Paid (cash)')),
  total numeric(10,2) not null default 0 check (total >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  menu_item_id uuid references public.menu_items(id) on delete set null,
  item_name text not null,
  unit_price numeric(10,2) not null check (unit_price > 0),
  quantity integer not null check (quantity between 1 and 50)
);

create table public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, menu_item_id)
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid references public.orders(id) on delete cascade,
  message text not null check (length(message) between 1 and 500),
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.queue_state (
  singleton boolean primary key default true check (singleton),
  walk_in_count integer not null default 0 check (walk_in_count between 0 and 10000),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

insert into public.queue_state (singleton) values (true);

create index orders_user_created_idx on public.orders (user_id, created_at desc);
create index orders_active_idx on public.orders (created_at) where status in ('Placed', 'Accepted', 'Preparing', 'Ready');
create index order_items_order_idx on public.order_items (order_id);
create index notifications_user_created_idx on public.notifications (user_id, created_at desc);
create index menu_items_visible_idx on public.menu_items (category, name) where is_active;

insert into public.menu_categories (name)
select distinct category from public.menu_items
on conflict (name) do nothing;

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger menu_items_set_updated_at
before update on public.menu_items
for each row execute function public.set_updated_at();

create trigger orders_set_updated_at
before update on public.orders
for each row execute function public.set_updated_at();

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, phone)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Student'),
    coalesce(new.raw_user_meta_data ->> 'phone', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create function public.has_staff_access()
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

create function public.has_admin_access()
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

create function public.has_active_access()
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

create function public.place_order(p_items jsonb, p_note text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_order_id uuid;
  v_item jsonb;
  v_menu_item public.menu_items%rowtype;
  v_quantity integer;
  v_total numeric(10,2) := 0;
begin
  if v_user_id is null then
    raise exception 'Sign in to place an order';
  end if;
  if not exists (select 1 from public.profiles where id = v_user_id and is_active and role = 'student') then
    raise exception 'Only student accounts can place orders';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'Order must contain between 1 and 50 distinct items';
  end if;
  if length(coalesce(p_note, '')) > 300 then
    raise exception 'Order note is too long';
  end if;

  insert into public.orders (user_id, student_name, note)
  select p.id, p.display_name, left(coalesce(p_note, ''), 300)
  from public.profiles p where p.id = v_user_id
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if (v_item ->> 'id') is null or (v_item ->> 'qty') !~ '^[0-9]+$' then
      raise exception 'Invalid item in order';
    end if;
    v_quantity := (v_item ->> 'qty')::integer;
    if v_quantity < 1 or v_quantity > 50 then
      raise exception 'Item quantity must be between 1 and 50';
    end if;

    select * into v_menu_item
    from public.menu_items
    where id = (v_item ->> 'id')::uuid and is_active and is_available
    for share;
    if not found then
      raise exception 'An item is unavailable; refresh the menu and try again';
    end if;

    insert into public.order_items (order_id, menu_item_id, item_name, unit_price, quantity)
    values (v_order_id, v_menu_item.id, v_menu_item.name, v_menu_item.price, v_quantity);
    v_total := v_total + v_menu_item.price * v_quantity;
  end loop;

  update public.orders set total = v_total where id = v_order_id;
  return v_order_id;
end;
$$;

create function public.advance_order(p_order_id uuid)
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

create function public.get_queue_status()
returns table (walk_in_count integer, active_preorders bigint, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select q.walk_in_count,
         (select count(*) from public.orders o
          where o.status in ('Placed', 'Accepted', 'Preparing', 'Ready')),
         q.updated_at
  from public.queue_state q
  where q.singleton and (select auth.uid()) is not null;
$$;

create function public.set_walk_in_queue_count(p_count integer)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated_at timestamptz;
begin
  if not public.has_staff_access() then
    raise exception 'Staff access required';
  end if;
  if p_count < 0 or p_count > 10000 then
    raise exception 'Queue count must be between 0 and 10000';
  end if;

  update public.queue_state
  set walk_in_count = p_count, updated_at = now(), updated_by = auth.uid()
  where singleton
  returning updated_at into v_updated_at;
  return v_updated_at;
end;
$$;

create function public.admin_save_category(p_name text)
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
  insert into public.menu_categories (name)
  values (v_name)
  on conflict (name) do nothing;
end;
$$;

create function public.admin_rename_category(p_old_name text, p_new_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_name text := trim(coalesce(p_old_name, ''));
  v_new_name text := trim(coalesce(p_new_name, ''));
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if length(v_new_name) not between 1 and 60 then
    raise exception 'Category name must be between 1 and 60 characters';
  end if;
  update public.menu_categories set name = v_new_name
  where name = v_old_name;
  if not found then
    raise exception 'Category not found';
  end if;
end;
$$;

create function public.admin_delete_category(p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  if exists (select 1 from public.menu_items where category = p_name) then
    raise exception 'Reassign or archive all menu items in this category first';
  end if;
  delete from public.menu_categories where name = trim(coalesce(p_name, ''));
  if not found then
    raise exception 'Category not found';
  end if;
end;
$$;

create function public.admin_save_menu_item(p_item jsonb)
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

create function public.admin_archive_menu_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_admin_access() then
    raise exception 'Admin access required';
  end if;
  update public.menu_items set is_active = false, is_available = false
  where id = p_item_id and is_active;
  if not found then
    raise exception 'Menu item not found';
  end if;
end;
$$;

create function public.set_menu_availability(p_item_id uuid, p_is_available boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_staff_access() then
    raise exception 'Staff access required';
  end if;
  update public.menu_items set is_available = p_is_available where id = p_item_id and is_active;
  if not found then
    raise exception 'Menu item not found';
  end if;
end;
$$;

create function public.set_user_role(p_user_id uuid, p_role public.app_role)
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
  from public.profiles
  where id = p_user_id
  for update;
  if not found then
    raise exception 'Profile not found';
  end if;

  if v_current_role = 'admin' and v_is_active and p_role <> 'admin' then
    perform pg_advisory_xact_lock(160041, 1);
    if (select count(*) from public.profiles where role = 'admin' and is_active) <= 1 then
      raise exception 'The last admin account cannot be demoted';
    end if;
  end if;

  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

create function public.admin_set_profile_active(p_user_id uuid, p_is_active boolean)
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
  from public.profiles
  where id = p_user_id
  for update;
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

create function public.admin_cancel_order(p_order_id uuid)
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

  update public.orders
  set status = 'Cancelled'
  where id = p_order_id and status in ('Placed', 'Accepted', 'Preparing', 'Ready')
  returning * into v_order;
  if not found then
    raise exception 'Order not found or no longer cancellable';
  end if;

  insert into public.notifications (user_id, order_id, message)
  values (v_order.user_id, v_order.id, 'Your order ' || v_order.token || ' was cancelled by the canteen.');
end;
$$;

alter table public.profiles enable row level security;
alter table public.menu_categories enable row level security;
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
on public.menu_categories for select to authenticated
using (public.has_active_access());

create policy "Authenticated users can read active menu items"
on public.menu_items for select to authenticated
using (is_active and public.has_active_access());

create policy "Students and staff can read own or operational orders"
on public.orders for select to authenticated
using (public.has_active_access() and (user_id = (select auth.uid()) or public.has_staff_access()));

create policy "Order owners and staff can read order items"
on public.order_items for select to authenticated
using (
  exists (
    select 1 from public.orders o
    where o.id = order_id
      and public.has_active_access()
      and (o.user_id = (select auth.uid()) or public.has_staff_access())
  )
);

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
on public.queue_state for select to authenticated
using (public.has_active_access());

revoke all on public.profiles, public.menu_items, public.orders, public.order_items,
  public.menu_categories, public.favorites, public.notifications, public.queue_state from anon, authenticated;

grant select on public.profiles, public.menu_items, public.orders, public.order_items,
  public.menu_categories, public.notifications, public.queue_state to authenticated;
grant select, insert, delete on public.favorites to authenticated;
grant update (is_read) on public.notifications to authenticated;

revoke all on function public.place_order(jsonb, text) from public, anon;
revoke all on function public.advance_order(uuid) from public, anon;
revoke all on function public.get_queue_status() from public, anon;
revoke all on function public.set_walk_in_queue_count(integer) from public, anon;
revoke all on function public.admin_save_menu_item(jsonb) from public, anon;
revoke all on function public.admin_archive_menu_item(uuid) from public, anon;
revoke all on function public.set_menu_availability(uuid, boolean) from public, anon;
revoke all on function public.set_user_role(uuid, public.app_role) from public, anon;
revoke all on function public.admin_save_category(text) from public, anon;
revoke all on function public.admin_rename_category(text, text) from public, anon;
revoke all on function public.admin_delete_category(text) from public, anon;
revoke all on function public.admin_set_profile_active(uuid, boolean) from public, anon;
revoke all on function public.admin_cancel_order(uuid) from public, anon;
revoke all on function public.has_active_access() from public, anon;

grant execute on function public.place_order(jsonb, text) to authenticated;
grant execute on function public.advance_order(uuid) to authenticated;
grant execute on function public.get_queue_status() to authenticated;
grant execute on function public.set_walk_in_queue_count(integer) to authenticated;
grant execute on function public.admin_save_menu_item(jsonb) to authenticated;
grant execute on function public.admin_archive_menu_item(uuid) to authenticated;
grant execute on function public.set_menu_availability(uuid, boolean) to authenticated;
grant execute on function public.set_user_role(uuid, public.app_role) to authenticated;
grant execute on function public.admin_save_category(text) to authenticated;
grant execute on function public.admin_rename_category(text, text) to authenticated;
grant execute on function public.admin_delete_category(text) to authenticated;
grant execute on function public.admin_set_profile_active(uuid, boolean) to authenticated;
grant execute on function public.admin_cancel_order(uuid) to authenticated;

revoke all on function public.has_staff_access() from public, anon;
revoke all on function public.has_admin_access() from public, anon;
grant execute on function public.has_staff_access() to authenticated;
grant execute on function public.has_admin_access() to authenticated;
grant execute on function public.has_active_access() to authenticated;
