# Cura Equi post-release audit

Audit authority: `origin/main-timed` at `e0d3b6c`, the newest release branch matching the handover. The checked-out `main` is an older October snapshot and does not contain the release lifecycle architecture. No project files were changed.

Static XML validation passed. No in-game execution logs or community reports were available, so engine-dependent behavior remains to be reproduced in KCD2.

## 1. Executive assessment

**Freeze feature development until targeted critical issues are fixed.**

The architecture is recoverable and generally understandable, but three release-safety mechanisms are incomplete:

- Player buff callbacks are not actually invalidated during loads because `_PrepareForLoad` references the wrong module table.
- Hunger processing bypasses the ownership authority and can operate on stolen or stale horse entities.
- Catch-up time can be silently discarded when horse resolution fails.

There is no evidence that Cura Equi corrupts base-game saves. Existing users can generally continue using their saves, but Cura Equi hunger, buffs, or horse debuffs may become inconsistent after quickloads, death loads, horse loss/replacement, or stolen-horse transitions.

## 2. Critical findings

### C1 — Load preparation invalidates the wrong buff module

- Severity: Critical
- Location: `Core.lua:171-212`, especially `Core.lua:201`; actual state is in `BuffLogic.lua:2-10`
- Trigger: Quickload, death load, or save switch while a 250 ms retry or 1.2-second player-status apply is pending.
- Consequence: A callback from the old save can run in the new save and apply a stale status. A horseless destination save may never execute `SyncAll`, leaving the stale status visible.
- Evidence: `_PrepareForLoad` uses `CuraEqui.BuffLogic`, but `BuffLogic.lua` only creates and exports `CuraEqui.Buffs`. `CuraEqui.BuffLogic` is never assigned.
- Fix direction: Invalidate `CuraEqui.Buffs._playerGen`, kill its retry timer, and introduce one shared load generation checked by every delayed callback.
- Reproduction: Schedule a hunger-tier transition, quickload during the 1.2-second apply delay into a horseless or differently hungry save, then inspect active Cura Equi player GUIDs.

This means the historical stale-callback problem was addressed conceptually but not fully wired into the release implementation.

### C2 — Ownership checks are bypassed by hunger and catch-up paths

- Severity: Critical
- Locations:
  - `HorseOwnership.lua:289-360`
  - `Horse.lua:516-566`
  - `Hunger.lua:255-261`
  - `Hunger.lua:368-401`
  - `Horse.lua:1282-1299`
- Trigger: Mount a stolen horse after previously having an owned horse, load while mounted on an unsupported horse, or change horse ownership while a watcher is active.
- Consequence: Hunger can be hydrated into, advanced on, persisted from, or debuffed onto a stolen/stale horse. Hunger can transfer between horses through the global persistence record.
- Evidence:
  - `TryInitOwnedHorseOnLoad` calls `SetOwnedHorse`, but regardless of whether that function rejects the horse, lines 344-352 unconditionally set `hasHorse`, `lastHorseEnt`, and start the watcher.
  - Normal ticks and catch-up use raw `Horse.Resolve`, not ownership-gated `ResolveHorse`.
  - Mounting any horse updates `Horse.playerHorseId`, while rejection of a stolen horse does not stop an already-running watcher.
- Fix direction: Make `SetOwnedHorse` return acceptance; only set session state when accepted. Use one authoritative owned-horse resolver in ticks, catch-up, feeding, persistence, and buff synchronization. Stop the watcher and clear the rejected entity’s Cura Equi debuffs on non-owned mounts.
- Reproduction: Own horse A, start hunger tracking, mount stolen horse B, wait and ride, then compare A/B state and DB hunger before and after reload.

### C3 — Elapsed catch-up time can be silently lost

