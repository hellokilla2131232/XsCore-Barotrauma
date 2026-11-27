print(">>> cl_ailod.lua 已开始执行 <<<")

-- =====================================================================
-- cl_ailod — AILod 参数设置面板 + 控制台命令
--
-- 依赖：00_easysettings.lua（必须按文件名排在前面先加载）
--
-- 配置文件：AILod.cfg（游戏根目录，纯 key=value 格式）
--
-- 【四个已踩的坑，改代码时别踩回去】
--   1. TickBox / Slider 的 parent 必须传 list.Content，
--      不能传 list 本身。GUIListBox 不允许直接加子元素，
--      会抛 "Children were added to GUIListBox" 并让游戏崩溃。
--
--   2. GUIScrollBar.BarScrollValue 收发都是【实际值】，不是 0~1 比例。
--      源码：get => BarScroll * (Range.Y - Range.X) + Range.X;
--            set => BarScroll = (value - Range.X) / (Range.Y - Range.X);
--      如果误传比例（如 0.45），会被当成 0.45 这个实际值处理，
--      BarScroll 算出来是负数并 clamp 到 0，滑块贴最左端。
--
--   3. GUI.TextBlock 创建后文本是写死的，不会自动刷新。
--      要实时显示滑块的值，必须保存引用并改它的 .Text。
--
--   4. GUITextBox.OnEnterPressed 的签名是
--      Func<GUITextBox, string, bool>，Lua 里要 return true 表示已处理，
--      否则文本框会按默认逻辑处理（可能导致值被吃掉）。
-- =====================================================================

-- 配置文件路径
-- 【关键】LuaCs 的 File.* 只能写「模组目录」。
--   PF 的做法：PerformanceFix.Path = ...  然后 File.Write(Path .. "/config.json")
--   `...` 是 LuaCs 传给 Autorun 脚本的 varargs，值就是模组根目录。
--   游戏根目录对 Lua 是只读的（写了静默失败），必须用模组目录。
local MOD_PATH = select(1, ...)
print("[AILod] MOD_PATH = [" .. tostring(MOD_PATH) .. "]")

local function GetCfgPath()
    if type(MOD_PATH) == "string" and MOD_PATH ~= "" then
        return MOD_PATH .. "/AILod.cfg"
    end

    -- 拿不到 varargs 时退回游戏根目录（C# 那边也用同一逻辑）
    local ok, base = pcall(function()
        return System.AppDomain.CurrentDomain.BaseDirectory
    end)
    if ok and base and base ~= "" then
        return base .. "AILod.cfg"
    end

    return "AILod.cfg"
end

local CFG_PATH = GetCfgPath()
local CFG_FILE = CFG_PATH

local defaults = {
    farRadius    = 2000,
    idleInterval = 0.25,
    enabled      = true,
    combatAuto   = true,    -- 战斗时自动缩小远场半径
}

-- 滑块范围
local DIST_MIN, DIST_MAX = 1000, 12000
local IV_MIN,   IV_MAX   = 0.1,  2.0

-- 建议范围（写进小贴士）
local DIST_SUGGEST = "1500 ~ 3000"
local IV_SUGGEST   = "0.20 ~ 0.35"

local cfg = {}
local _saveLogged = false

-- ---------- 接入 C# 的 AILodPlugin（直改内存字段，不依赖文件） ----------
-- LuaUserData.CreateStatic 不需要预先 RegisterType，只要类型存在就能拿到静态访问器
local AILodCs = nil
do
    -- 第一步：直接 CreateStatic
    local ok, v = pcall(function()
        return LuaUserData.CreateStatic("XsCore.AILodPlugin")
    end)
    if ok and v ~= nil then
        AILodCs = v
        print("[AILod] C# 接入成功（CreateStatic）")
    else
        print("[AILod] CreateStatic 失败: " .. tostring(v))

        -- 第二步：先 RegisterType 再 CreateStatic
        local ok2, err2 = pcall(function()
            LuaUserData.RegisterType("XsCore.AILodPlugin")
            return LuaUserData.CreateStatic("XsCore.AILodPlugin")
        end)
        if ok2 and err2 ~= nil then
            AILodCs = err2
            print("[AILod] C# 接入成功（RegisterType 后 CreateStatic）")
        else
            print("[AILod] RegisterType 也失败: " .. tostring(err2))
            print("[AILod] 将只靠 AILod.cfg 文件（需手动编辑）")
        end
    end
end

-- 把当前值推给 C#（失败静默，不影响 GUI）
local function PushToCs()
    if not AILodCs then return end
    pcall(function() AILodCs.SetEnabled(cfg.enabled) end)
    pcall(function() AILodCs.SetFarRadius(cfg.farRadius) end)
    pcall(function() AILodCs.SetIdleInterval(cfg.idleInterval) end)
