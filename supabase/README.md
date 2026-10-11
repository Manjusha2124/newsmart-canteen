# Supabase setup

The Smart Canteen frontend uses Supabase Auth and the database functions and
row-level security policies in `schema.sql`. Do not use it for real orders
until you have completed the setup below and tested the deployed site.

## Create the project

1. Create a Supabase project in an account controlled by the canteen or project
   owner. Save the database password in a password manager.
2. In the Supabase Dashboard, open **SQL Editor**, paste the contents of
   `schema.sql`, and run it once. It creates the initial schema and is not an
   idempotent repeatable migration. If you already ran it, do not run it again.
3. Run `realtime.sql` in the SQL Editor. This safely enables the live update
   publication for the app's tables and adds a uniqueness guard for menu items.
4. Under **Authentication → Providers → Email**, enable email/password sign-in
   and email confirmation for real accounts.
5. The frontend is now wired to Supabase Auth. Create the canteen owner's
   account in the app and confirm its email. The auth trigger creates a student
   profile using the submitted `display_name` and 10-digit `phone` metadata.
6. Open `bootstrap-admin.sql`, replace the email placeholder with that
   confirmed account's email, and run the script once in the Supabase SQL
   Editor. It promotes only a confirmed student account and refuses to run if
   an admin already exists. Never promote a public signup automatically.
7. Sign in as the owner. In **Admin Panel → Team**, grant staff roles to
   trusted canteen employees. The database prevents removing the final admin;
   role changes are enforced server-side, not just hidden in the UI.
8. If this project already has a database, back it up first and do not rerun
   `schema.sql`. If the hosted schema is missing `profiles.is_active` or the
   current admin/category workflows, review and run
   `migrations/202610110001_live_staff_admin.sql` in the SQL Editor. It replaces
   policies on the app tables with the role-aware policies in `schema.sql`.
   The migration stops before making changes if it finds legacy payment status
   values; review those values before retrying rather than deleting or guessing
   at historical payment data. Then run `realtime.sql` to enable live role,
   order, menu, notification, and queue updates. `realtime.sql` can safely be
   run again. `staff-admin-upgrade.sql` is only the older, limited role-guard
   patch and is not a substitute for the full migration.
9. The project's URL and publishable key are in `config.js`. If the app reports
   an invalid API key, copy both again from the same Supabase project's API
   settings. A publishable key is safe to use in a browser; never use a
   `service_role` key.
10. Sign in as the admin and use the **Import starter menu** action once if the
   menu is empty. Then use the admin account page to grant staff access.
11. Test registration, email confirmation, sign-in, menu display, cash-at-counter
   ordering, staff order status changes, and live queue updates before taking
   real orders.

## Staff and admin workflows

- Staff can view live orders, advance each order through Accepted, Preparing,
  Ready, and Completed, maintain the physical walk-in count, and mark menu
  items unavailable when needed.
- Admins can manage menu items, review orders and totals, see team accounts,
  and grant or revoke staff access.
- All writes go through role-checked Postgres functions. Row-level security
  limits student data and order visibility, and the browser never receives a
  privileged database credential.

## Security boundary

- Never put the `service_role` key, database password, or other secret in
  `index.html`, frontend configuration, Git, or GitHub Pages.
- Row-level security is enabled on application tables. Order creation,
  processing, menu availability, role changes, and walk-in queue updates use
  database functions that validate the signed-in role.
- Checkout is cash-at-counter only in the schema. No card or UPI transaction
  is processed by this project.
- Staff must update the walk-in queue count. The database does not measure
  people physically waiting on its own.
- The frontend now uses Supabase for accounts, menu, orders, favorites,
  notifications, role management, and queue state. Cart contents remain local
  to each signed-in browser until an order is submitted.
- The app supports cash-at-counter orders only. Do not collect online payment
  details through this site.
- Staff must update the physical walk-in queue count; the software cannot
  measure people waiting in line automatically.
- GitHub Pages can host the static frontend, but deployment, email delivery,
  domain configuration, and end-to-end production testing are separate steps.
