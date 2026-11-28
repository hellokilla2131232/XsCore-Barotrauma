# XsCore Performance Optimizer for Barotrauma

> A pure optimization mod for *Barotrauma*, built around one specific problem: **stutter during AI combat**.
> Mod version: **1.1.1** ｜ Target game: **1.15.33.2**
> Only requirement: **C# scripting must be enabled in LuaCs**

中文说明：[README.md](README.md)

## Overview

Barotrauma's AI cost does not come from *how many* AI there are — it comes from *the same work being redone every frame*. This mod deletes no characters, touches no stats, and changes no textures or sounds. It only intercepts three kinds of duplicated engine work:

| Duplicated work | Who repeats it | How it is intercepted |
|---|---|---|
| `<StatusEffect type="Always">` without `interval` → runs every frame | Engine, driven by content-pack XML | Each instance really runs at most once per second |
| Stationary NPCs running the full `Update` (pathing + perception + state machine) every frame | Outpost AI | Distant idle units drop to once per 0.25 s |
| Every AI walking the whole item list and allocating a new `List` | `AIObjectiveGetItem` | Cached per submarine for 0.5 s, shared by all AI |

Result: status-effect call volume down **27.5%** (151,400 of 549,720 calls intercepted, measured on 1.13.5.0), and item scans go from "33 duplicate passes" to "1 reused pass".

## Changelog

