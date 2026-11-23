-- LuaJIT smoke test with KOReader and Shelfmark stand-ins; not an emulator test.
local modules = {}
local function register(name, value) package.preload[name] = function() return value end end
local widget = {}
function widget:new(t) return setmetatable(t, self) end
function widget:extend(t) t.__index=t; return setmetatable(t, {__index=self}) end
register("ui/widget/container/widgetcontainer", widget)
register("libs/libkoreader-lfs", {attributes=function() return "directory" end, mkdir=function() return true end})
register("device", {screen={scaleBySize=function(_, n) return n end, getWidth=function() return 600 end, getHeight=function() return 800 end}})
local generic = {new=function(_, x) x.getSize=function() return {h=30, w=110} end; x.getHeight=function() return 30 end; x.generateVerticalLayout=function() return {} end; return x end}
register("ui/font", {getFace=function() return {} end})
for _, name in ipairs({"ui/geometry", "ui/widget/imagewidget", "ui/widget/textboxwidget", "ui/widget/titlebar", "ui/widget/textwidget", "ui/widget/container/centercontainer", "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/verticalgroup", "ui/widget/verticalspan"}) do register(name, generic) end
local shown = {}
local visible, scheduled = {}, {}
local skip_close_event
local ui_manager = {
    show=function(_, w) shown[#shown+1]=w; visible[w]=true end,
    close=function(_, w)
        if w ~= skip_close_event and w.onCloseWidget then w:onCloseWidget() end
        visible[w] = nil
    end,
    isWidgetShown=function(_, w) return visible[w] end,
    scheduleIn=function(_, _, job) scheduled[job]=true end,
    nextTick=function(_, job) scheduled[job]=true end,
    unschedule=function(_, job) scheduled[job]=nil end,
}
register("ui/uimanager", ui_manager)
for _, name in ipairs({"ui/widget/inputdialog", "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/menu", "ui/widget/textviewer", "ui/widget/buttondialog", "ui/widget/button"}) do
    register(name, generic)
end
local online_callback
register("ui/network/manager", {runWhenOnline=function(_, cb) online_callback = cb end})
local settings_dir = "/tmp"
register("datastorage", {getSettingsDir=function() return settings_dir end})
local values = {url="https://example.test", key="secret", dir="/tmp"}
local settings = {readSetting=function(_, k, d) if values[k] == nil then return d end; return values[k] end,
    saveSetting=function(_, k, v) values[k]=v end, flush=function() end}
local cache_values = {}
local cache_settings = {readSetting=function(_, k, d) if cache_values[k] == nil then return d end; return cache_values[k] end,
    saveSetting=function(_, k, v) cache_values[k]=v end, flush=function() end}
local activity_values = {}
local activity_settings = {readSetting=function(_, k, d) if activity_values[k] == nil then return d end; return activity_values[k] end,
    saveSetting=function(_, k, v) activity_values[k]=v end, flush=function() end}
register("luasettings", {open=function(_, path)
    if path:find("shelfmark%-cover%-cache") then return cache_settings end
    if path:find("shelfmark%-activity%-cache") then return activity_settings end
    return settings
end})
register("dispatcher", {registerAction=function() end})
local escape = function(s) return (s:gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)) end
register("socket.url", {escape=escape, unescape=function(s) return s end,
    parse=function(s) local scheme, host = s:match("^(https?)://([^/]+)"); return {scheme=scheme, host=host} end})
