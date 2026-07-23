# Cura Equi stabilization task list

Baseline: `feature/audit` at `e0d3b6c` (`main-timed finalize logs`)

Current release decision: **do not add features until the critical stabilization gates below pass.**

## Working agreement

For every task we will record:

1. **Why** the change is needed and which player-visible failure it prevents.
2. **Scope** of the smallest safe change, including behavior that must remain unchanged.
3. **Evidence** from source, logs, or a reproduction.
4. **Tests** performed before the task can be marked complete.
5. **Result** and any remaining uncertainty, especially where KCD2 engine behavior cannot be mocked.

Each fix should be a separate reviewable change. We will avoid feature work and unrelated refactoring during stabilization.

## Test strategy

Every critical fix must pass all applicable layers:

- **Static checks:** Lua syntax/load checks, searches for obsolete mutation paths, and `git diff --check`.
- **Automated lifecycle tests:** a small mocked KCD2 environment for timers, entities, ownership, buffs, and persistence. The repository currently has no local `lua`/`luac`, so the harness needs either a suitable runtime or an agreed alternative before it can run locally.
- **In-game tests:** controlled saves plus high-signal logs. A test passes only when both the visible result and the expected lifecycle log are correct.
- **Regression tests:** mounted load, quickload, death reload, in-session save switch, and repeated execution of the same event.

No task is complete from code inspection alone.

## Critical stabilization gates

### CE-01 — Make lifecycle generations and timer invalidation authoritative

- [ ] Map every production timer and assign it an owner, generation, captured identity, and cancellation rule.
- [x] Fix `_PrepareForLoad` to invalidate the actual buff module (`CuraEqui.Buffs`), not the nonexistent `CuraEqui.BuffLogic` table.
- [x] Guard the player-status retry callback as well as the delayed apply callback.
- [x] Guard horse-debuff retries in every branch, including the sated-clear retry.
- [ ] Guard post-death reconcile, gameplay-start resolve/settle, forced resync, and timed sated-removal callbacks.
- [ ] Invalidate the relevant generation on load, quickload, death, teardown, and supported-horse identity change.
- [ ] Ensure a callback resolves current player/horse state at execution time instead of mutating captured state from an earlier save.

**Why:** `_PrepareForLoad` currently looks for `CuraEqui.BuffLogic`, while `BuffLogic.lua` exports its state through `CuraEqui.Buffs`. Some delayed callbacks also have no generation check. A callback from an old save can therefore clear, apply, or resynchronize buffs in the newly loaded save—the historical duplicate/stale-icon failure mode.

**Key evidence:** `Core.lua:_PrepareForLoad`; `Core.lua:EnsureBuffsResynced`; `Core.lua:OnGameOverHidden`; `Core.lua:OnGameplayStarted`; `BuffLogic.lua:SyncPlayerStatus`; `BuffLogic.lua:SyncHorseDebuff`; `Effects.lua:ApplyPlayerTimed`.

**Required tests:**

- Schedule each callback, trigger load invalidation before it fires, then assert zero state/buff mutations.
- Quickload and death-load while a player tier change is pending; assert exactly one correct player icon.
- Save/load while a horse-debuff retry is pending; assert the old entity is never touched.
- Feed, then load another save before a timed callback expires; assert it cannot remove a buff belonging to the new save.

### CE-02 — Establish one ownership-safe horse authority

- [ ] Separate “raw engine candidate” resolution from “supported tracked horse” resolution with unambiguous APIs.
- [ ] Revalidate the cached `Horse.playerHorseId` before returning it.
- [ ] Require the ownership-safe resolver for hunger, catch-up, buffs, persistence hydration, and lifecycle resync.
- [ ] Define transitions for no horse, stolen horse, owned horse, black-market acquisition, horse replacement, streamed-out entity, and reinstantiated entity.
- [ ] Clear effects and invalidate horse-scoped work when the supported horse identity changes.

**Why:** `Horse.Resolve` can return a cached or raw horse entity without proving that it is the currently engine-owned horse, and critical callers use it directly. This can transfer hunger or effects to a stolen, temporary, stale, or previous entity.

