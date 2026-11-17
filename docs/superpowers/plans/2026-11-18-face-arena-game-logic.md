# FACE ARENA Deterministic Game Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement deterministic ten-lane champion transitions and automatic FIFO assignment without changing FACE ARENA's existing visual or audio presentation.

**Architecture:** Extract pure game rules into `face-arena-game-engine.js`, exposed as a browser global and CommonJS export so the same functions run in-browser and under Node's built-in test runner. Keep DOM, LocalStorage, clocks, generated battle IDs, and sound playback in the existing HTML adapter.

**Tech Stack:** Vanilla JavaScript, Node.js built-in `node:test` and `node:assert/strict`; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-18-face-arena-game-logic-design.md`

## Global Constraints

- Work only on `audio-engine-preview`; never merge or push to `main` without explicit approval.
- Do not spend Lovable credits or use paid agents.
- Preserve current UI, fonts, colors, animations, settings, and existing game audio.
- Add no third-party dependency.
- Keep existing LocalStorage data readable; do not wipe or reset user state.
- Preserve ten lanes, three active photos per user, 10-second cancellation, 150-second stages, one vote per battle, and 10–300 character comments.
- Demo fixtures must not pollute real user history or TOP ARENA.
- No backend, authentication, server-side timer, or cross-device guarantees in this implementation.

## Review Focus

- Equal `queuedAt` timestamps: stable insertion order must remain stable after reload; test FIFO tie-break.
- Legacy records without queue sequence: retain existing photos-array order; test normalization.
- Duplicate photo references across lanes: reject assignment without changing either lane; test duplicate guard.
- Repeated timeout/result processing: no duplicate history or stat increments; test idempotence.
- Challenger defeats incumbent: old champion must leave champion status and be archived; test both champion and challenger sides, including string photo IDs.

---

### Task 1: Add a dependency-free, testable game engine

**Files:**
- Create: `face-arena-game-engine.js`
- Create: `tests/face-arena-game-engine.test.js`

**Interfaces:**
- Export `normalizeQueue(photos) -> photos`, assigning stable queue sequence values only when absent.
- Export `selectNextAssignment(photos, lanes) -> { photoId, laneId } | null`, selecting the oldest eligible queued photo and the lowest eligible lane ID.
- Export `assignChallenger(state, assignment, battleUid, now) -> { state, assigned }`.
- Export `resolveBattle(state, laneId, now) -> { state, changed, result }`.
- Export `cancelBattle(state, laneId, now) -> { state, changed }`.
- Export `buildRanking(participantStats, photos) -> rows`, excluding all demo-only identities.

- [ ] **Step 1: Write failing tests** for stable FIFO order, equal timestamps, lane priority, no free lane, active photo exclusion, duplicate assignment, max-three cap, string photo IDs, and deterministic ranking tie-breaks.
- [ ] **Step 2: Run the tests** with `node --test tests/face-arena-game-engine.test.js`; expected initial failure because the engine module does not exist.
- [ ] **Step 3: Implement the pure engine** with no DOM, LocalStorage, Date.now, Math.random, or UI calls. The caller supplies `now` and `battleUid`.
- [ ] **Step 4: Run the focused tests**; expected all engine selection and invariant tests pass.
- [ ] **Step 5: Commit** as `feat: add deterministic FACE ARENA game engine`.

### Task 2: Implement deterministic champion transitions

**Files:**
- Modify: `face-arena-game-engine.js`
- Modify: `tests/face-arena-game-engine.test.js`

**Interfaces:**
- Use Task 1's `resolveBattle` and `cancelBattle` interfaces.
- Battle result shape must include lane ID, battle UID, winner side, champion photo ID after resolution, and completed photo IDs.

- [ ] **Step 1: Write failing tests** for champion defense, challenger victory, challenger defeat, incumbent defeat, draw, zero-vote cancellation, and repeated resolution.
- [ ] **Step 2: Run focused tests** and confirm the champion transition cases fail before implementation.
- [ ] **Step 3: Implement transitions**:
  - Champion defense increments wins, defenses, current streak, and best streak exactly once.
  - Challenger victory promotes challenger and archives an existing user-owned champion.
  - Challenger defeat archives challenger and preserves incumbent champion.
  - Draw/cancellation does not transfer title.
  - Completed user photos retain history records and do not consume an active slot.
  - Demo-only participants never create user history or ranking entries.
- [ ] **Step 4: Run all engine tests**; expected all transition and idempotency tests pass.
- [ ] **Step 5: Commit** as `fix: make champion transitions deterministic`.

### Task 3: Integrate FIFO assignment and engine transitions into the prototype

**Files:**
- Modify: `face-arena-demo-victory.html`
- Modify: `face-arena-game-engine.js` only if a tested adapter gap is discovered.
- Test: `tests/face-arena-game-engine.test.js`

**Interfaces:**
- HTML adapter reads/writes existing global `photos`, `arenaBattles`, `history`, and `participantStats`.
- It calls `window.FaceArenaGameEngine` and supplies `newBattleUid()` and `Date.now()`.
- Existing `saveState()`, `renderArenaGrid()`, `renderQueue()`, and `window.FaceArenaAudio` remain the integration points.

- [ ] **Step 1: Add adapter-level tests or a reproducible harness** for uploading a queued photo, automatically selecting a lane, and filling the next lane after a result. If extracting the inline adapter is necessary, keep the seam minimal and do not move rendering code.
- [ ] **Step 2: Run the harness** and verify the current manual/random pairing path fails the expected FIFO scenario.
- [ ] **Step 3: Load the engine before the existing inline application script** and replace `findFreeSlot`, queue assignment, and champion mutation with engine-backed operations.
- [ ] **Step 4: Trigger queue filling** after photo insertion, match cancellation/confirmation, battle completion/cancellation, and LocalStorage restoration. Preserve the existing 10-second cancel affordance; do not require a manual “Найти пару” action for automatic queue progression.
- [ ] **Step 5: Keep navigation and audio calls in the adapter**; use the existing sound events only, with no new UI sounds.
- [ ] **Step 6: Run focused tests and a static browser-script syntax check**; expected FIFO assignment and champion state agree with the engine.
- [ ] **Step 7: Commit** as `feat: automatically fill FACE ARENA lanes by FIFO`.

### Task 4: Fix ranking, history references, and legacy-state compatibility

**Files:**
- Modify: `face-arena-demo-victory.html`
- Modify: `face-arena-game-engine.js` if tests expose a pure-rule defect.
- Modify: `tests/face-arena-game-engine.test.js`

- [ ] **Step 1: Write failing tests** for demo exclusion, string photo IDs in history, old persisted photos without queue sequence, and completed-photo slot release.
- [ ] **Step 2: Run tests** and reproduce each failure.
- [ ] **Step 3: Route TOP ARENA through tested `buildRanking`; remove numeric coercion from history/photo lookups; normalize legacy queue order without deleting or rewriting user photos unnecessarily.
- [ ] **Step 4: Run tests**; expected demo records absent, string IDs preserved, legacy FIFO deterministic, and completed photos no longer counted as active.
- [ ] **Step 5: Commit** as `fix: isolate demo ranking and preserve photo history`.

### Task 5: End-to-end verification and preview deployment

**Files:**
- Verify: `face-arena-demo-victory.html`
- Verify: `face-arena-game-engine.js`
- Verify: `tests/face-arena-game-engine.test.js`

- [ ] **Step 1: Run the complete suite** with `node --test`; expected zero failures.
- [ ] **Step 2: Run syntax checks** on the engine and extracted/inline application script; expected no parse errors.
- [ ] **Step 3: Review invariants** against persisted state examples: ten lanes maximum, no duplicate photo assignment, three active photos maximum, single champion per lane, no duplicate vote/history mutation, demo exclusion.
- [ ] **Step 4: Inspect the diff** for accidental visual, settings, or audio changes; revert any unrelated changes.
- [ ] **Step 5: Push only to `audio-engine-preview` and verify the Vercel Preview deployment**. Do not merge to `main`.
- [ ] **Step 6: Report test results, preview URL, remaining prototype limitations, and the exact commits.**

## Scope and sequencing notes

Tasks 1 and 2 establish and verify pure rules before integration. Task 3 connects those rules to the existing UI lifecycle. Task 4 closes ranking/history compatibility gaps. Task 5 is the release gate. If the inline HTML cannot be tested safely without a disproportionate refactor, stop at the smallest adapter seam and report the gap instead of claiming end-to-end coverage.
