import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return respond(405, { error: "Method not allowed" });
  }

  const authorization = request.headers.get("Authorization");
  const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) {
    console.error("Staff invitation function is missing required Supabase secrets");
    return respond(500, { error: "Staff invitations are not configured" });
  }
  if (!token) {
    return respond(401, { error: "Sign in as an administrator to invite staff" });
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: "Bearer " + token } },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser(token);
  if (userError || !userData.user) {
    return respond(401, { error: "Your session is invalid or expired" });
  }
  const { data: callerProfile, error: profileError } = await userClient
    .from("profiles")
    .select("role,is_active")
    .eq("id", userData.user.id)
    .single();
  if (profileError || callerProfile?.role !== "admin" || !callerProfile.is_active) {
    return respond(403, { error: "Active admin access is required to invite staff" });
  }

  let body: { name?: unknown; email?: unknown; phone?: unknown };
  try {
    body = await request.json();
  } catch {
    return respond(400, { error: "Request body must be valid JSON" });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return respond(400, { error: "Request body must be a JSON object" });
  }
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const phone = typeof body.phone === "string" ? body.phone.trim() : "";
  if (name.length < 1 || name.length > 100 || !/^\S+@\S+\.\S+$/.test(email) ||
      !/^\d{10}$/.test(phone)) {
    return respond(400, { error: "Enter a valid name, email, and 10-digit phone number" });
  }

  const adminClient = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: inviteData, error: inviteError } = await adminClient.auth.admin
    .inviteUserByEmail(email, { data: { display_name: name, phone } });
  if (inviteError || !inviteData.user) {
    console.error("Staff invitation failed:", inviteError?.message || "Invite returned no user");
    return respond(400, { error: "Could not send the invitation. Check whether the email is already registered and email delivery is configured." });
  }

  const { data: updatedProfiles, error: roleError } = await adminClient
    .from("profiles")
    .update({ role: "staff", is_active: true })
    .eq("id", inviteData.user.id)
    .select("id");
  if (roleError || !updatedProfiles?.length) {
    console.error("Could not assign invited account the staff role:", roleError?.message || "Profile was not created");
    await adminClient.auth.admin.deleteUser(inviteData.user.id);
    return respond(500, { error: "Invitation was created but staff authorization failed; the incomplete account was rolled back" });
  }

  return respond(200, { message: "Staff invitation sent" });
});