- Severity: Critical
- Locations: `Hunger.lua:255-365`, `Core.lua:775-818`, `Core.lua:901-944`
- Trigger: Wait/sleep ends while no valid horse resolves, `hasHorse` is false, or the horse is streamed out/replaced.
- Consequence: Catch-up returns without applying anything, after which both close handlers clear `_sleepStartHour` and `_skipMinutesPlanned`. The elapsed interval cannot be recovered later.
- Evidence: Horse resolution occurs before elapsed minutes are calculated. Callers clear all catch-up markers regardless of success.
- Fix direction: Calculate an immutable catch-up record first. Consume it only after successful application to the authoritative owned horse. Otherwise retain it with a suppression reason or explicitly discard it under a documented unsupported-horse policy.
- Reproduction: Begin a two-hour wait with an owned horse, force horse resolution to fail at close, restore the horse, and verify whether the two hours are later applied exactly once.

### C4 — Self-rearming timers lack lifecycle generation checks

- Severity: Critical
- Locations:
  - `Hunger.lua:825-871`
  - `Hunger.lua:192-242`
  - `Core.lua:1003-1012`
  - `Core.lua:1040-1061`
- Trigger: Load/quickload at the boundary where a hunger or probe callback has already begun or is queued.
- Consequence: A stale callback can rearm itself after teardown. Since only the latest timer ID is stored, an orphan chain can become impossible to cancel and can produce duplicate ticks.
- Evidence: Hunger and probe callbacks always schedule their successor without checking a generation or current-running token. The 400 ms OGS settle and staggered resolution callbacks are also unguarded.
- Fix direction: Give watcher, probe, and load-settle paths independent generation counters. Every callback must validate its captured generation before mutating or rearming.
- Reproduction: Repeatedly quickload just before the ten-second hunger tick; timestamp every tick and verify that exactly one chain survives.

## 3. High-priority findings

- Persistence success is broken: `Persist.Save` at `Persist.lua:75-100` never returns `true`. Consequently `MaybeSave` never advances its throttle state and attempts a DB write every hunger tick. Write failures are also indistinguishable from success when the DB method silently returns failure.

- Presets have competing sources of truth: `horse.state.preset` and `horse.state_preset`. Bootstrap loads the dedicated key through `SetPreset`, but later `Persist.Load` can overwrite runtime configuration directly from the older hunger record. A manually selected preset may revert on reload until another hunger save occurs.

- Invalid preset deduplication is inconsistent: `SetPreset` stores the unvalidated requested name in `_activePreset` before `ApplyPreset` falls back to `moderate`.

- Feeding is non-atomic: `Horse.lua:832-934` modifies hunger, applies buffs, and saves before inventory removal at lines 951-1038. Missing inventory or partial deletion grants permanent nutrition without consuming all planned items.

- The fader fallback is never registered: `__eventsBound` is set when gameplay/quickload listeners are registered at `Core.lua:395-400`. The later guarded registration of `OnSetFaderState` at lines 1063-1065 therefore never runs.

- Planned wait duration can be erased: `onSkipTimeEvent` captures `OnConfirm` minutes at lines 842-850, but if that is the first event it immediately resets `_skipMinutesPlanned` at line 877.

- Time calculation is only time-of-day based. `_minutes_between_hours` wraps at 24 hours, so an exact 24-hour interval becomes zero unless the planned duration survives. There is no persisted world timestamp or general offline catch-up.

- `waitCatchup.enabled` is not consulted. The option currently has no effect.

- Horse state is runtime-per-entity but persistence-global. Every newly accessed horse can hydrate from the same `horse.state`, so owned-horse replacement transfers hunger unless that is explicitly made the design.

- `quraequi_init.lua:29` reloads nonexistent `Scripts/CuraEqui/Feeding.lua`. This appears harmless if `ReloadScript` only logs failure, but requires an engine test.

- Runtime version is `0.2.0` while `mod.manifest` reports `1.0`.

- Several lifecycle paths are dead or incomplete: `CuraEqui_ResyncPass` is defined but never scheduled; post-death reconcile flags/functions are referenced but never established.

## 4. Acceptable limitations

