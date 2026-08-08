# Cura Equi stabilization handover

Handover prepared: 2026-08-08

This document is the starting point for continuing Cura Equi on another computer. It records the repository state, audit decisions, work already performed, evidence gathered in KCD2, unresolved risks, and the next safe tasks. It should be read before editing source.

## Read these first

1. `HANDOVER.md` - current state and continuation instructions.
2. `STABILIZATION_TASKS.md` - authoritative CE-01 through CE-06 checklist and release gates.
3. `AUDIT_REPORT.md` - original post-release audit, architecture map, and detailed findings.
4. Latest Git history and the complete working-tree diff.

Do not treat `AUDIT_REPORT.md` as the latest implementation state. It describes the release baseline before the stabilization fixes. This handover records what changed afterward.

## Repository state at handover

- Old workspace: `D:\Steam\steamapps\common\KingdomComeDeliverance2\mods\curaequi`
- Current branch: `feature/audit`
- Current commit: `8573aca81dc9c669d7e9397136ab7c8d93e313f6` (`audit first refactor`)
- Release baseline: `e0d3b6c` (`main-timed finalize logs`)
- Release branch: `main-timed` / `origin/main-timed`
- `main` was identified as an older snapshot and is not the stabilization base.

Working tree at handover:

```text
 M Data/Scripts/CuraEqui/Core.lua
 M Data/Scripts/CuraEqui/Hunger.lua
?? AUDIT_REPORT.md
?? HANDOVER.md
```

Before `HANDOVER.md` was added, the source diff was:

```text
Data/Scripts/CuraEqui/Core.lua   | 20 lines added
Data/Scripts/CuraEqui/Hunger.lua | 88 lines changed
Total: 91 insertions, 17 deletions
```

Important: a fresh clone of `feature/audit` at `8573aca` will not contain the uncommitted `Core.lua` and `Hunger.lua` work or the untracked `AUDIT_REPORT.md` and `HANDOVER.md`. Copy the complete repository including `.git` and untracked files, or intentionally preserve the work in a commit/patch before moving.

SHA-256 hashes of important source files at handover:

```text
8192EE0E72EED88BFA5DEE540AE6328A1F1C843C326CA56FBB190C4DF618C7AB  Data/Scripts/CuraEqui/Core.lua
D905B8CA22234438F9E5B8E21B71E42F0507694555F9FEC5FBEAF444FF3F99A3  Data/Scripts/CuraEqui/Hunger.lua
3375B73190F2EA4F52D59B369EDFA7A7A6B5D47920BEFFC0663C919C8820A616  Data/Scripts/CuraEqui/BuffLogic.lua
2717346E4D0FD4E9BEAEF5C4B5CADF0DB4569567838F4612C78D120E015A71D8  Data/Scripts/CuraEqui/Effects.lua
```

`git diff --check` passed at handover. Git printed only LF-to-CRLF working-copy warnings for `Core.lua` and `Hunger.lua`.

## Release decision and working agreement

Feature development remains frozen until the critical stabilization gates pass.

For every change:

1. Briefly explain why the issue is being fixed and which player-visible failure it prevents before editing.
2. State which existing mechanics and behaviors must remain unchanged.
3. Keep the change small and reviewable.
4. Record evidence from source, logs, mocks, or reproduction.
5. Specify static, mocked, and in-game verification as applicable.
6. Do not mark a finding complete from code inspection alone.
7. Ask the user about remembered or intended mechanics before changing behavior. The user may know important design history not apparent in source.
8. Do not begin CE-02 until CE-01 is sufficiently resolved and reviewed.

The user reviews source changes and performs KCD2 testing. Codex must not build or modify PAK files. The user uses Community Standard PAK Builder. An earlier PAK update was made before this agreement; do not assume the existing ignored `Data/curaequi.pak` is authoritative. Rebuild it from reviewed source on the new computer.

## What the audit is stabilizing

The critical sequence is:

- CE-01: make lifecycle generations and timer invalidation authoritative.
- CE-02: establish one ownership-safe supported-horse authority.
- CE-03: make wait/sleep catch-up transactional and non-lossy.
- CE-04: reset and rehydrate runtime state safely across saves.
- CE-05: give persistence truthful success/failure semantics.
- CE-06: make status reconciliation single-authority and idempotent.

