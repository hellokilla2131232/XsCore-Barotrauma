# XsCore 更新日志

> English changelog: see [changes.en.md](changes.en.md)

## 1.0.0

首版发布。目标只有一个：让 AI 交战时不再卡。全部改动都在引擎调用层，不删单位、不改数值、不动贴图和音效。

三个 C# 插件分别堵住三处每帧重复劳动。`StatusThrottlePlugin` 处理 `<StatusEffect type="Always">` 漏写 `interval` 的情况：这类效果引擎会每帧执行，Barotraumatic 里有 419 个 Always 效果，194 个没写 interval。插件用反射拿到 `StatusEffect` 的 `Interval` 与 `Type`，Patch 全部 `Apply` 重载，同一实例 1 秒内重复调用直接跳过原逻辑，异常一律放行。1.13.5.0 实测：549,720 次调用中拦截 151,400 次（27.5%）。

`AILodPlugin` 处理前哨站 AI 的 `Character.Update`：非玩家、有 `AIController`、未死亡、`AIState` 含 `Idle`、`|CurrentSpeed| <= 0.5`、距最近玩家 > 6000px，六条全满足才降到 0.25 秒一次。战斗中、移动中、玩家附近永远全速，保证手感。`CurrentSpeed` 用反射读取，避免数值类型变化导致编译失败。

`GetItemsCachePlugin` 处理 `AIObjectiveGetItem.FindTargetItem()` 的重复遍历：它每扫完一轮物品就调 `character.Submarine.GetItems(alsoFromConnectedSubs: true)`，而 `GetItems` 内部是 `Item.ItemList.FindAll(...)`，遍历约 2940 个物品、每个都调 `IsEntityFoundOnThisSub`，并新建 List。33 个 AI 各自独立调用就是 33 份重复全量遍历。插件按 `Submarine` 实例缓存结果，TTL 0.50 秒，只缓存 `alsoFromConnectedSubs == true` 这一条（`false` 走原逻辑），每 10 秒清理过期条目，每 30 秒打印命中率。

Lua 侧两个脚本：`xsperffix.lua` 做战斗状态感知，参战时把参战角色插进优先队列，检出 Performance Fix 时自动进入兼容模式（不接管 interval、不动优先级表，只追加战斗参与者）；`cl_status.lua` 提供 `cl_status` 一键体检，输出 Lua 层、C# 层、运行时三栏。

适配 1.15.33.2 的四项 API 变化：`StatusEffect.interval` 从小写字段变成 `public readonly float Interval`；`StatusEffect.type` 从字段变成属性 `public ActionType Type`；`Character.Update(float)` 变成 `Update(float, Camera)`；`Submarine.GetItems(bool)` 签名未变。前两项需要反射兜底（大小写不敏感匹配 + `GetProperty` 兜底），第三项因为 Prefix 只声明 `__instance`、Harmony 允许少声明参数而无需改动，第四项直接可用。已用 `ilspycmd` 反编译 1.15.33.2 的 `Barotrauma.dll` 逐项核对，并用 `tools/verify-compile.ps1` 对真实程序集完成编译校验，三个插件零错误零警告。

`XsBtFix` 同步发布：只覆盖 Barotraumatic 的 `bt_stalker.xml` 与 `bt_teleglitch.xml`，给漏写 `interval` 的 `type="Always"` 效果补上间隔，其余原样。因为用 `<Override>`，**必须排在 Barotraumatic 上面**。

实测状态：1.13.5.0 三个插件已实测通过并确认「至少现在不卡了」；1.15.33.2 完成反编译核对与编译校验，游戏内行为待验证。注意 1.15 官方优化与本模组有三处重叠（离屏 ragdoll 更激进、前哨站 AI 优化、`OnlyInside/OnlyOutside` 无目标不执行），AILod 与 StatusThrottle 的实际收益会低于 1.13 时期；`GetItemsCache` 不受影响。
