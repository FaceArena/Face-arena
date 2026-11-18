import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token || token === authHeader) return reply({ error: "Authentication required" }, 401);
    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete" }, 500);

    const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: authData, error: authError } = await authClient.auth.getUser();
    if (authError || !authData.user) return reply({ error: "Invalid session" }, 401);
    if (authData.user.app_metadata?.role !== "admin") return reply({ error: "Administrator access required" }, 403);

    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const body = await req.json().catch(() => ({}));
    if (body?.action === "list_users") {
      const authUsers: any[] = [];
      for (let page = 1; ; page++) {
        const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
        if (error) throw error;
        const batch = data?.users || [];
        authUsers.push(...batch);
        if (batch.length < 1000) break;
      }
      const ids = authUsers.map((u: any) => u.id);
      const { data: profiles, error: profileError } = ids.length
        ? await admin.from("arena_profiles").select("user_id,display_name,handle,is_verified,created_at").in("user_id", ids)
        : { data: [], error: null };
      if (profileError) throw profileError;
      const profileMap = new Map((profiles || []).map((p: any) => [p.user_id, p]));
      const users = authUsers.map((u: any) => {
        const profile: any = profileMap.get(u.id);
        return {
          user_id: u.id,
          email: u.email || null,
          created_at: u.created_at || null,
          last_sign_in_at: u.last_sign_in_at || null,
          display_name: profile?.display_name || u.user_metadata?.display_name || u.user_metadata?.name || "Участник",
          handle: profile?.handle || null,
          is_verified: profile?.is_verified === true,
          profile_exists: !!profile
        };
      }).sort((a: any, b: any) => String(b.created_at || "").localeCompare(String(a.created_at || "")));
      return reply({ users });
    }

    if (body?.action === "set_verified") {
      const userId = String(body?.user_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) return reply({ error: "Invalid user id" }, 400);
      if (typeof body?.is_verified !== "boolean") return reply({ error: "is_verified must be boolean" }, 400);
      const { data: profile, error: updateError } = await admin.from("arena_profiles")
        .update({ is_verified: body.is_verified, updated_at: new Date().toISOString() })
        .eq("user_id", userId)
        .select("user_id,display_name,handle,is_verified")
        .maybeSingle();
      if (updateError) throw updateError;
      if (!profile) return reply({ error: "Profile not found for this user" }, 404);
      return reply({ ok: true, user: profile });
    }

    if (body?.action === "list_results") {
      const rows: any[] = [];
      for (let offset = 0; ; offset += 1000) {
        const { data, error } = await admin.from("arena_results")
          .select("id,battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,left_votes,right_votes,total_votes,opening,no_contest,completed_at,is_hidden,hidden_at")
          .order("completed_at", { ascending: false }).order("id", { ascending: false })
          .range(offset, offset + 999);
        if (error) throw error;
        rows.push(...(data || []));
        if (!data || data.length < 1000) break;
      }
      const photoIds = [...new Set(rows.flatMap((r: any) => [r.left_photo_id, r.right_photo_id]).filter(Boolean))];
      const { data: photoRows, error: photoError } = photoIds.length
        ? await admin.from("arena_photos").select("id,owner_id").in("id", photoIds)
        : { data: [], error: null };
      if (photoError) throw photoError;
      const ownerIds = [...new Set((photoRows || []).map((p: any) => p.owner_id).filter(Boolean))];
      const { data: profileRows, error: profileError } = ownerIds.length
        ? await admin.from("arena_profiles").select("user_id,display_name,handle").in("user_id", ownerIds)
        : { data: [], error: null };
      if (profileError) throw profileError;
      const photoMap = new Map((photoRows || []).map((p: any) => [p.id, p]));
      const profileMap = new Map((profileRows || []).map((p: any) => [p.user_id, p]));
      const results = rows.map((r: any) => {
        const lp: any = photoMap.get(r.left_photo_id);
        const rp: any = photoMap.get(r.right_photo_id);
        const lprof: any = lp ? profileMap.get(lp.owner_id) : null;
        const rprof: any = rp ? profileMap.get(rp.owner_id) : null;
        return { ...r, left_name: lprof?.display_name || "Участник", left_handle: lprof?.handle || "user", right_name: rprof?.display_name || "Участник", right_handle: rprof?.handle || "user" };
      });
      return reply({ results });
    }

    if (body?.action === "set_result_hidden") {
      const resultId = String(body?.result_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(resultId)) return reply({ error: "Invalid result id" }, 400);
      if (typeof body?.is_hidden !== "boolean") return reply({ error: "is_hidden must be boolean" }, 400);
      const { data: result, error: updateError } = await admin.from("arena_results")
        .update({ is_hidden: body.is_hidden, hidden_at: body.is_hidden ? new Date().toISOString() : null })
        .eq("id", resultId).select("id,is_hidden,hidden_at").maybeSingle();
      if (updateError) throw updateError;
      if (!result) return reply({ error: "Result not found" }, 404);
      return reply({ ok: true, result });
    }

    if (body?.action === "hide_all_results") {
      if (body?.confirmation !== "HIDE_ALL_ARENA_RESULTS") return reply({ error: "Explicit confirmation required" }, 400);
      const { data, error } = await admin.from("arena_results")
        .update({ is_hidden: true, hidden_at: new Date().toISOString() })
        .eq("is_hidden", false).select("id");
      if (error) throw error;
      return reply({ ok: true, hidden: data?.length || 0 });
    }

    if (body?.action === "list") {
      const photos: any[] = [];
      for (let offset = 0; ; offset += 1000) {
        const { data, error } = await admin.from("arena_photos").select("id,owner_id,object_path,status,created_at")
          .order("created_at", { ascending: false }).range(offset, offset + 999);
        if (error) throw error;
        photos.push(...(data || []));
        if (!data || data.length < 1000) break;
      }
      const ownerIds = [...new Set((photos || []).map((p: any) => p.owner_id))];
      const { data: profiles, error: profileError } = ownerIds.length
        ? await admin.from("arena_profiles").select("user_id,display_name,handle").in("user_id", ownerIds)
        : { data: [], error: null };
      if (profileError) throw profileError;
      const profileMap = new Map((profiles || []).map((p: any) => [p.user_id, p]));
      const rows = await Promise.all((photos || []).map(async (p: any) => {
        const { data } = await admin.storage.from("arena-photos").createSignedUrl(p.object_path, 300);
        const owner: any = profileMap.get(p.owner_id);
        return { ...p, display_name: owner?.display_name || "Участник", handle: owner?.handle || "user", image_url: data?.signedUrl || null };
      }));
      return reply({ photos: rows });
    }

    if (body?.action === "delete_one") {
      const photoId = String(body?.photo_id || "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(photoId)) return reply({ error: "Invalid photo id" }, 400);
      const { data: photo, error: findError } = await admin.from("arena_photos").select("id,object_path").eq("id", photoId).maybeSingle();
      if (findError) throw findError;
      if (!photo) return reply({ error: "Photo not found" }, 404);
      const { error: storageError } = await admin.storage.from("arena-photos").remove([photo.object_path]);
      if (storageError) throw storageError;
      const { error: updateError } = await admin.from("arena_photos").update({ status: "removed", updated_at: new Date().toISOString() }).eq("id", photoId);
      if (updateError) throw updateError;
      return reply({ ok: true, deleted: 1, metadata_preserved: true });
    }

    if (body?.action === "delete_all") {
      if (body?.confirmation !== "DELETE_ALL_ARENA_PHOTOS") return reply({ error: "Explicit confirmation required" }, 400);
      const photos: any[] = [];
      for (let offset = 0; ; offset += 1000) {
        const { data, error } = await admin.from("arena_photos").select("id,object_path")
          .order("created_at", { ascending: true }).range(offset, offset + 999);
        if (error) throw error;
        photos.push(...(data || []));
        if (!data || data.length < 1000) break;
      }
      let deleted = 0;
      for (let i = 0; i < (photos || []).length; i += 100) {
        const batch = photos!.slice(i, i + 100);
        const paths = [...new Set(batch.map((p: any) => p.object_path))];
        if (paths.length) {
          const { error: storageError } = await admin.storage.from("arena-photos").remove(paths);
          if (storageError) return reply({ error: storageError.message, deleted, total: photos!.length, partial: true }, 502);
        }
        const { error: updateError } = await admin.from("arena_photos").update({ status: "removed", updated_at: new Date().toISOString() }).in("id", batch.map((p: any) => p.id));
        if (updateError) return reply({ error: updateError.message, deleted, total: photos!.length, partial: true }, 502);
        deleted += batch.length;
      }
      return reply({ ok: true, deleted, total: photos?.length || 0, metadata_preserved: true });
    }
    return reply({ error: "Unknown action" }, 400);
  } catch (error) {
    console.error("[admin-photos]", error);
    return reply({ error: error instanceof Error ? error.message : "Internal server error" }, 500);
  }
});
