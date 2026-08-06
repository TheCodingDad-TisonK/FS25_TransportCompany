-- Regression test for the PDA stack overflow.
--
-- Both SmoothLists use the frame as their delegate, and reloadData ends
-- up calling setSelectedItem, which fires onListSelectionChanged
-- (SmoothListElement.lua:488, :857). The fake lists below reproduce
-- exactly that: reloadData re-enters the frame's callback. Before the
-- fix this recursed until Lua blew its stack.
local ROOT = ...
local pass, fail = 0, 0
local function ok(c, n, e)
    if c then pass = pass + 1; print("  PASS " .. n)
    else fail = fail + 1; print("  FAIL " .. n .. (e and ("  -> " .. tostring(e)) or "")) end
end

function Class(target, base)
    local mt = { __index = target }
    if base then
        setmetatable(target, { __index = base })
        target.superClass = function() return base end
    end
    target.class = function() return target end
    return mt
end

g_currentModName = "FS25_TransportCompany"
FillType = { UNKNOWN = 0, DIESEL = 1, WHEAT = 2 }
MoneyType = { MISSIONS = "m", AI = "ai" }
InputAction = { MENU_BACK = 1, MENU_ACTIVATE = 2, MENU_EXTRA_1 = 3 }
g_currentMission = { time = 5000, getFarmId = function() return 1 end }
g_i18n = {
    getText = function(_, k) return k end,
    formatMoney = function(_, v) return tostring(v) end,
    formatDistance = function(_, v) return tostring(v) end,
}
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    -- returns an ALREADY localized title, like the real engine
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function(_, i)
        return { isPalletType = false, hudOverlayFilename = "hud_wheat.png" }
    end,
}
function printWarning() end
function printError() end
TransportCompanyLog = { info = function() end, debug = function() end,
                        warning = function() end, error = function() end }

-- minimal engine frame base
TabbedMenuFrameElement = {}
TabbedMenuFrameElement.new = function(target, mt) return setmetatable({}, mt) end
function TabbedMenuFrameElement:onFrameOpen() end
function TabbedMenuFrameElement:onFrameClose() end
function TabbedMenuFrameElement:setMenuButtonInfo(i) self.menuButtonInfo = i end
function TabbedMenuFrameElement:setMenuButtonInfoDirty() self.dirty = true end

-- minimal MessageDialog base for the help dialog
MessageDialog = {}
MessageDialog.new = function(target, mt) return setmetatable({}, mt) end
function MessageDialog:onCreate() end
function MessageDialog:onOpen() end
function MessageDialog:onClose() end
function MessageDialog:close() self.isClosed = true end
function MessageDialog:setText() end

g_gui = {
    guis = {},
    loadGui = function(_, xml, name, instance)
        g_gui.lastXml = xml
        g_gui.guis[name] = instance
    end,
    showDialog = function(_, name)
        g_gui.shownName = name
        if g_gui.guis[name] and g_gui.guis[name].onOpen then
            g_gui.guis[name]:onOpen()
        end
    end,
}

dofile(ROOT .. "/scripts/transportCompany/TransportCompanyContract.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyTruck.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanySettings.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyCompany.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyManager.lua")
dofile(ROOT .. "/scripts/gui/InGameMenuTransportCompanyFrame.lua")
dofile(ROOT .. "/scripts/gui/TransportCompanyHelpDialog.lua")

TransportCompanyContractEvent = { TYPE_ADD = 1, TYPE_UPDATE = 2, TYPE_STATE_CHANGE = 3,
                                  TYPE_REMOVE = 4, sendEvent = function() end }
TransportCompanyMoneyEvent = { sendEvent = function() end }
TransportCompanyAcceptEvent = { MODE_SELF = 1, MODE_HIRE = 2 }

local mgr = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
mgr.isServer, mgr.isMissionLoaded = true, true
g_transportCompanyManager = mgr
-- The PDA binds to the local player's own company (farm 1 here).
local comp = mgr:getOrCreateCompany(1)
mgr._hasHq = function() return true end

local c = TransportCompanyContract.new()
c.contractId, c.amount, c.litersPerUnit, c.reward = "c1", 1000, 1, 500
c.fillTypeIndex, c.sourceName, c.destName = FillType.WHEAT, "Silo", "Dairy"
comp.contracts["c1"] = c

local frame = InGameMenuTransportCompanyFrame.new()

-- a text element that just records what it was told
local function text() return { setText = function(s, v) s.v = v end,
                               setVisible = function() end } end

local depth, maxDepth = 0, 0
local function fakeList(name)
    local L = { selectedIndex = 1, name = name }
    L.setDataSource = function() end
    L.setSelectedItem = function() end
    L.reloadData = function(self)
        depth = depth + 1
        maxDepth = math.max(maxDepth, depth)
        if depth < 200 then
            -- what the engine really does on reload
            frame:onListSelectionChanged(self, 1, 1)
        end
        depth = depth - 1
    end
    return L