end

local function Clamp(v, mn, mx)
    if v < mn then return mn end
    if v > mx then return mx end
    return v
end

---------------------------------------------------------------------
-- 创建可输入的文本框
-- Barotrauma 没有 GUI.TextBox，只有：
--   GUI.CreateTextBoxWithPlaceholder(rectT, text, LocalizedString placeholder)
-- 若创建失败则退化为只读 TextBlock，保证面板不会崩。
---------------------------------------------------------------------
local textBoxAvailable = nil   -- nil=未探测, true/false=结果

local function MakeValueBox(parent, value)
    local rectT = GUI.RectTransform(Vector2(0.35, 0.055), parent)

    -- 首次调用时探测
    if textBoxAvailable == nil then
        local ok = pcall(function()
            local probe = GUI.CreateTextBoxWithPlaceholder(rectT, "0", nil)
            if probe == nil then error("nil") end
            -- 探测用，立刻移除
            if probe.Parent then probe.Parent.RemoveChild(probe) end
        end)
        textBoxAvailable = ok and true or false
        if not textBoxAvailable then
            print("[AILod] 提示：本版本无可用输入框 API，改用手动输入模式（用 cl_ailod 命令设值）")
        end
        -- 探测的 rectT 已被消耗，重建一个
        rectT = GUI.RectTransform(Vector2(0.35, 0.055), parent)
    end

    if textBoxAvailable then
        local ok, box = pcall(function()
            return GUI.CreateTextBoxWithPlaceholder(rectT, value, nil)
        end)
        if ok and box ~= nil then
            return box, true
        end
        textBoxAvailable = false
    end

    -- 退化：只读文本
    return GUI.TextBlock(rectT, value, nil, nil), false
end

---------------------------------------------------------------------
-- 读写配置
---------------------------------------------------------------------
local function ResetToDefaults()
    for k, v in pairs(defaults) do cfg[k] = v end
end

local function LoadCfg()


-- 配置文件存在性检查延后到 BuildPanel 之后
    ResetToDefaults()

    local ok, content = pcall(function()
        return System.IO.File.ReadAllText(CFG_PATH)
    end)
    if not ok or content == nil or content == "" then
        -- 退化：再试一次 LuaCs 的 File.Read
        local ok2, c2 = pcall(function() return File.Read(CFG_PATH) end)
        if not ok2 or c2 == nil then return end
        content = c2
    end

    for line in content:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" then
            if v == "true" then
                cfg[k] = true
            elseif v == "false" then
                cfg[k] = false
            else
                local n = tonumber(v)
                cfg[k] = n or v
            end
        end
    end
end

local function SaveCfg()
    local lines = {}
    for k, _ in pairs(defaults) do
        lines[#lines + 1] = string.format("%s=%s", k, tostring(cfg[k]))
    end
    local content = table.concat(lines, "\n")

    -- 1) System.IO + UTF8（无 BOM）
    local ok = pcall(function()
        System.IO.File.WriteAllText(CFG_PATH, content,
            System.Text.UTF8Encoding(false))
        return true
    end)
    if ok then
        if not _saveLogged then
            _saveLogged = true
            print("[AILod] 配置已写入: " .. tostring(CFG_PATH))
        end
        return true
    end

    -- 2) LuaCs 的 File.WriteAllText
    ok = pcall(function() File.WriteAllText(CFG_PATH, content) end)
    if ok then return true end

    -- 3) LuaCs 的 File.Write
    ok = pcall(function() File.Write(CFG_PATH, content) end)
    return ok
end

LoadCfg()

