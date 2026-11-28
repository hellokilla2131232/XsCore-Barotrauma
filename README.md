# XsCore 性能优化 for Barotrauma

> 面向《潜渊症》的纯优化模组，专门解决「AI 交战时卡顿」。
> 模组版本：**1.1.1** ｜ 适配游戏：**1.15.33.2**
> 唯一前提：**LuaCs 的 C# 脚本开关必须打开**

English guide: see [README.en.md](README.en.md)

## 简介

《潜渊症》的 AI 开销不在「AI 数量」，而在「同一件事被每帧重复做」。本模组不删单位、不改数值、不动贴图和音效，只在引擎调用层拦掉三类重复劳动：

| 重复劳动 | 谁在重复 | 拦法 |
|---|---|---|
| `<StatusEffect type="Always">` 没写 `interval` → 每帧执行 | 引擎，按内容包里的 XML 走 | 同一实例 1 秒才真执行一次 |
| 站桩 NPC 每帧跑完整 `Update`（寻路+感知+状态机） | 前哨站 AI | 远场闲置单位降到 0.25 秒一次 |
| 每个 AI 各自全量遍历物品表并新建 `List` | `AIObjectiveGetItem` | 按船缓存 0.5 秒，所有 AI 共享一份 |

结果：状态效果调用量降 **27.5%**（549,720 次中拦截 151,400 次，1.13.5.0 实测数据），物品遍历从「33 份重复」降到「1 份复用」。

## 更新日志

