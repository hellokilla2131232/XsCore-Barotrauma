-- =====================================================================
-- Xs 性能补丁 · 动态优先级调度（兼容版）
--
-- 设计要点：
--   1) 若检测到 Performance Fix 已在运行 → 自动进入「兼容模式」
--      · 不碰 characterUpdateInterval / mapEntityUpdateInterval（交给它管）
--      · 不清空优先级表（它每 roundStart 会 Clear，清空会打架）
--      · 只做 Performance Fix 没做的事：战斗状态检测 + 追加战斗参与者
--   2) 若没有 Performance Fix → 进入「独立模式」，自己管间隔与优先级
--
-- 两种模式下都不 Hook.Patch 任何游戏方法，只用官方 LuaCs API
-- =====================================================================

XsPerf = XsPerf or {}
XsPerf.Path = table.pack(...)[1]

local CFG = {
    Enabled            = true,

    -- 独立模式下才生效（兼容模式下自动忽略）
    ManageIntervals    = true,   -- 是否自己设全局更新间隔
    FarCharacterInterval = 3,
    MapEntityInterval    = 3,
    PoweredInterval      = 2,
    AccumulatorMaxMs     = 80,

    -- 战斗判定
    CombatRadius       = 3000,
    CombatMinOthers    = 2,

    -- 调度
    RescanIntervalMs   = 500,

    -- 兼容模式下是否也提升手持物（默认开，开销很小）
    BoostItemsInCombat = true,

    -- 渲染侧（可选，默认关，留给 Shadow Culling 处理）
    CullShadows        = false,
    CullShadowMaxDist  = 6000,

    Debug              = false,
}

-- ===================== 运行环境判定 =====================
local CompatMode = false          -- true = 检测到 Performance Fix

local function DetectEnv()
    local ok, present = pcall(function()
        return PerformanceFix ~= nil and PerformanceFix.Config ~= nil
    end)
    CompatMode = ok and present or false
    if CompatMode then
        print("[XsPerf] 检测到 Performance Fix，进入兼容模式：不接管间隔与优先级表，只追加战斗参与者")
    else
        print("[XsPerf] 未检测到 Performance Fix，进入独立模式：自行管理间隔与优先级")
    end
end

-- ===================== 全局间隔（仅独立模式）=====================
local function ApplyGlobalIntervals()
    if not CFG.Enabled then return end
    if CompatMode or not CFG.ManageIntervals then return end
    local ok, err = pcall(function()
        Game.characterUpdateInterval = CFG.FarCharacterInterval
        Game.mapEntityUpdateInterval = CFG.MapEntityInterval
        if Game.IsMultiplayer then
            Game.poweredUpdateInterval = CFG.PoweredInterval
        end
        Timer.AccumulatorMax = CFG.AccumulatorMaxMs / 1000
    end)
    if not ok then
        print("[XsPerf] 应用全局间隔失败：" .. tostring(err))
    end
end

local function RestoreGlobalIntervals()
    pcall(function()
        Game.characterUpdateInterval = 1
        Game.mapEntityUpdateInterval = 1
        Game.poweredUpdateInterval = 1
    end)
end

-- ===================== 工具 =====================
local function Dist(a, b)
    return Vector2.Distance(a.WorldPosition, b.WorldPosition)
end

local function IsAlive(c)
    return c ~= nil and not c.IsDead and not c.Removed
end

