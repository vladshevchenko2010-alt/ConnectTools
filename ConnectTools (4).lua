script_name('ConnectTools for Arizona Mobile')
script_version('2.0.2')
script_version_number(4)
script_author('Radare')
script_description('Reconnect to the server and autologin to your account as well auto-registration (fully controllable)')

local sf = require 'sampfuncs'
local sampev = require 'lib.samp.events'
local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local dlstatus = require 'moonloader'.download_status

-- true = пишет в moonloader.log все пакеты интерфейса 9 (пароль НЕ выводится)
local DEBUG = true

---------------------------------------------------------------------
-- КОНФИГ
---------------------------------------------------------------------
local cfg_path = getWorkingDirectory() .. '/config/ConnectTools.json'

local default_cfg = {
    config = { AutoReconnect = false, AutoLogin = false, AutoReg = false, Theme = 2, Enabled = true },
    autoreconnect = { onBanned = false, onPassword = false, onKicked = false, onRejected = false, delay = 10.0 },
    autologin = {
        nickname = "Your_Nickname",
        password = "yourpassword",
        spawn = "[{\"id\": 0, \"spawn\": \"Стандартный спавн\" }]",
        spawn_use = 0
    },
    autoreg = { password = "123123", refferal = "Sam_Mason", resetId = false },
    macro = { enabled = false, delay = 400, steps = {} },
    custom = {
        bg = {0.06, 0.08, 0.13},
        frame = {0.10, 0.14, 0.22},
        accent = {0.26, 0.59, 0.98},
        text = {0.95, 0.97, 1.00}
    }
}

local function merge(defaults, loaded)
    local res = {}
    for k, v in pairs(defaults) do
        if type(v) == 'table' then
            if next(v) == nil then
                res[k] = (type(loaded) == 'table' and type(loaded[k]) == 'table') and loaded[k] or {}
            else
                res[k] = merge(v, type(loaded) == 'table' and loaded[k] or nil)
            end
        else
            if type(loaded) == 'table' and loaded[k] ~= nil then res[k] = loaded[k] else res[k] = v end
        end
    end
    return res
end

local function load_config()
    local loaded
    if doesFileExist(cfg_path) then
        local f = io.open(cfg_path, 'r')
        if f then
            local content = f:read('*a')
            f:close()
            local ok, decoded = pcall(decodeJson, content)
            if ok and type(decoded) == 'table' then loaded = decoded end
        end
    end
    return merge(default_cfg, loaded)
end

local toolsconfig = load_config()

local function cfg_save()
    local dir = getWorkingDirectory() .. '/config'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local f = io.open(cfg_path, 'w')
    if f then
        f:write(encodeJson(toolsconfig))
        f:close()
    end
end

---------------------------------------------------------------------
-- ПЕРЕМЕННЫЕ
---------------------------------------------------------------------
local renderWindow = ffi.new('bool[1]', false)
local NickName = ffi.new('char[256]', toolsconfig.autologin.nickname)
local Password = ffi.new('char[256]', toolsconfig.autologin.password)
local regPassword = ffi.new('char[256]', toolsconfig.autoreg.password)
local refferalName = ffi.new('char[256]', toolsconfig.autoreg.refferal)

local sizeX, sizeY = getScreenResolution()
local item_spawn = {}
local items_spawn
local Reconnect = {
    delay = ffi.new('float[1]', toolsconfig.autoreconnect.delay),
    remaining = 0,
    active = ffi.new('bool[1]', false)
}
local scr_dir = getWorkingDirectory() .. '/ConnectTools'
local names_file, surnames_file = scr_dir .. '/names.txt', scr_dir .. '/surnames.txt'
local connects, nickname, exit, lastNickname, lastPassword = 0, nil, false, "", ""
local current_item_spawn = ffi.new('int[1]', toolsconfig.autologin.spawn_use)

local AutoReconnect = ffi.new('bool[1]', toolsconfig.config.AutoReconnect)
local AutoLogin = ffi.new('bool[1]', toolsconfig.config.AutoLogin)
local AutoReg = ffi.new('bool[1]', toolsconfig.config.AutoReg)
local onBanned = ffi.new('bool[1]', toolsconfig.autoreconnect.onBanned)
local onPassword = ffi.new('bool[1]', toolsconfig.autoreconnect.onPassword)
local onKicked = ffi.new('bool[1]', toolsconfig.autoreconnect.onKicked)
local onRejected = ffi.new('bool[1]', toolsconfig.autoreconnect.onRejected)
local resetId = ffi.new('bool[1]', toolsconfig.autoreg.resetId)

---------------------------------------------------------------------
-- МАКРОС: запись ваших нажатий и автоповтор
---------------------------------------------------------------------
local MACRO_IFACE = 9 -- интерфейс экранов входа/спавна
local macro = {
    rec = ffi.new('bool[1]', false),
    enabled = ffi.new('bool[1]', toolsconfig.macro.enabled),
    delay = ffi.new('int[1]', toolsconfig.macro.delay),
    idx = 1, seq = 0, lastKey = '', lastClickSeq = -1,
    busy = false, sending = false, lastRestart = 0
}

local function trig_key(iface, sub, json)
    json = tostring(json or '')
    if #json > 24 then json = '' end
    return iface .. ':' .. sub .. ':' .. json
end