- Sated is correctly runtime-only in the release branch: persistence returns `satedUntil = 0`, saved records zero the old fields, and player sated buffs are non-persistent.
- Player clear logic targets only Cura Equi GUIDs; it should not remove unrelated mods’ effects.
- Clear functions correctly treat an available removal API plus attempted calls as success.
- Repeated player and horse application removes the same GUID first, improving idempotence.
- Player hunger status and sated status are intentionally mutually exclusive.
- Stolen horses being unsupported is a reasonable design choice. The problem is inconsistent enforcement, not the policy itself.
- Preset changes are non-retroactive: calculations read the active rates when future ticks/catch-up occur; historical hunger is not recalculated.
- Ten-second polling is modest when only one watcher exists.
- The 100-second sated bucket system is workable, though it intentionally rounds remaining duration upward.

## 5. Architecture map

- Initialization: `quraequi_init.lua` loads configuration, persistence, core, utilities, effects, horse handling, then hunger.
- Lifecycle: `Core.lua` handles gameplay start, quickload start, GameOver UI, SkipTime UI, bootstrap, teardown, and preset commands.
- Persistence: one per-save `horse.state` record plus a separate preset record.
- Horse resolution:
  - `Horse.Resolve`: raw engine/cached entity lookup.
  - `ResolveHorse`: session ownership gate.
  - `HorseOwnership`: engine `GetPlayerHorse` verification and session snapshots.
- Runtime horse state: `HorseState[entity.id]`, lazily hydrated from the global per-save hunger record.
- Hunger: one intended ten-second self-rearming watcher, plus an ownership probe while horseless.
- Catch-up: SkipTime open/close markers and time-of-day arithmetic; no durable timestamp ledger.
- Statuses:
  - `SyncAll`
  - horse debuff clear/apply
  - delayed player hunger-status clear/apply
  - separate timed-sated bucket synchronization
- Presets: `SetPreset` is intended as authority, but `Persist.Load` still bypasses it.
- Feeding: no GFX/Flash file override exists in this release. It wraps `Horse.GetActions`, adds an `Action`, opens the engine multi-selection inventory API, and processes selection through `Horse:OnInventoryClosed`.

## 6. Recent catch-up anomaly

The most plausible explanation is that the stolen horse was intentionally rejected as non-owned:

1. `IsEngineOwnedHorse` would reject it.
2. The mount handler would not start tracking.
3. SkipTime close would see no supported horse and discard catch-up.
4. Black-market acquisition would cause the engine to expose it as the player horse.
5. Tracking and catch-up would then begin working.
6. Reloading an older save could restore a valid engine-owned horse context.

That sequence is strongly supported by the code. The console may also matter because Cura Equi has no console/pause detection and depends entirely on UI events plus advancing game time.

However, adjacent genuine bugs make the result nondeterministic:

- An already-running watcher is not stopped when a stolen horse is mounted.
- Raw resolution can then tick the stolen horse anyway.
- Load initialization can unconditionally start tracking a horse rejected by the ownership gate.
- Failed catch-up consumes the pending time markers.

Therefore the observation is best classified as **an unresolved test condition exposing a likely lifecycle bug**, not proof that the numerical catch-up formula itself is wrong.

Required diagnostic line:

```text
catchup event=<open|plan|close|apply|defer>
loadGen=<n> watcherGen=<n>
rawId=<id> rawGuid=<guid>
ownedId=<id> ownedGuid=<guid>
engineOwned=<bool> sessionOwns=<bool>
hasHorse=<bool> eligible=<bool>
startHour=<h> endHour=<h> plannedMin=<n> elapsedMin=<n>
before=<hunger> delta=<n> after=<hunger> clamp=<bool>
result=<applied|deferred|discarded> reason=<reason>
consoleOrPause=<known|unknown>
```

## 7. Refactoring recommendations

Required before new features:

- Repair buff invalidation to use `CuraEqui.Buffs`.
- Introduce generation guards for every lifecycle timer.
- Make ownership resolution authoritative across all mutation paths.
- Make catch-up transactional: calculate, apply, then consume.
- Make `Persist.Save` return real success and consolidate preset persistence.
- Stop or quarantine hunger tracking when a non-owned horse is mounted.
- Make feeding inventory removal and nutrition application consistent.

