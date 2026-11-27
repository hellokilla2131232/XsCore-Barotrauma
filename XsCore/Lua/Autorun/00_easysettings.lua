-- =====================================================================
-- easysettings —— 简易 GUI 设置面板库
--
-- 源自 Performance Fix 模组（Workshop 2701251094）的 Lua/easysettings.lua
-- 原样复用，用于给 XsCore 的优化模块提供可调参数界面。
--
-- 提供：
--   AddMenu(name, onOpen)          注册一个菜单项（出现在 ESC 暂停菜单）
--   BasicList(parent, size)        创建滚动列表容器
--   TickBox(parent, text, cb, st)  勾选框
--   Slider(parent, min, max, cb, v) 滑块
--   CloseButton(parent)            关闭按钮
--   SaveTable(path, tbl)           存 JSON
--   LoadTable(path)                读 JSON
--   Open(name)                     主动打开某个菜单
-- =====================================================================
local easySettings = {}

easySettings.Settings = {}

local GUIComponent = LuaUserData.CreateStatic("Barotrauma.GUIComponent")

local function GetChildren(comp)
    local tbl = {}
    for value in comp.GetAllChildren() do
        table.insert(tbl, value)
    end
    return tbl
end

Hook.Patch("Barotrauma.GUI", "TogglePauseMenu", {}, function ()
    if GUI.GUI.PauseMenuOpen then
        local frame = GUI.GUI.PauseMenu

        local list = GetChildren(GetChildren(frame)[2])[1]

        for key, value in pairs(easySettings.Settings) do
            local button = GUI.Button(GUI.RectTransform(Vector2(1, 0.1), list.RectTransform), value.Name, GUI.Alignment.Center, "GUIButtonSmall")

            button.OnClicked = function ()
                value.OnOpen(frame)
            end
        end
    end
end, Hook.HookMethodType.After)

easySettings.SaveTable = function (path, tbl)
    File.Write(path, json.serialize(tbl))
end
easySettings.LoadTable = function (path)
    if not File.Exists(path) then
        return {}
    end

    return json.parse(File.Read(path))
end

easySettings.AddMenu = function (name, onOpen)
    table.insert(easySettings.Settings, {Name = name, OnOpen = onOpen})
end

easySettings.BasicList = function (parent, size)
    local menuContent = GUI.Frame(GUI.RectTransform(size or Vector2(0.6, 0.6), parent.RectTransform, GUI.Anchor.Center))
    local menuList = GUI.ListBox(GUI.RectTransform(Vector2(1, 0.95), menuContent.RectTransform, GUI.Anchor.TopCenter))

    easySettings.CloseButton(menuContent)

    return menuList
end

easySettings.TickBox = function (parent, text, onSelected, state)
    if state == nil then state = true end

    local tickBox = GUI.TickBox(GUI.RectTransform(Vector2(1, 0.2), parent.RectTransform), text)
    tickBox.Selected = state
    tickBox.OnSelected = function ()
        onSelected(tickBox.State == GUIComponent.ComponentState.Selected)
    end

    return tickBox
end

easySettings.Slider = function (parent, min, max, onSelected, value)
    local scrollBar = GUI.ScrollBar(GUI.RectTransform(Vector2(1, 0.1), parent.RectTransform), 0.1, nil, "GUISlider")
    scrollBar.Range = Vector2(min, max)
    scrollBar.BarScrollValue = value or max / 2
    scrollBar.OnMoved = function ()
        onSelected(scrollBar.BarScrollValue)
    end

    return scrollBar
end

easySettings.CloseButton = function (parent)
    local button = GUI.Button(GUI.RectTransform(Vector2(1, 0.05), parent.RectTransform, GUI.Anchor.BottomCenter), "Close", GUI.Alignment.Center, "GUIButton")

    button.OnClicked = function ()
        GUI.GUI.TogglePauseMenu()
    end

    return button
end

easySettings.Open = function (name)
    for key, value in pairs(easySettings.Settings) do
        if value.Name == name then
            local frame = GUI.GUI.PauseMenu

            value.OnOpen(frame)
        end
    end
end

_G.easySettings = easySettings
return easySettings