**Key evidence:** `Horse.lua:Horse.Resolve`; `HorseOwnership.lua:IsEngineOwnedHorse`; `HorseOwnership.lua:PlayerOwnsHorse`; `Hunger.lua:Hunger_CatchUpAfterSleep`; buff and gameplay-start resync call sites.

**Required tests:**

- With an owned horse cached, mount a stolen horse; assert the stolen horse never receives hunger state or debuffs.
- Acquire that horse through the black market; assert tracking begins once, with the explicitly chosen state-transfer rule.
- Replace the owned horse and force entity streaming/reinstantiation; assert the old entity is cleared and the new stable identity is accepted.
- Load a horseless save after a horse-owning save; assert no cached entity is considered supported.

### CE-03 — Make skip-time catch-up transactional and non-lossy

- [ ] Represent a skip session as one record with generation, start, planned duration, supported-horse identity, and completion status.
- [ ] Do not mark the session handled or clear its timing inputs until catch-up returns an explicit result.
- [ ] Define result states such as `applied`, `not_eligible`, `retryable_no_horse`, `invalid_time`, and `failed`.
- [ ] Consolidate the duplicate SkipTime close paths behind one idempotent handler.
- [ ] Define exactly what happens if ownership changes during waiting.
- [ ] Add the audit-requested diagnostic line: horse identifiers, ownership/eligibility, generation, time inputs, delta, before/after hunger, clamp, and suppression reason.

**Why:** the close handlers set `_skipHandled = true`; `Hunger_CatchUpAfterSleep` can then return immediately when no horse resolves; the caller still clears `_sleepStartHour` and `_skipMinutesPlanned`. Valid elapsed time can be silently discarded, matching the reported `47 -> 47` observation.

**Key evidence:** both SkipTime close paths in `Core.lua`; `Hunger.lua:Hunger_CatchUpAfterSleep`.

**Required tests:**

- Wait with an owned horse and assert catch-up is applied exactly once even if multiple close events fire.
- Make horse resolution unavailable at close and available shortly afterward; assert the elapsed time is either retried or rejected by the documented policy, never silently consumed.
- Test stolen horse, acquisition during/after waiting, no horse, console open, midnight rollover, negative/zero delta, and configured catch-up cap.
- Reload an older save after a completed wait; assert no time from the newer save leaks into it.

### CE-04 — Reset and rehydrate runtime state safely across saves

- [ ] Inventory every value that survives in `CuraEqui.state`, `CuraEqui.HorseState`, `CuraEqui.Horse`, `CuraEqui.Buffs`, and `CuraEqui.Effects`.
- [ ] Define a single load-boundary reset that clears save-scoped tables, cached entities, pending skip sessions, memoized buff UUIDs, and throttling state.
- [ ] Rehydrate persisted hunger only after a supported horse and the active save context are known.
- [ ] Ensure an entity ID reused by another save cannot reuse the earlier save’s `HorseState` entry.
- [ ] Keep sated state runtime-only and prove it is never reconstructed during hydration.

**Why:** `HorseState` is a Lua table keyed by transient entity ID, and lazy persistence loading only occurs when an entry is first created. `_PrepareForLoad` does not currently clear that table or every related cache. An in-session save switch can therefore reuse runtime state instead of loading the selected save’s state.

**Key evidence:** `Horse.lua:HorseStateGet`; `Core.lua:_PrepareForLoad`; module-level caches in `Horse.lua`, `BuffLogic.lua`, `Effects.lua`, and `Persist.lua`.

**Required tests:**

- Alternate between two saves with deliberately different hunger values at least five times; each load must show its own value.
- Repeat with matching/reused entity IDs in the mock test.
- Switch from horse-owning to horseless and back; assert no old entity/state is visible during the horseless session.
- Save while sated, reload, and assert sated is absent while persisted hunger remains correct.

### CE-05 — Give persistence truthful success/failure semantics