end

frame.contentList = fakeList("content")
frame.detailList  = fakeList("detail")
frame.emptyText   = text()
frame.detailBox   = { setVisible = function(s, v) s.visible = v end }
frame.detailTitle, frame.detailSubtitle = text(), text()
frame.progressLabel, frame.rewardText = text(), text()
frame.rewardLabel = text()
frame.progressBarBg = { size = { 680, 33 }, setVisible = function() end }
frame.progressBar   = { margin = { 4, 0 }, startSize = { 6, 0 },
                        setSize = function(s, w) s.w = w end }
frame.backButtonInfo = {}
frame.acceptButtonInfo = {}
frame.hireButtonInfo = {}

print("\n-- no runaway recursion --")
local okCall, err = pcall(function() frame:updateTabContent() end)
ok(okCall, "updateTabContent completes", err)
ok(maxDepth < 10, "reload nesting stays shallow (max " .. maxDepth .. ")", maxDepth)

print("\n-- detail panel is populated --")
ok(#frame.detailRows > 0, "detail rows built", #frame.detailRows)
local labels = {}
for _, r in ipairs(frame.detailRows) do labels[r.label] = r.value end
ok(labels["transportCompany_contractSource"] == "Silo", "pickup shown", labels["transportCompany_contractSource"])
ok(labels["transportCompany_contractDestination"] == "Dairy", "dropoff shown", labels["transportCompany_contractDestination"])
ok(frame.detailTitle.v ~= nil and frame.detailTitle.v ~= "", "title set", frame.detailTitle.v)
ok(frame.rewardText.v == "500", "reward shown", frame.rewardText.v)
ok(frame.rewardLabel.v ~= nil, "reward has a label", frame.rewardLabel.v)

print("")
print("-- fill type name is not double-translated --")
-- getFillTypeTitleByIndex already returns localized text; wrapping it in
-- getText again produced "Missing 'Soybeans' in l10n_en.xml" in the UI
ok(c:getLocalizedFillType() == "Wheat", "title used verbatim", c:getLocalizedFillType())
ok(frame.rows[1].primary == "Wheat", "row shows the real name", frame.rows[1].primary)
ok(frame.rows[1].icon == "hud_wheat.png", "row carries the fill type icon", frame.rows[1].icon)

print("\n-- every row uses the single cell layout --")
local allRow = true
for _, r in ipairs(frame.rows) do if r.cellName ~= "row" then allRow = false end end
ok(allRow, "content rows all use 'row'")
ok(frame:getCellTypeForItemInSection(frame.contentList, 1, 99) == "row",
   "out-of-range probe still returns a real cell type")
ok(frame:getCellTypeForItemInSection(frame.detailList, 1, 1) == "detailItem",
   "detail list uses detailItem")

print("\n-- selection callback from the detail list is ignored --")
local before = maxDepth
frame:onListSelectionChanged(frame.detailList, 1, 1)
ok(maxDepth == before, "detail list selection does not rebuild")

print("\n-- tab switching --")
for _, tab in ipairs({ 2, 3, 1 }) do
    local okTab, errTab = pcall(function() frame:setTab(tab) end)
    ok(okTab, "switch to tab " .. tab, errTab)
end
ok(frame.currentTab == 1, "ends on dispatch")

print("")
print("-- settings tab --")
frame:setTab(4)
ok(#frame.rows == #TransportCompanySettings.definitions,
   "one row per setting", #frame.rows)
ok(frame.rows[1].setting ~= nil, "rows carry their definition")
ok(frame:getSelectedSetting() ~= nil, "a setting is selected")

-- shared settings are server-authoritative; localOnly always editable
g_server = nil
local shared, localOnly
for _, d in ipairs(TransportCompanySettings.definitions) do
    if d.localOnly then localOnly = d else shared = shared or d end
end
ok(TransportCompanySettings.getIsEditable(localOnly) == true,
   "local setting editable on a client")
ok(TransportCompanySettings.getIsEditable(shared) == false,
   "shared setting refused on a client")
g_server = {}
ok(TransportCompanySettings.getIsEditable(shared) == true,
   "shared setting editable on the server")

print("")
print("-- setting values cycle sanely --")
local st = comp.settings
st:set("showNotifications", true)
st:cycle("showNotifications", 1)
ok(st:get("showNotifications") == false, "boolean toggles")
st:set("maxActiveContracts", 12)          -- max
st:cycle("maxActiveContracts", 1)
ok(st:get("maxActiveContracts") == 1, "number wraps past max to min",
   st:get("maxActiveContracts"))
st:set("hiredDriverRewardShare", 20)
st:cycle("hiredDriverRewardShare", 1)
ok(st:get("hiredDriverRewardShare") == 25, "percentage steps by 5",
   st:get("hiredDriverRewardShare"))
ok(st:getDisplayValue("showNotifications") == "transportCompany_off",
   "booleans display as on/off", st:getDisplayValue("showNotifications"))

print("")
print("-- ledger indexes the panel instead of duplicating it --")
local done = TransportCompanyContract.new()
done.contractId, done.amount, done.reward = "old1", 500, 900
done.fillTypeIndex = FillType.WHEAT
done:complete()
comp.contracts["old1"] = done
frame:setTab(3)
ok(frame.rows[1].summary == true, "first row is the company summary")
local hist = 0
for _, r in ipairs(frame.rows) do if r.contract ~= nil then hist = hist + 1 end end
ok(hist == 1, "finished job listed as history", hist)
ok(frame.rows[1].primary ~= frame.rows[2].primary,
   "history row is not a copy of the summary")

print("")
print("-- help footer button is on every tab --")
g_currentModDirectory = "/mods/tc/"
local frame2 = InGameMenuTransportCompanyFrame.new()
frame2.getDescendantById = function() return nil end
local okInit, errInit = pcall(function() frame2:initialize() end)
ok(okInit, "frame initializes with the help button", errInit)
ok(frame2.helpButtonInfo ~= nil and frame2.helpButtonInfo.text ~= nil,
   "help button defined with a label", frame2.helpButtonInfo and frame2.helpButtonInfo.text)
frame2.setMenuButtonInfo = function(_, buttons) frame2.lastButtons = buttons end
frame2.setMenuButtonInfoDirty = function() end
frame2.contentList = { selectedIndex = 0 }
frame2.currentTab = InGameMenuTransportCompanyFrame.TAB_DISPATCH
frame2:_updateMenuButtons()
local hasHelp = false
for _, b in ipairs(frame2.lastButtons) do
    if b == frame2.helpButtonInfo then hasHelp = true end
end
ok(hasHelp, "help button present in the footer", hasHelp)
ok(frame2.lastButtons[1] == frame2.backButtonInfo, "back stays the first button")

print("")
print("-- help dialog pages --")
local help = TransportCompanyHelpDialog.new()
help.titleText   = { setText = function(s, v) s.v = v end }
help.bodyText    = { setText = function(s, v) s.v = v end }
help.pageCounter = { setText = function(s, v) s.v = v end }
help.btnPrevBg   = { setImageColor = function() end }
help.btnPrevText = { setTextColor = function() end }
help.btnNextBg   = { setImageColor = function() end }
help.btnNextText = { setTextColor = function() end }
ok(#TransportCompanyHelpDialog.PAGES >= 6, "at least six guide pages", #TransportCompanyHelpDialog.PAGES)
help:showPage(1)
ok(help.currentPage == 1, "starts on page 1")
ok(help.titleText.v ~= "" and help.bodyText.v ~= "", "page 1 has title and body")
ok(help.pageCounter.v == "1 / " .. #TransportCompanyHelpDialog.PAGES, "counter shows position",
   help.pageCounter.v)
help:showPage(2)
ok(help.currentPage == 2, "next page advances")
help:onClickPrev()
ok(help.currentPage == 1, "prev goes back")
help:onClickPrev()
ok(help.currentPage == 1, "prev clamps at page 1")
help:showPage(#TransportCompanyHelpDialog.PAGES)
help:onClickNext()
ok(help.currentPage == #TransportCompanyHelpDialog.PAGES, "next clamps at the last page")
help:onClickClose()
ok(help.isClosed == true, "close dismisses the dialog")

print("")
print("-- help dialog opens from the frame --")
g_gui.shownName = nil
g_transportCompanyHelpDialog = nil
TransportCompanyHelpDialog.show()
ok(g_gui.shownName == "transportCompanyHelpDialog", "dialog opened via g_gui:showDialog",
   tostring(g_gui.shownName))
ok(g_transportCompanyHelpDialog ~= nil, "dialog instance cached", g_transportCompanyHelpDialog)
ok(g_transportCompanyHelpDialog.currentPage == 1, "opens on the first page")
ok(g_gui.lastXml == "/mods/tc/gui/TransportCompanyHelpDialog.xml",
   "xml path built from the manager's captured mod directory", tostring(g_gui.lastXml))

-- Regression: g_currentModDirectory is nil at click time (it is only
-- valid during mod loading). The dialog must use the directory the
-- manager captured at load, never read the global on open.
g_currentModDirectory = nil
g_transportCompanyHelpDialog = nil
local okShow, errShow = pcall(TransportCompanyHelpDialog.show)
ok(okShow, "help dialog opens without g_currentModDirectory set", errShow)
ok(g_gui.shownName == "transportCompanyHelpDialog", "still opens with nil g_currentModDirectory",
   tostring(g_gui.shownName))

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
