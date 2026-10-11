do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'orders',
    'order_items',
    'menu_items',
    'queue_state',
    'notifications',
    'profiles'
  ]
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    exception
      when duplicate_object then null;
    end;
  end loop;
end;
$$;

create unique index if not exists menu_items_name_category_unique
on public.menu_items (lower(name), lower(category));