Beneficial later:

- Replace loosely related fields in `CuraEqui.state` with explicit lifecycle, horse, timer, and SkipTime state groups.
- Choose either per-save companion hunger or per-horse hunger and encode that choice in the persistence schema.
- Remove dead lifecycle paths and the missing `Feeding.lua` reload.
- Align manifest/runtime versions.
- Add structured transition logging rather than many independent trace flags.

Avoid for now:

- Rewriting the hunger formula.
- Replacing the interaction system.
- Large event-driven refactors before lifecycle tests exist.
- Adding the Take/Eat prototype to Cura Equi.

The feeding bridge should be **retained but isolated** behind a small wrapper module. It is not actually a reusable GFX bridge, so a Take/Eat prototype would still need separate investigation into world-interaction context.

## 8. Development readiness checklist

- [ ] Correct release branch checked out and designated as the development base
- [ ] Player callback invalidation fixed and tested
- [ ] Exactly one hunger timer survives repeated loads
- [ ] Stolen horses never receive Cura Equi hunger/debuff mutations
- [ ] Horse replacement policy explicitly chosen and tested
- [ ] Failed resolution defers rather than loses catch-up
- [ ] Preset has one persisted source of truth
- [ ] Persistence writes report success and throttle correctly
- [ ] Feeding failure cannot grant free nutrition
- [ ] Mounted, death-load, quickload, and horseless status tests pass
- [ ] Release diagnostics capture horse identity and catch-up suppression
- [ ] Runtime and manifest versions agree

## 9. Test matrix

| Scenario | Required assertion |
|---|---|
| Cold start | One watcher; correct preset; no stale statuses |
| Normal load | Hunger loads once; sated starts cleared |
| Quickload | Old callbacks cannot apply or rearm |
| Death reload | Exactly one status and one watcher afterward |
| In-session save switch | No horse/state/timer leakage |
| Mounted save | Owned horse resolves and hydrates once |
| Unmounted save | Owned horse still tracks if intended |
| No horse | No watcher, player status, or horse debuff |
| Owned horse | Tick, persistence, statuses, feeding work |
| Stolen horse | No hunger mutation, debuff, persistence, or feeding |
| Black-market acquisition | Ownership transition starts tracking once |
| Horse replacement | Defined hunger-transfer policy is honored |
| Waiting | Catch-up applies exactly once |
| Sleeping | Same, including midnight and 24-hour cases |
| Fast travel | Either documented live ticking or one catch-up, never both |
| Console open during wait | Log whether world time/UI callbacks advance |
| Preset changes | Immediate apply, immediate durable persistence, one log/toast |
| Feeding before/after reload | Sated runtime-only; hunger persists |
| Inventory deletion failure | No free or partially paid nutrition |
| UI/action mod conflict | Original actions remain and no duplicate feed action |
| Ownership mod conflict | Rejection is safe and diagnostically visible |
| Buff UI mod conflict | Cura Equi clears only its own GUIDs |
| Time-progression mod | No duplicate or negative catch-up |

## Final decisions

1. Evidence of a critical release issue? **Yes.**
2. Can users continue existing saves? **Generally yes; no base-save corruption is evident, but mod state may become inconsistent.**
3. Can development continue on the current branch? **No. The checked-out `main` is obsolete; stabilize `origin/main-timed` first.**
4. Mandatory first fixes? **Buff generation invalidation, timer generations, ownership enforcement, and lossless catch-up.**
5. Highest-risk subsystem? **Horse identity/ownership combined with lifecycle timers.**
6. Architecture suitable for new features? **Yes after targeted stabilization.**
7. Feeding bridge? **Retain and isolate; do not redesign yet.**
8. Catch-up anomaly? **Likely an unsupported stolen-horse condition exposing genuine lifecycle weaknesses, not evidence of a broken arithmetic formula.**
