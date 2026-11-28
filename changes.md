# XsCore 更新日志

> English changelog: see [changes.en.md](changes.en.md)

## 1.1.0

战斗优化专题。新增目标选择节流，AILod 加战斗自适应。

### 新增

**TargetThrottle（合并进 AILodPlugin）**

`EnemyAIController.UpdateTargets()` 共 671 行，行 3752 / 3933 各有一处 `O(目标数 × 角色数)` 的嵌套遍历。20 个怪物同时跑 = 24,000 次判断/帧 = 144 万次/秒，这是战斗时「一次性大量计算」的主因。

做法：每个怪物每 3 帧才算一次目标，省 66% 开销，目标切换延迟最多 50ms。实测跳过率 72.7%（样本 11 次，理论 66.7%）。

**AILod 战斗自适应**

从「按距离判定战斗」改成「按客观信号判定」，两条独立触发：

1. 我方队伍（同 TeamID）总血量下降
2. 玩家 3000px 内存在 `EnemyAIController` 且 State 为 Attack / Aggressive / PassiveAggressive

触发后远场半径自动缩到 25%（1500 → 375px），保持 30 秒后恢复。不判断敌我关系（`IsHostileTo` 依赖 mod 可改的阵营配置）。PvP 模式直接停用。

实测：1500 → 375 → 1500，保持 40 秒后自动恢复。

### 修复

- `Character.TeamID` 在 1.15 是 `CharacterTeamType` 枚举，不是 `byte`。写 `byte team = pc.TeamID` 会导致 CS0266 编译错误，进而**整个 C# 包作废**。
- 配置文件路径从游戏根目录改到模组目录（`LocalMods/XsCore/AILod.cfg`）——LuaCs 的 `File.*` 只能写模组目录。
- C# 侧用 `TryGetPackageForPlugin<AILodPlugin>() → pkg.Dir` 拿同一个路径。

### 改进

- AILod 新增 GUI 面板（`XsCore · AI LOD`），滑块 + 输入框 + 范围建议
- 新增 `AILod_diag.log`：启动时记录 PatchAll 每一步，绕过控制台无法搜索的限制
- `xsperffix.lua` 的 `TrackFrame` 改用环形缓冲，去掉每帧 `table.remove(t, 1)` 的 O(n) 搬运（每秒省 35,940 次）
- 建议值调整：远场 6000~8000 → 1500~3000（实测 1500 就有 93% 跳过率）

### 已知限制

- 只优化 CPU 逻辑层，不动 GPU 渲染。GPU 瓶颈（灯光多、阴影多）时无效。
- 多人服务端需要手动把 `RunConfig.xml` 的 `<Server>` 改成 `Standard`。

## 1.0.0

首版发布。目标只有一个：让 AI 交战时不再卡。全部改动都在引擎调用层，不删单位、不改数值、不动贴图和音效。

三个 C# 插件分别堵住三处每帧重复劳动。`StatusThrottlePlugin` 处理 `<StatusEffect type="Always">` 漏写 `interval` 的情况：这类效果引擎会每帧执行，Barotraumatic 里有 419 个 Always 效果，194 个没写 interval。插件用反射拿到 `StatusEffect` 的 `Interval` 与 `Type`，Patch 全部 `Apply` 重载，同一实例 1 秒内重复调用直接跳过原逻辑，异常一律放行。1.13.5.0 实测：549,720 次调用中拦截 151,400 次（27.5%）。

`AILodPlugin` 处理前哨站 AI 的 `Character.Update`：非玩家、有 `AIController`、未死亡、`AIState` 含 `Idle`、`|CurrentSpeed| <= 0.5`、距最近玩家 > 6000px，六条全满足才降到 0.25 秒一次。战斗中、移动中、玩家附近永远全速，保证手感。`CurrentSpeed` 用反射读取，避免数值类型变化导致编译失败。

`GetItemsCachePlugin` 处理 `AIObjectiveGetItem.FindTargetItem()` 的重复遍历：它每扫完一轮物品就调 `character.Submarine.GetItems(alsoFromConnectedSubs: true)`，而 `GetItems` 内部是 `Item.ItemList.FindAll(...)`，遍历约 2940 个物品、每个都调 `IsEntityFoundOnThisSub`，并新建 List。33 个 AI 各自独立调用就是 33 份重复全量遍历。插件按 `Submarine` 实例缓存结果，TTL 0.50 秒，只缓存 `alsoFromConnectedSubs == true` 这一条（`false` 走原逻辑），每 10 秒清理过期条目，每 30 秒打印命中率。

Lua 侧两个脚本：`xsperffix.lua` 做战斗状态感知，参战时把参战角色插进优先队列，检出 Performance Fix 时自动进入兼容模式（不接管 interval、不动优先级表，只追加战斗参与者）；`cl_status.lua` 提供 `cl_status` 一键体检，输出 Lua 层、C# 层、运行时三栏。

适配 1.15.33.2 的四项 API 变化：`StatusEffect.interval` 从小写字段变成 `public readonly float Interval`；`StatusEffect.type` 从字段变成属性 `public ActionType Type`；`Character.Update(float)` 变成 `Update(float, Camera)`；`Submarine.GetItems(bool)` 签名未变。前两项需要反射兜底（大小写不敏感匹配 + `GetProperty` 兜底），第三项因为 Prefix 只声明 `__instance`、Harmony 允许少声明参数而无需改动，第四项直接可用。已用 `ilspycmd` 反编译 1.15.33.2 的 `Barotrauma.dll` 逐项核对，并用 `tools/verify-compile.ps1` 对真实程序集完成编译校验，三个插件零错误零警告。

`XsBtFix` 同步发布：只覆盖 Barotraumatic 的 `bt_stalker.xml` 与 `bt_teleglitch.xml`，给漏写 `interval` 的 `type="Always"` 效果补上间隔，其余原样。因为用 `<Override>`，**必须排在 Barotraumatic 上面**。

实测状态：1.13.5.0 三个插件已实测通过并确认「至少现在不卡了」；1.15.33.2 完成反编译核对与编译校验，游戏内行为待验证。注意 1.15 官方优化与本模组有三处重叠（离屏 ragdoll 更激进、前哨站 AI 优化、`OnlyInside/OnlyOutside` 无目标不执行），AILod 与 StatusThrottle 的实际收益会低于 1.13 时期；`GetItemsCache` 不受影响。
