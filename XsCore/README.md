# XsCore 性能优化

## 需要什么
- LuaCsForBarotrauma
- 游戏内：设置 → Mod 设置 → `Are C# Mods Allowed` = **Enabled**（否则 C# 部分不加载）

## 包含什么
| 模块 | 层 | 作用 |
|---|---|---|
| StatusThrottle | C# | 拦掉「type=Always 且无 interval」的状态效果的重复执行 |
| AILod | C# | 远处站桩 AI 降频更新，战斗与近处不变 |
| xsperffix | Lua | 战斗时提升参与者优先级（与 Performance Fix 共存） |

## 不需要什么
不依赖任何内容包。不带 EA/AA/Barotraumatic 也能用。

## 验证
进游戏看控制台，应出现：
```
[XsStatusThrottle] 已加载 | interval字段=interval | type字段=type | 已 patch 3 个 Apply 重载
[XsAILod] 已加载 | 远场 6000px | 闲置 AI 降频至 0.25s | 已 patch 1 个 Update 重载
```
