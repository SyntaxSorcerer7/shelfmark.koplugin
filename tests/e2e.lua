-- Runs as a late user patch inside the real KOReader application.
local UIManager = require("ui/uimanager")
local Device = require("device")
local phase = assert(os.getenv("SHELFMARK_E2E_PHASE"))
local artifacts = assert(os.getenv("SHELFMARK_E2E_ARTIFACTS"))
local base = "http://127.0.0.1:8084"
local plugin

local function step(callback, delay)
    UIManager:scheduleIn(delay or 0.2, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            io.stderr:write("E2E FAILED: " .. tostring(err) .. "\n")
            pcall(function() Device.screen:shot(artifacts .. "/" .. phase .. "-failure.png") end)
            os.exit(1)
        end
    end)
end

local function screenshot(name)
    UIManager:forceRePaint()
    Device.screen:shot(artifacts .. "/" .. phase .. "-" .. name .. ".png")
end

local function last()
    return assert(plugin.session_widgets[#plugin.session_widgets], "Missing Shelfmark window")
end

local function success()
    plugin:shutdown()
    local file = assert(io.open(artifacts .. "/" .. phase .. "-passed.txt", "w"))
    file:write("PASS\n"); file:close()
    print("E2E " .. phase .. " PASSED")
    os.exit(0)
end

step(function()
    local fm = assert(require("apps/filemanager/filemanager").instance, "File manager did not start")
    plugin = assert(fm.shelfmark, "Shelfmark was not loaded by KOReader")
    if phase == "offline" then
        plugin:onShelfmarkOpen()
        local home = plugin.home_menu
        assert(home.cache_only and home.item_table[1].title == "Das Testbuch", "Offline activity missing")
        assert(home.item_table[1].cover_path, "Offline cover missing")
        plugin:refreshHome(home) -- Real connection failure must preserve the cache.
        assert(home.item_table[1].title == "Das Testbuch", "Failed refresh cleared activity")
        screenshot("activity")
        success()
        return
    end
    plugin:save("url", base)
    plugin:save("username", "fixture-user")
    plugin:save("password", "fixture-password")
    plugin:onShelfmarkOpen()
    plugin:searchDialog()
    last():setInputText("Test")
    last().buttons[1][2].callback() -- Author search, retaining the input.
    assert(last():getInputText() == "Test")
    last().buttons[2][1].callback() -- Search library selector.
    step(function()
        local libraries = last()
        assert(#libraries.item_table == 1, "Inactive metadata provider was offered")
        assert(libraries.item_table[1].name == "openlibrary")
        libraries:onMenuSelect(libraries.item_table[1])
        assert(last():getInputText() == "Test")
        screenshot("search")
        last().buttons[3][2].callback() -- Submit through the real dialog.
        step(function()
            local results = last()
            assert(#results.item_table == 1 and results.item_table[1].book.title == "Das Testbuch", "Search failed")
            assert(plugin.session_cookie, "Shelfmark session login failed")
            screenshot("results")
            results:onMenuSelect(results.item_table[1])
            local details = last()
            assert(#details.item_table == 1 and details.item_table[1].release.source == "e2e", "Edition missing")
            screenshot("details")
            details:onMenuSelect(details.item_table[1])
            local confirmation = last()
            assert(confirmation.ok_callback, "Download confirmation missing")
            UIManager:close(confirmation)
            confirmation.ok_callback()
            local deadline = os.time() + 60
            local function waitForDownload()
                plugin:refreshHome(plugin.home_menu)
                local entry = plugin.home_menu.item_table[1]
                assert(entry.status ~= "error", "Shelfmark download failed")
                if entry.status ~= "complete" then
                    assert(os.time() < deadline, "Download did not complete")
                    step(waitForDownload, 1)
                    return
                end
                assert(entry.title == "Das Testbuch" and entry.cover_path, "Activity cover or title missing")
                plugin:shutdown()
                plugin:onShelfmarkOpen()
                assert(plugin.home_menu.cache_only, "Activity was not restored on reopening")
                screenshot("activity")
                local plus = assert(fm.opds_plus, "OPDS Plus not loaded")
                plus.servers = {{title="E2E catalog", url=base .. "/opds"}}
                plugin.home_menu.item_table[1].open_button.callback()
                step(function()
                    assert(not plugin.session_active, "Shelfmark did not close on handoff")
                    local browser = assert(plus.opds_browser, "OPDS Plus handoff failed")
                    assert(browser.catalog_title == "Suche: Das Testbuch", "OPDS search title missing")
                    assert(#browser.item_table > 0 and browser.item_table[1].text == "Das Testbuch", "OPDS result missing")
                    screenshot("opds")
                    success()
                end)
            end
            step(waitForDownload, 1)
        end)
    end)
end)
