(function () {
  "use strict";

  const CONFIG = window.FACE_ARENA_CONFIG || {};
  const SUPABASE_URL = CONFIG.supabaseUrl || "";
  const PUBLISHABLE_KEY = CONFIG.publishableKey || "";
  const SDK_URL = "https://esm.sh/@supabase/supabase-js@2.119.0";

  let client = null;
  let currentSession = null;
  let initialized = false;
  let authSubscription = null;

  const byId = (id) => document.getElementById(id);
  const setStatus = (message, isError) => {
    const el = byId("faAuthStatus");
    if (!el) return;
    el.textContent = message || "";
    el.dataset.state = isError ? "error" : "info";
  };
  const friendlyError = (error) => {
    const message = String(error && error.message || "Неизвестная ошибка");
    if (/invalid login credentials/i.test(message)) return "Неверный email или пароль.";
    if (/user already registered/i.test(message)) return "Этот email уже зарегистрирован. Попробуйте войти.";
    if (/email not confirmed/i.test(message)) return "Подтвердите email по ссылке из письма.";
    if (/password.*(characters|length)/i.test(message)) return "Пароль должен содержать не менее 8 символов.";
    if (/unique|duplicate/i.test(message)) return "Этот никнейм уже занят.";
    return message.slice(0, 220);
  };
  const configured = () => !!(SUPABASE_URL.startsWith("https://") && PUBLISHABLE_KEY.startsWith("sb_publishable_"));

  async function ensureClient() {
    if (client) return client;
    if (!configured()) throw new Error("Supabase ещё не подключён. Нужны URL и publishable key отдельного проекта FACE ARENA.");
    const sdk = await import(SDK_URL);
    client = sdk.createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    return client;
  }

  async function refreshProfile(user) {
    if (!user || !client) return;
    const { data, error } = await client.from("profiles")
      .select("display_name, handle, avatar_path")
      .eq("id", user.id)
      .maybeSingle();
    if (error) throw error;
    if (data && typeof window.applyFaceArenaCloudProfile === "function") {
      let avatarUrl = "";
      if (data.avatar_path) {
        const publicAvatar = client.storage.from("face-arena-avatars").getPublicUrl(data.avatar_path);
        avatarUrl = publicAvatar.data.publicUrl;
      }
      window.applyFaceArenaCloudProfile({
        name: data.display_name || user.user_metadata?.display_name || "Игрок",
        handle: data.handle || "",
        avatarPath: data.avatar_path || "",
        avatarUrl,
        userId: user.id
      });
    }
  }

  async function updateSession(session) {
    currentSession = session || null;
    const signedIn = !!(session && session.user);
    const email = signedIn ? session.user.email || "Аккаунт" : "";
    const status = byId("faAuthAccount");
    if (status) status.textContent = signedIn ? ("Выполнен вход: " + email) : "Вы используете гостевой профиль.";
    const signOut = byId("faSignOut");
    if (signOut) signOut.hidden = !signedIn;
    const emailActions = document.querySelectorAll("[data-fa-auth-action]");
    emailActions.forEach((el) => { el.disabled = !configured() || signedIn; });
    const google = byId("faGoogle");
    if (google) google.disabled = !configured() || signedIn;
    if (signedIn) {
      try { await refreshProfile(session.user); }
      catch (error) { setStatus("Вход выполнен, но профиль не загрузился: " + friendlyError(error), true); }
    }
  }

  async function init() {
    if (initialized) return;
    initialized = true;
    if (!configured()) {
      setStatus("Авторизация подготовлена, но Supabase-проект FACE ARENA ещё не подключён.", false);
      updateSession(null);
      mount();
      return;
    }
    try {
      const sb = await ensureClient();
      const { data, error } = await sb.auth.getSession();
      if (error) throw error;
      await updateSession(data.session);
      mount();
      const { data: listener } = sb.auth.onAuthStateChange((event, session) => {
        currentSession = session || null;
        // Defer database reads outside the auth callback to avoid holding its internal lock.
        Promise.resolve().then(() => updateSession(session));
      });
      authSubscription = listener.subscription;
      if (new URLSearchParams(location.search).has("error_description")) {
        setStatus(new URLSearchParams(location.search).get("error_description"), true);
      }
    } catch (error) {
      setStatus("Не удалось подключить авторизацию: " + friendlyError(error), true);
    }
  }

  async function signUp() {
    try {
      const sb = await ensureClient();
      const email = (byId("faEmail")?.value || "").trim();
      const password = byId("faPassword")?.value || "";
      const name = (byId("setName")?.value || "").trim();
      if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error("Введите корректный email.");
      if (password.length < 8) throw new Error("Пароль должен содержать не менее 8 символов.");
      const { data, error } = await sb.auth.signUp({
        email, password, options: { data: { display_name: name || "Игрок" }, emailRedirectTo: location.href.split("#")[0] + "#settings" }
      });
      if (error) throw error;
      if (data.session) {
        setStatus("Аккаунт создан. Вы вошли в FACE ARENA.", false);
        await updateSession(data.session);
      } else {
        setStatus("Письмо для подтверждения отправлено на " + email + ". Подтвердите адрес и затем войдите.", false);
      }
    } catch (error) { setStatus(friendlyError(error), true); }
  }

  async function signIn() {
    try {
      const sb = await ensureClient();
      const email = (byId("faEmail")?.value || "").trim();
      const password = byId("faPassword")?.value || "";
      if (!email || !password) throw new Error("Введите email и пароль.");
      const { data, error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
      await updateSession(data.session);
      setStatus("Вход выполнен.", false);
    } catch (error) { setStatus(friendlyError(error), true); }
  }

  async function signInGoogle() {
    try {
      const sb = await ensureClient();
      const { error } = await sb.auth.signInWithOAuth({
        provider: "google",
        options: { redirectTo: location.href.split("#")[0] + "#settings" }
      });
      if (error) throw error;
    } catch (error) { setStatus(friendlyError(error), true); }
  }

  async function signOut() {
    try {
      if (!client) return;
      const { error } = await client.auth.signOut();
      if (error) throw error;
      await updateSession(null);
      if (typeof window.clearFaceArenaCloudProfile === "function") window.clearFaceArenaCloudProfile();
      setStatus("Вы вышли из аккаунта. Гостевой профиль остался на этом устройстве.", false);
    } catch (error) { setStatus(friendlyError(error), true); }
  }

  async function saveProfile(profile) {
    if (!currentSession || !client) return { skipped: true };
    const name = String(profile.name || "").trim().slice(0, 24);
    const handle = String(profile.handle || "").trim().replace(/^@/, "");
    if (!name) throw new Error("Укажите имя.");
    if (handle && !/^[A-Za-z0-9_.]{3,20}$/.test(handle)) throw new Error("Никнейм: 3–20 символов, латинские буквы, цифры, точка или подчёркивание.");
    const { error } = await client.from("profiles").upsert({
      id: currentSession.user.id, display_name: name, handle: handle || null
    }, { onConflict: "id" });
    if (error) throw error;
    return { saved: true };
  }

  async function uploadAvatar(file) {
    if (!currentSession || !client) throw new Error("Сначала войдите в аккаунт.");
    if (!file || !["image/jpeg", "image/png", "image/webp"].includes(file.type)) throw new Error("Поддерживаются JPG, PNG и WEBP.");
    if (file.size > 5 * 1024 * 1024) throw new Error("Размер аватара не должен превышать 5 МБ.");
    const userId = currentSession.user.id;
    const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
    const path = userId + "/avatar." + ext;
    const { error: uploadError } = await client.storage.from("face-arena-avatars").upload(path, file, { upsert: true, contentType: file.type });
    if (uploadError) throw uploadError;
    const { data } = client.storage.from("face-arena-avatars").getPublicUrl(path);
    const { error: profileError } = await client.from("profiles").update({ avatar_path: path }).eq("id", userId);
    if (profileError) throw profileError;
    return data.publicUrl;
  }

  function mount() {
    const signup = byId("faSignUp");
    const signin = byId("faSignIn");
    const google = byId("faGoogle");
    const logout = byId("faSignOut");
    const avatar = byId("faAvatarFile");
    const upload = byId("faUploadAvatar");
    if (signup) signup.onclick = signUp;
    if (signin) signin.onclick = signIn;
    if (google) google.onclick = signInGoogle;
    if (logout) logout.onclick = signOut;
    if (upload && avatar) upload.onclick = () => avatar.click();
    if (avatar) avatar.onchange = async () => {
      try {
        const url = await uploadAvatar(avatar.files && avatar.files[0]);
        const img = document.querySelector("#pv .pr-av img");
        if (img) img.src = url;
        setStatus("Аватар обновлён.", false);
      } catch (error) { setStatus(friendlyError(error), true); }
      avatar.value = "";
    };
    updateSession(currentSession);
    if (!configured()) {
      [signup, signin, google].forEach((el) => { if (el) el.disabled = true; });
    }
  }

  window.FaceArenaAuth = { init, mount, saveProfile, signOut, getSession: () => currentSession, isConfigured: configured };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init, { once: true });
  else init();
})();