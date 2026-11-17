# FACE ARENA Game Logic Design

**Date:** 2026-11-18  
**Branch:** `audio-engine-preview`

## Intent

Replace the prototype's scattered, partially random battle transitions with a small deterministic game engine. The engine must make the ten-lane champion system and FIFO queue behave consistently, while keeping the existing FACE ARENA interface and demo workflow intact.

The current implementation is not merely missing a queue loop: `tryFillSlots()` does not assign queued photos, `startMatch()` selects a random mock opponent, and `finishBattle()` updates champion state in several special-case branches. That combination makes the intended rules difficult to enforce and test.

## Goals

- Model exactly ten independent lanes.
- Each lane has at most one champion and one challenger at a time.
- A champion remains in the lane after a successful defense.
- If the challenger wins, the challenger becomes champion; a user-owned former champion is moved to completed history.
- A defeated challenger is moved to completed history; the incumbent champion remains.
- When a lane is ready for a challenger, assign the oldest queued eligible photo automatically.
- FIFO ordering is deterministic, including photos with equal timestamps.
- A photo can occupy only one active lane and one active battle at a time.
- Enforce the existing maximum of three active photos per user, counting queued, matched, voting, and champion photos.
- Keep completed photos and their battle records in history; finishing a battle must not delete a photo.
- Keep demo fixtures out of the real-user TOP ARENA ranking.
- Preserve existing 10-second match cancellation, 150-second stages, one-vote-per-battle behavior, required 10–300 character comment, and current visual/audio presentation.

## Non-goals

- No authentication, Supabase, database, server-side timers, cross-device synchronization, or production multiplayer in this change. The repository currently contains a standalone LocalStorage prototype; client-side logic cannot provide production-grade concurrency or enforce rules across devices.
- No redesign, new UI screens, new sound effects, or changes to the approved visual style.
- No new comment-scoring or AI judging formula. Comments remain required input; they do not alter the winner unless a separately approved rule is added.
- No changes to the existing 150-second timing policy or the three-photo cap.

## Approaches considered

1. **Patch the existing inline functions.** Smallest immediate diff, but queue assignment, champion changes, and statistics would remain coupled to rendering and LocalStorage state. Regression risk stays high.
2. **Extract a deterministic, dependency-free game engine and test it with Node's built-in test runner.** Adds one focused module and tests, while the current HTML remains responsible for rendering, persistence, and user interaction. This is the selected approach because it makes the rules testable without adding dependencies or redesigning the app.

## Proposed design

### Game engine boundary

Create a browser-compatible JavaScript module that also exports its pure functions to Node's built-in test runner. It must not read the DOM, LocalStorage, current time, random values, or global UI state. The caller supplies timestamps and state; the engine returns updated state and transition results.

The engine owns:
- selecting eligible queued photos in stable FIFO order;
- selecting the next eligible lane;
- assigning one challenger to a lane;
- resolving a battle result and transferring or retaining the title;
- updating user photo status, participant statistics, and history records;
- rejecting duplicate assignments and cap violations.

The existing HTML remains responsible for:
- rendering and navigation;
- persisting the returned state to LocalStorage;
- generating unique battle IDs and supplying timestamps;
- playing the already-configured game sounds at the corresponding transition;
- opening and closing existing match/vote/result UI.

### Lane and battle rules

- Lane IDs are stable and range from 1 through 10.
- A lane with an active battle cannot accept another challenger.
- A lane with an incumbent champion and no challenger is eligible for the next FIFO photo.
- An empty lane is eligible for the next FIFO photo.
- If several lanes are eligible, choose the lowest lane ID first.
- Queue order is ascending `queuedAt`; equal timestamps retain their existing queue insertion order. Newly queued photos receive a monotonic queue sequence so ties remain stable after persistence.
- A photo already assigned to a lane, in a battle, or marked champion is not eligible for another assignment.
- A draw or cancelled battle does not transfer the title. The incumbent champion, if any, remains champion.
- A challenger win transfers the title. A user-owned former champion is completed and archived; a demo-only former champion is not added to user history or TOP ARENA.
- A champion defense increments that champion's wins, defenses, and streak exactly once.
- A challenger loss increments losses and resets that participant's current streak.
- After resolution/cancellation, the lane becomes available for the next queued challenger while retaining its incumbent champion where applicable.

### Ranking

TOP ARENA contains real user participants only. Sort deterministically by:
1. champion status;
2. title defenses (descending);
3. wins (descending);
4. current streak (descending);
5. stable participant ID (ascending).

Demo fixtures must never create or modify real-user ranking rows.

### Compatibility and migration

Existing LocalStorage records must continue to load. Legacy queued photos without a queue sequence retain their current array order as the tie-breaker; the engine may assign sequence values during the first safe state normalization. Existing photo IDs remain strings where supplied; no numeric coercion is allowed for history lookups.

### Error and edge behavior

- More than ten lanes: ignore/reject lanes outside IDs 1–10; never create an eleventh lane.
- More than three active photos for a user: reject a new queue entry without mutating existing state.
- Duplicate photo assignment: reject without changing either lane.
- Missing participant/photo references: do not create phantom user history or ranking rows.
- Zero-vote timeout: cancel the challenger attempt, preserve incumbent champion, then continue FIFO filling.
- Repeated resolution call: idempotently return no second stats/history update.

## Constraints

- Work only on `audio-engine-preview`; do not merge or push changes to `main` without explicit user approval.
- Do not spend Lovable credits or use paid agents.
- Preserve the current interface, fonts, colors, animations, settings, and existing game audio.
- Add no third-party dependency; use Node's built-in `node:test` if the runtime is available.

## Open implementation choices

The builder may choose the smallest compatible internal state representation after inspecting the complete upload/confirmation flow, provided all rules above are preserved and existing LocalStorage data remains readable. If the existing demo's mock-vs-user presentation cannot support a rule without changing visible behavior, stop and report the conflict rather than silently inventing new gameplay.
