-- SPDX-License-Identifier: AGPL-3.0-or-later
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Button = require("ui/widget/button")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Dispatcher = require("dispatcher")
local http = require("socket.http")
local url = require("socket.url")
local ltn12 = require("ltn12")
local json = require("json")
local socketutil = require("socketutil")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local IconWidget = require("ui/widget/iconwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local Shelfmark = WidgetContainer:extend{ name = "shelfmark" }

function Shelfmark:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/shelfmark.lua")
    self.ui.menu:registerToMainMenu(self)
    Dispatcher:registerAction("shelfmark_open", {category="none", event="ShelfmarkOpen", title="Shelfmark", filemanager=true})
end

function Shelfmark:addToMainMenu(items)
    if not self.ui.document then
        items.shelfmark = {text="Shelfmark", callback=function() self:onShelfmarkOpen() end}
    end
end

-- All Shelfmark-owned windows belong to one session. OPDS Plus windows are
-- intentionally not tracked here, as their lifecycle belongs to that plugin.
function Shelfmark:present(widget, cleanup, is_root)
    if not self.session_active then
        UIManager:show(widget)
        return widget
    end
    self.session_widgets = self.session_widgets or {}
    local widgets = self.session_widgets
    widgets[#widgets+1] = widget
    local previous_close = widget.onCloseWidget
    local closed = false
    widget.onCloseWidget = function(w, ...)
        if closed then return end
        closed = true
        for i = #widgets, 1, -1 do
            if widgets[i] == w then table.remove(widgets, i); break end
        end
        if previous_close then previous_close(w, ...) end
        if cleanup then cleanup() end
        if is_root and self.session_active then self:shutdown() end
    end
    UIManager:show(widget)
    return widget
end

function Shelfmark:shutdown()
    if not self.session_active then return end
    self.session_active = false
    self.session_generation = (self.session_generation or 0) + 1
    local widgets = self.session_widgets or {}
    while #widgets > 0 do
        local widget = widgets[#widgets]
        UIManager:close(widget)
        -- Defensive fallback if a widget did not dispatch CloseWidget.
        if widgets[#widgets] == widget then widget:onCloseWidget() end
    end
    self.session_widgets = nil
    self.home_menu = nil
    self.session_cookie = nil
    self.last_query = nil
end

function Shelfmark:onCloseWidget()
    self:shutdown()
end

function Shelfmark:message(text)
    self:present(InfoMessage:new{text=tostring(text)})
end

function Shelfmark:input(title, value, callback, secret)
    local dialog
    dialog = InputDialog:new{
        title=title, input=value or "", text_type=secret and "password" or nil,
        buttons={{{text="Abbrechen", id="close", callback=function() UIManager:close(dialog) end},
                  {text="OK", is_enter_default=true, callback=function()
                      local value = dialog:getInputText()
                      UIManager:close(dialog)
                      callback(value)
                  end}}},
    }
    self:present(dialog)
    dialog:onShowKeyboard()
end

function Shelfmark:list(title, items, select)
    local menu = Menu:new{title=title, item_table=items, covers_fullscreen=true,
        is_borderless=true, is_popout=false, title_bar_fm_style=true,
        onMenuSelect=function(_, item) select(item) end}
    self:present(menu)
    return menu
end

function Shelfmark:save(key, value)
    if key == "url" or key == "username" or key == "password" or key == "http_headers" then
        self.session_cookie = nil
    end
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Shelfmark:request(path, body, sink, is_login, retried, raw)
    local base = (self.settings:readSetting("url") or ""):gsub("/+$", "")
    if not base:match("^https?://[^/]+") then return nil, "Bitte zuerst die Serveradresse einstellen." end
    local username = self.settings:readSetting("username", "")
    local password = self.settings:readSetting("password", "")
    local use_login = username ~= "" or password ~= ""
    if use_login and (username == "" or password == "") then
        return nil, "Bitte Benutzername und Passwort einstellen."
    end
    if use_login and not is_login and not self.session_cookie then
        local login, login_error = self:request("/api/auth/login", {username=username, password=password}, nil, true)
        if not login then return nil, "Anmeldung fehlgeschlagen: " .. login_error end
        if not login.success or not self.session_cookie then return nil, "Anmeldung fehlgeschlagen: Sitzung fehlt." end
    end
    local headers = { ["Accept"]="application/json" }
    for name, value in pairs(self.settings:readSetting("http_headers", {})) do
        headers[name] = value
    end
    if use_login and self.session_cookie and not is_login then headers.Cookie = self.session_cookie end
    local payload
    if body then
        local ok
        ok, payload = pcall(json.encode, body)
        if not ok then return nil, "Anfrage konnte nicht erstellt werden." end
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end
    local chunks, received = {}, 0
    local response_sink = sink or (raw and function(chunk)
        if chunk then
            received = received + #chunk
            if received > 4 * 1024 * 1024 then return nil, "Cover zu groß" end
            chunks[#chunks+1] = chunk
        end
        return 1
    end) or ltn12.sink.table(chunks)
    socketutil:set_timeout(15, 120)
    local ok, result, code, response_headers = pcall(http.request, {
        url=base .. path, method=body and "POST" or "GET", headers=headers,
        source=payload and ltn12.source.string(payload) or nil,
        sink=response_sink, redirect=false,
    })
    socketutil:reset_timeout()
    if not ok then return nil, "Netzwerkfehler: " .. tostring(result) end
    if tonumber(code) == 401 and use_login and not is_login then
        self.session_cookie = nil
        if not retried and not sink then return self:request(path, body, nil, false, true, raw) end
    end
    if not result or tonumber(code) ~= 200 then
        local error_text = table.concat(chunks)
        local decoded_ok, decoded = pcall(json.decode, error_text)
        if decoded_ok and type(decoded) == "table" then error_text = decoded.message or decoded.error or error_text end
        return nil, "Shelfmark: " .. tostring(code or result) .. (error_text ~= "" and (" – " .. error_text:sub(1, 300)) or "")
    end
    if is_login then
        local cookie_header = response_headers and response_headers["set-cookie"]
        if type(cookie_header) == "table" then cookie_header = table.concat(cookie_header, ", ") end
        if type(cookie_header) == "string" then
            -- Shelfmark's Flask session cookie is the first cookie in its login response.
            local name, value = cookie_header:match("^%s*([^=;%s,]+)=([^;,%s]*)")
            if name and value ~= "" then self.session_cookie = name .. "=" .. value end
        end
    end
    if sink then return true, response_headers end
    if raw then return table.concat(chunks), response_headers end
    local decoded_ok, decoded = pcall(json.decode, table.concat(chunks))
    if not decoded_ok or type(decoded) ~= "table" then return nil, "Ungültige Antwort von Shelfmark." end
    return decoded
end

function Shelfmark:online(callback, owner)
    local generation = self.session_generation
    NetworkMgr:runWhenOnline(function()
        if self.session_active and self.session_generation == generation
            and (not owner or UIManager:isWidgetShown(owner)) then
            callback()
        end
    end)
end

local HomeHeader = WidgetContainer:extend{}
function HomeHeader:getHeight() return self[1]:getSize().h end
function HomeHeader:generateVerticalLayout()
    local layout = self.titlebar:generateVerticalLayout()
    layout[#layout+1] = {self.search_button}
    return layout
end

function Shelfmark:onShelfmarkOpen()
    if self.session_active then self:shutdown() end
    self.session_generation = (self.session_generation or 0) + 1
    self.session_active = true
    self:showHome()
    return true
end

function Shelfmark:showHome()
    local screen = Device.screen
    local width = screen:getWidth()
    local gap = screen:scaleBySize(12)
    local menu
    local bar = TitleBar:new{width=width, title="Shelfmark", fullscreen=true,
        left_icon="appbar.settings", left_icon_tap_callback=function() self:showSettings() end,
        close_callback=function() self:shutdown() end,
        with_bottom_line=true}
    local search_button = Button:new{text="Titel oder Autor suchen …", width=width - 2 * gap,
        align="left", text_font_bold=false, callback=function() self:searchDialog() end}
    local label = TextWidget:new{text="Abgerufen", face=Font:getFace("smallinfofont", 20), bold=true}
    local header = HomeHeader:new{titlebar=bar, search_button=search_button,
        VerticalGroup:new{align="left", bar, VerticalSpan:new{width=gap},
            HorizontalGroup:new{HorizontalSpan:new{width=gap}, search_button}, VerticalSpan:new{width=gap},
            HorizontalGroup:new{HorizontalSpan:new{width=gap}, label}, VerticalSpan:new{width=gap}}}
    menu = Menu:new{title="Shelfmark", custom_title_bar=header, is_borderless=true, is_popout=false,
        covers_fullscreen=true, is_enable_shortcut=false, items_per_page=5, state_w=screen:scaleBySize(72),
        item_table={{text="Abgerufene Bücher werden geladen …", placeholder=true}},
        onMenuSelect=function(_, item, pos)
            if item.refresh then self:refreshHome(menu)
            elseif not item.placeholder then
                if item.status == "complete" then
                    if pos and item.button_start and pos.x >= item.button_start then self:openInOPDS(item, menu) end
                else
                    self:message((item.title or "Buch") .. "\nStatus: " .. item.status_label .. "\n\nIn OPDS Plus suchen ist nach Abschluss verfügbar.")
                end
            end
        end,
        onGotoPage=function(m, page)
            Menu.onGotoPage(m, page)
            self:loadHomeCovers(m, m.cache_only)
            return true
        end,
    }
    menu.cover_files = {}
    self.home_menu = menu
    self:present(menu, function()
        if menu.initial_job then UIManager:unschedule(menu.initial_job); menu.initial_job = nil end
        if menu.refresh_job then UIManager:unschedule(menu.refresh_job); menu.refresh_job = nil end
        self:releaseHomeCovers(menu)
        if self.home_menu == menu then self.home_menu = nil end
    end, true)
    local cached = self:readHomeCache()
    if cached then self:displayHomeEntries(menu, cached, true) end
    if (self.settings:readSetting("url") or "") ~= "" then
        menu.initial_job = function()
            menu.initial_job = nil
            if self.home_menu == menu then self:online(function() self:refreshHome(menu) end) end
        end
        UIManager:nextTick(menu.initial_job)
    else
        menu.item_table = {{text="Server über das Einstellungssymbol einrichten.", placeholder=true}}
        menu:updateItems()
    end
end

function Shelfmark:homeCacheKey()
    return (self.settings:readSetting("url", "") or "") .. "\n" ..
        (self.settings:readSetting("username", "") or "")
end

function Shelfmark:readHomeCache()
    local cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/shelfmark-activity-cache.lua")
    if cache:readSetting("account") ~= self:homeCacheKey() then return nil end
    local entries = cache:readSetting("entries")
    if type(entries) ~= "table" then return nil end
    return entries
end

function Shelfmark:homeEntryWidget(entry, cover)
    local screen = Device.screen
    local gap = screen:scaleBySize(8)
    local width = screen:getWidth() - screen:scaleBySize(64)
    local icon_width = screen:scaleBySize(55)
    local button = entry.status == "complete" and Button:new{text="Buch öffnen", text_font_size=16,
        callback=function() self:openInOPDS(entry, self.home_menu) end} or nil
    local trailing = button or TextWidget:new{text=entry.status_label, face=Font:getFace("smallinfofont", 16)}
    local button_width = trailing:getSize().w
    local text_width = math.max(screen:scaleBySize(80), width - icon_width - button_width - 2 * gap)
    local text = TextBoxWidget:new{text=entry.title .. "\n" .. entry.author, width=text_width,
        height=screen:scaleBySize(76), height_adjust=true, height_overflow_show_ellipsis=true,
        face=Font:getFace("smallinfofont", 16)}
    entry.button_start = button and (screen:getWidth() - screen:scaleBySize(32) - button_width) / screen:getWidth() or nil
    entry.open_button = button
    local cover_slot = CenterContainer:new{dimen=Geom:new{w=icon_width, h=screen:scaleBySize(72)}, cover}
    return HorizontalGroup:new{align="center", cover_slot, HorizontalSpan:new{width=gap}, text,
        HorizontalSpan:new{width=gap}, trailing}
end

function Shelfmark:displayHomeEntries(menu, entries, cache_only)
    local items = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.title) == "string" and type(entry.status) == "string" then
            local author = type(entry.author) == "string" and entry.author or "Autor unbekannt"
            local label = type(entry.status_label) == "string" and entry.status_label or entry.status
            local item = {text=entry.title .. " — " .. author, title=entry.title, author=author,
                mandatory=label, status=entry.status, status_label=label, preview=entry.preview,
                timestamp=entry.timestamp,
                state=IconWidget:new{icon="book.opened", width=Device.screen:scaleBySize(45), height=Device.screen:scaleBySize(60)}}
            item.state = self:homeEntryWidget(item, item.state)
            item.text, item.mandatory = "", nil
            items[#items+1] = item
        end
    end
    if #items == 0 then items[1] = {text="Noch keine Abrufe vorhanden.", placeholder=true} end
    self:releaseHomeCovers(menu)
    menu.cache_only = cache_only == true
    menu.state_w = #entries > 0 and (Device.screen:getWidth() - Device.screen:scaleBySize(100)) or Device.screen:scaleBySize(72)
    menu.item_table = items
    menu.page = math.min(menu.page or 1, math.max(1, math.ceil(#items / (menu.perpage or 5))))
    menu:updateItems()
    self:loadHomeCovers(menu, cache_only)
end

function Shelfmark:refreshHome(menu)
    if self.home_menu ~= menu then return end
    local snapshot, err = self:request("/api/activity/snapshot")
    local statuses
    if snapshot and type(snapshot.status) == "table" then
        statuses = snapshot.status
    else
        local status, status_err = self:request("/api/status")
        if not status then
            if not self:readHomeCache() then
                self:releaseHomeCovers(menu)
                menu.item_table = {{text="Abgerufen konnte nicht geladen werden. Zum erneuten Laden antippen.\n" .. tostring(err or status_err), refresh=true}}
                menu:updateItems()
            end
            return
        end
        statuses = status
    end
    local entries, seen = {}, {}
    local labels = {queued="Wartet", resolving="Wird vorbereitet", locating="Wird gesucht", downloading="Wird geladen", complete="Abgeschlossen", error="Fehler", cancelled="Abgebrochen"}
    local function add(id, entry, status, timestamp)
        if type(entry) ~= "table" then return end
        id = tostring(id or entry.id or "")
        if id == "" or seen[id] then return end
        seen[id] = true
        local title = type(entry.title) == "string" and entry.title or "Ohne Titel"
        local author = type(entry.author) == "string" and entry.author ~= "" and entry.author or "Autor unbekannt"
        local label = labels[status] or tostring(status)
        entries[#entries+1] = {title=title, author=author, status=status, status_label=label,
            preview=type(entry.preview) == "string" and entry.preview or nil,
            timestamp=tonumber(timestamp or entry.added_time) or 0}
    end
    local active = false
    local buckets = {"queued", "resolving", "locating", "downloading", "complete", "error", "cancelled"}
    for _, bucket in ipairs(buckets) do
        local tasks = type(statuses) == "table" and statuses[bucket]
        if type(tasks) == "table" then
            for id, entry in pairs(tasks) do
                add(id, entry, bucket)
                if bucket == "queued" or bucket == "resolving" or bucket == "locating" or bucket == "downloading" then active = true end
            end
        end
    end
    local offset, history_complete = 0, true
    while true do
        local history = self:request("/api/activity/history?limit=100&offset=" .. offset)
        if type(history) ~= "table" then history_complete = false; break end
        if #history == 0 then break end
        for _, row in ipairs(history) do
            if type(row) == "table" and row.item_type == "download" and labels[row.final_status]
                and type(row.snapshot) == "table" then
                add(row.source_id or row.item_key, row.snapshot.download, row.final_status)
            end
        end
        offset = offset + 100
    end
    if not history_complete and self:readHomeCache() then return end
    table.sort(entries, function(a, b) return a.timestamp > b.timestamp end)
    if history_complete then
        local cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/shelfmark-activity-cache.lua")
        cache:saveSetting("account", self:homeCacheKey())
        cache:saveSetting("entries", entries)
        cache:flush()
    end
    self:displayHomeEntries(menu, entries)
    if menu.refresh_job then UIManager:unschedule(menu.refresh_job) end
    if active then
        menu.refresh_job = function() if self.home_menu == menu then self:refreshHome(menu) end end
        UIManager:scheduleIn(20, menu.refresh_job)
    else
        menu.refresh_job = nil
    end
end

function Shelfmark:releaseHomeCovers(menu)
    for _, entry in ipairs(menu.item_table or {}) do
        if entry.state and entry.state.free then entry.state:free() end
        entry.state = nil
    end
    for _, path in ipairs(menu.cover_files or {}) do os.remove(path) end
    menu.cover_files = {}
end

function Shelfmark:homeCover(link, cache_only)
    local directory = DataStorage:getSettingsDir() .. "/shelfmark-covers"
    if not lfs.attributes(directory, "mode") then lfs.mkdir(directory) end
    if lfs.attributes(directory, "mode") ~= "directory" then
        if cache_only then return nil end
        return self:cover({cover_url=link}), false
    end

    if not self.cover_cache then
        self.cover_cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/shelfmark-cover-cache.lua")
    end
    local cache = self.cover_cache
    local entries = cache:readSetting("entries", {})
    local key = (self.settings:readSetting("url", "") or "") .. "\n" ..
        (self.settings:readSetting("username", "") or "") .. "\n" .. link
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if entry.key == key then
            local path = directory .. "/" .. entry.file
            local file = io.open(path, "rb")
            table.remove(entries, i)
            if file then
                file:close()
                entries[#entries+1] = entry
                cache:saveSetting("entries", entries)
                cache:flush()
                return path, true
            end
            break
        end
    end

    if cache_only then return nil end
    local temporary = self:cover({cover_url=link})
    if not temporary then return nil end
    local source = io.open(temporary, "rb")
    if not source then return temporary, false end
    local bytes = source:read("*a")
    source:close()
    local id = tonumber(cache:readSetting("next_id", 1)) or 1
    local extension = temporary:match("(%.[a-z]+)$") or ".jpg"
    local filename = tostring(id) .. extension
    local path = directory .. "/" .. filename
    local target = io.open(path, "wb")
    if not target then return temporary, false end
    local ok = target:write(bytes)
    local closed = target:close()
    if not ok or not closed then os.remove(path); return temporary, false end
    os.remove(temporary)
    entries[#entries+1] = {key=key, file=filename}
    while #entries > 64 do
        local oldest = table.remove(entries, 1)
        os.remove(directory .. "/" .. oldest.file)
    end
    cache:saveSetting("next_id", id + 1)
    cache:saveSetting("entries", entries)
    cache:flush()
    return path, true
end

function Shelfmark:loadHomeCovers(menu, cache_only)
    if self.home_menu ~= menu then return end
    local first = (menu.page - 1) * menu.perpage + 1
    local changed = false
    for index = first, math.min(first + menu.perpage - 1, #menu.item_table) do
        local entry = menu.item_table[index]
        if entry and not entry.cover_checked and type(entry.preview) == "string" and entry.preview ~= "" then
            local path, cached = self:homeCover(entry.preview, cache_only)
            entry.cover_checked = not cache_only or path ~= nil
            if path then
                if not cached then menu.cover_files[#menu.cover_files+1] = path end
                entry.cover_path = path
                changed = true
            end
        end
    end
    if changed and self.home_menu == menu then
        -- Menu:updateItems frees the previous row widgets, so recreate every row.
        for _, entry in ipairs(menu.item_table) do
            if entry.status then
                local cover = entry.cover_path and ImageWidget:new{file=entry.cover_path,
                    width=Device.screen:scaleBySize(55), height=Device.screen:scaleBySize(72),
                    scale_factor=0, alpha=true, file_do_cache=false}
                    or IconWidget:new{icon="book.opened", width=Device.screen:scaleBySize(45), height=Device.screen:scaleBySize(60)}
                entry.state = self:homeEntryWidget(entry, cover)
            end
        end
        menu:updateItems(nil, true)
    end
end

function Shelfmark:showHeaders()
    local headers = self.settings:readSetting("http_headers", {})
    local items = {{text="Header hinzufügen", add=true}}
    local names = {}
    for name in pairs(headers) do names[#names+1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(names) do items[#items+1] = {text=name, name=name} end
    local menu
    local function edit(name)
        self:input("Header-Name", name, function(new_name)
            new_name = new_name:match("^%s*(.-)%s*$")
            local lower = new_name:lower()
            if new_name == "" or new_name:find("[^!#$%%&'*+%.%^_`|~%w-]") or
                lower == "host" or lower == "content-length" or lower == "content-type" or
                lower == "cookie" or lower == "accept" then
                self:message("Ungültiger oder vom Plugin verwalteter Header-Name.")
                self:showHeaders()
                return
            end
            for existing in pairs(headers) do
                if existing ~= name and existing:lower() == lower then
                    self:message("Dieser Header ist bereits vorhanden.")
                    self:showHeaders()
                    return
                end
            end
            self:input("Header-Wert", name and headers[name] or "", function(value)
                if value:find("[\r\n]") then
                    self:message("Der Header-Wert darf keine Zeilenumbrüche enthalten.")
                else
                    if name then headers[name] = nil end
                    headers[new_name] = value
                    self:save("http_headers", headers)
                end
                self:showHeaders()
            end, true)
        end)
    end
    menu = self:list("HTTP-Header", items, function(item)
        UIManager:close(menu)
        if item.add then edit(); return end
        local dialog
        dialog = ButtonDialog:new{title=item.name, buttons={
            {{text="Bearbeiten", callback=function() UIManager:close(dialog); edit(item.name) end}},
            {{text="Löschen", callback=function()
                UIManager:close(dialog)
                headers[item.name] = nil
                self:save("http_headers", headers)
                self:showHeaders()
            end}},
            {{text="Zurück", callback=function() UIManager:close(dialog); self:showHeaders() end}},
        }}
        self:present(dialog)
    end)
end

function Shelfmark:showSettings()
    local popup
    local function edit(key, title, secret)
        UIManager:close(popup)
        self:input(title, self.settings:readSetting(key), function(value)
            if key ~= "password" then value = value:match("^%s*(.-)%s*$") end
            self:save(key, value)
        end, secret)
    end
    popup = ButtonDialog:new{title="Einstellungen", buttons={
        {{text="Serveradresse", callback=function() edit("url", "Shelfmark-Serveradresse") end}},
        {{text="Benutzername", callback=function() edit("username", "Shelfmark-Benutzername") end}},
        {{text="Passwort", callback=function() edit("password", "Shelfmark-Passwort", true) end}},
        {{text="HTTP-Header", callback=function() UIManager:close(popup); self:showHeaders() end}},
        {{text="OPDS-Plus-Katalog auswählen", callback=function()
            UIManager:close(popup)
            self:chooseOPDSCatalog()
        end}},
        {{text="Abgerufen aktualisieren", callback=function()
            UIManager:close(popup)
            local menu = self.home_menu
            if menu then self:online(function() self:refreshHome(menu) end) end
        end}},
        {{text="Schließen", callback=function() UIManager:close(popup) end}},
    }}
    self:present(popup)
end

function Shelfmark:searchDialog(mode, value, provider)
    mode = mode or "general"
    local hints = {general="Titel oder Autor", author="Autor eingeben", title="Buchtitel eingeben"}
    local dialog
    dialog = InputDialog:new{
        title="Shelfmark – Bücher suchen", input=value or self.last_query or "",
        input_hint=hints[mode],
        buttons={
            (function()
                local buttons = {}
                for _, option in ipairs({{key="general", label="Allgemein"}, {key="author", label="Autor"}, {key="title", label="Titel"}}) do
                    buttons[#buttons+1] = {text=(mode == option.key and "✓ " or "") .. option.label, callback=function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchDialog(option.key, query, provider)
                    end}
                end
                return buttons
            end)(),
            {{text="Such Bibliothek: " .. (provider and provider.display_name or "Standard"), callback=function()
                self:online(function()
                    local data, err = self:request("/api/metadata/providers")
                    if not data then return self:message(err) end
                    local items = {}
                    for _, entry in ipairs(data.providers or {}) do
                        if entry.enabled and entry.available and type(entry.name) == "string" and entry.name ~= "" then
                            items[#items+1] = {text=entry.display_name or entry.name, name=entry.name,
                                display_name=entry.display_name or entry.name}
                        end
                    end
                    if #items == 0 then return self:message("Keine aktiven Such Bibliotheken verfügbar.") end
                    local menu
                    menu = self:list("Such Bibliothek", items, function(item)
                        local query = dialog:getInputText()
                        UIManager:close(menu)
                        UIManager:close(dialog)
                        self:searchDialog(mode, query, item)
                    end)
                end, dialog)
            end}},
            {{text="Schließen", id="close", callback=function() UIManager:close(dialog) end},
             {text="Suchen", is_enter_default=true, callback=function()
                local query = dialog:getInputText()
                if query:match("%S") then
                    self.last_query = query
                    UIManager:close(dialog)
                    self:online(function() self:search(query, mode, provider and provider.name) end)
                end
             end}},
        },
    }
    self:present(dialog)
    dialog:onShowKeyboard()
end

local function libraryLabel(book)
    local library = type(book.library) == "table" and book.library
    if not library then return nil end
    if library.ebook == "owned" then return "✓ In deiner Bibliothek" end
    if library.ebook == "collection" then return "In einer Sammlung vorhanden" end
    if json.util and library.ebook == json.util.null then return "Noch nicht vorhanden" end
end

function Shelfmark:search(query, mode, provider)
    local field = (mode == "author" or mode == "title") and mode or "query"
    local path = "/api/metadata/search?content_type=ebook&" .. field .. "=" .. url.escape(query)
    if provider then path = path .. "&provider=" .. url.escape(provider) end
    local data, err = self:request(path)
    if not data then return self:message(err) end
    local items = {}
    local screen = Device.screen
    local text_width = screen:getWidth() - screen:scaleBySize(64)
    local gap = screen:scaleBySize(4)
    for _, book in ipairs(data.books or {}) do
        local authors = book.authors
        if type(authors) == "table" then authors = table.concat(authors, ", ") end
        local year = tonumber(book.publish_year)
        local info = (type(authors) == "string" and authors ~= "") and authors or "Autor unbekannt"
        local label = libraryLabel(book) or "Status unbekannt"
        local secondary = (year and year > 0 and (tostring(year) .. " · ") or "") .. label
        local title = tostring(book.title or "Ohne Titel")
        local author_width = math.floor(text_width * 0.42)
        local status_width = text_width - author_width - gap
        local content = {align="left",
            TextBoxWidget:new{text=title, width=text_width, height=screen:scaleBySize(54),
                height_adjust=true, height_overflow_show_ellipsis=true, face=Font:getFace("smallinfofont", 22), bold=true},
            VerticalSpan:new{width=gap},
            HorizontalGroup:new{
                TextBoxWidget:new{text=info, width=author_width, height=screen:scaleBySize(28),
                    height_adjust=true, height_overflow_show_ellipsis=true, face=Font:getFace("smallinfofont", 16)},
                HorizontalSpan:new{width=gap},
                TextBoxWidget:new{text=secondary, width=status_width, height=screen:scaleBySize(28), alignment="right",
                    height_adjust=true, height_overflow_show_ellipsis=true, face=Font:getFace("smallinfofont", 15)}}}
        items[#items+1] = {text="", state=VerticalGroup:new(content), book=book}
    end
    if #items == 0 then return self:message("Keine Bücher gefunden.") end
    local menu = Menu:new{title="Suchergebnisse", item_table=items, covers_fullscreen=true,
        is_borderless=true, is_popout=false, title_bar_fm_style=true,
        items_per_page=6, is_enable_shortcut=false, state_w=1,
        onMenuSelect=function(_, item) self:bookDetails(item.book) end}
    self:present(menu)
end

local function plain(value)
    if type(value) ~= "string" then return "" end
    return util.htmlToPlainTextIfHtml(value)
end

local function html(value)
    return plain(value):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("\n", "<br/>")
end

-- Only Shelfmark-relative cover URLs carry the login cookie. External cover
-- servers receive no credentials and redirects are deliberately disabled.
function Shelfmark:cover(book)
    local link = book.cover_url
    if type(link) ~= "string" or link == "" then return nil end
    local bytes
    if link:sub(1, 1) == "/" and link:sub(1, 2) ~= "//" then
        bytes = self:request(link, nil, nil, false, false, true)
    elseif link:match("^https?://") then
        local chunks, length = {}, 0
        socketutil:set_timeout(10, 30)
        local ok, result, code = pcall(http.request, {url=link, redirect=false, sink=function(chunk)
            if chunk then
                length = length + #chunk
                if length > 4 * 1024 * 1024 then return nil, "Cover zu groß" end
                chunks[#chunks+1] = chunk
            end
            return 1
        end})
        socketutil:reset_timeout()
        if ok and result and tonumber(code) == 200 then bytes = table.concat(chunks) end
    end
    if type(bytes) ~= "string" or #bytes == 0 or #bytes > 4 * 1024 * 1024 then return nil end
    local ext = bytes:sub(1, 3) == "\255\216\255" and ".jpg" or bytes:sub(1, 8) == "\137PNG\13\10\26\10" and ".png" or nil
    if not ext then return nil end
    local temporary = os.tmpname()
    os.remove(temporary) -- Lua may create this name before returning it.
    local path = temporary .. ext
    local f = io.open(path, "wb")
    if not f then return nil end
    local ok = f:write(bytes)
    f:close()
    if not ok then os.remove(path); return nil end
    return path
end

function Shelfmark:bookDetails(book)
    if not book.provider or not book.provider_id then return self:message("Anbieter oder Buch-ID fehlt.") end
    local provider, id = url.escape(tostring(book.provider)), url.escape(tostring(book.provider_id))
    local detail = self:request("/api/metadata/book/" .. provider .. "/" .. id)
    if detail and type(detail) == "table" then
        for key, value in pairs(detail) do if value ~= nil and type(value) ~= "userdata" then book[key] = value end end
    end
    local data, err = self:request("/api/releases?content_type=ebook&provider=" .. provider .. "&book_id=" .. id)
    if not data then return self:message(err) end
    local releases = data.releases or {}
    local cover = self:cover(book)
    self:showBookScreen(book, releases, cover)
end

local BookHeader = WidgetContainer:extend{}
function BookHeader:getHeight() return self.fixed_height end
function BookHeader:generateVerticalLayout()
    local layout = self.titlebar:generateVerticalLayout()
    if self.opds_button then layout[#layout+1] = {self.opds_button} end
    return layout
end

function Shelfmark:showBookScreen(book, releases, cover)
    local screen = Device.screen
    local width, height = screen:getWidth(), screen:getHeight()
    local header_height = math.floor(height / 2)
    local gap = screen:scaleBySize(12)
    local menu
    local description = plain(book.description)
    if description == "" then description = "Keine Beschreibung verfügbar." end
    local bar = TitleBar:new{width=width, title="Buchdetails", fullscreen=true,
        left_icon="info", left_icon_tap_callback=function()
            self:present(TextViewer:new{title="Beschreibung", text=description, text_type="book_info"})
        end,
        with_bottom_line=true, close_callback=function() if menu then menu:onClose() end end}
    local label = TextWidget:new{text="Ausgaben", face=Font:getFace("smallinfofont", 18), bold=true}
    local opds_button
    if type(book.library) == "table" and (book.library.ebook == "owned" or book.library.ebook == "collection") then
        opds_button = Button:new{text="Buch öffnen", callback=function() self:openInOPDS(book, menu) end}
    end
    local body_height = math.max(1, header_height - bar:getHeight() - 3 * gap - label:getSize().h)
    local cover_width = math.floor(width * 0.32)
    local info_width = width - cover_width - 3 * gap
    local cover_widget
    if cover then
        cover_widget = ImageWidget:new{file=cover, width=cover_width, height=body_height, scale_factor=0, alpha=true, file_do_cache=false}
    else
        cover_widget = TextBoxWidget:new{text="Kein Cover", width=cover_width,
            face=Font:getFace("smallinfofont", 16), alignment="center"}
    end
    local authors = type(book.authors) == "table" and table.concat(book.authors, ", ") or plain(book.authors)
    local year = tonumber(book.publish_year)
    local metadata = (authors ~= "" and authors or "Autor unbekannt") .. (year and year > 0 and (" · " .. tostring(year)) or "")
    local status = libraryLabel(book)
    local text = metadata .. (status and ("\n" .. status) or "") .. "\n\n" .. description
    local button_width = opds_button and opds_button:getSize().w or 0
    local title_width = math.max(1, info_width - (opds_button and (button_width + gap) or 0))
    local title = TextBoxWidget:new{text=plain(book.title or "Ohne Titel"), width=title_width,
        height=screen:scaleBySize(75), height_adjust=true, height_overflow_show_ellipsis=true,
        face=Font:getFace("smallinfofont", 18), bold=true}
    local title_row = {align="top", title}
    if opds_button then title_row[#title_row+1] = HorizontalSpan:new{width=gap}; title_row[#title_row+1] = opds_button end
    title_row = HorizontalGroup:new(title_row)
    local title_height = title_row:getSize().h
    local info = TextBoxWidget:new{text=text, width=info_width, height=math.max(1, body_height - title_height - gap),
        height_overflow_show_ellipsis=true, face=Font:getFace("smallinfofont", 18), alignment="left"}
    local info_column = VerticalGroup:new{align="left", title_row, VerticalSpan:new{width=gap}, info}
    local header_content = {align="left", bar, VerticalSpan:new{width=gap},
            HorizontalGroup:new{align="top", HorizontalSpan:new{width=gap},
                CenterContainer:new{dimen=Geom:new{w=cover_width, h=body_height}, cover_widget},
                HorizontalSpan:new{width=gap}, info_column}, VerticalSpan:new{width=gap}}
    header_content[#header_content+1] = HorizontalGroup:new{HorizontalSpan:new{width=gap}, label}
    header_content[#header_content+1] = VerticalSpan:new{width=gap}
    local header = BookHeader:new{fixed_height=header_height, titlebar=bar, opds_button=opds_button,
        VerticalGroup:new(header_content)}
    local items = {}
    for _, release in ipairs(releases) do
        local details = {}
        for _, field in ipairs({"format", "language", "source"}) do
            if type(release[field]) == "string" and release[field] ~= "" then details[#details+1] = release[field] end
        end
        local size = type(release.size) == "string" and release.size ~= "" and release.size or nil
        local title = tostring(release.title or book.title or "Ausgabe")
        local text = title .. (#details > 0 and (" — " .. table.concat(details, " · ")) or "")
        items[#items+1] = {text=text, mandatory=size, release=release,
            confirmation=text .. (size and (" · " .. size) or "")}
    end
    if #items == 0 then items[1] = {text="Keine Ausgaben gefunden.", unavailable=true} end
    menu = Menu:new{title="Buchdetails", custom_title_bar=header, item_table=items,
        covers_fullscreen=true, is_borderless=true, is_popout=false,
        items_per_page=3, items_max_lines=2,
        onSwipe=function(m, _, gesture)
            if gesture.pos.y < header_height then return true end
            if gesture.direction == "north" or gesture.direction == "west" then m:onNextPage()
            elseif gesture.direction == "south" or gesture.direction == "east" then m:onPrevPage() end
            return true
        end,
        onMenuSelect=function(_, item)
            if item.unavailable then return end
            self:present(ConfirmBox:new{text="Diese Ausgabe bei Shelfmark herunterladen?\n\n" .. item.confirmation,
                ok_text="Herunterladen", ok_callback=function() self:queue(item.release, book) end})
        end,
    }
    self:present(menu, function()
        if cover_widget and cover_widget.free then cover_widget:free() end
        if cover then os.remove(cover) end
    end)
end

function Shelfmark:opdsPlus()
    local plus = self.ui.opds_plus
    if not plus or type(plus._createBrowserInstance) ~= "function" then
        self:message("OPDS Plus ist nicht verfügbar. Bitte Plugin installieren oder aktivieren und KOReader neu starten.")
        return nil
    end
    return plus
end

function Shelfmark:chooseOPDSCatalog(callback)
    local plus = self:opdsPlus()
    if not plus then return end
    local items = {}
    for _, server in ipairs(plus.servers or {}) do
        if type(server.url) == "string" and server.url ~= "" then
            items[#items+1] = {text=server.title or server.url, server=server}
        end
    end
    if #items == 0 then return self:message("Bitte zuerst einen Katalog in OPDS Plus einrichten.") end
    local menu
    menu = self:list("OPDS-Plus-Katalog wählen", items, function(item)
        self:save("opds_catalog_url", item.server.url)
        UIManager:close(menu)
        if callback then callback(item.server, plus) end
    end)
end

function Shelfmark:openInOPDS(item, owner)
    local plus = self:opdsPlus()
    if not plus then return end
    local chosen, preferred = nil, self.settings:readSetting("opds_catalog_url")
    local servers = plus.servers or {}
    for _, server in ipairs(servers) do
        if preferred and server.url == preferred then chosen = server; break end
    end
    if not chosen and not preferred then
        if #servers == 1 then chosen = servers[1] end
    end
    local function open(server, opds)
        self:online(function() self:searchInOPDS(opds, server, item.title) end, owner)
    end
    if chosen then open(chosen, plus) else self:chooseOPDSCatalog(open) end
end

function Shelfmark:searchInOPDS(plus, server, title)
    if type(server.url) ~= "string" or type(title) ~= "string" or title == "" then
        return self:message("Katalogadresse oder Buchtitel fehlt.")
    end
    -- Close all Shelfmark windows and cancel its work before switching apps.
    self:shutdown()
    -- Use the installed plugin's own browser and credentials; never store its password here.
    local browser = plus:_createBrowserInstance()
    plus.opds_browser = browser
    browser.root_catalog_title = server.title or "Katalog"
    browser.root_catalog_username = server.username
    browser.root_catalog_password = server.password
    browser.root_catalog_raw_names = server.raw_names
    browser.catalog_title = browser.root_catalog_title
    UIManager:show(browser)
    local template
    if server.url:find("%%s") then
        template = server.url
    else
        if not browser:updateCatalog(server.url) then
            return self:message("Der OPDS-Plus-Katalog konnte nicht geöffnet werden.")
        end
        template = browser.search_url
    end
    if type(template) ~= "string" or not (template:find("%%s") or template:find("{searchTerms}", 1, true)) then
        return self:message("Dieser Katalog bietet keine unterstützte OPDS-Suche. Der Katalog ist geöffnet.")
    end
    local base, target = url.parse(server.url), url.parse(template)
    local function port(parsed) return tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80) end
    if not base or not target or not base.host or not target.host or
        base.scheme ~= target.scheme or base.host:lower() ~= target.host:lower() or port(base) ~= port(target) then
        return self:message("Die Katalogsuche verweist auf einen anderen Server und wird aus Sicherheitsgründen nicht automatisch geöffnet.")
    end
    local function runSearch(query)
        local encoded = url.escape(query)
        local search_url = template:gsub("{searchTerms}", function() return encoded end):gsub("%%s", function() return encoded end)
        browser.catalog_title = "Suche: " .. query
        if not browser:updateCatalog(search_url) then
            UIManager:show(ConfirmBox:new{
                text="Kein Treffer in OPDS Plus. Vielleicht ist das Buch noch nicht in CWNG angekommen oder der Titel weicht ab. Suchbegriff anpassen?",
                ok_text="Suche ändern", ok_callback=function()
                    self:input("Titel in OPDS Plus suchen", query, function(value)
                        if value:match("%S") then runSearch(value) end
                    end)
                end,
            })
        end
    end
    runSearch(title)
end

function Shelfmark:queue(release, book)
    if not release.source or not release.source_id then return self:message("Ausgabe ohne Quellen-ID.") end
    local payload = {}
    for key, value in pairs(release) do payload[key] = value end
    if book then
        if type(book.title) == "string" and book.title ~= "" then payload.title = book.title end
        if type(book.authors) == "table" and #book.authors > 0 then payload.author = table.concat(book.authors, ", ") end
        if type(book.cover_url) == "string" then payload.preview = book.cover_url end
        if tonumber(book.publish_year) then payload.year = tonumber(book.publish_year) end
    end
    local data, err = self:request("/api/releases/download", payload)
    if not data then return self:message(err) end
    self:message("Download bei Shelfmark gestartet. Nach der Verarbeitung kann das Buch über CWNG verfügbar werden.")
    local menu = self.home_menu
    if menu then
        if menu.refresh_job then UIManager:unschedule(menu.refresh_job) end
        menu.refresh_job = function() if self.home_menu == menu then self:refreshHome(menu) end end
        UIManager:scheduleIn(3, menu.refresh_job)
    end
end

return Shelfmark