完整变更记录见 [changes.md](changes.md)。最新发布在 [Releases](https://github.com/hellokilla2131232/XsCore-Barotrauma/releases) 页面。

## 安装

### 1. 下载并放置

从 [Releases](https://github.com/hellokilla2131232/XsCore-Barotrauma/releases/latest) 下载 **`XsCore-v*.zip`**，解压到游戏根目录，得到：

```
Barotrauma/LocalMods/XsCore/          三个 C# 插件 + 五个 Lua
```

**Release 页面里该下哪个**：

| 文件 | 是什么 | 要不要下 |
|---|---|---|
| **`XsCore-v*.zip`** | 模组本体 | **下这个，唯一要下的** |
| `SHA256SUMS.txt` | 三个产物的校验值 | 可选，想验证下载完整就下 |
| `Source code (zip / tar.gz)` | GitHub 自动生成的仓库源码 | **不要下**，不是可用的模组包 |
| `Release attestation (json)` | GitHub 自动生成的构建溯源 | 不要下 |

只有**一个** zip，不存在「该装哪个」的选择。

### 2. 在游戏里启用

`设置` → `模组` → 勾选 **XsCore 性能优化**。

### 3. 确认 C# 开关

| 游戏版本 | 位置 | 需要的值 |
|---|---|---|
| 1.15+（内置 LuaCs） | 游戏根目录 `LuaCsSetupConfig.xml` | `EnableCsScripting="true"` |
| 1.13 及更早（工作坊 LuaCs） | `WorkshopMods/Installed/2559634234/Config/SettingsShared.xml` | `CsRunPolicy = Enabled` |

C# 开关关掉的话，三个插件不会编译，剩下的只有 Lua 那部分。

### 4. 多人服务器（可选）

`RunConfig.xml` 默认是 `<Server>None</Server>`，**服务端不加载 C# 插件**。

多人游戏里 AI 逻辑在服务端跑，想让服务器也享受优化，需要把：

```xml
<Server>None</Server>
```

改成：

```xml
<Server>Standard</Server>
```

改完重启服务器生效。单人游玩不受影响。

## 包含什么

### XsCore（主包）

| 模块 | 层 | 管什么 | 参数 |
|---|---|---|---|
| **StatusThrottlePlugin** | C# | 状态效果节流 | `Always` 且 `interval<=0` → 1.0s 一次 |
| **AILodPlugin** | C# | AI 距离分级 + 战斗自适应 | 远场可调（默认 2000px）、闲置降频至 0.25s、战斗中自动缩到 25% |
| **GetItemsCachePlugin** | C# | `Submarine.GetItems` 缓存 | TTL 0.50s、按船实例、只缓存 `alsoFromConnectedSubs=true` |
| **TargetThrottle**（合并进 AILod） | C# | AI 目标选择节流 | 每个怪物每 3 帧算一次 `UpdateTargets`，省 66% |
| **xsperffix.lua** | Lua | 战斗状态感知 | 参战角色插进优先队列，检出 Performance Fix 自动进兼容模式 |
| **cl_status.lua** | Lua | 一键体检 | 命令 `cl_status` |

### XsCore 是唯一包

不装任何附属补丁。Barotraumatic 之类的怪物 mod 漏写 `interval` 的 `type="Always"` 效果，全部由 `StatusThrottlePlugin` 在代码层统一兜住——BT 里有 194 处这样写，覆盖范围远超逐个改 XML 的做法，而且不会因为 mod 更新而失效。

## 命令

| 命令 | 作用 |
|---|---|
| `cl_status` | 一键体检：Lua 层 / C# 层 / 运行时三栏 |
| `cl_perf` | 帧时间统计 |
| `cl_perf_mode` | 确认兼容模式还是独立模式 |
| `cl_perf_toggle` | 开关战斗感知 |

## 验证

启动后打开控制台（` 键），这四行都应该在：

```
[XsStatusThrottle] 已加载 | interval字段=Interval | type字段=Type(属性) | 已 patch N 个 Apply 重载 | 节流 1.00s
[XsAILod] 已加载 | 远场 6000px | 闲置 AI 降频至 0.25s | 已 patch N 个 Update 重载
[XsGetItemsCache] 初始化 | TTL=0.50s | 缓存 Submarine.GetItems，所有 AI 共享
[XsPerf] 已启用：模式=独立/兼容 | 战区半径=3000
```

进游戏 30 秒后：

```
[XsGetItemsCache] 命中 X/Y (Z%) | 缓存条目 N
```

命中率越高越好，目标 **> 80%**。低于 50% 说明没有 AI 在频繁调用 `GetItems`，那这部分开销本来就不在你的机器上。

## 兼容性

### 与 Performance Fix

**不冲突，互补**。

| 系统 | 管什么 |
|---|---|
| Performance Fix | 全局 tick 节奏、interval、光影合并 |
| XsCore | 拦截具体引擎调用、按条件跳过 |

`xsperffix.lua` 启动时检测 Performance Fix，检出就进**兼容模式**：不接管 interval、不动优先级表，只追加战斗参与者。日志里会打印 `模式=兼容`。

### 与 Barotraumatic

**不需要任何兼容补丁**。

XsCore 1.1.0 之前发过一个 `XsBtFix`（整份复制 BT 的 `bt_stalker.xml` / `bt_teleglitch.xml`，只补 `interval`），1.1.1 起**已移除**。原因：

| 问题 | 说明 |
|---|---|
| 覆盖不全 | 只补 2 个生物的 6 处，BT 里有 194 处同类写法 |
| 会过时 | 整份复制怪物定义，BT 一更新就回滚到旧版 |
| 排序脆弱 | `<Override>` 型排错位置就静默失效 |

`StatusThrottlePlugin` 在代码层拦的是**所有**内容包的 `type="Always"` 且 `interval<=0` 的效果，BT 更新也不受影响。

### 与 1.15 官方优化

1.15 的 `Optimizations` 章节做了三件与我们重叠的事，**收益会被官方吃掉一部分**：

| 官方改动 | 对本模组的影响 |
|---|---|
| 离屏 ragdoll 停用更激进 | AILod 收益下降 |
| 前哨站 NPC AI 优化 | AILod 收益下降 |
| `OnlyInside/OnlyOutside` 状态效果无目标时不再执行 | StatusThrottle 收益下降 |

`GetItemsCache` 不受影响——官方日志没提 `AIObjectiveGetItem` 或 `Submarine.GetItems`。

## 已知限制

| 项 | 说明 |
|---|---|
| **GetItems 缓存共享 List** | 下游若写入会互相污染；当前 `FindTargetItem` 只读，安全 |
| **AILod 跳过 Update** | 1.15 的签名是 `Update(float, Camera)`，跳过会连带跳过其中的相机相关分支；只跳「远场 + 闲置 + 不动」的单位 |
| **C# 插件失败不报错到界面** | 编译失败只写日志，看不到就说没生效 |
| **cl_status 的 C# 栏是间接指标** | 插件是编译进 DLL 的静态类，Lua 查不到实例，只能看启动日志 |

## 开发

```powershell
# 1. 提交前先跑编译校验（需要本机装有游戏）
pwsh -File .github\scripts\verify-compile.ps1

# 2. 打包 + 全部门禁（版本号/编码/XML）
pwsh -File .github\scripts\package-release.ps1

# 3. 产物在 build\release-assets\
```

修改 `VERSION` 后推送 `main`，GitHub Actions 会自动打 `v<版本>` 标签并发布 Release。`VERSION` 与两个 `filelist.xml` 的 `modversion` 必须一致，否则门禁直接失败。

## 相关项目

同一作者的 Dugong Refit 潜艇改型（独立包，未在此仓库发布）：外壳 200→400、引擎 270→520、反应堆 3000→6500，三个制造台、三门 coilgun、自动反应堆。

## 许可

MIT
