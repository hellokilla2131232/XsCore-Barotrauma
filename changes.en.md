# XsCore Changelog

> 中文更新日志：[changes.md](changes.md)

## 1.0.0

First release. One goal: stop the stutter during AI combat. Every change lives at the engine call layer — no characters removed, no stats touched, no textures or sounds modified.

Three C# plugins plug three separate pieces of per-frame duplicated work. `StatusThrottlePlugin` handles `<StatusEffect type="Always">` without an `interval`: the engine executes those every frame, and Barotraumatic alone ships 419 Always effects, 194 of them without an interval. The plugin reflects `StatusEffect.Interval` and `StatusEffect.Type`, patches every `Apply` overload, and skips the original logic when the same instance is called again within one second. Any exception passes through untouched. Measured on 1.13.5.0: 151,400 of 549,720 calls intercepted (27.5%).

`AILodPlugin` handles outpost `Character.Update`: not a player, has an `AIController`, not dead, `AIState` contains `Idle`, `|CurrentSpeed| <= 0.5`, and farther than 6000 px from the nearest player — only when all six hold does it drop to one call per 0.25 s. In combat, while moving, and near players it always runs full speed, so feel is preserved. `CurrentSpeed` is read reflectively to survive numeric type changes.

`GetItemsCachePlugin` handles the repeated scan in `AIObjectiveGetItem.FindTargetItem()`: after finishing each item pass it calls `character.Submarine.GetItems(alsoFromConnectedSubs: true)`, which internally is `Item.ItemList.FindAll(...)` — walking roughly 2940 items, calling `IsEntityFoundOnThisSub` on each, and allocating a new List. With 33 independent AIs that is 33 full duplicate passes. The plugin caches the result per `Submarine` instance with a 0.50 s TTL, caches only the `alsoFromConnectedSubs == true` path (`false` falls through to the original logic), sweeps expired entries every 10 s, and logs a hit-rate line every 30 s.

On the Lua side: `xsperffix.lua` provides combat awareness, pushing combat participants into the priority queue and switching to compatible mode when Performance Fix is detected (it then leaves intervals and the priority table alone and only appends combat participants); `cl_status.lua` provides the `cl_status` one-shot health check with Lua layer / C# layer / runtime columns.

Four API changes were adapted for 1.15.33.2: `StatusEffect.interval` became `public readonly float Interval`; `StatusEffect.type` became the property `public ActionType Type`; `Character.Update(float)` became `Update(float, Camera)`; and `Submarine.GetItems(bool)` was unchanged. The first two need reflective fallbacks (case-insensitive match plus a `GetProperty` fallback), the third needed no change because the prefix only declares `__instance` and Harmony allows omitting parameters, and the fourth works as-is. Each item was verified by decompiling `Barotrauma.dll` from 1.15.33.2 with `ilspycmd`, plus a compile check against the real assemblies via `tools/verify-compile.ps1` — zero errors, zero warnings.

`XsBtFix` ships alongside: it overrides only Barotraumatic's `bt_stalker.xml` and `bt_teleglitch.xml`, filling in the missing `interval` on `type="Always"` effects and leaving everything else intact. Because it uses `<Override>`, it **must load above Barotraumatic**.

Status: all three plugins were measured working on 1.13.5.0 ("at least it no longer stutters"); on 1.15.33.2 the decompile and compile checks pass and in-game behaviour is still to be verified. Note that 1.15's official optimizations overlap this mod in three places (more aggressive off-screen ragdoll disabling, outpost AI optimizations, `OnlyInside/OnlyOutside` effects no longer running without targets), so real AILod and StatusThrottle gains will be lower than on 1.13; `GetItemsCache` is unaffected.