Highest-risk interaction: horse identity/ownership combined with lifecycle timers and cross-save state.

There is no evidence that Cura Equi corrupts base-game saves. The identified risks concern Cura Equi runtime state, hunger, persistence, and visible buffs after lifecycle or ownership transitions.

## Confirmed design intent that must be preserved

- Higher numeric hunger means the horse is hungrier; values are clamped to 0-100.
- Ten-second live polling is intentional when exactly one supported watcher exists.
- Stolen or otherwise unsupported horses should not receive Cura Equi hunger, debuffs, persistence, or feeding behavior.
- Sated is runtime-only. It must not be reconstructed from persistence after load.
- Player hunger status and player sated status are mutually exclusive.
- Cura Equi should clear only its own buff GUIDs.
- Preset changes are non-retroactive: they affect future ticks/catch-up, not historical hunger.
- Wait/sleep is intended to stop live polling, record planned or elapsed game time, calculate one catch-up delta, reduce remaining sated time, sync/save, and then restart polling.
- The wait/sleep architecture is existing stabilization-sensitive behavior, not a new feature. Preserve the stop/calculate/restart model when CE-03 is addressed.
- Stolen-horse rejection is an intended policy; inconsistent enforcement is the bug.
- Feeding and interaction redesigns are deferred unless a stabilization reproduction proves they are involved.

## CE-01 work already committed in 8573aca

The first CE-01 slice is committed:

- `_PrepareForLoad` now invalidates `CuraEqui.Buffs`, the actual exported buff module, instead of nonexistent `CuraEqui.BuffLogic`.
- Player-status retry callbacks have generation guards.
- Both horse-debuff retry branches have lifecycle and captured-identity guards.
- Invalidated horse retries clear their pending state.
- Timed player-effect removals use `Effects._satedGen`, which `_PrepareForLoad` advances.

Why: old-save callbacks could otherwise clear or apply buffs in a newly loaded save, recreating stale or duplicate UI icons.

Remaining uncertainty: horse-debuff retry cancellation was code-verified but was not directly observable in-game.

## CE-01 work currently uncommitted

### Gameplay-start generation guards (`Core.lua`)

- `OnGameplayStarted` captures `_horseSyncFenceGen` after `Bootstrap("ogs")` performs its own load reset.
- The delayed 300/1200 ms horse-resolution retries abort when the generation changes.
- The 400 ms OGS settle callback aborts before clearing fences or syncing buffs when stale.

Why: a gameplay-start callback from an earlier save could repopulate horse identity, drop lifecycle fences, or synchronize buffs in the next save.

Preserved: init toast behavior, immediate first resolve attempt, retry timing, supported-horse logic, and buff reconciliation behavior for the active generation.

### Hunger-watcher generation (`Core.lua`, `Hunger.lua`)

- `_PrepareForLoad` invalidates `_hungerWatcherGen` and clears `_hungerWatcherActive`.
- `StartWatching` starts a new generation and schedules `Script.SetTimer` with a closure carrying that generation.
- `CuraEqui_HungerTick` checks activity/generation before any mutation.
- It checks again after the tick body before creating its successor timer.
- `StopWatching` invalidates the generation before killing the stored timer ID.

Why: `KillTimer` is best-effort if a callback is already queued or running. An old callback could mutate hunger after load and create an orphan duplicate timer chain.

Preserved: configured tick interval, hunger formulas, first-tick timing, error handling, sleep/wait stop and restart, persistence call sites, buff updates, and ownership behavior.

Implementation note: the watcher changed from `SetTimerForFunction` to `SetTimer` closures because a named-function timer cannot carry the old generation that distinguishes one timer chain from another.

### Horseless probe generation (`Core.lua`, `Hunger.lua`)

- Each `StartProbing` call owns `_horseProbeGen` and marks `_horseProbeActive`.
- The initial 500 ms and recurring 10-second probes are closure timers carrying that generation.
- A stale callback aborts before resolving or mutating horse state.
- The callback rechecks before rearming.
- Resolving a horse completes and invalidates the probe chain before starting hunger tracking.
- `_PrepareForLoad`, `TeardownAll`, and `StopProbing` invalidate the probe generation.
- `_PrepareForLoad` now kills and logs the stored horse-probe timer.