---------------------------------------------------------------------
-- GUI 面板
---------------------------------------------------------------------
local function BuildPanel()
    if not _G.easySettings then
        print("[AILod] 警告：easysettings 未加载，设置面板不可用（命令仍可用）")
        return
    end

    easySettings.AddMenu("XsCore · AI LOD", function (frame)
        local list = easySettings.BasicList(frame, Vector2(0.72, 0.85))
        local content = list.Content          -- 坑1：必须用 Content
        local rt = content.RectTransform

        -- 标题
        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.05), rt), "AI LOD 设置", nil, nil)
        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.05), rt),
            "远处站着不动的 AI 会被降频，减少 Update 调用。", nil, nil)

        -- ---- 开关 ----
        easySettings.TickBox(content, "启用 AILod", function (state)
            cfg.enabled = state
            if AILodCs then
                pcall(function() AILodCs.SetEnabled(state) end)
            end
            SaveCfg()
        end, cfg.enabled)

        -- 战斗自适应开关
        easySettings.TickBox(content, "战斗时自动缩小远场（推荐开启）", function (state)
            cfg.combatAuto = state
            SaveCfg()
        end, cfg.combatAuto)

        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.05), rt),
            "玩家 3000px 内出现 >=2 个其他角色时判定为战斗中，\n" ..
            "远场半径自动缩到 25%（例如 2000 → 500），打完自动恢复。", nil, nil)

        -------------------------------------------------------------
        -- 距离：输入框 + 滑块
        -------------------------------------------------------------
        local distBox, distSlider, distEditable
        local syncing = false

        local function ApplyDistance(v, fromSlider)
            if syncing then return end
            syncing = true
            v = math.floor(Clamp(tonumber(v) or cfg.farRadius, DIST_MIN, DIST_MAX))
            cfg.farRadius = v
            if distBox then distBox.Text = tostring(v) end
            if not fromSlider and distSlider then
                distSlider.BarScrollValue = v
            end
            if AILodCs then
                pcall(function() AILodCs.SetFarRadius(cfg.farRadius) end)
            end
            SaveCfg()
            syncing = false
        end

        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.04), rt),
            "远场半径（px）", nil, nil)

        distBox, distEditable = MakeValueBox(rt, tostring(math.floor(cfg.farRadius)))
        if distEditable and distBox then
            -- 坑4：返回 true 表示已处理
            distBox.OnEnterPressed = function (tb, text)
                local n = tonumber(text)
                if n then
                    ApplyDistance(n, false)
                else
                    tb.Text = tostring(math.floor(cfg.farRadius))   -- 无效则回滚
                end
                return true
            end
        end

        distSlider = easySettings.Slider(content, DIST_MIN, DIST_MAX, function (v)
            ApplyDistance(v, true)
        end, cfg.farRadius)

        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.03), rt),
            string.format("范围 %d ~ %d    │    建议 %s", DIST_MIN, DIST_MAX, DIST_SUGGEST),
            nil, nil)
        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.05), rt),
            "超过此距离的站桩 AI 才降频。越大越省，但远处 AI 的动作会变迟钝。", nil, nil)

        -------------------------------------------------------------
        -- 间隔：输入框 + 滑块
        -------------------------------------------------------------
        local ivBox, ivSlider, ivEditable
        local syncingIv = false

        local function ApplyInterval(v, fromSlider)
            if syncingIv then return end
            syncingIv = true
            v = Clamp(tonumber(v) or cfg.idleInterval, IV_MIN, IV_MAX)
            -- 保留两位小数
            v = math.floor(v * 100 + 0.5) / 100
            cfg.idleInterval = v
            if ivBox then ivBox.Text = string.format("%.2f", v) end
            if not fromSlider and ivSlider then
                ivSlider.BarScrollValue = v
            end
            if AILodCs then
                pcall(function() AILodCs.SetIdleInterval(cfg.idleInterval) end)
            end
            SaveCfg()
            syncingIv = false
        end

        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.04), rt),
            "闲置间隔（秒）", nil, nil)

        ivBox, ivEditable = MakeValueBox(rt, string.format("%.2f", cfg.idleInterval))
        if ivEditable and ivBox then
            ivBox.OnEnterPressed = function (tb, text)
                local n = tonumber(text)
                if n then
                    ApplyInterval(n, false)
                else
                    tb.Text = string.format("%.2f", cfg.idleInterval)
                end
                return true
            end
        end

        ivSlider = easySettings.Slider(content, IV_MIN, IV_MAX, function (v)
            ApplyInterval(v, true)
        end, cfg.idleInterval)

        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.03), rt),
            string.format("范围 %.2f ~ %.2f    │    建议 %s", IV_MIN, IV_MAX, IV_SUGGEST),
            nil, nil)
        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.05), rt),
            "降频后的更新频率。越大越省，但 AI 的反应会慢。", nil, nil)

        -------------------------------------------------------------
        -- 条件说明
        -------------------------------------------------------------
        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.20), rt),
            "降频条件（全部满足才会跳过 Update）:\n" ..
            "  1. 不是玩家角色\n" ..
            "  2. 有 AIController\n" ..
            "  3. AIState = Idle（空闲）\n" ..
            "  4. 当前速度 <= 0.5\n" ..
            "  5. 距离最近玩家 > 远场半径", nil, nil)

        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.04), rt),
            "回车确认输入。修改立刻写入 AILod.cfg，C# 侧 5 秒内重读。", nil, nil)
    end)
end

-- 用 pcall 包裹，防止面板注册失败导致整个脚本中断
do
    local ok, err = pcall(BuildPanel)
    if ok then
        print("[AILod] 面板已注册（ESC 菜单里会出现 XsCore · AI LOD）")
    else
        print("[AILod] !! 面板注册失败: " .. tostring(err))
    end
