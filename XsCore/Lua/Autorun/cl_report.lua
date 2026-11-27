-- =====================================================================
-- cl_report — 一键生成诊断报告（TXT）
--
-- 用法：cl_report
-- 输出：<游戏目录>/cl_report.txt
--
-- 为什么存在：
--   控制台日志滚太快，复制不方便；这个指令把能读到的状态
--   全部写进一个文件，直接发给开发者定位问题。
-- =====================================================================

local function Safe(fn, default)
    local ok, v = pcall(fn)
    if ok then return v end
    return default
end

local function Fmt(f, ...)
    local ok, s = pcall(string.format, f, ...)
    if ok then return s end
    return f
end

-- 报告行收集
local lines = {}
local function W(s) lines[#lines + 1] = tostring(s or "") end
local function WL() W("") end

-- 时间戳
local function Now()
    return Safe(function()
        return os.date("%Y-%m-%d %H:%M:%S")
    end, "?")
end

-- 安全读取颜色/布尔
local function Bool(b) return b and "是" or "否" end

---------------------------------------------------------------------
-- 分区：环境
---------------------------------------------------------------------
local function SectionEnv()
    W("========== 环境 ==========")
    W("生成时间      : " .. Now())
    -- 版本：多个候选
    local ver = Safe(function() return Game.Version end, nil)
              or Safe(function() return Game.VersionString end, nil)
              or Safe(function() return GameMain.Version end, nil)
    W("游戏版本      : " .. (ver and tostring(ver) or "读不到（API 名称需确认）"))
    W("LuaCs 版本    : " .. tostring(Safe(function() return LuaCsSetup.Version end, nil)
                                     or "读不到"))

    -- 各 interval
    W("characterUpdateInterval : " .. tostring(Safe(function() return Game.characterUpdateInterval end, "?")))
    W("mapEntityUpdateInterval : " .. tostring(Safe(function() return Game.mapEntityUpdateInterval end, "?")))
    W("poweredUpdateInterval   : " .. tostring(Safe(function() return Game.poweredUpdateInterval end, "?")))
    W("Timer.AccumulatorMax    : " .. tostring(Safe(function() return Timer.AccumulatorMax end, "?")))
    WL()
end

---------------------------------------------------------------------
-- 分区：我们的模组
---------------------------------------------------------------------
local function SectionOurMods()
    W("========== 我们的优化模组 ==========")

    -- ---- Lua 层 ----
    W("[Lua 层]")

    local pf = Safe(function() return PerformanceFix ~= nil end, false)
    W(Fmt("  Performance Fix          : %s", pf and "已加载" or "未加载"))

    local xp = Safe(function() return XsPerf ~= nil end, false)
    W(Fmt("  XsPerf（战斗感知）        : %s", xp and "已加载" or "未加载"))
    if xp then
        local mode = Safe(function() return XsPerf.Mode end, nil)
        local radius = Safe(function() return XsPerf.CFG and XsPerf.CFG.CombatRadius end, nil)
        if mode then W("      模式                    : " .. tostring(mode)) end
        if radius then W("      战区半径                : " .. tostring(radius)) end
    end

    local xl = Safe(function() return XsLight ~= nil end, false)
    W(Fmt("  XsLight（光照感知）        : %s", xl and "已加载" or "未加载"))
    if xl then
        local mf = Safe(function() return XsLight.CFG and XsLight.CFG.MinFactor end, nil)
        local ub = Safe(function() return XsLight.CFG and XsLight.CFG.UnlimitedBase end, nil)
        if mf then W(Fmt("      全黑系数                : %.2f", mf)) end
        if ub then W("      本地生物基数            : " .. tostring(ub)) end
    end

    -- ---- C# 层（无法直接查，只能列出启动时应有的标记）----
    WL()
    W("[C# 层]（以下由启动日志确认，本报告无法直接读取）")
    W("  XsStatusThrottle : 启动日志搜「[XsStatusThrottle] 已加载」")
    W("  XsAILod          : 启动日志搜「[XsAILod] 已加载」")
    W("  XsGetItemsCache  : 启动日志搜「[XsGetItemsCache] 命中」")
    WL()
end

---------------------------------------------------------------------
-- 分区：运行时数据
---------------------------------------------------------------------
local function SectionRuntime()
    W("========== 运行时 ==========")

    local chars = 0
    Safe(function()
        for _ in Character.CharacterList do chars = chars + 1 end
    end)
    W("角色总数        : " .. chars)

    local items = 0
    Safe(function()
        for _ in Item.ItemList do items = items + 1 end
    end)
    W("物品总数        : " .. items)

    local subs = 0
    Safe(function()
        for _ in Submarine.Loaded do subs = subs + 1 end
    end)
    W("已加载潜艇      : " .. subs)

    -- 玩家位置
    local ctrl = Safe(function() return Character.Controlled end, nil)
    if ctrl then
        W("玩家角色        : " .. tostring(Safe(function() return ctrl.Name end, "?")))
        W("玩家位置        : " .. tostring(Safe(function()
            return string.format("%.0f, %.0f", ctrl.WorldPosition.X, ctrl.WorldPosition.Y)
        end, "?")))
    end
    WL()
end

---------------------------------------------------------------------
-- 分区：AI 状态抽样（判断 AILod 有没有用）
---------------------------------------------------------------------
local function SectionAI()
    W("========== AI 抽样（最多 15 个非玩家）==========")
    W(Fmt("%-4s %-22s %-16s %-10s %-12s %s", "ID", "名称", "AIState", "速度", "距最近玩家", "是否人类"))

    local count = 0
    Safe(function()
        for c in Character.CharacterList do
            if count >= 15 then break end
            if c ~= nil and not c.Removed and not c.IsPlayer and c.AIController ~= nil then
                count = count + 1

                -- AIState：枚举要 ToString()，直接 tostring 会得到数字
                local st = Safe(function()
                    local s = c.AIState
                    if s == nil then return "nil" end
                    local okT, v = pcall(function() return s.ToString() end)
                    if okT and v ~= nil then return tostring(v) end
                    return tostring(s)
                end, "?")

                local sp = Safe(function() return c.CurrentSpeed or 0 end, 0)
                local hp = Safe(function() return c.IsHuman end, false)

                -- 名称：优先 Info.Name，回退 Name
                local nm = Safe(function()
                    local n = c.Info and c.Info.Name
                    if n ~= nil and tostring(n) ~= "" then return tostring(n) end
                    return tostring(c.Name)
                end, "?")

                -- 距最近玩家
                local dist = Safe(function()
                    local best = 1e9
                    for p in Character.CharacterList do
                        if p ~= nil and not p.Removed and (p.IsPlayer or p == Character.Controlled) then
                            local d = (p.WorldPosition - c.WorldPosition).Length()
                            if d < best then best = d end
                        end
                    end
                    return best
                end, -1)

                W(Fmt("%-4s %-22s %-16s %-10.2f %-12.0f %s",
                    tostring(Safe(function() return c.ID end, "?")),
                    nm,
                    st, sp, dist, Bool(hp)))
            end
        end
    end)

    if count == 0 then W("  （当前没有 AI 角色）") end
    WL()
end

---------------------------------------------------------------------
-- 分区：潜艇电力（如果玩家在船上）
---------------------------------------------------------------------
local function SectionPower()
    W("========== 玩家潜艇电力 ==========")

    local sub = Safe(function()
        local c = Character.Controlled
        return c and c.Submarine or nil
    end, nil)

    if not sub then
        W("  （玩家不在潜艇上）")
        WL()
        return
    end

    W("潜艇名称        : " .. tostring(Safe(function() return sub.Info and sub.Info.Name end, "?")))

    Safe(function()
        local reactors, sc, jb = 0, 0, 0
        for item in Item.ItemList do
            if item ~= nil and not item.Removed and item.Submarine == sub then
                local idf = Safe(function() return tostring(item.Prefab.Identifier) end, "")
                if idf == "reactor1" then reactors = reactors + 1
                elseif idf == "supercapacitor" then sc = sc + 1
                elseif idf == "junctionbox" then jb = jb + 1
                end
            end
        end
        W("反应堆          : " .. reactors)
        W("超级电容器      : " .. sc)
        W("接线盒          : " .. jb)
    end)

    WL()
end

---------------------------------------------------------------------
-- 分区：已知问题提示
---------------------------------------------------------------------
local function SectionNotes()
    W("========== 已知提示 ==========")
    W("  1. GetItemsCache 命中率需要玩一会儿才有数据（刚启动 0% 正常）")
    W("  2. C# 插件状态只能看启动日志，本报告读不到")
    W("  3. 如果 EA 报 ambiguous method signature，是 EA 自己的兼容问题")
    WL()
end

---------------------------------------------------------------------
-- 写文件
---------------------------------------------------------------------
local function WriteFile(path, content)
    -- 方案 A：LuaCs 自带的 File 包装（MoonSharp 里可用）
    local okA = Safe(function()
        File.WriteAllText(path, content)
        return true
    end, false)
    if okA then return true end

    -- 方案 B：.NET System.IO（沙箱可能挡）
    local okB = Safe(function()
        System.IO.File.WriteAllText(path, content, System.Text.Encoding.UTF8)
        return true
    end, false)
    if okB then return true end

    -- 方案 C：标准 Lua io（若 LuaCs 开了 io 库）
    local okC = Safe(function()
        local f = io.open(path, "w")
        if f == nil then return false end
        f:write(content)
        f:close()
        return true
    end, false)

    return okC
end

---------------------------------------------------------------------
-- 主命令
---------------------------------------------------------------------
Game.AddCommand("cl_report", "生成诊断报告到 cl_report.txt", function()
    lines = {}

    W("##############################################################")
    W("#  Barotrauma 诊断报告")
    W("#  由 XsCore 的 cl_report 生成")
    W("##############################################################")
    WL()

    SectionEnv()
    SectionOurMods()
    SectionRuntime()
    SectionAI()
    SectionPower()
    SectionNotes()

    W("##############################################################")
    W("#  报告结束")
    W("##############################################################")

    local content = table.concat(lines, "\n")

    -- 候选路径：先试沙箱外容易找的位置
    local paths = {
        -- 1. 桌面（最方便你找到）
        Safe(function()
            local d = System.Environment.GetFolderPath(System.Environment.SpecialFolder.Desktop)
            return d .. "\\cl_report.txt"
        end, nil),
        -- 2. 我的文档
        Safe(function()
            local d = System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyDocuments)
            return d .. "\\cl_report.txt"
        end, nil),
        -- 3. 游戏目录
        Safe(function() return System.AppDomain.CurrentDomain.BaseDirectory .. "cl_report.txt" end, nil),
        -- 4. 当前工作目录
        "cl_report.txt",
    }

    local written = nil
    for _, p in ipairs(paths) do
        if p and WriteFile(p, content) then
            written = p
            break
        end
    end

    -- 控制台反馈
    print("")
    print("========================================")
    print("  诊断报告已生成")
    print("========================================")
    if written then
        print("  路径: " .. written)
    else
        print("  !! 写文件失败，改为直接输出到控制台")
        for _, l in ipairs(lines) do print(l) end
    end
    print("  行数: " .. #lines)
    print("========================================")
    print("")
end)