Why: a queued probe from a horseless save could survive quickload, resolve a horse in the next save, overwrite session horse identity, and start an extra hunger watcher.

Preserved: 500 ms initial probe, 10-second unresolved interval, current resolver, current `SetOwnedHorse` behavior, current promotion behavior, and hunger start after resolution. Ownership policy was deliberately not changed; it belongs to CE-02.

## In-game evidence gathered

Original log locations on the old computer:

```text
D:\Steam\steamapps\common\KingdomComeDeliverance2\test1.log
D:\Steam\steamapps\common\KingdomComeDeliverance2\test2.log
D:\Steam\steamapps\common\KingdomComeDeliverance2\test3.log
D:\Steam\steamapps\common\KingdomComeDeliverance2\kcd.log
```

These logs are outside the repository. Copy them separately if historical evidence is wanted on the new computer.

### Committed first-slice testing

- Patched PAK was confirmed loaded.
- Eight quickloads.
- Eight gameplay-start reconciliations.
- One death/load sequence.
- Player status was changed from 40 to 95 immediately before quickload; no stale or duplicate UI icons appeared.
- A 30-second sated state was followed by quickload; the loaded runtime correctly had `sated=0`.
- No Lua/runtime errors.
- Horse-debuff retry behavior remained code-verified rather than directly observable.

### Gameplay-start and watcher smoke testing

- Multiple quickload and death/load cycles showed correct hunger-timer teardown.
- UI remained clean with no stale or duplicate icons.
- No Cura Equi/Lua runtime errors.
- Ordinary owned-horse hunger ticks continued at the expected ten-second cadence on sessions left running long enough.
- Existing `hungerTrace=true` is throttled, so it is regression evidence but cannot by itself prove that two callbacks never fired inside one throttle window.

### Wait/sleep observation

The source confirms the intended stop/calculate/restart design. A log showed `SkipTime.gfx` opening, then hunger starting values moving approximately `75 -> 79 -> 85` between ordinary `+0.01` tick lines.

This is consistent with catch-up rather than continued polling. Under the moderate preset, daytime catch-up is approximately `(0.04 - 0.005) = 0.035 hunger/minute`: two hours adds about 4.2 and three hours adds about 6.3.

No authoritative wait diagnostic was available because `skipTrace=false`, and normal hunger lines lacked wall-clock timestamps. Do not treat this observation as proof that CE-03 is correct.

### Latest owned/horseless/probe test

- An owned session produced normal hunger ticks.
- Owned-to-horseless quickload killed the hunger timer.
- Horseless initialization produced no hunger activity.
- Horseless-to-owned quickload explicitly logged `killed horse probe timer`.
- A second horseless session followed by death explicitly logged probe cancellation at the death boundary.
- UI remained clean and behavior looked correct on the surface.
- No Cura Equi/Lua runtime errors.
- The final owned-horse load exited before ten seconds elapsed, so that run did not independently prove watcher ticking after the final horseless/death transition.

Interpret this as a successful in-game smoke test, not complete proof that a callback already executing at the exact lifecycle boundary was rejected.

## CE-01 current status

CE-01 remains in progress. Do not mark it complete yet.

Implemented or substantially addressed:

- Correct buff-module invalidation.
- Player delayed apply and retry generations.
- Horse-debuff retry generations and identity checks.
- Timed player-effect removal generation.
- Gameplay-start resolve/settle generation.
- Hunger watcher generation and rearm prevention.
- Horseless probe generation and rearm prevention.
- Load/death invalidation for the above paths.

Still required:

1. Finish the production timer inventory. Assign every timer an owner, generation, captured identity, and cancellation rule.
2. Investigate the remaining reconcile paths before editing:
   - `EnsureBuffsResynced` schedules 0/150 ms callbacks that capture `h` and `S`, but no call site was found.
   - `CuraEqui_ResyncPass` is defined but never scheduled.
   - `OnGameOverHidden` schedules a post-death callback only when `_needsPostDeathReconcile` is set, but that flag is not set elsewhere.
   - The callback calls `ForceTierReconcile`, which is not defined elsewhere.