local function GetPlayers()
    local list = {}
    for c in Character.CharacterList do
        if IsAlive(c) and (c.IsPlayer or Character.Controlled == c) then
            list[#list + 1] = c
        end
    end
    return list
end

local function FindCombatZones(players)
    local inZone = {}
    if #players == 0 then return inZone end
    for _, p in ipairs(players) do
        local nearby = {}
        for c in Character.CharacterList do
            if c ~= p and IsAlive(c) and Dist(c, p) <= CFG.CombatRadius then
                nearby[#nearby + 1] = c
            end
        end
        if #nearby >= CFG.CombatMinOthers then
            inZone[p] = true
            for _, c in ipairs(nearby) do inZone[c] = true end
        end
    end
    return inZone
end

-- ===================== 调度 =====================
local lastScan = -1
local p0Count = 0
local modeTag = "?"

local function Rescan()
    if not CFG.Enabled then return end

    local players = GetPlayers()
    local zone = FindCombatZones(players)

    -- ★ 关键：兼容模式下绝不清空（Performance Fix 的调度会保留，我们只追加）
    if not CompatMode then
        pcall(function() Game.ClearPriorityCharacter() end)
        pcall(function() Game.ClearPriorityItem() end)
    end

    p0Count = 0

    for c in Character.CharacterList do
        if IsAlive(c) and (zone[c] or c.IsPlayer or Character.Controlled == c) then
            pcall(function() Game.AddPriorityCharacter(c) end)
            p0Count = p0Count + 1

            if CFG.BoostItemsInCombat and c.Inventory ~= nil then
                local r = c.Inventory.GetItemInLimbSlot(InvSlotType.RightHand)
                local l = c.Inventory.GetItemInLimbSlot(InvSlotType.LeftHand)
                if r ~= nil then pcall(function() Game.AddPriorityItem(r) end) end
                if l ~= nil then pcall(function() Game.AddPriorityItem(l) end) end
            end
        end
    end

    -- 阴影剔除（默认关；若装了 Shadow Culling 就别开）
    if CFG.CullShadows and CLIENT then
        local ref = Character.Controlled
        pcall(function()
            for item in Item.ItemList do
                if not item.Removed then
                    local light = item.GetComponentString("LightComponent")
                    if light ~= nil then
                        local far = (ref == nil) or (Dist(item, ref) > CFG.CullShadowMaxDist)
                        if far ~= light.CastShadows then
                            light.CastShadows = not far
                        end
                    end
                end
            end
        end)
    end

    lastScan = Timer.GetTime()
    modeTag = CompatMode and "兼容(追加)" or "独立(接管)"
end

-- ===================== 帧时间统计 =====================
local frameTimes = {}
local lastFrameTime = Timer.GetTime()

local function TrackFrame()
    local now = Timer.GetTime()
    frameTimes[#frameTimes + 1] = now - lastFrameTime
    lastFrameTime = now
    if #frameTimes > 600 then table.remove(frameTimes, 1) end
end

local function FrameStats()
    if #frameTimes == 0 then return nil end
    local sum, mx = 0, 0
    for i = 1, #frameTimes do
        local v = frameTimes[i]
        sum = sum + v
        if v > mx then mx = v end
    end
    return sum / #frameTimes, mx, #frameTimes
end

-- ===================== 钩子 =====================
Hook.Add("loaded", "XsPerf.init", function()
    DetectEnv()
    ApplyGlobalIntervals()
    Timer.Wait(function() Rescan() end, 1500)
    print(string.format("[XsPerf] 已启用 | 模式=%s | 战区半径=%d | %s",
        modeTag, CFG.CombatRadius,
        CompatMode and "间隔由 Performance Fix 管理" or ("远场角色间隔=" .. CFG.FarCharacterInterval)))
end)

Hook.Add("roundStart", "XsPerf.round", function()
    DetectEnv()
    ApplyGlobalIntervals()
    -- 兼容模式下延迟更久，确保 Performance Fix 先完成它自己的 SetPriority
    Timer.Wait(function() Rescan() end, CompatMode and 1600 or 800)
end)

Hook.Add("think", "XsPerf.scheduler", function()
    TrackFrame()
    if Timer.GetTime() - lastScan >= (CFG.RescanIntervalMs / 1000) then
        Rescan()
    end
end)

Hook.Add("item.equip", "XsPerf.equip", function(item, character)
    if item == nil then return end
    pcall(function()
        Game.RemovePriorityItem(item)
        Game.AddPriorityItem(item)
    end)
end)

Hook.Add("characterCreated", "XsPerf.spawn", function(character)
    if not IsAlive(character) then return end
    local p = Character.Controlled
    if p ~= nil and Dist(character, p) <= CFG.CombatRadius then
        pcall(function() Game.AddPriorityCharacter(character) end)
    end
end)

-- ===================== 控制台 =====================
Game.AddCommand("cl_perf", "XsPerf：打印帧时间统计与当前模式", function()
    local avg, mx, n = FrameStats()
    if avg == nil then
        print("[XsPerf] 还没有采样数据")
        return
    end
    local fps = 0
    if avg > 0 then fps = 1 / avg end
    print(string.format("[XsPerf] 模式=%s | 采样 %d 帧 | 平均 %.2f ms (约 %.0f FPS) | 最长 %.1f ms | P0 实体 %d",
        modeTag, n, avg * 1000, fps, mx * 1000, p0Count))
end)

Game.AddCommand("cl_perf_toggle", "XsPerf：开关本模组（兼容模式下只停追加，不影响 Performance Fix）", function()
    CFG.Enabled = not CFG.Enabled
    if CFG.Enabled then
        ApplyGlobalIntervals()
        Rescan()
        print("[XsPerf] 已开启（模式=" .. modeTag .. "）")
    else
        if not CompatMode then
            RestoreGlobalIntervals()
            pcall(function() Game.ClearPriorityCharacter() end)
            pcall(function() Game.ClearPriorityItem() end)
        end
        print("[XsPerf] 已关闭（兼容模式：Performance Fix 不受影响）")
    end
end)

Game.AddCommand("cl_perf_mode", "XsPerf：显示当前运行模式与冲突状态", function()
    print(string.format("[XsPerf] 兼容模式=%s | ManageIntervals=%s | P0=%d",
        tostring(CompatMode), tostring(CFG.ManageIntervals), p0Count))
    if CompatMode then
        print("  → 检测到 Performance Fix：间隔与静态优先级由它管理，本模组只追加战斗参与者")
    else
        print("  → 未检测到 Performance Fix：本模组自行管理间隔与优先级")
    end
end)
