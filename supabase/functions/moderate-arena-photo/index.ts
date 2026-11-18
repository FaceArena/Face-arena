import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

function detectImage(bytes: Uint8Array): { mime: string; ext: string } | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return { mime: "image/jpeg", ext: "jpg" };
  }
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e &&
      bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a &&
      bytes[6] === 0x1a && bytes[7] === 0x0a) {
    return { mime: "image/png", ext: "png" };
  }
  if (bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" &&
      String.fromCharCode(...bytes.slice(8, 12)) === "WEBP") {
    return { mime: "image/webp", ext: "webp" };
  }
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token || token === authHeader) return reply({ error: "Войдите в аккаунт и повторите попытку." }, 401);

    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const groqKey = Deno.env.get("GROQ_API_KEY");
    if (!url || !anonKey || !serviceKey) return reply({ error: "Сервис загрузки временно недоступен." }, 503);
    if (!groqKey) {
      console.error("[moderate-arena-photo] GROQ_API_KEY is not configured");
      return reply({ error: "Проверка фотографий временно недоступна. Попробуйте позже." }, 503);
    }

    const authClient = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: authData, error: authError } = await authClient.auth.getUser();
    if (authError || !authData.user) return reply({ error: "Сеанс завершён. Войдите снова." }, 401);
    const userId = authData.user.id;

    const form = await req.formData();
    const file = form.get("file");
    if (!(file instanceof File)) return reply({ error: "Не выбрана фотография." }, 400);
    if (file.size <= 0 || file.size > 5 * 1024 * 1024) {
      return reply({ error: "Размер фотографии не должен превышать 5 МБ." }, 413);
    }

    const bytes = new Uint8Array(await file.arrayBuffer());
    const detected = detectImage(bytes);
    if (!detected) return reply({ error: "Формат файла не поддерживается. Выберите JPEG, PNG или WebP." }, 415);

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { count, error: countError } = await admin.from("arena_photos")
      .select("id", { count: "exact", head: true })
      .eq("owner_id", userId)
      .in("status", ["queued", "matched", "champion"]);
    if (countError) throw countError;
    if ((count || 0) >= 3) return reply({ error: "Достигнут лимит: одновременно можно иметь не более 3 активных фотографий." }, 409);

    const { data: rateAllowed, error: rateError } = await admin.rpc("claim_arena_photo_moderation_attempt", {
      p_owner_id: userId,
    });
    if (rateError) throw rateError;
    if (rateAllowed !== true) {
      return reply({ error: "Слишком много попыток проверки. Подождите 10 минут и попробуйте снова." }, 429);
    }

    const groqResponse = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${groqKey}`,
        "Content-Type": "application/json",
      },
      signal: AbortSignal.timeout(30000),
      body: JSON.stringify({
        model: "qwen/qwen3.8-27b",
        temperature: 0,
        max_completion_tokens: 600,
        reasoning_effort: "none",
        // Qwen 3.8 supports JSON Object Mode, but Groq strict JSON Schema mode
        // is currently limited to GPT-OSS models. Keep schema validation server-side.
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            content: "You are a cautious image policy reviewer for a public photo-voting game. Assess only visible image content; never identify people or infer protected traits. Allow ordinary clothed portraits, fashion, sports, fitness, and non-explicit beach/swimwear photos. Reject only unmistakable explicit sexual activity, exposed intimate nudity, graphic real-world violence/gore, or clear hateful extremist propaganda. Send ambiguous, borderline, low-quality, promotional graphics, QR codes, and spam to manual review. Be conservative: uncertainty means review, not rejection. Output one JSON object only, with exactly these keys: decision (string: allow, reject, or review), confidence (number from 0 to 1), categories (array of short strings), reason (short neutral Russian string). Always include all four fields, even when the decision is review. Do not include markdown or any text outside the JSON object."
          },
          {
            role: "user",
            content: [
              {
                type: "text",
                text: "Check whether this photo is suitable for FACE ARENA public battles. Choose allow only when clearly suitable; reject only for an unmistakable severe violation; otherwise choose review. Give a short neutral reason in Russian."
              },
              {
                type: "image_url",
                image_url: { url: `data:${detected.mime};base64,${toBase64(bytes)}` }
              }
            ]
          }
        ]
      }),
    });

    if (!groqResponse.ok) {
      const providerError = await groqResponse.text();
      // Log only a short provider diagnostic; never log the API key or image payload.
      console.error("[moderate-arena-photo] Groq HTTP", groqResponse.status, providerError.slice(0, 700));
      return reply({ error: "Не удалось проверить фотографию. Попробуйте ещё раз позже." }, 503);
    }

    const groqData = await groqResponse.json();
    const message = groqData?.choices?.[0]?.message;
    const raw = message?.content;
    // Some vision-model responses include surrounding whitespace or fenced JSON.
    // Accept only a parseable JSON object; never infer an allow decision from malformed output.
    const rawText = typeof raw === "string"
      ? raw.trim()
      : Array.isArray(raw)
        ? raw.map((part: any) => typeof part?.text === "string" ? part.text : "").join("\\n").trim()
        : "";
    const jsonText = rawText.replace(/^\`\`\`(?:json)?\\s*/i, "").replace(/\\s*\`\`\`$/, "");
    const objectMatch = jsonText.match(/\\{[\\s\\S]*\\}/);
    let moderation: any = null;
    try { moderation = JSON.parse(objectMatch?.[0] || jsonText); } catch { moderation = null; }
    const valid = moderation &&
      ["allow", "reject", "review"].includes(moderation.decision) &&
      (moderation.confidence === undefined ||
        (typeof moderation.confidence === "number" && moderation.confidence >= 0 && moderation.confidence <= 1)) &&
      (moderation.categories === undefined || Array.isArray(moderation.categories)) &&
      (moderation.reason === undefined || typeof moderation.reason === "string");
    if (!valid) {
      console.error("[moderate-arena-photo] Invalid moderation response", {
        contentType: typeof raw,
        contentLength: rawText.length,
        finishReason: groqData?.choices?.[0]?.finish_reason ?? "unknown",
        hasMessage: Boolean(message),
        hasRefusal: Boolean(message?.refusal),
      });
      return reply({ error: "Не удалось проверить фотографию. Попробуйте ещё раз." }, 503);
    }

    const confidence = typeof moderation.confidence === "number" ? moderation.confidence : 0.5;
    const categories = Array.isArray(moderation.categories)
      ? moderation.categories.filter((item: unknown) => typeof item === "string").slice(0, 12)
      : [];
    const reason = typeof moderation.reason === "string" && moderation.reason.trim()
      ? moderation.reason.trim().slice(0, 500)
      : "Требуется дополнительная проверка";
    let decision = moderation.decision as "allow" | "reject" | "review";
    // Missing/low confidence always goes to manual review, never automatic approval.
    if (confidence < 0.85) decision = "review";

    const id = crypto.randomUUID();
    if (decision === "reject") {
      return reply({
        decision: "reject",
        message: "Эта фотография не подходит для участия. Выберите другую.",
      }, 422);
    }

    if (decision === "allow") {
      const objectPath = `${userId}/${id}.${detected.ext}`;
      const { error: uploadError } = await admin.storage.from("arena-photos")
        .upload(objectPath, bytes, { contentType: detected.mime, upsert: false, cacheControl: "60" });
      if (uploadError) throw uploadError;

      const { data: photoId, error: enqueueError } = await admin.rpc("enqueue_moderated_arena_photo", {
        p_owner_id: userId,
        p_object_path: objectPath,
      });
      if (enqueueError) {
        await admin.storage.from("arena-photos").remove([objectPath]);
        if (String(enqueueError.message || "").includes("Maximum 3 active")) {
          return reply({ error: "Достигнут лимит: одновременно можно иметь не более 3 активных фотографий." }, 409);
        }
        throw enqueueError;
      }
      return reply({ decision: "allow", photo_id: photoId, object_path: objectPath });
    }

    const objectPath = `moderation-pending/${userId}/${id}.${detected.ext}`;
    const { error: uploadError } = await admin.storage.from("arena-photos")
      .upload(objectPath, bytes, { contentType: detected.mime, upsert: false, cacheControl: "60" });
    if (uploadError) throw uploadError;

    const { error: reviewError } = await admin.from("arena_photo_moderation").insert({
      owner_id: userId,
      object_path: objectPath,
      decision: "pending",
      reason,
      categories,
      confidence,
    });
    if (reviewError) {
      await admin.storage.from("arena-photos").remove([objectPath]);
      throw reviewError;
    }

    return reply({
      decision: "review",
      message: "Фотография отправлена администратору на проверку. После одобрения она появится в очереди.",
    }, 202);
  } catch (error) {
    console.error("[moderate-arena-photo]", error instanceof Error ? error.message : "Unknown error");
    return reply({ error: "Не удалось обработать фотографию. Попробуйте ещё раз позже." }, 500);
  }
});
