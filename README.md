# XsCore — Barotrauma 性能优化

> 一套面向 Barotrauma 的性能优化模组，针对「AI 交战时卡顿」这一具体问题。
> 当前适配游戏版本：**1.15.33.2**

---

## 包含什么

### XsCore（主包）

| 模块 | 层 | 作用 |
|---|---|---|
| **StatusThrottlePlugin** | C# | 状态效果节流：`type=Always` 且 `interval<=0` 的效果降到 1 秒一次 |
| **AILodPlugin** | C# | 远处站着不动的 AI，`Update` 降到 0.25 秒一次 |
| **GetItemsCachePlugin** | C# | 缓存 `Submarine.GetItems`，所有 AI 共享同一份物品列表（TTL 0.5s） |
| **xsperffix.lua** | Lua | 战斗时把参战角色插进优先队列（检测到 Performance Fix 自动进兼容模式） |
| **cl_status.lua** | Lua | 一键体检命令 |

### XsBtFix（可选）

给 Barotraumatic 的 Stalker / Teleglitch 补 `StatusEffect` 的 `interval`。

**必须排在 Barotraumatic 上面。**

---

## 解决什么问题

Barotrauma 的 AI 开销主要来自两处：

### ① 状态效果每帧执行

```xml
<StatusEffect type="Always" />
```

`type="Always"` 且没写 `interval` 时，引擎每帧执行它。
Barotraumatic 有 419 个 Always 效果，其中 194 个没 interval。

### ② AI 反复遍历物品

`AIObjectiveGetItem.FindTargetItem()` 每扫完一轮物品就调用：

```csharp
itemList = character.Submarine.GetItems(alsoFromConnectedSubs: true);
```

而 `GetItems` 内部是 `Item.ItemList.FindAll(...)`——遍历全部物品并新建 List。

33 个 AI 各自独立调用 = 33 份重复全量遍历。

---

## 安装

1. 把 `XsCore` 文件夹放进 `Barotrauma/LocalMods/`
2. 启动游戏 → `设置` → `模组` → 勾选 `XsCore 性能优化`
3. **确保 C# 允许**：
   - 游戏 1.15+：`LuaCsSetupConfig.xml` 里 `EnableCsScripting="true"`
   - 游戏 1.13：LuaCs 的 `SettingsShared.xml` 里 `CsRunPolicy="Enabled"`

`XsBtFix` 同理，但**加载顺序必须在 Barotraumatic 之上**。

---

## 验证

启动后看控制台，三行都应该在：

```
[XsStatusThrottle] 已加载 | interval字段=Interval | type字段=Type(属性) | 已 patch N 个 Apply 重载
[XsAILod] 已加载 | 远场 6000px | 闲置 AI 降频至 0.25s | 已 patch N 个 Update 重载
[XsGetItemsCache] 初始化 | TTL=0.50s
```

游戏内命令：

| 命令 | 作用 |
|---|---|
| `cl_status` | 一键体检所有优化模块 |
| `cl_perf` | 帧时间统计 |
| `cl_perf_mode` | 兼容/独立模式 |

30 秒后应该看到缓存命中率：

```
[XsGetItemsCache] 命中 X/Y (Z%) | 缓存条目 N
```

命中率越高效果越好（目标 > 80%）。

---

## 与 Performance Fix 的关系

**不冲突，互补**。

| 系统 | 管什么 |
|---|---|
| **Performance Fix** | 全局 tick 节奏、interval、光影合并 |
| **XsCore** | 拦截具体调用、按条件跳过 |

`xsperffix.lua` 检测到 Performance Fix 时会自动进入**兼容模式**：不接管 interval，只做战斗优先级。

---

## 已知限制

| 项 | 说明 |
|---|---|
| **GetItems 缓存共享 List** | 若下游有写入会互相污染；当前 `FindTargetItem` 只读，安全 |
| **AILod 跳过 Update** | 1.15 的 `Update(float, Camera)` 带 Camera 参数，跳过可能影响摄像机逻辑（只跳远处站桩 AI） |
| **cl_status 的 C# 栏** | C# 插件是静态类，Lua 查不到，只能看启动日志 |

---

## 版本历史

| 版本 | 变更 |
|---|---|
| 1.15.33.2 | 适配 `StatusEffect.Interval`（大写 readonly）、`Type`（属性） |
| 1.13.5.0 | 首版，三个 C# 插件实测通过 |

---

## 许可

MIT