register("socketutil", {set_timeout=function() end, reset_timeout=function() end})
register("util", {htmlToPlainTextIfHtml=function(s) return s end})
register("ui/widget/iconwidget", {new=function(_, v) return v end})
local canned = {}
local json_null = function() end
register("json", {util={null=json_null}, encode=function(value) canned.sent=value; return "{}" end, decode=function(value) return assert(canned[value], value) end})
register("ltn12", {source={string=function(s) return function() return s end end}, sink={
    table=function(t) return function(s) if s then t[#t+1]=s end; return 1 end end,
    file=function(f) return function(s) if s then return f:write(s) end; return f:close() end end,
}})
local requests = {}
local auth_mode, expire_once = false, false
register("socket.http", {request=function(req)
    requests[#requests+1]=req
    assert(req.redirect == false)
    assert(not req.headers["X-Api-Key"])
    local body, headers = "response", {}
    if auth_mode and req.url:find("/api/auth/login", 1, true) then
        assert(canned.sent.username == "test-user" and canned.sent.password == "test-password")
        canned.response = {success=true}
        headers["set-cookie"] = "shelfmark_session=fixture; HttpOnly; Path=/"
        req.sink(body); req.sink(nil)
        return 1, 200, headers
    end
    if auth_mode then
        assert(req.headers.Cookie == "shelfmark_session=fixture" and not req.headers["X-Api-Key"])
        if expire_once then expire_once = false; req.sink(nil); return 1, 401, {} end
    end
    if req.url:find("metadata/search", 1, true) then canned.response={books={{title="Dune", authors={"Frank Herbert"}, provider="test", provider_id="42", publish_year=1965, library={ebook="owned"}}, {title="Sammlung", library={ebook="collection"}}, {title="Unbekannt"}, {title="Nicht gefunden", library={ebook=json_null}}}}
    elseif req.url:find("/api/metadata/book/", 1, true) then canned.response={title="Dune", description="Beschreibung", authors={"Frank Herbert"}}
    elseif req.url:find("/api/releases?", 1, true) then canned.response={releases={{title="Ein sehr langer Titel, der in der Ausgabenliste abgeschnitten werden kann", source="test", source_id="abc", format="epub", size="123.45 MB"}}}
    elseif req.url:find("/api/releases/download", 1, true) then canned.response={status="queued"}
    elseif req.url:find("/api/status", 1, true) then canned.response={complete={abc={}}}
    elseif req.url:find("/api/localdownload", 1, true) then body="EPUB DATA"; headers["content-disposition"]='attachment; filename="book.epub"'
    else error(req.url) end
    req.sink(body); req.sink(nil)
    return 1, 200, headers
end})
G_reader_settings = {readSetting=function(_, _, default) return default end}
local plugin = assert(loadfile("main.lua"))()
local instance = setmetatable({ui={menu={registerToMainMenu=function() end}, openFile=function() end}}, plugin)
instance:init()
instance:search("Dune & Co")
assert(requests[#requests].url:find("Dune%%20%%26%%20Co"))
local results=shown[#shown]
assert(results.item_table[1].state[1].text == "Dune" and results.item_table[1].state[3][1].text:find("Frank Herbert"))
assert(results.item_table[1].state[3][3].text:find("1965") and results.item_table[1].state[3][3].text:find("In deiner Bibliothek"))
assert(results.item_table[2].state[3][3].text:find("In einer Sammlung vorhanden"))
assert(results.item_table[3].state[3][3].text == "Status unbekannt" and results.item_table[4].state[3][3].text == "Noch nicht vorhanden")
instance:search("Frank & Co", "author", "provider name")
assert(requests[#requests].url:find("author=Frank%%20%%26%%20Co"))
assert(requests[#requests].url:find("provider=provider%%20name"))
instance:search("Dune", "title", "test")
assert(requests[#requests].url:find("title=Dune") and requests[#requests].url:find("provider=test"))
local detail_book, detail_releases
instance.showBookScreen = function(_, book, releases) detail_book, detail_releases = book, releases end
results:onMenuSelect(results.item_table[1])
assert(detail_book.description == "Beschreibung" and detail_book.library.ebook == "owned" and #detail_releases == 1)
instance.showBookScreen = nil
local opened
instance.openInOPDS = function(_, book) opened = book end
instance:showBookScreen(detail_book, detail_releases)
local book_screen = shown[#shown]
assert(book_screen.item_table[1].mandatory == "123.45 MB")
assert(book_screen.item_table[1].confirmation:find("123.45 MB", 1, true))
local button = book_screen.custom_title_bar.opds_button
assert(button and button.text == "Buch öffnen")
assert(book_screen.custom_title_bar:generateVerticalLayout()[1][1] == button)
button.callback()
assert(opened == detail_book)
instance:showBookScreen({title="Sammlung", library={ebook="collection"}}, {})
assert(shown[#shown].custom_title_bar.opds_button ~= nil)
instance:showBookScreen({title="Unbekannt"}, {})
assert(shown[#shown].custom_title_bar.opds_button == nil)
instance.openInOPDS = nil
instance:queue(detail_releases[1])
assert(canned.sent.source_id == "abc" and values.pending == nil)
values.url="http://example.test"
auth_mode = true
values.username = "test-user"; values.password = "test-password"
local status = assert(instance:request("/api/status"))
assert(status.complete.abc)
expire_once = true
assert(instance:request("/api/status").complete.abc)
instance:save("username", "other-user")
assert(instance.session_cookie == nil)
local home = {page=1, perpage=5, cover_files={}, updateItems=function() end}
settings_dir = os.tmpname()
os.remove(settings_dir)
assert(os.execute("mkdir -p '" .. settings_dir .. "/shelfmark-covers' ") == 0)
local downloads = 0
instance.cover = function()
    downloads = downloads + 1
    local path = settings_dir .. "/download.jpg"
    local file = assert(io.open(path, "wb")); assert(file:write("cover")); file:close()
    return path
end
local first = assert(instance:homeCover("/cover/1"))
assert(instance:homeCover("/cover/1") == first and downloads == 1)
for i = 2, 64 do assert(instance:homeCover("/cover/" .. i)) end
assert(instance:homeCover("/cover/1") == first)
assert(instance:homeCover("/cover/65"))
assert(#cache_values.entries == 64 and io.open(first, "rb"))
assert(cache_values.entries[1].key:find("/cover/3", 1, true))
instance.cover_cache = nil
assert(instance:homeCover("/cover/1") == first and downloads == 65)
for _, entry in ipairs(cache_values.entries) do os.remove(settings_dir .. "/shelfmark-covers/" .. entry.file) end
os.execute("rmdir '" .. settings_dir .. "/shelfmark-covers' '" .. settings_dir .. "'")
settings_dir = "/tmp"
instance.cover = nil
instance.home_menu = home
instance.request = function(_, path)
    if path == "/api/activity/snapshot" then return {status={complete={a={title="Buch A", author="Autor A", added_time=20}}, queued={q={title="Buch Q", author="Autor Q", added_time=30}}}} end
    if path:find("/api/activity/history?limit=100&offset=0", 1, true) then return {
        {item_type="download", final_status="complete", source_id="b", snapshot={download={title="Buch B", author="Autor B", added_time=10}}},
        {item_type="download", final_status="error", source_id="c", snapshot={download={title="Fehler"}}},
    } end
    if path:find("/api/activity/history", 1, true) then return {} end
end
instance:refreshHome(home)
assert(#home.item_table == 4 and home.item_table[1].status_label == "Wartet" and home.item_table[2].status_label == "Abgeschlossen" and home.item_table[4].status_label == "Fehler")
assert(#activity_values.entries == 4 and activity_values.entries[1].title == "Buch Q")
local saved_entries = instance:readHomeCache()
local restored = {page=1, perpage=5, cover_files={}, item_table={}, updateItems=function() end}
instance.home_menu = restored
instance:displayHomeEntries(restored, saved_entries, true)
assert(restored.item_table[2].title == "Buch A" and restored.cache_only)
instance.request = function() return nil, "offline" end
instance:refreshHome(restored)
assert(#restored.item_table == 4 and #activity_values.entries == 4)
instance.request = function(_, path)
    if path == "/api/activity/snapshot" then return {status={complete={new={title="Neu"}}}} end
    return nil, "history unavailable"
end
instance:refreshHome(restored)
assert(restored.item_table[2].title == "Buch A" and #activity_values.entries == 4)
instance.request = function(_, path)
    if path == "/api/activity/snapshot" then return {status={complete={new={title="Neu"}}}} end
    if path:find("/api/activity/history", 1, true) then return {} end
end
instance:refreshHome(restored)
assert(#activity_values.entries == 1 and restored.item_table[1].title == "Neu" and not restored.cache_only)
values.username = "anderer Benutzer"
assert(instance:readHomeCache() == nil)
values.username = "other-user"
local visited = {}
local browser = {paths={}, updateCatalog=function(self, location)
    visited[#visited+1] = location
    if #visited == 1 then self.search_url = "http://catalog.test/search?q=%s" end
    return true
end}
instance:searchInOPDS({_createBrowserInstance=function() return browser end},
    {url="http://catalog.test/opds", title="Testkatalog"}, "Buch & Test")
assert(visited[1] == "http://catalog.test/opds" and visited[2] == "http://catalog.test/search?q=Buch%20%26%20Test")
local closed, cleaned = 0, 0
instance.session_active = true
instance.session_generation = 1
instance.session_widgets = {}
local function testwidget()
    return {onCloseWidget=function() closed = closed + 1 end}
end
local root, child = testwidget(), testwidget()
local network_calls = 0
instance:online(function() network_calls = network_calls + 1 end)
instance:present(root, function() cleaned = cleaned + 1 end, true)
instance:present(child, function() cleaned = cleaned + 1 end)
instance:shutdown()
assert(not instance.session_active and instance.session_widgets == nil and closed == 2 and cleaned == 2)
assert(instance.session_generation == 2 and instance.session_cookie == nil)
online_callback()
assert(network_calls == 0)
local freed = 0
local temp_file = os.tmpname()
local covers = {item_table={{state={free=function() freed = freed + 1 end}}}, cover_files={temp_file}}
instance:releaseHomeCovers(covers)
assert(freed == 1 and #covers.cover_files == 0 and io.open(temp_file, "r") == nil)
instance:shutdown()
assert(closed == 2 and cleaned == 2)

activity_values.entries = nil
instance.request = function(_, path)
    assert(path == "/api/releases/download")
    return {status="queued"}
end
local exits = {
    function(menu) menu.custom_title_bar.titlebar.close_callback() end,
    function(menu) ui_manager:close(menu) end,
    function() instance:onCloseWidget() end,
    function()
        instance:searchInOPDS({_createBrowserInstance=function() return browser end},
            {url="http://catalog.test/search?q=%s"}, "Buch")
        assert(ui_manager:isWidgetShown(browser))
    end,
}
for _, exit in ipairs(exits) do
    instance:onShelfmarkOpen()
    local menu = instance.home_menu
    local initial_job = menu.initial_job
    assert(scheduled[initial_job])
    instance:queue(detail_releases[1])
    local refresh_job = menu.refresh_job
    assert(scheduled[refresh_job])
    local cover_path = os.tmpname()
    local cover_file = assert(io.open(cover_path, "wb"))
    cover_file:close()
    instance:showBookScreen({title="Buch"}, {}, cover_path)
    local details = shown[#shown]
    instance.session_cookie = "fixture"
    instance.last_query = "Buch"
    instance:online(function() error("closed session was used") end)
    exit(menu)
    assert(not instance.session_active and not instance.home_menu and not instance.session_widgets)
    assert(not instance.session_cookie and not instance.last_query)
    assert(not ui_manager:isWidgetShown(menu) and not ui_manager:isWidgetShown(details))
    assert(not scheduled[initial_job] and not scheduled[refresh_job])
    assert(io.open(cover_path, "rb") == nil)
    instance:onShelfmarkOpen()
    online_callback()
    instance:shutdown()
end

instance:onShelfmarkOpen()
local owner = instance:present(testwidget())
instance:online(function() network_calls = network_calls + 1 end, owner)
ui_manager:close(owner)
online_callback()
assert(instance.session_active and network_calls == 0)
local fallback_cleaned = false
skip_close_event = instance:present(testwidget(), function() fallback_cleaned = true end)
instance:shutdown()
assert(fallback_cleaned)
print("Smoke test passed")