- [ ] Make `Persist.Save` return an explicit boolean based on API availability, protected-call success, and backend result semantics.
- [ ] Make `SavePreset` follow the same contract.
- [ ] Reset `MaybeSave` throttling state at the appropriate save/load boundary.
- [ ] Update in-memory “saved” markers only after confirmed success.
- [ ] Log failures with operation, key, schema version, and error—without logging noisy success on every tick.
- [ ] Validate loaded schema, preset, hunger type/range, and missing/corrupt records before mutating runtime state.

**Why:** `Persist.Save` currently returns no value, so `MaybeSave` never observes success and cannot advance its throttle markers. Protected calls also only prove that Lua did not throw, not that the backend accepted the write. This can cause redundant writes and make failed persistence look successful.

**Key evidence:** `Persist.lua:Save`; `Persist.lua:SavePreset`; `Persist.lua:MaybeSave`; catch-up and hunger save call sites.

**Required tests:**

- Mock successful, unavailable, throwing, and explicitly failing DB backends and assert truthful results.
- Assert unchanged hunger does not write continuously after one confirmed save.
- Force a failed catch-up save and verify it is logged and remains eligible for a later save attempt.
- Load missing, malformed, out-of-range, and older-schema records; assert safe defaults/migration without runtime corruption.

### CE-06 — Prove status reconciliation is single-authority and idempotent

- [ ] Define one public reconciliation entry point for player hunger status, sated status, and horse debuffs.
- [ ] Make clear helpers report “API available and all intended calls completed safely,” not a guessed removal count.
- [ ] Ensure every apply is clear-before-apply and only targets Cura Equi GUIDs.
- [ ] Ensure sated and hunger status cannot be visible together.
- [ ] Remove or route competing direct clear/apply paths through the authority.
- [ ] Bound retries and record why a reconciliation was deferred or abandoned.

**Why:** status safety currently depends on several direct clear/apply paths, cached UUIDs, delayed retries, and subtly different return semantics. Even after timer invalidation is fixed, competing authorities can recreate duplicate icons or leave the UI stale.

**Key evidence:** `BuffLogic.lua:SyncPlayerStatus`, `SyncHorseDebuff`, `SyncAll`, and `SyncSatedTimer`; `Effects.lua` clear/apply helpers; direct buff calls found in `Core.lua`, `Horse.lua`, `Hunger.lua`, and `Debug.lua`.

**Required tests:**

- Call reconcile repeatedly for every hunger tier; assert one expected GUID and no others.
- Exercise sated start, extension, expiry, load, quickload, and death; assert hunger and sated never coexist.
- Make removal APIs temporarily unavailable, then restore them; assert bounded retry and one final icon.
- Verify the clear list contains only Cura Equi GUIDs.

## Release-blocking in-game matrix

- [ ] Cold game start
- [ ] Normal save load
- [ ] Quickload
- [ ] Death reload
- [ ] In-session switch between two saves
- [ ] Mounted and unmounted saves
- [ ] No horse, owned horse, stolen horse, and black-market acquisition
- [ ] Horse replacement and entity streaming/reinstantiation
- [ ] Waiting, sleeping, fast travel, and console open during waiting
- [ ] Preset change immediately before and after time skip
- [ ] Feeding before and after reload
- [ ] Repeated lifecycle events and delayed-callback invalidation
- [ ] Relevant horse ownership, status UI, and SkipTime mod-conflict smoke tests

## Gate for feature development

Feature work may resume only when:

- [ ] CE-01 through CE-06 are complete or a finding has been disproved with recorded evidence.
- [ ] Automated lifecycle tests pass.
- [ ] The full in-game matrix passes without duplicate icons, cross-save state, lost eligible catch-up, or stale-entity mutations.
- [ ] Persistence failures are observable and recoverable.
- [ ] Remaining limitations are documented as intentional behavior.
- [ ] A clean release-candidate save/load soak test has been completed.

## Deferred until stabilization is complete

- New horse-needs features
- Take/Eat interaction prototype
- Feeding GFX redesign unless a stabilization test proves it is involved
- Logging cleanup beyond what is needed for high-signal verification
- Broad architectural or stylistic refactors