end

-- 启动时把已有配置推给 C#
do
    if AILodCs then
        local ok = pcall(PushToCs)
        if ok then
            print("[AILod] 已把当前配置推给 C#")
        end
    else
        print("[AILod] C# AILodPlugin 未接入（只靠配置文件）")
    end
end

-- 配置文件：放在面板之后处理，失败也不影响菜单
do
    local ok, err = pcall(function()
        local exists = false
        pcall(function() exists = System.IO.File.Exists(CFG_PATH) end)

        if exists then
            print("[AILod] 读取配置: " .. tostring(CFG_PATH))
        else
            local okw = SaveCfg()
            if okw then
                print("[AILod] 已创建默认配置: " .. tostring(CFG_PATH))
            else
                print("[AILod] !! 配置文件写入失败: " .. tostring(CFG_PATH))
            end
        end
    end)
    if not ok then
        print("[AILod] !! 配置文件操作异常: " .. tostring(err) .. "（命令仍可用）")
    end
end

---------------------------------------------------------------------
-- 命令
---------------------------------------------------------------------
local function ShowStatus()
    print("")
    print("========================================")
    print("  AILod 当前设置")
    print("========================================")
    print("  启用        : " .. (cfg.enabled and "是" or "否"))
    print("  远场半径    : " .. tostring(math.floor(cfg.farRadius)) .. " px")
    print("                范围 " .. DIST_MIN .. " ~ " .. DIST_MAX .. "，建议 " .. DIST_SUGGEST)
    print("  闲置间隔    : " .. string.format("%.2f", cfg.idleInterval) .. " 秒")
    print("  战斗自适应  : " .. (cfg.combatAuto and "开（战斗中远场缩到 25%）" or "关"))
    print("                范围 " .. string.format("%.2f", IV_MIN) .. " ~ " ..
          string.format("%.2f", IV_MAX) .. "，建议 " .. IV_SUGGEST)
    print("  配置文件    : " .. CFG_FILE)
    print("")
    print("  改值方式：")
    print("    cl_ailod 8000           只改距离")
    print("    cl_ailod 8000 0.3       改距离 + 间隔")
    print("    cl_ailod on / off       开关")
    print("    cl_ailod reload         重读配置文件")
    print("    cl_ailod reset          恢复默认")
    print("  或按 ESC 用「XsCore · AI LOD」面板调")
    print("========================================")
    print("")
end

Game.AddCommand("cl_ailod", "查看/设置 AILod 参数", function (args)
    -- 调试：把 args 的真实类型和值打出来
    print("[AILod] args type=" .. type(args) .. " value=[" .. tostring(args) .. "]")

    -- LuaCs 的 AddCommand 回调第一个参数是 table（参数数组）
    local parts = {}
    if type(args) == "table" then
        local i = 1
        while args[i] ~= nil do
            parts[#parts + 1] = tostring(args[i])
            i = i + 1
        end
    elseif args ~= nil then
        parts[1] = tostring(args)
    end
    local a = table.concat(parts, " ")
    a = a:gsub("^%s+", ""):gsub("%s+$", "")

    if a == "" then
        ShowStatus()
        return
    end

    if a == "reload" then
        LoadCfg()
        print("[AILod] 已重读 " .. CFG_FILE)
        ShowStatus()
        return
    end

    if a == "reset" then
        ResetToDefaults()
        SaveCfg()
        print("[AILod] 已恢复默认值")
        ShowStatus()
        return
    end

    if a == "on" then
        cfg.enabled = true
        SaveCfg()
        print("[AILod] 已启用")
        return
    end

    if a == "off" then
        cfg.enabled = false
        SaveCfg()
        print("[AILod] 已禁用")
        return
    end

    local nums = {}
    for w in a:gmatch("%S+") do
        local n = tonumber(w)
        if n then nums[#nums + 1] = n end
    end

    if #nums == 0 then
        print("[AILod] 参数无效，输入 cl_ailod 查看用法")
        return
    end

    if #nums >= 1 then
        local d = nums[1]
        if d < 100 or d > 100000 then
            print("[AILod] 距离应在 100 ~ 100000 之间")
            return
        end
        cfg.farRadius = math.floor(d)
    end

    if #nums >= 2 then
        local iv = nums[2]
        if iv < 0.05 or iv > 5.0 then
            print("[AILod] 间隔应在 0.05 ~ 5.0 之间")
            return
        end
        cfg.idleInterval = iv
    end

    SaveCfg()
    print("[AILod] 已更新并写入 " .. CFG_FILE)
    ShowStatus()
end)