Full history in [changes.md](changes.md) (Chinese, the canonical log). Latest build on the [Releases](https://github.com/hellokilla2131232/XsCore-Barotrauma/releases) page.

## Installation

### 1. Download and place

Grab **`XsCore-v*.zip`** from [Releases](https://github.com/hellokilla2131232/XsCore-Barotrauma/releases/latest) and extract it into the game root so you get:

```
Barotrauma/LocalMods/XsCore/          three C# plugins + five Lua scripts
```

**Which file on the Release page**:

| File | What it is | Download? |
|---|---|---|
| **`XsCore-v*.zip`** | The mod itself | **Yes — the only one you need** |
| `SHA256SUMS.txt` | Checksums of the built artifacts | Optional, for verifying the download |
| `Source code (zip / tar.gz)` | GitHub auto-generated repo snapshot | **No** — not a usable mod package |
| `Release attestation (json)` | GitHub build provenance | No |

There is only **one** zip, so there is no “which one do I install” choice.

### 2. Enable in game

`Settings` → `Mods` → tick **XsCore 性能优化**.

### 3. Confirm the C# switch

| Game version | Location | Required value |
|---|---|---|
| 1.15+ (bundled LuaCs) | `<game>/LuaCsSetupConfig.xml` | `EnableCsScripting="true"` |
| 1.13 and older (Workshop LuaCs) | `WorkshopMods/Installed/2559634234/Config/SettingsShared.xml` | `CsRunPolicy = Enabled` |

With C# disabled the three plugins are never compiled; only the Lua half runs.

### 4. Multiplayer servers (optional)

`RunConfig.xml` ships with `<Server>None</Server>`, which means **servers do not load the C# plugins**.

In multiplayer, AI logic runs on the server. To let the server benefit, change:

```xml
<Server>None</Server>
```

to:

```xml
<Server>Standard</Server>
```

Restart the server to apply. Singleplayer is unaffected.

## What is inside

### XsCore (main package)

| Module | Layer | Purpose | Parameters |
|---|---|---|---|
| **StatusThrottlePlugin** | C# | Status-effect throttling | `Always` with `interval<=0` → once per 1.0 s |
| **AILodPlugin** | C# | Distance-based AI LOD + combat adaptation | Adjustable far radius (default 2000 px), idle units at 0.25 s, shrinks to 25% during combat |
| **GetItemsCachePlugin** | C# | `Submarine.GetItems` cache | 0.50 s TTL, per submarine, only `alsoFromConnectedSubs=true` |
| **TargetThrottle** (merged into AILod) | C# | AI target-selection throttle | Each monster computes `UpdateTargets` once per 3 frames, saving 66% |
| **xsperffix.lua** | Lua | Combat awareness | Pushes combat participants into the priority queue; auto-detects Performance Fix and switches to compatible mode |
| **cl_status.lua** | Lua | One-shot health check | Command `cl_status` |

### XsCore is the only package

No companion patch is needed. Any `type="Always"` effect missing an `interval` — from Barotraumatic or any other content pack — is covered centrally by `StatusThrottlePlugin` at the code level. BT alone ships 194 such effects; patching XML files one by one cannot scale to that, and would silently rot every time the source mod updates.

## Commands

| Command | Purpose |
|---|---|
| `cl_status` | Health check: Lua layer / C# layer / runtime |
| `cl_perf` | Frame-time statistics |
| `cl_perf_mode` | Confirm compatible vs standalone mode |
| `cl_perf_toggle` | Toggle combat awareness |

## Verifying

Open the console (`` ` ``) after launch; all four lines should be present:

```
[XsStatusThrottle] 已加载 | interval字段=Interval | type字段=Type(属性) | 已 patch N 个 Apply 重载 | 节流 1.00s
[XsAILod] 已加载 | 远场 6000px | 闲置 AI 降频至 0.25s | 已 patch N 个 Update 重载
[XsGetItemsCache] 初始化 | TTL=0.50s | 缓存 Submarine.GetItems，所有 AI 共享
[XsPerf] 已启用：模式=独立/兼容 | 战区半径=3000
```

After 30 seconds in game:

```
[XsGetItemsCache] 命中 X/Y (Z%) | 缓存条目 N
```

Higher is better; aim for **> 80%**. Below 50% means little AI is calling `GetItems` — that cost was not your bottleneck anyway.

## Compatibility

### With Performance Fix

No conflict — they are complementary.

| System | Scope |
|---|---|
| Performance Fix | Global tick pacing, intervals, light merging |
| XsCore | Intercepts specific engine calls and skips by condition |

`xsperffix.lua` probes for Performance Fix at startup; when found it enters **compatible mode**: it does not take over intervals or the priority table and only appends combat participants. The log line shows `模式=兼容`.

### With Barotraumatic

**No compatibility patch required.**

XsCore shipped an `XsBtFix` companion before 1.1.0 (a full copy of BT's `bt_stalker.xml` / `bt_teleglitch.xml` with `interval` attributes added). It was **removed in 1.1.1**:

| Problem | Detail |
|---|---|
| Incomplete coverage | Patched 6 effects across 2 creatures; BT contains 194 of the same pattern |
| Goes stale | Full copies of creature definitions roll back to an old BT version on every BT update |
| Fragile load order | An `<Override>` package silently does nothing if loaded below the original |

`StatusThrottlePlugin` intercepts **every** `type="Always"` effect with `interval<=0` across all content packs, and is immune to BT updates.

### With 1.15's official optimizations

The 1.15 `Optimizations` section covers three things that overlap with this mod, so **part of the gain is now provided by the game**:

| Official change | Effect on this mod |
|---|---|
| More aggressive off-screen ragdoll disabling | Lower AILod gain |
| Outpost NPC AI optimizations | Lower AILod gain |
| `OnlyInside/OnlyOutside` effects no longer execute without valid targets | Lower StatusThrottle gain |

`GetItemsCache` is unaffected — the official notes never mention `AIObjectiveGetItem` or `Submarine.GetItems`.

## Known limitations

| Item | Detail |
|---|---|
| **Shared item list** | Downstream code writing into the cached list would pollute it; `FindTargetItem` currently only reads |
| **AILod skips `Update`** | In 1.15 the signature is `Update(float, Camera)`; skipping also skips camera-related branches inside it. Only far, idle, stationary units are skipped |
| **C# failures are log-only** | A compile error produces a log line, nothing in the UI. No log line = not loaded |
| **`cl_status` C# column is indirect** | Plugins are compiled static classes; Lua cannot see instances, so read the startup log |

## Development

```powershell
# 1. Compile check before committing (requires the game installed locally)
pwsh -File .github\scripts\verify-compile.ps1

# 2. Package + all gates (version / encoding / XML)
pwsh -File .github\scripts\package-release.ps1

# 3. Output lands in build\release-assets\
```

Bump `VERSION` and push to `main`; GitHub Actions creates the `v<version>` tag and publishes the Release. `VERSION` must match `modversion` in both `filelist.xml` files or the gate fails.

## Related

The same author's Dugong Refit submarine (separate package, not published here): hull 200→400, engine 270→520, reactor 3000→6500, three fabricators, three coilguns, automatic reactor.

## License

MIT
