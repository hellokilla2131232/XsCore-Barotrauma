# XsCore Changelog

> 中文更新日志：[changes.md](changes.md)

## 1.1.0

Combat optimization release. Adds target-selection throttling and combat-adaptive AI LOD.

### New

**TargetThrottle (merged into AILodPlugin)**

`EnemyAIController.UpdateTargets()` is 671 lines, with two nested `O(targets × characters)` loops at lines 3752 and 3933. Twenty monsters running it simultaneously means 24,000 checks per frame, about 1.44 million per second. That is the real source of the "one-time heavy computation" during combat.

Fix: each monster only recomputes targets once every 3 frames, cutting overhead by 66% with a worst-case target-switch delay of 50 ms. Measured skip rate: 72.7% (11 samples; theoretical 66.7%).

**Combat-adaptive AILod**

Replaced distance-based combat detection with two objective triggers:

1. The player team's (same TeamID) total health drops.
2. An `EnemyAIController` is within 3000 px of the player with State Attack, Aggressive, or PassiveAggressive.

When triggered, the far-field radius shrinks to 25% (1500 to 375 px) and recovers after 30 seconds. Hostility checks are deliberately avoided: `IsHostileTo` depends on team configuration that any mod can override. PvP mode disables the feature entirely.

Measured: 1500 to 375 to 1500, held for 40 seconds, then recovered automatically.

### Fixed

- `Character.TeamID` is a `CharacterTeamType` enum in 1.15, not `byte`. Writing `byte team = pc.TeamID` raises CS0266 and invalidates the entire C# package.
- Config file moved from the game root to the mod directory (`LocalMods/XsCore/AILod.cfg`). LuaCs `File.*` can only write inside the mod directory.
- The C# side now resolves the same path through `TryGetPackageForPlugin<AILodPlugin>() → pkg.Dir`.

### Improved

- AILod gained a GUI panel (`XsCore · AI LOD`) with sliders, numeric input, and suggested ranges.
- New `AILod_diag.log`: records every PatchAll step at startup, working around the console having no search.
- `xsperffix.lua`'s `TrackFrame` now uses a ring buffer, removing the per-frame `table.remove(t, 1)` O(n) shift (saves 35,940 array moves per second).
- Adjusted suggested ranges: far field 6000-8000 to 1500-3000 (1500 already yields a 93% skip rate in testing).

### Known limitations

- Only CPU-side logic is optimized; GPU rendering is untouched. There is no benefit when the GPU is the bottleneck (many lights, heavy shadows).
- Multiplayer servers must manually change `RunConfig.xml`'s `<Server>` to `Standard`.

## 1.0.0

First release. One goal: stop the stutter during AI combat. Every change lives at the engine call layer — no characters removed, no stats touched, no textures or sounds modified.

Three C# plugins plug three separate pieces of per-frame duplicated work. `StatusThrottlePlugin` handles `<StatusEffect type="Always">` without an `interval`: the engine executes those every frame, and Barotraumatic alone ships 419 Always effects, 194 of them without an interval. The plugin reflects `StatusEffect.Interval` and `StatusEffect.Type`, patches every `Apply` overload, and skips the original logic when the same instance is called again within one second. Any exception passes through untouched. Measured on 1.13.5.0: 151,400 of 549,720 calls intercepted (27.5%).

`AILodPlugin` handles outpost `Character.Update`: not a player, has an `AIController`, not dead, `AIState` contains `Idle`, `|CurrentSpeed| <= 0.5`, and farther than 6000 px from the nearest player — only when all six hold does it drop to one call per 0.25 s. In combat, while moving, and near players it always runs full speed, so feel is preserved. `CurrentSpeed` is read reflectively to survive numeric type changes.

`GetItemsCachePlugin` handles the repeated scan in `AIObjectiveGetItem.FindTargetItem()`: after finishing each item pass it calls `character.Submarine.GetItems(alsoFromConnectedSubs: true)`, which internally is `Item.ItemList.FindAll(...)` — walking roughly 2940 items, calling `IsEntityFoundOnThisSub` on each, and allocating a new List. With 33 independent AIs that is 33 full duplicate passes. The plugin caches the result per `Submarine` instance with a 0.50 s TTL, caches only the `alsoFromConnectedSubs == true` path (`false` falls through to the original logic), sweeps expired entries every 10 s, and logs a hit-rate line every 30 s.

On the Lua side: `xsperffix.lua` provides combat awareness, pushing combat participants into the priority queue and switching to compatible mode when Performance Fix is detected (it then leaves intervals and the priority table alone and only appends combat participants); `cl_status.lua` provides the `cl_status` one-shot health check with Lua layer / C# layer / runtime columns.

Four API changes were adapted for 1.15.33.2: `StatusEffect.interval` became `public readonly float Interval`; `StatusEffect.type` became the property `public ActionType Type`; `Character.Update(float)` became `Update(float, Camera)`; and `Submarine.GetItems(bool)` was unchanged. The first two need reflective fallbacks (case-insensitive match plus a `GetProperty` fallback), the third needed no change because the prefix only declares `__instance` and Harmony allows omitting parameters, and the fourth works as-is. Each item was verified by decompiling `Barotrauma.dll` from 1.15.33.2 with `ilspycmd`, plus a compile check against the real assemblies via `tools/verify-compile.ps1` — zero errors, zero warnings.

`XsBtFix` ships alongside: it overrides only Barotraumatic's `bt_stalker.xml` and `bt_teleglitch.xml`, filling in the missing `interval` on `type="Always"` effects and leaving everything else intact. Because it uses `<Override>`, it **must load above Barotraumatic**.

Status: all three plugins were measured working on 1.13.5.0 ("at least it no longer stutters"); on 1.15.33.2 the decompile and compile checks pass and in-game behaviour is still to be verified. Note that 1.15's official optimizations overlap this mod in three places (more aggressive off-screen ragdoll disabling, outpost AI optimizations, `OnlyInside/OnlyOutside` effects no longer running without targets), so real AILod and StatusThrottle gains will be lower than on 1.13; `GetItemsCache` is unaffected.