local function macro_run_from(i)
    if macro.busy then return end
    macro.busy = true
    lua_thread.create(function()
        wait(toolsconfig.macro.delay)
        local steps = toolsconfig.macro.steps
        local first = true
        while i <= #steps do
            local st = steps[i]
            if not first and not st.chain then break end
            if not first then wait(300) end
            macro.sending = true
            sendFrontendClick(st.iface, st.id, st.sub, st.json)
            macro.sending = false
            showToolTip("Макрос: шаг " .. i .. " из " .. #steps)
            first = false
            i = i + 1
        end
        macro.idx = i
        macro.busy = false
    end)
end

local function macro_on_incoming(iface, sub, json)
    if iface ~= MACRO_IFACE then return end
    macro.seq = macro.seq + 1
    macro.lastKey = trig_key(iface, sub, json)
    if toolsconfig.macro.enabled and not macro.rec[0] and not AutoLogin[0] and not AutoReg[0] and not macro.busy then
        local steps = toolsconfig.macro.steps
        local st = steps[macro.idx]
        if st and st.trig == macro.lastKey then
            macro_run_from(macro.idx)
        elseif steps[1] and steps[1].trig == macro.lastKey and os.clock() - macro.lastRestart > 5 then
            -- снова показан экран входа (например, после рестарта сервера): начинаем с первого шага
            macro.lastRestart = os.clock()
            macro.idx = 1
            macro_run_from(1)
        end
    end
end

local function macro_on_send(iface, id_val, sub, json_str)
    if iface ~= MACRO_IFACE or not macro.rec[0] or macro.sending then return end
    table.insert(toolsconfig.macro.steps, {
        iface = iface, id = id_val, sub = sub, json = json_str,
        trig = macro.lastKey,
        chain = (macro.seq == macro.lastClickSeq)
    })
    macro.lastClickSeq = macro.seq
    cfg_save()
end

---------------------------------------------------------------------
-- ТЕМА
---------------------------------------------------------------------
local THEMES = {
    { name = 'Тёмная',     bg = {0.07,0.07,0.07}, frame = {0.13,0.13,0.13}, accent = {0.55,0.55,0.55}, text = {1.00,1.00,1.00}, check = {1.00,1.00,1.00} },
    { name = 'Синяя',      bg = {0.06,0.08,0.13}, frame = {0.10,0.14,0.22}, accent = {0.26,0.59,0.98}, text = {0.95,0.97,1.00}, check = {0.45,0.75,1.00} },
    { name = 'Фиолетовая', bg = {0.09,0.07,0.14}, frame = {0.15,0.12,0.23}, accent = {0.62,0.42,0.96}, text = {0.97,0.95,1.00}, check = {0.78,0.62,1.00} },
    { name = 'Красная',    bg = {0.10,0.06,0.07}, frame = {0.18,0.10,0.12}, accent = {0.95,0.22,0.24}, text = {1.00,0.96,0.96}, check = {1.00,0.45,0.45} },
    { name = 'Зелёная',    bg = {0.06,0.10,0.08}, frame = {0.10,0.17,0.13}, accent = {0.20,0.75,0.45}, text = {0.95,1.00,0.97}, check = {0.45,0.95,0.65} },
    { name = 'Светлая',    bg = {0.95,0.95,0.97}, frame = {0.86,0.87,0.91}, accent = {0.26,0.59,0.98}, text = {0.08,0.08,0.10}, check = {0.15,0.45,0.90} },
}

local function mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

local cc = {
    bg = ffi.new('float[3]', toolsconfig.custom.bg),
    frame = ffi.new('float[3]', toolsconfig.custom.frame),
    accent = ffi.new('float[3]', toolsconfig.custom.accent),
    text = ffi.new('float[3]', toolsconfig.custom.text),
}
local themeDirty = false
local CEF = (imgui.ColorEditFlags and imgui.ColorEditFlags.PickerHueBar) or 0
local pickKey = 'accent'
local PICK_LABELS = { bg = 'Фон окна', frame = 'Панели и поля', accent = 'Акцент', text = 'Текст' }
local PICK_ORDER = { 'bg', 'frame', 'accent', 'text' }

local function color_edit(label, key)
    if imgui.ColorEdit3(u8(label), cc[key], CEF) then
        toolsconfig.custom[key] = { cc[key][0], cc[key][1], cc[key][2] }
        imgui.Theme(true)
        themeDirty = true
    end
end

function imgui.Theme(skipSwitch)
    if not skipSwitch then imgui.SwitchContext() end
    local style = imgui.GetStyle()
    local C = toolsconfig.custom
    local P = { bg = C.bg, frame = C.frame, accent = C.accent, text = C.text }
    local lum = 0.299 * P.bg[1] + 0.587 * P.bg[2] + 0.114 * P.bg[3]
    P.check = (lum > 0.5) and P.accent or mix(P.accent, {1, 1, 1}, 0.35)
    local V = function(col, a) return imgui.ImVec4(col[1], col[2], col[3], a or 1.0) end

    style.WindowPadding = imgui.ImVec2(8, 8)
    style.FramePadding = imgui.ImVec2(10, 10)
    style.ItemSpacing = imgui.ImVec2(10, 10)
    style.ItemInnerSpacing = imgui.ImVec2(6, 6)
    style.TouchExtraPadding = imgui.ImVec2(5 * MONET_DPI_SCALE, 5 * MONET_DPI_SCALE)
    style.IndentSpacing = 0
    style.ScrollbarSize = 20 * MONET_DPI_SCALE
    style.GrabMinSize = 20 * MONET_DPI_SCALE

    style.WindowBorderSize = 1
    style.ChildBorderSize = 1
    style.PopupBorderSize = 1
    style.FrameBorderSize = 0
    style.TabBorderSize = 0

    style.WindowRounding = 12
    style.ChildRounding = 10
    style.FrameRounding = 10
    style.PopupRounding = 10
    style.ScrollbarRounding = 10
    style.GrabRounding = 10
    style.TabRounding = 10

    style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
    style.ButtonTextAlign = imgui.ImVec2(0.5, 0.5)
    style.SelectableTextAlign = imgui.ImVec2(0.5, 0.5)

    local white = {1, 1, 1}
    local c = style.Colors
    c[imgui.Col.Text]                  = V(P.text)
    c[imgui.Col.TextDisabled]          = V(mix(P.text, P.bg, 0.55))
    c[imgui.Col.WindowBg]              = V(P.bg)
    c[imgui.Col.ChildBg]               = V(P.bg)
    c[imgui.Col.PopupBg]               = V(P.bg)
    c[imgui.Col.Border]                = V(mix(P.bg, P.accent, 0.45), 0.8)
    c[imgui.Col.BorderShadow]          = V(P.bg, 0.0)
    c[imgui.Col.FrameBg]               = V(P.frame)
    c[imgui.Col.FrameBgHovered]        = V(mix(P.frame, P.accent, 0.30))
    c[imgui.Col.FrameBgActive]         = V(mix(P.frame, P.accent, 0.50))
    c[imgui.Col.TitleBg]               = V(P.frame)
    c[imgui.Col.TitleBgActive]         = V(mix(P.frame, P.accent, 0.35))
    c[imgui.Col.TitleBgCollapsed]      = V(P.frame)
    c[imgui.Col.MenuBarBg]             = V(P.frame)
    c[imgui.Col.ScrollbarBg]           = V(P.frame)
    c[imgui.Col.ScrollbarGrab]         = V(mix(P.frame, P.accent, 0.6))
    c[imgui.Col.ScrollbarGrabHovered]  = V(mix(P.frame, P.accent, 0.8))
    c[imgui.Col.ScrollbarGrabActive]   = V(P.accent)
    c[imgui.Col.CheckMark]             = V(P.check)
    c[imgui.Col.SliderGrab]            = V(P.accent)
    c[imgui.Col.SliderGrabActive]      = V(mix(P.accent, white, 0.25))
    c[imgui.Col.Button]                = V(mix(P.frame, P.accent, 0.35))
    c[imgui.Col.ButtonHovered]         = V(mix(P.frame, P.accent, 0.65))
    c[imgui.Col.ButtonActive]          = V(P.accent)
    c[imgui.Col.Header]                = V(mix(P.frame, P.accent, 0.35))
    c[imgui.Col.HeaderHovered]         = V(mix(P.frame, P.accent, 0.60))
    c[imgui.Col.HeaderActive]          = V(P.accent)
    c[imgui.Col.Separator]             = V(mix(P.bg, P.accent, 0.35))
    c[imgui.Col.SeparatorHovered]      = V(P.accent)
    c[imgui.Col.SeparatorActive]       = V(P.accent)
    c[imgui.Col.ResizeGrip]            = V(P.accent, 0.30)
    c[imgui.Col.ResizeGripHovered]     = V(P.accent, 0.67)
    c[imgui.Col.ResizeGripActive]      = V(P.accent, 0.95)
    c[imgui.Col.Tab]                   = V(P.frame)
    c[imgui.Col.TabHovered]            = V(mix(P.frame, P.accent, 0.70))
    c[imgui.Col.TabActive]             = V(mix(P.frame, P.accent, 0.85))
    c[imgui.Col.TabUnfocused]          = V(P.frame)
    c[imgui.Col.TabUnfocusedActive]    = V(mix(P.frame, P.accent, 0.45))
    c[imgui.Col.PlotLines]             = V(P.accent)
    c[imgui.Col.PlotLinesHovered]      = V(mix(P.accent, white, 0.3))
    c[imgui.Col.PlotHistogram]         = V(P.accent)
    c[imgui.Col.PlotHistogramHovered]  = V(mix(P.accent, white, 0.3))
    c[imgui.Col.TextSelectedBg]        = V(P.accent, 0.40)
    c[imgui.Col.DragDropTarget]        = V(P.check, 0.90)
    c[imgui.Col.NavHighlight]          = V(P.accent)
    c[imgui.Col.NavWindowingHighlight] = V(white, 0.70)
    c[imgui.Col.NavWindowingDimBg]     = V({0.8, 0.8, 0.8}, 0.20)
    c[imgui.Col.ModalWindowDimBg]      = V({0, 0, 0}, 0.70)
end

imgui.OnInitialize(function()
    imgui.Theme()
end)

---------------------------------------------------------------------
-- ОКНО
---------------------------------------------------------------------
imgui.OnFrame(function() return renderWindow[0] end,
function(player)
    imgui.SetNextWindowPos(imgui.ImVec2(sizeX / 2, sizeY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(sizeX * 0.45, sizeY * 0.85), imgui.Cond.FirstUseEver)
    imgui.Begin(thisScript().name .. " " .. thisScript().version .. " by Radare (t.me/ryderinc)", renderWindow)

    do
        local on = toolsconfig.config.Enabled
        imgui.PushStyleColor(imgui.Col.Button, on and imgui.ImVec4(0.15, 0.62, 0.30, 1) or imgui.ImVec4(0.75, 0.20, 0.20, 1))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, on and imgui.ImVec4(0.20, 0.72, 0.36, 1) or imgui.ImVec4(0.85, 0.28, 0.28, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, on and imgui.ImVec4(0.10, 0.52, 0.24, 1) or imgui.ImVec4(0.65, 0.15, 0.15, 1))
        if imgui.Button(on and u8'СКРИПТ ВКЛЮЧЁН (нажмите, чтобы выключить)' or u8'СКРИПТ ВЫКЛЮЧЕН (нажмите, чтобы включить)', imgui.ImVec2(-1, 0)) then
            toolsconfig.config.Enabled = not toolsconfig.config.Enabled
            macro.idx = 1
            macro.busy = false
            msg("Скрипт " .. (toolsconfig.config.Enabled and "включён" or "выключен"))
            cfg_save()
        end
        imgui.PopStyleColor(3)
    end

    if imgui.BeginTabBar('Tabs') then
        -- РЕКОННЕКТ
        if imgui.BeginTabItem(u8'Реконнект') then
            if imgui.Checkbox(u8'Реконнект', AutoReconnect) then
                msg("Вы " .. (AutoReconnect[0] and "включили" or "выключили") .. " реконнект")
                if AutoReconnect[0] then msg("Помните, что вы должны находиться в игре для того чтобы работало реконнектирование") end
                toolsconfig.config.AutoReconnect = AutoReconnect[0]
                cfg_save()
            end
            imgui.SameLine()
            if imgui.Button(u8'Перезайти') then
                msg("Переподключение..")
                main_reconnect(0)
            end
            if Reconnect.active[0] then
                imgui.SameLine()
                if imgui.Button(u8'Отмена') then
                    msg("Перезаход отменен.")
                    Reconnect.active[0] = false
                end
            end
            if AutoReconnect[0] then
                if imgui.Checkbox(u8'Реконнектить при "You banned from this server"', onBanned) then
                    msg("Вы " .. (onBanned[0] and "включили" or "выключили") .. " реконнект при блоке айпишника")
                    toolsconfig.autoreconnect.onBanned = onBanned[0]
                    cfg_save()
                end
                if imgui.Checkbox(u8'Реконнектить при неверном пароле', onPassword) then
                    msg("Вы " .. (onPassword[0] and "включили" or "выключили") .. " реконнект при неверном пароле")
                    toolsconfig.autoreconnect.onPassword = onPassword[0]
                    cfg_save()
                end
                if imgui.Checkbox(u8'Реконнектить при кике/вылете из сервера', onKicked) then
                    msg("Вы " .. (onKicked[0] and "включили" or "выключили") .. " реконнект при кике/вылете")
                    toolsconfig.autoreconnect.onKicked = onKicked[0]
                    cfg_save()
                end
                if imgui.Checkbox(u8'Реконнектить при сервер/закрыт слот', onRejected) then
                    msg("Вы " .. (onRejected[0] and "включили" or "выключили") .. " реконнект при сервер/закрыт слот")
                    toolsconfig.autoreconnect.onRejected = onRejected[0]
                    cfg_save()
                end
                if imgui.SliderFloat(u8'Задержка реконнекта (в секундах)', Reconnect.delay, 0.0, 1000.0) then
                    toolsconfig.autoreconnect.delay = Reconnect.delay[0]
                    cfg_save()
                end
            end
            imgui.EndTabItem()
        end

        -- АВТОЛОГИН
        if imgui.BeginTabItem(u8'Автологин') then
            if imgui.Checkbox(u8'Автологин', AutoLogin) then
                if AutoReg[0] then
                    msg("У вас уже включена авторегистрация. Выключите её, чтобы запустить автологин")
                    AutoLogin[0] = false
                else
                    msg("Вы " .. (AutoLogin[0] and "включили" or "выключили") .. " автологин")
                    toolsconfig.config.AutoLogin = AutoLogin[0]
                    cfg_save()
                end
            end
            if AutoLogin[0] then
                if imgui.InputText(u8"Никнейм", NickName, ffi.sizeof(NickName)) then
                    toolsconfig.autologin.nickname = ffi.string(NickName)
                    cfg_save()
                end
                if imgui.InputText(u8"Пароль", Password, ffi.sizeof(Password)) then
                    toolsconfig.autologin.password = ffi.string(Password)
                    cfg_save()
                end
                if imgui.Button(u8"Очистить поля") then
                    ffi.copy(NickName, '')
                    ffi.copy(Password, '')
                    toolsconfig.autologin.nickname = ''
                    toolsconfig.autologin.password = ''
                    cfg_save()
                    msg("Поля очищены")
                end
                imgui.SameLine()
                if imgui.Button(u8"Заполнить данными последней сессии") then
                    if #lastNickname > 0 and #lastPassword > 0 then
                        toolsconfig.autologin.nickname = lastNickname
                        toolsconfig.autologin.password = lastPassword
                        ffi.copy(NickName, lastNickname)
                        ffi.copy(Password, lastPassword)
                        cfg_save()
                        msg("Данные заполнены")
                    else
                        msg("Данные еще не собраны пока")
                    end
                end
                if items_spawn and #item_spawn > 0 then
                    if imgui.Combo(u8"Место спавна", current_item_spawn, items_spawn, #item_spawn) then
                        toolsconfig.autologin.spawn_use = current_item_spawn[0]
                        cfg_save()
                    end
                end
            end
            imgui.EndTabItem()
        end

        -- АВТОРЕГИСТРАЦИЯ
        if imgui.BeginTabItem(u8'Авторегистрация') then
            if imgui.Checkbox(u8'Авторегистрация', AutoReg) then
                if AutoLogin[0] then
                    msg("У вас уже запущен автологин. Выключите его, чтобы запустить авторегистрацию")
                    AutoReg[0] = false
                else
                    if AutoReg[0] then
                        if not doesFileExist(surnames_file) or not doesFileExist(names_file) then
                            msg("Скачивание база для генерации ников")
                            download_file("https://raw.githubusercontent.com/zeraye/names-surnames-list/master/surnames-list.txt", surnames_file)
                            download_file("https://raw.githubusercontent.com/zeraye/names-surnames-list/master/male-names-list.txt", names_file)
                        end
                    end
                    msg("Вы " .. (AutoReg[0] and "включили" or "выключили") .. " авторегистрацию")
                    toolsconfig.config.AutoReg = AutoReg[0]
                    cfg_save()
                end
            end
            if AutoReg[0] then
                if imgui.Button(u8"Обновить базу фамилий (raw.githubusercontent.com)") then
                    msg("Скачивание...")
                    download_file("https://raw.githubusercontent.com/zeraye/names-surnames-list/master/surnames-list.txt", surnames_file)
                    download_file("https://raw.githubusercontent.com/zeraye/names-surnames-list/master/male-names-list.txt", names_file)
                end
                if imgui.InputText(u8"Реферал (необязательно)", refferalName, ffi.sizeof(refferalName)) then
                    toolsconfig.autoreg.refferal = ffi.string(refferalName)
                    cfg_save()
                end
                if imgui.InputText(u8"Пароль создаваемого аккаунта", regPassword, ffi.sizeof(regPassword)) then
                    toolsconfig.autoreg.password = ffi.string(regPassword)
                    cfg_save()
                end
                if imgui.Button(u8"Очистить поля") then
                    msg("Поля очищены")
                    ffi.copy(refferalName, '')
                    ffi.copy(regPassword, '')
                    toolsconfig.autoreg.refferal = ''
                    toolsconfig.autoreg.password = ''
                    cfg_save()
                end
                if imgui.Checkbox(u8'Перезаходить при регистрации (смена ID)', resetId) then
                    msg("Вы " .. (resetId[0] and "включили" or "выключили") .. " перезаход при регистрации")
                    toolsconfig.autoreg.resetId = resetId[0]
                    cfg_save()
                end
            end
            imgui.EndTabItem()
        end
        -- МАКРОС
        if imgui.BeginTabItem(u8'Макрос') then
            imgui.TextWrapped(u8'1) Включите запись. 2) Вручную нажмите "Войти", выберите точку, "Начать играть". 3) Выключите запись и включите макрос. Для записи лучше снять галочку "Запомнить меня" в игре.')
            local steps = toolsconfig.macro.steps
            if imgui.Checkbox(u8'Запись', macro.rec) then
                if macro.rec[0] then
                    toolsconfig.macro.steps = {}
                    macro.lastClickSeq = -1
                    macro.enabled[0] = false
                    toolsconfig.macro.enabled = false
                    msg("Запись начата. Нажимайте кнопки вручную.")
                else
                    msg("Запись остановлена. Шагов: " .. #toolsconfig.macro.steps)
                end
                cfg_save()
            end
            if imgui.Checkbox(u8'Макрос (автовход)', macro.enabled) then
                if macro.enabled[0] and (AutoLogin[0] or AutoReg[0]) then
                    msg("Выключите автологин/авторегистрацию, чтобы включить макрос")
                    macro.enabled[0] = false
                elseif macro.enabled[0] and #steps == 0 then
                    msg("Сначала запишите шаги")
                    macro.enabled[0] = false
                else
                    if macro.enabled[0] then macro.rec[0] = false end
                    toolsconfig.macro.enabled = macro.enabled[0]
                    macro.idx = 1
                    cfg_save()
                    msg("Макрос " .. (macro.enabled[0] and "включён" or "выключен"))
                end
            end
            if imgui.SliderInt(u8'Задержка перед шагом (мс)', macro.delay, 100, 3000) then
                toolsconfig.macro.delay = macro.delay[0]
                cfg_save()
            end
            imgui.Text(u8'Записано шагов: ' .. #steps)
            for i, st in ipairs(steps) do
                local shown = (tostring(st.json):gsub('"password"%s*:%s*"[^"]*"', '"password":"***"')):sub(1, 60)
                imgui.TextWrapped(string.format('%d) %d/%d/%d %s%s', i, st.iface, st.id, st.sub, shown, st.chain and ' [chain]' or ''))
            end
            if imgui.Button(u8'Удалить последний шаг') then
                table.remove(toolsconfig.macro.steps)
                cfg_save()
            end
            imgui.SameLine()
            if imgui.Button(u8'Очистить макрос') then
                toolsconfig.macro.steps = {}
                macro.enabled[0] = false
                toolsconfig.macro.enabled = false
                macro.idx = 1
                cfg_save()
            end
            imgui.EndTabItem()
        end
        -- ТЕМА
        if imgui.BeginTabItem(u8'Тема') then
            imgui.TextWrapped(u8'Выберите, какой цвет менять, и смешивайте его: квадрат (насыщенность/яркость), полоса оттенка и поля RGB/HSV, как в Paint. Готовые варианты ниже просто подставляют цвета.')
            for i, key in ipairs(PICK_ORDER) do
                local label = (pickKey == key and '> ' or '') .. PICK_LABELS[key]
                if imgui.Button(u8(label) .. '##pick' .. key) then pickKey = key end
                if i % 2 ~= 0 then imgui.SameLine() end
            end
            imgui.PushItemWidth(260 * MONET_DPI_SCALE)
            if imgui.ColorPicker3('##picker', cc[pickKey], CEF) then
                toolsconfig.custom[pickKey] = { cc[pickKey][0], cc[pickKey][1], cc[pickKey][2] }
                imgui.Theme(true)
                themeDirty = true
            end
            imgui.PopItemWidth()
            if themeDirty and not imgui.IsMouseDown(0) then
                cfg_save()
                themeDirty = false
            end
            imgui.Separator()
            imgui.Text(u8'Готовые цвета:')
            for i, t in ipairs(THEMES) do
                if imgui.Button(u8(t.name) .. '##theme' .. i) then
                    for _, key in ipairs({'bg', 'frame', 'accent', 'text'}) do
                        for j = 1, 3 do cc[key][j - 1] = t[key][j] end
                        toolsconfig.custom[key] = { t[key][1], t[key][2], t[key][3] }
                    end
                    imgui.Theme(true)
                    cfg_save()
                end
                if i % 2 ~= 0 and i < #THEMES then imgui.SameLine() end
            end
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
    imgui.End()
end)

---------------------------------------------------------------------
-- MAIN
---------------------------------------------------------------------
function main()
    repeat wait(0) until isSampAvailable()
    if not doesDirectoryExist(scr_dir) then createDirectory(scr_dir) end

    msg(thisScript().name .. " " .. thisScript().version .. " by Radare (t.me/ryderinc) loaded!")
    update_splist()

    sampRegisterChatCommand('rec', function() main_reconnect(0) end)
    sampRegisterChatCommand('ct', function()
        toolsconfig.config.Enabled = not toolsconfig.config.Enabled
        macro.idx = 1
        macro.busy = false
        msg("Скрипт " .. (toolsconfig.config.Enabled and "включён" or "выключен"))
        cfg_save()
    end)
    sampRegisterChatCommand('rectool', function()
        update_splist()
        renderWindow[0] = not renderWindow[0]
    end)

    addEventHandler('onReceivePacket', function(id, bs, ...)
        if id ~= 220 then return end
        if not toolsconfig.config.Enabled then return end
        raknetBitStreamIgnoreBits(bs, 8)
        if raknetBitStreamReadInt8(bs) ~= 84 then return end

        local interfaceid = raknetBitStreamReadInt8(bs)
        local subid = raknetBitStreamReadInt8(bs)
        local json = readArzString(bs)

        if DEBUG then
            print(string.format('[CT] iface=%d sub=%d json=%s', interfaceid, subid, tostring(json):sub(1, 300)))
        end

        macro_on_incoming(interfaceid, subid, json)

        if toolsconfig.config.AutoLogin then
            if interfaceid == 9 then
                if subid == 3 then
                    if json == "spawn" then
                        lua_thread.create(function()
                            wait(200)
                            showToolTip("Выбор точки спавна - " .. u8:decode(item_spawn[toolsconfig.autologin.spawn_use + 1] or "Стандартный"))
                            sendFrontendClick(9, 6, 0, tostring(toolsconfig.autologin.spawn_use))
                        end)
                    end
                    if json == "user_already_game" then
                        lua_thread.create(function()
                            wait(2000)
                            showToolTip("Попытка автоавторизации для аккаунта - " .. toolsconfig.autologin.nickname)
                            sendAuth(toolsconfig.autologin.nickname, toolsconfig.autologin.password)
                        end)
                    end
                end
                if subid == 0 then
                    lua_thread.create(function()
                        wait(200)
                        showToolTip("Попытка автоавторизации для аккаунта - " .. toolsconfig.autologin.nickname)
                        sendAuth(toolsconfig.autologin.nickname, toolsconfig.autologin.password)
                    end)
                end
                if subid == 8 then
                    toolsconfig.autologin.spawn = json
                    update_splist()
                    cfg_save()
                end
            end
        end

        if toolsconfig.config.AutoReg then
            if interfaceid == 9 then
                if subid == 4 then
                    if json == "user_exist" then
                        sendReg()
                    end
                end
                if subid == 3 then
                    if json == "spawn" then
                        lua_thread.create(function()
                            wait(200)
                            sendFrontendClick(9, 6, 0, "1")
                        end)
                    end
                    if json == "user_already_game" then
                        if nickname ~= nil then
                            lua_thread.create(function()
                                wait(200)
                                sendAuth(nickname, toolsconfig.autoreg.password)
                            end)
                        else
                            sendReg()
                        end
                    end
                end
                if subid == 0 then
                    if nickname ~= nil then
                        lua_thread.create(function()
                            wait(200)
                            sendAuth(nickname, toolsconfig.autoreg.password)
                        end)
                    else
                        sendReg()
                    end
                end
            end
        else
            if interfaceid == 9 and subid == 3 then
                if json == "loading" then
                    if not toolsconfig.config.AutoLogin then showToolTip("Загрузка...") end
                    return false
                end
                if json == "error" then
                    if toolsconfig.config.AutoLogin then
                        AutoLogin[0] = false
                        toolsconfig.config.AutoLogin = false
                        cfg_save()
                        showToolTip("Автологин отменен из-за ошибки. Проверьте настройки.")
                    else
                        showToolTip("Автологин отменен из-за ошибки. Перезаход отменен!")
                    end
                    return false
                end
            end
        end
    end)

    addEventHandler('onSendPacket', function(id, bs, ...)
        if id ~= 220 then return end
        raknetBitStreamIgnoreBits(bs, 8)
        if raknetBitStreamReadInt8(bs) ~= 63 then return end

        local interfaceid = raknetBitStreamReadInt8(bs)
        local id_val = raknetBitStreamReadInt32(bs)
        local subid = raknetBitStreamReadInt32(bs)
        local len = raknetBitStreamReadInt16(bs)
        local json_str = raknetBitStreamReadString(bs, len)

        if DEBUG then
            local safe = (json_str:gsub('"password"%s*:%s*"[^"]*"', '"password":"***"'))
            print(string.format('[CT-SEND] iface=%d id=%d sub=%d json=%s', interfaceid, id_val, subid, safe))
        end

        macro_on_send(interfaceid, id_val, subid, json_str)

        if interfaceid == 9 and (id_val == 0 or id_val == 1) and subid == 0 then
            local ok, data = pcall(decodeJson, json_str)
            if ok and type(data) == 'table' then
                lastNickname = data['username'] or ""
                lastPassword = data['password'] or ""
            end
        end
    end)

    wait(-1) -- ВАЖНО: без этого скрипт сразу выгружается
end

---------------------------------------------------------------------
-- ФУНКЦИИ
---------------------------------------------------------------------
function readArzString(bs)
    local length = raknetBitStreamReadInt16(bs)
    local encoded = raknetBitStreamReadInt8(bs)
    if encoded ~= 0 then
        return raknetBitStreamDecodeString(bs, length + encoded)
    end
    return raknetBitStreamReadString(bs, length)
end

function sendAuth(nick, pass)
    sendFrontendClick(9, 0, 0, encodeJson({ password = pass, username = nick }))
end

function sendReg()
    msg("Авторегистрация нового игрока")
    nickname = generateNickName()
    lua_thread.create(function()
        wait(200)
        sendFrontendClick(9, 1, 0, encodeJson({
            password = toolsconfig.autoreg.password,
            referralUsername = toolsconfig.autoreg.refferal,
            username = nickname
        }))
        wait(200)
        sendFrontendClick(9, 3, 1, '{"clothes":0,"gender":0,"skin":0}')
        wait(200)
        sendFrontendClick(9, 3, 0, '')
    end)
end

function showToolTip(msg_text)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 143)
    raknetBitStreamWriteBool(bs, true)
    raknetBitStreamWriteInt16(bs, #msg_text)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteString(bs, msg_text)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

function sendFrontendClick(interfaceid, id, subid, json_str)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 63)
    raknetBitStreamWriteInt8(bs, interfaceid)
    raknetBitStreamWriteInt32(bs, id)
    raknetBitStreamWriteInt32(bs, subid)
    raknetBitStreamWriteInt16(bs, #json_str)
    raknetBitStreamWriteString(bs, json_str)
    raknetSendBitStreamEx(bs, 1, 7, 1)
    raknetDeleteBitStream(bs)
end

local fallback_names = {"Johns", "Emma", "Michael", "Olivia", "William", "James", "Benjamin", "Ethan", "Alexander", "Daniel", "Matthew", "Joseph", "David", "Andrew", "Jackson", "Christopher", "Samuel", "Gabriel", "Ryan", "Nicholas", "Joshua", "Jacob", "Nathan", "Jonathan", "Christian", "Elijah"}
local fallback_surnames = {"Smith", "Johnson", "Brown", "Taylor", "Miller", "Davis", "Garcia", "Wilson", "Anderson", "Thomas", "Martinez", "Jones", "Clark", "Lewis", "Walker", "Hall", "Young", "Lee", "Allen", "Adams", "Harris", "White", "Martin", "Thompson", "Wright", "Jackson", "Turner", "Hill", "Moore", "Scott", "Cooper", "King", "Green", "Baker", "Nelson", "Murphy", "Bailey", "Reed", "Brooks", "Morgan", "Ross", "Parker", "Rogers", "Gray", "Roberts", "Cook", "Murray", "Powell", "Perez", "Barnes", "Carter", "Morris", "Wood", "Mitchell", "Watson", "Collins", "Stewart", "Sanchez", "Morales", "Ramos", "Reyes", "Bennett", "Rivera", "Long", "Foster", "Howard", "Ward", "Cox", "Diaz", "Hayes", "Peterson", "Price", "Butler", "Simmons", "Fisher", "Henderson", "Coleman", "Lopez", "Berry", "Sanders", "Bryant", "Perry", "George", "Rice", "Harrison", "Reid", "Mendoza", "Hamilton", "Woods", "Bishop", "Knight", "Burton", "Gomez"}

function generateNickName()
    local names, surnames
    if doesFileExist(names_file) then names = fileMassive(names_file) end
    if doesFileExist(surnames_file) then surnames = fileMassive(surnames_file) end
    if not names or #names == 0 then names = fallback_names end
    if not surnames or #surnames == 0 then surnames = fallback_surnames end

    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local name = names[math.random(#names)]
    local surname = surnames[math.random(#surnames)]
    return name .. "_" .. surname
end

function download_file(url, path)
    msg("Скачивание файла с URL: " .. url)
    downloadUrlToFile(url, path, function(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOAD then
            msg("Файл успешно скачан в: " .. string.gsub(path, "/storage/emulated/0/Android/media/", ""))
        end
    end)
end

function fileMassive(path)
    local file = io.open(path, "r")
    if not file then
        msg("Не удалось открыть файл: " .. path)
        return nil
    end
    local massive = {}
    for line in file:lines() do
        line = line:gsub("[\r\n%s]+", "")
        if #line > 0 then
            table.insert(massive, line:sub(1, 1):upper() .. line:sub(2):lower())
        end
    end
    file:close()
    return massive
end

function update_splist()
    item_spawn = {}
    local ok, decoded = pcall(decodeJson, toolsconfig.autologin.spawn)
    if ok and type(decoded) == 'table' and #decoded > 0 then
        for _, item in ipairs(decoded) do
            table.insert(item_spawn, u8(tostring(item.id) .. ". " .. tostring(item.spawn)))
        end
    else
        table.insert(item_spawn, u8("0. Стандартный спавн"))
    end
    items_spawn = ffi.new('const char*[?]', #item_spawn, item_spawn)
end

function msg(message)
    sampAddChatMessage("[ConnectTools] {ffffff}" .. message, 0xD2691E)
end

function main_reconnect(mode)
    if mode == 0 then
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, sf.PACKET_DISCONNECTION_NOTIFICATION)
        raknetSendBitStreamEx(bs, sf.SYSTEM_PRIORITY, sf.RELIABLE, 0)
        raknetDeleteBitStream(bs)

        bs = raknetNewBitStream()
        raknetEmulPacketReceiveBitStream(sf.PACKET_CONNECTION_LOST, bs)
        raknetDeleteBitStream(bs)
    end
    if mode == 1 then
        if not toolsconfig.config.Enabled then return end
        lua_thread.create(function()
            if Reconnect.active[0] then
                msg("Попытка реконнекта уже запущена т.к. идет переподключение")
                return
            end
            Reconnect.active[0] = true
            local ms = 500 + Reconnect.delay[0] * 1000
            if ms <= 0 then ms = 100 end

            while ms > 0 and Reconnect.active[0] do
                if ms <= 500 then
                    main_reconnect(0)
                    printStringNow("~g~reconnect", 3000)
                    ms = 0
                    Reconnect.active[0] = false
                end
                printStringNow(string.format('reconnect wait %.2f sec...', ms / 1000), 100)
                wait(100)
                ms = ms - 100
            end
        end)
    end
end

---------------------------------------------------------------------
-- СОБЫТИЯ SAMP
---------------------------------------------------------------------
function sampev.onAuthenticationRequest()
    msg("Запрос авторизации у сервера.. Попытка: " .. connects)
end

function sampev.onConnectionRequestAccepted()
    msg("Подключено. Заход в игру.")
    macro.idx = 1
    macro.busy = false
end

function sampev.onConnectionAttemptFailed()
    msg("Ошибка при коннекте.. Попытка: " .. connects)
    macro.idx = 1
    macro.busy = false
    connects = connects + 1
end

function sampev.onConnectionNoFreeSlot()
    msg("Сервер полон.. Попытка: " .. connects)
    connects = connects + 1
end

function sampev.onConnectionBanned()
    msg("Вы забанены на данном сервере")
    if exit then
        msg("Перезаход.. (Авторегистрация)")
        main_reconnect(1)
    end
    if toolsconfig.autoreconnect.onBanned and toolsconfig.config.AutoReconnect then
        msg("Реконнект..")
        main_reconnect(1)
    end
end

function sampev.onConnectionPasswordInvalid()
    msg("Неверный пароль сервера")
    if toolsconfig.autoreconnect.onPassword and toolsconfig.config.AutoReconnect then
        msg("Реконнект..")
        main_reconnect(1)
    end
end

function sampev.onConnectionClosed()
    msg("Потеря связи с сервером")
    macro.idx = 1
    macro.busy = false
    if toolsconfig.autoreconnect.onKicked and toolsconfig.config.AutoReconnect then
        msg("Реконнект..")
        main_reconnect(1)
    end
end

function sampev.onConnectionRejected()
    msg("Подключение отклонено.")
    if exit then
        msg("Перезаход.. (Авторегистрация)")
        main_reconnect(0)
    end
    if toolsconfig.autoreconnect.onRejected and toolsconfig.config.AutoReconnect then
        msg("Реконнект..")
        main_reconnect(1)
    end
end

function sampev.onSendSpawn()
    if not toolsconfig.config.Enabled then return true end
    if not toolsconfig.config.AutoReg then return true end
    if not toolsconfig.autoreg.resetId then
        nickname = nil
        return true
    end
    if not exit then
        lua_thread.create(function()
            showToolTip("Перезаход для завершения регой (выход из мира в консоль)")
            sampSendEnterVehicle(65535, false)
            wait(2000)
            main_reconnect(0)
            exit = true
        end)
    else
        nickname = nil
        exit = false
    end
end

function onScriptTerminate(s, quitGame)
    if s == thisScript() then
        cfg_save()
    end
end
