(() => {
  const SUPABASE_URL = "https://nvvkmjeobnnxlrpiuisf.supabase.co";
  const SUPABASE_KEY = "sb_publishable_-a7Qjy5NL3ZUaKfLpIi4Dg_x2hzmNKE";
  const WORKER_URL = "https://face-arena-preview.9mmm77v2jj.workers.dev";
  const EVENT = "face-arena-snapshot";

  class FaceArenaSync {
    constructor() {
      this.client = null;
      this.user = null;
      this.channel = null;
      this.ready = false;
      this.loading = false;
      this.lastSnapshot = null;
    }

    async init() {
      if (!window.supabase?.createClient) {
        this.showFatal("Не удалось загрузить клиент Supabase. Проверьте подключение к сети.");
        return;
      }
      this.client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
      });
      this.mountAuthGate();
      this.client.auth.onAuthStateChange((_event, session) => {
        queueMicrotask(async () => {
          this.user = session?.user || null;
          this.ready = !!this.user;
          this.renderAuthGate();
          if (this.user) {
            await this.loadSnapshot();
            this.subscribe();
          } else {
            this.unsubscribe();
            this.dispatch(null);
          }
        });
      });
      const { data, error } = await this.client.auth.getSession();
      if (error) this.showMessage(error.message);
      this.user = data.session?.user || null;
      this.ready = !!this.user;
      this.renderAuthGate();
      if (this.user) {
        await this.loadSnapshot();
        this.subscribe();
      }
    }

    isOnline() { return !!this.client && !!this.user && this.ready; }
    getUser() { return this.user; }

    mountAuthGate() {
      if (document.getElementById("fa-auth-gate")) return;
      const style = document.createElement("style");
      style.textContent = `
        #fa-auth-gate{position:fixed;inset:0;z-index:99999;display:none;align-items:center;justify-content:center;padding:20px;background:rgba(5,5,5,.96);backdrop-filter:blur(18px)}
        #fa-auth-gate.on{display:flex}
        #fa-auth-card{width:min(100%,420px);padding:26px 22px;background:#101010;border:1px solid #262626;border-radius:20px}
        #fa-auth-card .fa-logo{font:800 13px Unbounded,Arial,sans-serif;letter-spacing:.1em;margin-bottom:28px}
        #fa-auth-card h2{font:800 23px Unbounded,Arial,sans-serif;margin:0 0 8px}
        #fa-auth-card p{color:#999;font-size:13px;margin:0 0 18px}
        #fa-auth-card input{display:block;width:100%;margin:10px 0;padding:14px 13px;border-radius:10px;border:1px solid #303030;background:#080808;color:#fff;font:600 14px Manrope,Arial,sans-serif;outline:none}
        #fa-auth-card input:focus{border-color:#3478ff}
        #fa-auth-card button{width:100%;padding:13px;border:0;border-radius:10px;background:#fff;color:#050505;font:800 12px Unbounded,Arial,sans-serif;margin-top:9px;cursor:pointer}
        #fa-auth-card button.secondary{background:#171717;color:#fff;border:1px solid #303030}
        #fa-auth-card button:disabled{opacity:.45}
        #fa-auth-error{min-height:20px;color:#ff5a5a;font-size:12px;margin-top:10px}
        #fa-auth-toggle{display:block;text-align:center;color:#aaa;background:none!important;border:0!important;font:600 12px Manrope,Arial,sans-serif!important}
        #fa-auth-name{display:none}
      `;
      document.head.appendChild(style);
      const gate = document.createElement("div");
      gate.id = "fa-auth-gate";
      gate.innerHTML = `
        <div id="fa-auth-card">
          <div class="fa-logo"><span style="color:#ff3434">F</span><span style="color:#3478ff">A</span> FACE ARENA</div>
          <h2 id="fa-auth-title">Войти в арену</h2>
          <p id="fa-auth-desc">Войдите, чтобы участвовать в общих битвах и сохранять результаты на всех устройствах.</p>
          <input id="fa-auth-name" autocomplete="nickname" maxlength="32" placeholder="Ваше имя">
          <input id="fa-auth-email" type="email" autocomplete="email" placeholder="Email">
          <input id="fa-auth-password" type="password" autocomplete="current-password" placeholder="Пароль (от 8 символов)">
          <button id="fa-auth-submit">Войти</button>
          <button id="fa-auth-google" class="secondary">Продолжить с Google</button>
          <button id="fa-auth-toggle" class="secondary">Создать аккаунт</button>
          <div id="fa-auth-error" role="status" aria-live="polite"></div>
        </div>`;
      document.body.appendChild(gate);
      this.authMode = "signin";
      document.getElementById("fa-auth-toggle").onclick = () => {
        this.authMode = this.authMode === "signin" ? "signup" : "signin";
        this.renderAuthGate();
      };
      document.getElementById("fa-auth-submit").onclick = () => this.submitAuth();
      document.getElementById("fa-auth-google").onclick = () => this.googleAuth();
      gate.addEventListener("keydown", e => {
        if (e.key === "Enter") this.submitAuth();
      });
    }

    renderAuthGate() {
      const gate = document.getElementById("fa-auth-gate");
      if (!gate) return;
      gate.classList.toggle("on", !this.user);
      const signup = this.authMode === "signup";
      document.getElementById("fa-auth-title").textContent = signup ? "Создать аккаунт" : "Войти в арену";
      document.getElementById("fa-auth-desc").textContent = signup
        ? "Аккаунт нужен для очереди, голосования и сохранения истории."
        : "Войдите, чтобы участвовать в общих битвах и сохранять результаты на всех устройствах.";
      document.getElementById("fa-auth-name").style.display = signup ? "block" : "none";
      document.getElementById("fa-auth-password").autocomplete = signup ? "new-password" : "current-password";
      document.getElementById("fa-auth-submit").textContent = signup ? "Зарегистрироваться" : "Войти";
      document.getElementById("fa-auth-toggle").textContent = signup ? "Уже есть аккаунт? Войти" : "Создать аккаунт";
      document.getElementById("fa-auth-error").textContent = "";
    }

    async submitAuth() {
      const email = document.getElementById("fa-auth-email").value.trim();
      const password = document.getElementById("fa-auth-password").value;
      const name = document.getElementById("fa-auth-name").value.trim().slice(0, 32);
      const button = document.getElementById("fa-auth-submit");
      const errorEl = document.getElementById("fa-auth-error");
      if (!email || !password) { errorEl.textContent = "Введите email и пароль."; return; }
      if (this.authMode === "signup" && password.length < 8) { errorEl.textContent = "Пароль должен содержать минимум 8 символов."; return; }
      if (this.authMode === "signup" && !name) { errorEl.textContent = "Укажите имя."; return; }
      button.disabled = true;
      errorEl.textContent = "";
      try {
        const result = this.authMode === "signup"
          ? await this.client.auth.signUp({ email, password, options: { data: { display_name: name } } })
          : await this.client.auth.signInWithPassword({ email, password });
        if (result.error) throw result.error;
        if (this.authMode === "signup" && !result.data.session) {
          errorEl.textContent = "Проверьте почту и подтвердите email, затем войдите.";
        }
      } catch (error) {
        errorEl.textContent = error?.message || "Не удалось выполнить вход.";
      } finally {
        button.disabled = false;
      }
    }

    async googleAuth() {
      const errorEl = document.getElementById("fa-auth-error");
      errorEl.textContent = "";
      const { error } = await this.client.auth.signInWithOAuth({
        provider: "google",
        options: { redirectTo: location.origin + location.pathname }
      });
      if (error) errorEl.textContent = error.message;
    }

    showFatal(message) {
      const el = document.createElement("div");
      el.style.cssText = "position:fixed;inset:0;z-index:100000;background:#050505;color:#fff;display:grid;place-items:center;padding:24px;text-align:center;font:600 14px Manrope,Arial";
      el.textContent = message;
      document.body.appendChild(el);
    }

    showMessage(message) {
      const el = document.getElementById("fa-auth-error");
      if (el) el.textContent = message;
    }

    dispatch(snapshot) {
      this.lastSnapshot = snapshot;
      window.dispatchEvent(new CustomEvent(EVENT, { detail: snapshot }));
    }

    async loadSnapshot() {
      if (!this.isOnline()) return this.lastSnapshot;
      if (this.loading) { this.pendingReload = true; return this.lastSnapshot; }
      this.loading = true;
      try {
        const c = this.client;
        const [photoRes, profileRes, laneRes, battleRes, participantRes, voteRes, resultRes] = await Promise.all([
          c.from("arena_photos").select("id,owner_id,object_path,status,created_at").neq("status", "removed").order("created_at", { ascending: true }),
          c.from("arena_profiles").select("user_id,display_name,handle"),
          c.from("arena_lanes").select("lane_id,champion_photo_id,challenger_photo_id").order("lane_id"),
          c.from("arena_battles").select("id,lane_id,opening,stage,started_at,stage_ends_at,finished_at").in("stage", ["waiting","voting"]),
          c.from("arena_battle_participants").select("battle_id,photo_id,owner_id,side"),
          c.from("arena_votes").select("battle_id,voter_id,target_photo_id,comment,created_at"),
          c.from("arena_results").select("id,battle_id,lane_id,left_photo_id,right_photo_id,winner_photo_id,is_draw,left_votes,right_votes,total_votes,opening,completed_at").order("completed_at", { ascending: false }).limit(500)
        ]);
        for (const r of [photoRes,profileRes,laneRes,battleRes,participantRes,voteRes,resultRes]) if (r.error) throw r.error;

        const profiles = new Map(profileRes.data.map(x => [x.user_id, x]));
        const photoRows = photoRes.data;
        const photosById = new Map(photoRows.map(p => [p.id,p]));
        const photos = photoRows.map(p => {
          const profile = profiles.get(p.owner_id) || {};
          return {
            id: p.id, ownerId: p.owner_id, userId: p.owner_id, name: profile.display_name || "Участник",
            handle: profile.handle || "", dataUrl: c.storage.from("arena-photos").getPublicUrl(p.object_path).data.publicUrl,
            objectPath: p.object_path, status: p.status, queuedAt: Date.parse(p.created_at)
          };
        });
        const photoMap = new Map(photos.map(p => [p.id,p]));
        const participantsByBattle = new Map();
        for (const p of participantRes.data) {
          if (!participantsByBattle.has(p.battle_id)) participantsByBattle.set(p.battle_id, []);
          participantsByBattle.get(p.battle_id).push(p);
        }
        const votesByBattle = new Map();
        const battleById = new Map(battleRes.data.map(b => [b.id,b]));
        for (const member of participantRes.data) {
          const battle = battleById.get(member.battle_id);
          const photo = photoMap.get(member.photo_id);
          if (battle && photo && member.owner_id === this.user.id) {
            photo.battleId = battle.lane_id;
            photo.battleUid = battle.id;
            photo.side = member.side === "left" ? "R" : "B";
          }
        }
        for (const v of voteRes.data) {
          if (!votesByBattle.has(v.battle_id)) votesByBattle.set(v.battle_id, []);
          votesByBattle.get(v.battle_id).push(v);
        }
        const activeByLane = new Map(battleRes.data.map(b => [b.lane_id,b]));
        const arenaBattles = laneRes.data.map(lane => {
          const battle = activeByLane.get(lane.lane_id);
          const members = battle ? (participantsByBattle.get(battle.id) || []).sort((a,b) => a.side.localeCompare(b.side)) : [];
          const left = members.find(x => x.side === "left");
          const right = members.find(x => x.side === "right");
          const leftPhoto = left ? photoMap.get(left.photo_id) : null;
          const rightPhoto = right ? photoMap.get(right.photo_id) : null;
          const votes = battle ? (votesByBattle.get(battle.id) || []) : [];
          const redVotes = left ? votes.filter(v => v.target_photo_id === left.photo_id).length : 0;
          const blueVotes = right ? votes.filter(v => v.target_photo_id === right.photo_id).length : 0;
          const champ = lane.champion_photo_id ? photoMap.get(lane.champion_photo_id) : null;
          const me = members.find(x => x.owner_id === this.user.id);
          const stage = !battle ? "empty" : (battle.stage === "waiting" ? "w" : "v");
          return {
            id: lane.lane_id, laneId: lane.lane_id, battleUid: battle?.id || null, opening: !!battle?.opening,
            stage, stageEnd: battle ? Date.parse(battle.stage_ends_at) : 0,
            stageStarted: battle ? Date.parse(battle.started_at) : 0, totalStage: 70,
            redVotes, blueVotes,
            redName: leftPhoto?.name || "—", blueName: rightPhoto?.name || "—",
            redImg: leftPhoto?.dataUrl || "", blueImg: rightPhoto?.dataUrl || "",
            redPhotoId: leftPhoto?.id || null, bluePhotoId: rightPhoto?.id || null,
            userPhotoId: me?.photo_id || null, isParticipant: !!me, userSide: me?.side === "left" ? "R" : me?.side === "right" ? "B" : null,
            championPhotoId: battle?.opening ? null : lane.champion_photo_id,
            championSide: !battle ? (champ ? "R" : null) : !battle.opening && champ ? (leftPhoto?.id === champ.id ? "R" : rightPhoto?.id === champ.id ? "B" : null) : null,
            championName: !battle?.opening ? champ?.name || null : null,
            championImg: !battle?.opening ? champ?.dataUrl || null : null,
            championStreak: 0, isMock: false, hasChampionWaiting: !battle && !!champ
          };
        });

        const history = [];
        for (const result of resultRes.data) {
          const leftPhoto = photosById.get(result.left_photo_id);
          const rightPhoto = photosById.get(result.right_photo_id);
          const myPhoto = leftPhoto?.owner_id === this.user.id ? leftPhoto : rightPhoto?.owner_id === this.user.id ? rightPhoto : null;
          if (!myPhoto) continue;
          const opponent = myPhoto.id === result.left_photo_id ? rightPhoto : leftPhoto;
          const myVotes = myPhoto.id === result.left_photo_id ? result.left_votes : result.right_votes;
          const oppVotes = myPhoto.id === result.left_photo_id ? result.right_votes : result.left_votes;
          history.push({
            resultId: result.id, photoId: myPhoto.id, battleId: result.lane_id, battleUid: result.battle_id,
            laneId: result.lane_id, result: result.is_draw ? "draw" : result.winner_photo_id === myPhoto.id ? "win" : "lose",
            myVotes, oppVotes, myImg: c.storage.from("arena-photos").getPublicUrl(myPhoto.object_path).data.publicUrl,
            opponentImg: opponent ? c.storage.from("arena-photos").getPublicUrl(opponent.object_path).data.publicUrl : "",
            opponentName: profiles.get(opponent?.owner_id)?.display_name || "Участник", completedAt: Date.parse(result.completed_at)
          });
        }

        const VOTED = new Set(voteRes.data.filter(v => v.voter_id === this.user.id).map(v => v.battle_id));
        const MY = {};
        for (const [battleId, votes] of votesByBattle) {
          MY[battleId] = votes.map(v => {
            const member = (participantsByBattle.get(battleId) || []).find(p => p.photo_id === v.target_photo_id);
            return { s: member?.side === "left" ? "R" : "B", v: v.comment, author: profiles.get(v.voter_id)?.display_name || "Участник" };
          });
        }
        const participantStats = {};
        const getStats = (photoId) => {
          if (!photoId) return null;
          if (!participantStats[photoId]) {
            const row = photosById.get(photoId);
            const p = row ? profiles.get(row.owner_id) || {} : {};
            participantStats[photoId] = {
              wins: 0, losses: 0, defenses: 0, currentStreak: 0, bestStreak: 0,
              name: p.display_name || "Участник",
              img: row ? c.storage.from("arena-photos").getPublicUrl(row.object_path).data.publicUrl : "",
              isChampion: false, laneId: null
            };
          }
          return participantStats[photoId];
        };
        for (const result of [...resultRes.data].sort((a,b) => Date.parse(a.completed_at)-Date.parse(b.completed_at))) {
          const leftStats = getStats(result.left_photo_id);
          const rightStats = getStats(result.right_photo_id);
          if (result.winner_photo_id === result.left_photo_id) {
            leftStats.wins++; leftStats.currentStreak++; leftStats.bestStreak = Math.max(leftStats.bestStreak,leftStats.currentStreak);
            rightStats.losses++; rightStats.currentStreak = 0;
            if (!result.opening) leftStats.defenses++;
          } else if (result.winner_photo_id === result.right_photo_id) {
            rightStats.wins++; rightStats.currentStreak++; rightStats.bestStreak = Math.max(rightStats.bestStreak,rightStats.currentStreak);
            leftStats.losses++; leftStats.currentStreak = 0;
          }
        }
        for (const lane of laneRes.data) {
          if (lane.champion_photo_id) {
            const championStats = getStats(lane.champion_photo_id);
            championStats.isChampion = true;
            championStats.laneId = lane.lane_id;
          }
        }
        const myProfile = profiles.get(this.user.id) || {};
        const snapshot = {
          photos, arenaBattles, history, VOTED, MY, profiles: profileRes.data,
          profile: { name: myProfile.display_name || this.user.user_metadata?.display_name || "Участник", handle: myProfile.handle || "user" },
          participantStats
        };
        this.dispatch(snapshot);
        return snapshot;
      } catch (error) {
        console.error("[FACE ARENA sync]", error);
        this.showMessage(error?.message || "Не удалось загрузить данные арены.");
        return null;
      } finally {
        this.loading = false;
        if (this.pendingReload) {
          this.pendingReload = false;
          queueMicrotask(() => this.loadSnapshot());
        }
      }
    }

    subscribe() {
      if (!this.isOnline() || this.channel) return;
      this.channel = this.client.channel("face-arena-live")
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_photos" }, () => this.loadSnapshot())
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_lanes" }, () => this.loadSnapshot())
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_battles" }, () => this.loadSnapshot())
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_battle_participants" }, () => this.loadSnapshot())
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_votes" }, () => this.loadSnapshot())
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_results" }, () => this.loadSnapshot())
        .on("postgres_changes", { event: "*", schema: "public", table: "arena_profiles" }, () => this.loadSnapshot())
        .subscribe();
    }

    unsubscribe() {
      if (this.channel) this.client.removeChannel(this.channel);
      this.channel = null;
    }

    async wake() {
      try {
        const response = await fetch(WORKER_URL + "/wake", { method: "POST" });
        if (!response.ok) throw new Error("Coordinator returned " + response.status);
        return await response.json();
      } catch (error) {
        console.warn("[FACE ARENA coordinator unavailable; using safe RPC fallback]", error);
        const { data, error: rpcError } = await this.client.rpc("worker_tick");
        if (rpcError) console.error("[FACE ARENA worker_tick]", rpcError);
        return data || null;
      }
    }

    async uploadPhoto(file) {
      if (!this.isOnline()) throw new Error("Сначала войдите в аккаунт.");
      if (!file) throw new Error("Не выбран файл фотографии.");
      const ext = (file.type.split("/")[1] || "jpg").replace("jpeg","jpg");
      const path = this.user.id + "/" + crypto.randomUUID() + "." + ext;
      const upload = await this.client.storage.from("arena-photos").upload(path,file,{contentType:file.type,upsert:false});
      if (upload.error) throw upload.error;
      const enqueue = await this.client.rpc("enqueue_arena_photo",{p_object_path:path});
      if (enqueue.error) {
        await this.client.storage.from("arena-photos").remove([path]);
        throw enqueue.error;
      }
      await this.wake();
      await this.loadSnapshot();
      return enqueue.data;
    }

    async registerVisit(battleId) {
      const { error } = await this.client.rpc("register_arena_visit",{p_battle_id:battleId});
      if (error) throw error;
      await this.wake();
      await this.loadSnapshot();
    }

    async submitVote(battleId,targetPhotoId,comment) {
      const { error } = await this.client.rpc("submit_arena_vote",{
        p_battle_id:battleId,p_target_photo_id:targetPhotoId,p_comment:comment
      });
      if (error) throw error;
      await this.loadSnapshot();
    }

    async deletePhoto(photoId) {
      const { error } = await this.client.rpc("delete_arena_photo",{p_photo_id:photoId});
      if (error) throw error;
      await this.loadSnapshot();
    }

    async updateProfile(name,handle) {
      const { error } = await this.client.from("arena_profiles").update({
        display_name:name,handle:handle,updated_at:new Date().toISOString()
      }).eq("user_id",this.user.id);
      if (error) throw error;
      await this.loadSnapshot();
    }

    async signOut() {
      await this.client.auth.signOut();
    }
  }

  const sync = new FaceArenaSync();
  window.FaceArenaSync = sync;
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => sync.init(), { once: true });
  else sync.init();
})();