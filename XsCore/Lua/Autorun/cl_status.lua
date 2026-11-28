-- =====================================================================
-- XsStatus 一键体检：检查所有优化模组是否生效
-- 命令：cl_status
-- =====================================================================

local MOD_PATH = select(1, ...)

local function ok(b) return b and "[OK]" or "[--]" end

local function TryRead(fn)
    local ok_, v = pcall(fn)
    if ok_ then return v end
    return nil
end

Game.AddCommand("cl_status", "检查所有优化模组的加载状态", function()
    print("")
    print("========================================")
    print("   优化模组状态体检")
    print("========================================")

    ---------------------------------------------------------------
    -- 一、Lua 层
    ---------------------------------------------------------------
    print("")
    print("[Lua 层]")

    -- Performance Fix
    local pf = TryRead(function() return PerformanceFix ~= nil and PerformanceFix.Config ~= nil end)
    print(string.format("  %s Performance Fix%s", ok(pf), pf and "" or "（未加载或未启用）"))

    -- XsPerf
    local xp = TryRead(function() return XsPerf ~= nil end)
    print(string.format("  %s XsPerf（战斗状态感知）", ok(xp)))

    -- XsLight
    local xl = TryRead(function() return XsLight ~= nil end)
    print(string.format("  %s XsLight（光照感知）", ok(xl)))

    -- 光照参数抽查
    if xl then
        local minf = TryRead(function() return XsLight.CFG and XsLight.CFG.MinFactor end)
        if minf then
            print(string.format("        全黑感知系数 = %.2f", minf))
        end
    end

    ---------------------------------------------------------------
    -- 二、C# 层（无法直接从 Lua 读，用间接指标）
    ---------------------------------------------------------------
    print("")
    -- ---------------------------------------------------------------
    -- AILod：读共享配置文件（C# 那边 5 秒热重载）
    -- 注意：LuaUserData.CreateStatic 拿不到自定义插件的类型，
    --       所以不走内存直连，改成读 AILod.cfg。
    -- ---------------------------------------------------------------
    do
        local cfgPath
        if type(MOD_PATH) == "string" and MOD_PATH ~= "" then
            cfgPath = MOD_PATH .. "/AILod.cfg"
        else
            cfgPath = "AILod.cfg"
        end

        local exists, content = false, nil

        -- 多层回退：System.IO 在 LuaCs 沙箱里可能不可用，退回 File.*
        pcall(function() exists = System.IO.File.Exists(cfgPath) end)
        if not exists then
            pcall(function() exists = File.Exists(cfgPath) end)
        end

        if exists then
            pcall(function() content = System.IO.File.ReadAllText(cfgPath) end)
            if content == nil then
                pcall(function() content = File.Read(cfgPath) end)
            end
        end

        if exists and content and content ~= "" then
            print("  [OK] AILod.cfg 已存在")
            print("       路径: " .. tostring(cfgPath))
            for line in content:gmatch("[^\r\n]+") do
                local s = line:gsub("^%s+", ""):gsub("%s+$", "")
                if s ~= "" and s:sub(1, 1) ~= "#" then
                    print("       " .. s)
                end
            end
        else
            print("  [--] AILod.cfg 不存在或读不到")
            print("       路径: " .. tostring(cfgPath))
        end
    end

    print("")
    print("[C# 层]（启动日志里搜 [XsStatusThrottle] / [XsAILod]）")

    local ci = TryRead(function() return Game.characterUpdateInterval end)
    local mi = TryRead(function() return Game.mapEntityUpdateInterval end)
    local pi = TryRead(function() return Game.poweredUpdateInterval end)
    print(string.format("  characterUpdateInterval  = %s", tostring(ci)))
    print(string.format("  mapEntityUpdateInterval  = %s", tostring(mi)))
    print(string.format("  poweredUpdateInterval    = %s", tostring(pi)))
    print("  （这三个值被改过 → Performance Fix 或 XsPerf 在管）")

    ---------------------------------------------------------------
    -- 三、运行时指标
    ---------------------------------------------------------------
    print("")
    print("[运行时]")

    local acc = TryRead(function() return Timer.AccumulatorMax end)
    if acc then
        print(string.format("  Timer.AccumulatorMax = %.3f 秒", acc))
    end

    -- 角色数
    local n = 0
    pcall(function()
        for _ in Character.CharacterList do n = n + 1 end
    end)
    print(string.format("  当前角色总数 = %d", n))

    -- 物品数
    local items = 0
    pcall(function()
        for _ in Item.ItemList do items = items + 1 end
    end)
    print(string.format("  当前物品总数 = %d", items))

    ---------------------------------------------------------------
    -- 四、命令提示
    ---------------------------------------------------------------
    print("")
    print("[其它诊断命令]")
    print("  cl_perf          帧时间统计（XsPerf）")
    print("  cl_perf_mode     兼容/独立模式")
    print("  cl_light_probe   光照度与物种判定（XsLight）")
    print("  cl_light         切换光照感知")
    print("  cl_btfix_stat    BT 补丁统计（若装了 XsBtFix）")
    print("========================================")
    print("")
end)