3. Decide with the user whether those paths are intended mechanics worth retaining, or abandoned/dead lifecycle experiments. Do not silently remove or activate them.
4. If retained, guard them with lifecycle generation and resolve current horse/state at execution time rather than mutating captured `h`/`S`.
5. Make standalone teardown authoritative for every timer owner. `TeardownAll` currently invalidates the probe generation; verify whether it should directly invalidate the hunger-watcher generation too rather than relying on its current Bootstrap caller subsequently calling `StopWatching`.
6. Define and implement horse-scoped invalidation on supported-horse identity change. This overlaps CE-02 and must not be guessed before the supported-horse authority is defined.
7. Directly test timed sated-removal cancellation across saves.
8. Add or adopt a mocked lifecycle harness. No `lua` or `luac` executable was available in the old workspace.

Timer inventory notes already known:

- `BuffLogic.lua`: delayed player apply, player retry, two horse-debuff retry branches.
- `Effects.lua`: timed player-effect removal.
- `Hunger.lua`: hunger watcher and horseless probe.
- `Core.lua`: forced resync, post-death reconcile, init toast, gameplay-start resolve retries, gameplay-start settle.
- `Debug.lua`: a debug-only repeating timer; classify it explicitly rather than accidentally treating it as production gameplay state.
- The init toast is delayed but does not mutate save, horse, hunger, or buff state. Document its session-only cancellation policy rather than overengineering it unless a real failure is found.

## Exact next task

Start with a read-only lifecycle diagnostic, not a broad refactor:

1. Re-run repository-wide timer and symbol searches.
2. Confirm that `EnsureBuffsResynced`, `CuraEqui_ResyncPass`, `_needsPostDeathReconcile`, and `ForceTierReconcile` still have no live producers/callers.
3. Trace why the historical code expected a post-death reconcile and whether active OGS reconciliation has replaced it.
4. Explain the failure prevented and the intended mechanic to the user before editing.
5. Choose one small outcome:
   - guard and wire an intentionally retained reconcile path; or
   - remove/document a demonstrably dead path without changing active behavior.

Do not begin CE-02 as part of that slice.

Static verification for the next slice:

- Lua syntax/load check if a runtime is available.
- Repository search for obsolete timer/callback references.
- `git diff --check`.
- Confirm no unrelated source or PAK changes.

Mocked verification if a harness becomes available:

- Schedule each retained callback.
- Advance the relevant lifecycle generation before it fires.
- Execute queued callbacks.
- Assert zero horse resolution side effects, state writes, buff calls, persistence calls, or successor timers.
- Control case: unchanged generation executes exactly once using current horse/state.

In-game verification:

- Quickload and death/load during pending status/timer windows.
- Owned-to-horseless and horseless-to-owned switches.
- Leave the final owned load running for at least 20-30 seconds and observe normal watcher continuation.
- Confirm one correct UI status, no stale horse debuff, no clustered hunger changes, and no Lua/runtime errors.

## CE-02 through CE-06 roadmap

### CE-02: ownership-safe horse authority

Do not merely replace names. Define raw engine candidate versus supported tracked horse, then route every mutation through the supported resolver.

Key unresolved decisions/tests:

- Revalidate cached `Horse.playerHorseId`.
- Make `SetOwnedHorse` report acceptance.
- Prevent `TryInitOwnedHorseOnLoad` from setting session state and starting the watcher after rejection.
- Stop/quarantine tracking when a stolen horse is mounted.
- Define owned horse replacement and streaming/reinstantiation behavior.
- Decide whether hunger belongs to the save's current companion or to an individual horse.
- Invalidate horse-scoped timers/effects on supported identity change.

### CE-03: transactional wait/sleep catch-up

Preserve stop/calculate-once/restart behavior, but replace loose flags with one skip-session record and explicit results.

Known bugs:

- Duplicate close paths.
- Elapsed time is consumed even when no horse resolves.
- `OnConfirm` planned minutes can be immediately erased if it is the first event.
- `waitCatchup.enabled` is not consulted.
- Exact 24-hour time-of-day wrap can become zero if planned duration is lost.
- The system-fader fallback appears never to register because `__eventsBound` is already set.

Required diagnostic should include event, lifecycle/watcher generation, raw and supported horse IDs, ownership/eligibility, start/end/planned/elapsed time, before/delta/after hunger, clamp, result, and suppression reason.

### CE-04: cross-save reset and rehydration

Inventory and reset all save-scoped values in `CuraEqui.state`, `HorseState`, `Horse`, `Buffs`, `Effects`, and persistence throttles. Prevent reused transient entity IDs from inheriting another save's runtime state. Keep sated runtime-only.

### CE-05: persistence truthfulness

`Persist.Save` currently returns no true success, so `MaybeSave` cannot advance throttling markers. Define explicit backend success/failure semantics, update markers only after success, validate loaded records, and keep failed writes eligible for retry.

### CE-06: status reconciliation authority

Consolidate player hunger status, sated status, and horse debuffs behind one idempotent reconcile authority. Bound retries, clear only Cura Equi GUIDs, and prevent hunger and sated player icons from coexisting.

## Other high-priority findings after CE-01 to CE-06

These are real findings but must not distract from the critical order:

- Persistence/preset records have competing sources of truth.
- Invalid preset requests can be stored in `_activePreset` before fallback.
- Feeding changes hunger and saves before inventory removal, allowing free nutrition if deletion fails.
- `quraequi_init.lua` reloads nonexistent `Scripts/CuraEqui/Feeding.lua`.
- Runtime version `0.2.0` differs from manifest version `1.0`.
- Some lifecycle and resync code is dead or incomplete.

## New-computer transfer checklist

1. Copy the complete repository directory, including `.git`, modified files, and untracked Markdown files.
2. Optionally copy the external test logs listed above.
3. Do not rely on the ignored PAK; rebuild it from reviewed source with Community Standard PAK Builder.
4. On the new computer, run:

```powershell
git status --short
git branch --show-current
git log -5 --oneline --decorate
git diff --stat
git diff --check
```

5. Expected branch/HEAD: `feature/audit` at `8573aca` unless the work was intentionally committed during transfer.
6. Expected dirty source files before any transfer commit: `Core.lua` and `Hunger.lua`.
7. Expected untracked audit files before any transfer commit: `AUDIT_REPORT.md` and `HANDOVER.md`.
8. Compare the source hashes in this document. If they differ, inspect the diff before continuing.
9. Confirm KCD2 and the Community Standard PAK Builder use the transferred source tree.
10. Preserve save backups used for the two-hunger-value, horseless, owned, death, wait, and sated tests.

If cloning instead of copying the complete repository, first preserve the working tree with an intentional WIP commit or a patch plus copies of untracked files. Do not assume Git will move uncommitted or untracked work automatically.

## Suggested prompt for a new audit task

Paste this into the new Codex task after transferring the repository:

```text
Continue the Cura Equi stabilization audit.

Repository: <new absolute path to curaequi>
Branch: feature/audit
Expected base commit: 8573aca - audit first refactor

First read completely:
- HANDOVER.md
- STABILIZATION_TASKS.md
- AUDIT_REPORT.md
- latest Git history, status, and full working-tree diff

Working agreement:
- Stabilize before adding features.
- Before every edit, briefly explain why the change is needed, which player-visible failure it prevents, and which existing mechanics must remain unchanged.
- Keep each change small and reviewable.
- Do not mark an issue complete from source inspection alone.
- Specify static, mocked, and in-game verification.
- Ask before changing behavior whose original design intent is uncertain.
- Do not build or modify PAK files; I use Community Standard PAK Builder.
- Do not begin CE-02 until CE-01 is reviewed and sufficiently resolved.

Current task:
Perform the read-only CE-01 diagnostic described under "Exact next task" in HANDOVER.md. Confirm whether EnsureBuffsResynced, CuraEqui_ResyncPass, _needsPostDeathReconcile, and ForceTierReconcile are live or dead. Explain the intended mechanic and failure prevented before proposing one narrow change.
```

## Final handover status

- Feature work remains frozen.
- CE-01 is partially implemented and has encouraging in-game smoke evidence, but is not complete.
- Current UI behavior is clean on the tested load/death/horseless transitions.
- No Lua/runtime errors were found in the reviewed logs.
- Automated lifecycle testing is still missing.
- The immediate continuation is remaining reconcile/timer lifecycle analysis, not CE-02 and not feature work.
- Preserve the current uncommitted source diff during transfer.
