-- =========================================================
-- FS25 Transport Company - PDA Frame
-- =========================================================
-- TabbedMenuFrameElement with sub-tabs: Dispatch, Fleet,
-- Ledger. Uses base-game list patterns, zero custom drawing.
--
-- Mirrors the InGameMenuContractsFrame pattern:
-- subCategorySelector for sub-tabs, SmoothList for content,
-- base-game profiles for all visual elements.
--
-- LIST API NOTE
-- SmoothListElement has no clearItems/addItem/emptyListSetSize, and
-- ListItemElement has no setText — all four are absent from the
-- engine. A SmoothList pulls from a data source
-- (SmoothListElement.lua:323, :399-430, :630):
--
--   list:setDataSource(self)                     -- once, at setup
--   list:reloadData()                            -- to refresh
--   self:getNumberOfItemsInSection(list, section)
--   self:populateCellForItemInSection(list, section, index, cell)
--
-- and a cell exposes its named children through
-- cell:getAttribute(name) (ListItemElement.lua:167), which returns
-- the element you then call :setText() on.
-- =========================================================

InGameMenuTransportCompanyFrame = {}
local InGameMenuTransportCompanyFrame_mt = Class(InGameMenuTransportCompanyFrame, TabbedMenuFrameElement)

-- Sub-tab indices
InGameMenuTransportCompanyFrame.TAB_DISPATCH = 1
InGameMenuTransportCompanyFrame.TAB_FLEET = 2
InGameMenuTransportCompanyFrame.TAB_LEDGER = 3

-- Bare l10n keys. g_i18n:getText expects the key itself — the
-- "$l10n_" prefix is only for XML attribute values.
InGameMenuTransportCompanyFrame.TAB_NAMES = {
    "transportCompany_tabDispatch",
    "transportCompany_tabFleet",
    "transportCompany_tabLedger"
}

function InGameMenuTransportCompanyFrame.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or InGameMenuTransportCompanyFrame_mt)

    self.hasCustomMenuButtons = true
    self.currentTab = InGameMenuTransportCompanyFrame.TAB_DISPATCH

    -- Flattened rows for the current tab, rebuilt on every refresh.
    -- Each row is { cellName = <ListItem name>, contract = ..., ... }.
    self.rows = {}
    self.detailRows = {}

    return self
end

function InGameMenuTransportCompanyFrame:initialize()
    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK
    }

    self.acceptButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("transportCompany_acceptContract"),
        callback = function()
            self:onButtonAccept()
        end
    }
    self.hireButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("transportCompany_hireDriver"),
        callback = function()
            self:onButtonHire()
        end
    }

    -- Sub-category selector (Dispatch / Fleet / Ledger tabs)
    self.subCategorySelector = self:getDescendantById("subCategorySelector")
    self.subCategoryDotBox = self:getDescendantById("subCategoryDotBox")
    self.subCategoryDotTemplate = self:getDescendantById("subCategoryDotTemplate")

    if self.subCategorySelector ~= nil and self.subCategoryDotBox ~= nil and self.subCategoryDotTemplate ~= nil then
        local selectorTexts = {}
        for _, key in ipairs(InGameMenuTransportCompanyFrame.TAB_NAMES) do
            table.insert(selectorTexts, g_i18n:getText(key))
        end

        -- Clone dot indicators for each sub-tab
        for i = 1, #selectorTexts do
            local dot = self.subCategoryDotTemplate:clone(self.subCategoryDotBox)
            dot.getIsSelected = function()
                return self.subCategorySelector:getState() == i
            end
        end

        self.subCategoryDotBox:invalidateLayout()
        self.subCategorySelector:setTexts(selectorTexts)
        self.subCategorySelector:setState(self.currentTab, true)
    end

    -- Left list + the message shown when it has nothing in it
    self.contentList = self:getDescendantById("contentList")
    self.emptyText = self:getDescendantById("noContractsText")
    if self.contentList ~= nil then
        self.contentList:setDataSource(self)
    end

    -- Right-hand detail panel
    self.detailBox      = self:getDescendantById("detailBox")
    self.detailTitle    = self:getDescendantById("detailTitle")
    self.detailSubtitle = self:getDescendantById("detailSubtitle")
    self.detailList     = self:getDescendantById("detailList")
    self.progressLabel  = self:getDescendantById("progressLabel")
    self.progressBarBg  = self:getDescendantById("progressBarBg")
    self.progressBar    = self:getDescendantById("progressBar")
    self.rewardText     = self:getDescendantById("rewardText")
    if self.detailList ~= nil then
        self.detailList:setDataSource(self)
    end
end

function InGameMenuTransportCompanyFrame:onFrameOpen()
    InGameMenuTransportCompanyFrame:superClass().onFrameOpen(self)
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onFrameClose()
    InGameMenuTransportCompanyFrame:superClass().onFrameClose(self)
    self.rows = {}
    self.detailRows = {}
end

---Switch to a sub-tab.
---@param tabIndex number TAB_DISPATCH, TAB_FLEET, or TAB_LEDGER
function InGameMenuTransportCompanyFrame:setTab(tabIndex)
    self.currentTab = tabIndex
    self.resetSelection = true
    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setState(tabIndex, true)
    end
    self:updateTabContent()
end

---Handle sub-category selector change. Bound to the MultiTextOption's
---#onClick attribute, which is the callback the element actually
---registers (MultiTextOptionElement.lua:63).
function InGameMenuTransportCompanyFrame:onChangeSubCategory(state)
    self.currentTab = state or (self.subCategorySelector ~= nil and self.subCategorySelector:getState())
        or InGameMenuTransportCompanyFrame.TAB_DISPATCH
    self.resetSelection = true
    self:updateTabContent()
end

-- ── Row building ───────────────────────────────────────────

---Rebuild self.rows for the current sub-tab and refresh the list.
function InGameMenuTransportCompanyFrame:updateTabContent()
    self.rows = {}

    local manager = TransportCompanyManager.getInstance()
    if manager ~= nil then
        if self.currentTab == InGameMenuTransportCompanyFrame.TAB_DISPATCH then
            self:_buildDispatchRows(manager)
        elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_FLEET then
            self:_buildFleetRows(manager)
        elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_LEDGER then
            self:_buildLedgerRows(manager)
        end
    end

    self:_updateEmptyText(manager)

    if self.contentList ~= nil then
        self.contentList:reloadData()
        -- Each tab has a different number of rows, so an index carried
        -- over from the previous tab can point past the end. That left
        -- the detail panel and footer looking at nothing, which is why
        -- switching tabs appeared to work only sometimes.
        if self.resetSelection and #self.rows > 0 then
            self.contentList:setSelectedItem(1, 1, false, true)
        end
        self.resetSelection = false
    end
    self:_updateDetail()
    self:_updateMenuButtons()
end

---Tell the player why the list is empty.
---
---Without an HQ there is no company at all, and that is by far the
---most likely reason someone is staring at a blank page — so say so
---explicitly rather than showing the generic "no contracts" line.
function InGameMenuTransportCompanyFrame:_updateEmptyText(manager)
    if self.emptyText == nil then return end

    local key = "transportCompany_noContracts"
    if manager == nil or not manager:_hasHq() then
        key = "transportCompany_noHq"
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_FLEET then
        key = "transportCompany_fleetNoTrucks"
    end
    self.emptyText:setText(g_i18n:getText(key))
end

---The contract under the cursor, or nil when the selection is not an
---acceptable contract row.
---@return TransportCompanyContract|nil
function InGameMenuTransportCompanyFrame:getSelectedContract()
    if self.contentList == nil then return nil end
    -- SmoothListElement exposes selectedIndex as a field
    -- (SmoothListElement.lua:38); there is no getSelectedIndex().
    local row = self.rows[self.contentList.selectedIndex]
    if row == nil then return nil end
    return row.contract
end

---Show Accept / Hire only on the Dispatch tab, and only when the
---highlighted contract is still available.
---
---setMenuButtonInfo alone does nothing visible: TabbedMenu only re-reads
---a page's buttons when the page reports itself dirty
---(TabbedMenu.lua:117-119), which is why the footer stayed empty.
function InGameMenuTransportCompanyFrame:_updateMenuButtons()
    local buttons = { self.backButtonInfo }

    local contract = self:getSelectedContract()
    if contract ~= nil and contract.state == TransportCompanyContract.STATE_AVAILABLE then
        table.insert(buttons, self.acceptButtonInfo)
        table.insert(buttons, self.hireButtonInfo)
    end

    self:setMenuButtonInfo(buttons)
    self:setMenuButtonInfoDirty()
end

---Selection changed in a list.
---
---Only the left list matters here. Both lists share this frame as
---their delegate (SmoothListElement.lua:130), and reloadData ends up
---calling setSelectedItem, which fires this callback
---(SmoothListElement.lua:488, :857). So reacting to the detail list
---meant _updateDetail -> detailList:reloadData -> onListSelectionChanged
----> _updateDetail forever, and the menu died with a stack overflow in
---GuiElement/TextElement/I18N a second after opening.
---@param list table The list that raised the event
function InGameMenuTransportCompanyFrame:onListSelectionChanged(list, section, index)
    if list ~= nil and list == self.detailList then
        return
    end
    self:_updateDetail()
    self:_updateMenuButtons()
end

function InGameMenuTransportCompanyFrame:onButtonAccept()
    self:_requestAccept(TransportCompanyAcceptEvent.MODE_SELF)
end

function InGameMenuTransportCompanyFrame:onButtonHire()
    self:_requestAccept(TransportCompanyAcceptEvent.MODE_HIRE)
end

---Ask the server to take the highlighted contract. The client never
---mutates contract state itself; the board comes back via
---TransportCompanyContractEvent.
function InGameMenuTransportCompanyFrame:_requestAccept(mode)
    local contract = self:getSelectedContract()
    if contract == nil then return end

    TransportCompanyAcceptEvent.sendEvent(
        contract.contractId, mode, g_currentMission:getFarmId()
    )

    -- On a listen server the request was handled synchronously, so the
    -- board is already up to date; on a client this simply redraws the
    -- current state and the event refreshes it again on arrival.
    self:updateTabContent()
end

---Dispatch tab: open contracts.
---
---The left panel is 410px wide (fs25_subCategoryContainer), so a row
---carries only a title and two short values. Route, deadline, progress
---and assigned driver all live in the detail panel on the right.
function InGameMenuTransportCompanyFrame:_buildDispatchRows(manager)
    for _, contract in pairs(manager.contracts) do
        if contract.state ~= TransportCompanyContract.STATE_COMPLETED and
           contract.state ~= TransportCompanyContract.STATE_EXPIRED then

            local stateText = ""
            if contract.state == TransportCompanyContract.STATE_AVAILABLE then
                stateText = g_i18n:getText("transportCompany_stateAvailable")
            elseif contract.state == TransportCompanyContract.STATE_ACCEPTED then
                stateText = g_i18n:getText("transportCompany_stateAccepted")
            end

            table.insert(self.rows, {
                cellName = "row",
                contract = contract,
                primary  = contract:getLocalizedFillType(),
                left     = g_i18n:formatMoney(contract.reward, 0, true, true),
                right    = stateText,
            })
        end
    end
end

---Fleet tab: one row per enrolled truck.
function InGameMenuTransportCompanyFrame:_buildFleetRows(manager)
    for uniqueId, truck in pairs(manager.trucks) do
        table.insert(self.rows, {
            cellName = "row",
            truck    = truck,
            primary  = truck.vehicleName or uniqueId,
            left     = g_i18n:formatMoney(truck:getProfit(), 0, true, true),
            right    = string.format("%d", truck.jobsDelivered),
        })
    end
end

---Ledger tab: company totals as label/value rows.
---
---Revenue, wages and job count come from the company ledger, not from
---summing the fleet: a contract the player hauls personally cannot be
---attributed to a truck, so the per-truck books would under-report it.
---Fuel and distance are genuinely per-truck and are summed.
function InGameMenuTransportCompanyFrame:_buildLedgerRows(manager)
    local totalFuel, totalDistance = 0, 0
    for _, truck in pairs(manager.trucks) do
        totalFuel = totalFuel + truck.fuelCost
        totalDistance = totalDistance + truck.distanceM
    end

    local ledger = manager.ledger
    local money = function(v) return g_i18n:formatMoney(v, 0, true, true) end

    local entries = {
        { "transportCompany_totalRevenue",  money(ledger.revenue) },
        { "transportCompany_totalFuel",     money(totalFuel) },
        { "transportCompany_totalWages",    money(ledger.driverWages) },
        { "transportCompany_totalDistance", g_i18n:formatDistance(totalDistance, 1) },
        { "transportCompany_totalJobs",     tostring(ledger.jobs) },
        { "transportCompany_totalProfit",
          money(ledger.revenue - ledger.driverWages - totalFuel) },
    }
    for _, e in ipairs(entries) do
        table.insert(self.rows, {
            cellName = "row",
            primary  = g_i18n:getText(e[1]),
            left     = "",
            right    = e[2],
        })
    end
end

-- ── Detail panel ───────────────────────────────

---Rebuild the right-hand panel for whatever is selected on the left.
---
---This is where a job becomes actionable. Accepting used to produce a
---notification and nothing else, with no way to see where to load,
---where to deliver, or how long was left.
function InGameMenuTransportCompanyFrame:_updateDetail()
    -- Belt and braces against the recursion described on
    -- onListSelectionChanged: this must never re-enter itself, however
    -- the list callbacks are wired up.
    if self._inUpdateDetail then
        return
    end
    self._inUpdateDetail = true

    self:_rebuildDetail()

    self._inUpdateDetail = false
end

function InGameMenuTransportCompanyFrame:_rebuildDetail()
    self.detailRows = {}

    local index = self.contentList ~= nil and self.contentList.selectedIndex or 0
    local row = self.rows[index]
    local hasDetail = false

    if self.currentTab == InGameMenuTransportCompanyFrame.TAB_LEDGER then
        hasDetail = self:_buildCompanyDetail()
    elseif row ~= nil and row.contract ~= nil then
        hasDetail = self:_buildContractDetail(row.contract)
    elseif row ~= nil and row.truck ~= nil then
        hasDetail = self:_buildTruckDetail(row.truck)
    end

    if self.detailBox ~= nil then
        self.detailBox:setVisible(hasDetail)
    end
    if self.detailList ~= nil then
        self.detailList:reloadData()
    end
end

---Append one label/value line to the detail panel.
function InGameMenuTransportCompanyFrame:_addDetail(labelKey, value)
    table.insert(self.detailRows, {
        cellName = "detailItem",
        label = g_i18n:getText(labelKey),
        value = value,
    })
end

function InGameMenuTransportCompanyFrame:_buildContractDetail(contract)
    local isPallet = contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET
    local typeText = isPallet
        and g_i18n:getText("transportCompany_contractTypePallet")
        or g_i18n:getText("transportCompany_contractTypeBulk")

    if self.detailTitle ~= nil then
        self.detailTitle:setText(contract:getLocalizedFillType())
    end
    if self.detailSubtitle ~= nil then
        self.detailSubtitle:setText(typeText)
    end

    self:_addDetail("transportCompany_contractSource",
        contract.sourceName ~= "" and contract.sourceName or "-")
    self:_addDetail("transportCompany_contractDestination",
        contract.destName ~= "" and contract.destName or "-")
    self:_addDetail(
        isPallet and "transportCompany_contractPallets"
                 or "transportCompany_contractVolume",
        string.format("%d %s", math.floor(contract.amount),
                      contract:getAmountUnitText()))

    local stateKey = "transportCompany_statusAvailable"
    if contract.state == TransportCompanyContract.STATE_ACCEPTED then
        stateKey = "transportCompany_statusAccepted"
    end
    self:_addDetail("transportCompany_contractStatus", g_i18n:getText(stateKey))

    local timeLeft = contract:getTimeLeft()
    if timeLeft ~= nil then
        self:_addDetail("transportCompany_contractDeadline", string.format("%.1f d",
            math.max(0, timeLeft / TransportCompanyContract.DAY_LENGTH)))
    end

    if contract.state == TransportCompanyContract.STATE_ACCEPTED then
        self:_addDetail("transportCompany_contractTruck",
            contract.isHiredDriver
                and g_i18n:getText("transportCompany_hireDriver")
                or g_i18n:getText("transportCompany_fleetTruckName"))
    end

    self:_setProgress(contract:getProgressRatio(), string.format(
        "%d / %d %s", math.floor(contract.delivered),
        math.floor(contract.amount), contract:getAmountUnitText()))

    if self.rewardText ~= nil then
        self.rewardText:setText(g_i18n:formatMoney(contract.reward, 0, true, true))
    end
    return true
end

---Ledger detail: the company as a whole. Nothing on this tab maps to
---a single contract or truck, so the panel summarises instead of
---sitting blank.
function InGameMenuTransportCompanyFrame:_buildCompanyDetail()
    local manager = TransportCompanyManager.getInstance()
    if manager == nil then
        return false
    end

    local totalFuel, totalDistance, fleet = 0, 0, 0
    for _, truck in pairs(manager.trucks) do
        totalFuel = totalFuel + truck.fuelCost
        totalDistance = totalDistance + truck.distanceM
        fleet = fleet + 1
    end

    local open = 0
    for _, contract in pairs(manager.contracts) do
        if contract.state == TransportCompanyContract.STATE_ACCEPTED then
            open = open + 1
        end
    end

    local ledger = manager.ledger
    local money = function(v) return g_i18n:formatMoney(v, 0, true, true) end
    local profit = ledger.revenue - ledger.driverWages - totalFuel

    if self.detailTitle ~= nil then
        self.detailTitle:setText(g_i18n:getText("transportCompany_ledgerTitle"))
    end
    if self.detailSubtitle ~= nil then
        self.detailSubtitle:setText(g_i18n:getText("ui_transportCompanyPage"))
    end

    self:_addDetail("transportCompany_totalRevenue",  money(ledger.revenue))
    self:_addDetail("transportCompany_totalFuel",     money(totalFuel))
    self:_addDetail("transportCompany_totalWages",    money(ledger.driverWages))
    self:_addDetail("transportCompany_totalDistance",
        g_i18n:formatDistance(totalDistance, 1))
    self:_addDetail("transportCompany_ledgerTrucks",  tostring(fleet))
    self:_addDetail("transportCompany_ledgerActiveJobs", tostring(open))
    self:_addDetail("transportCompany_totalJobs",     tostring(ledger.jobs))

    self:_setProgress(0, "")
    if self.rewardText ~= nil then
        self.rewardText:setText(money(profit))
    end
    return true
end

function InGameMenuTransportCompanyFrame:_buildTruckDetail(truck)
    if self.detailTitle ~= nil then
        self.detailTitle:setText(truck.vehicleName or "")
    end
    if self.detailSubtitle ~= nil then
        self.detailSubtitle:setText(g_i18n:getText("transportCompany_fleetTruckName"))
    end

    local money = function(v) return g_i18n:formatMoney(v, 0, true, true) end
    self:_addDetail("transportCompany_fleetRevenue",  money(truck.revenue))
    self:_addDetail("transportCompany_fleetFuelCost", money(truck.fuelCost))
    self:_addDetail("transportCompany_totalWages",    money(truck.otherCost or 0))
    self:_addDetail("transportCompany_fleetDistance",
        g_i18n:formatDistance(truck.distanceM, 1))
    self:_addDetail("transportCompany_fleetJobs", tostring(truck.jobsDelivered))

    self:_setProgress(0, "")
    if self.rewardText ~= nil then
        self.rewardText:setText(money(truck:getProfit()))
    end
    return true
end

---Drive the progress bar, mirroring InGameMenuContractsFrame.lua:239-241:
---the bar is sized against the background inner width and clamped so a
---tiny value still renders its rounded end caps.
function InGameMenuTransportCompanyFrame:_setProgress(ratio, text)
    if self.progressLabel ~= nil then
        self.progressLabel:setText(text or "")
    end
    if self.progressBarBg == nil or self.progressBar == nil then
        return
    end

    local hasBar = (text or "") ~= ""
    self.progressBarBg:setVisible(hasBar)
    if not hasBar then
        return
    end

    local fullWidth = self.progressBarBg.size[1] - self.progressBar.margin[1] * 2
    local value = math.max(ratio or 0, self.progressBar.startSize[1] * 2 / fullWidth)
    self.progressBar:setSize(fullWidth * math.min(value, 1), nil)
end

-- ── SmoothList data source ─────────────────────────────────

function InGameMenuTransportCompanyFrame:getNumberOfItemsInSection(list, section)
    if list == self.detailList then
        return #self.detailRows
    end
    return #self.rows
end

---Cell layout for a row.
---
---This must ALWAYS name a ListItem that exists in the XML, even when
---the list is empty. buildSectionInfo calls getWidthOfItemFast(1, 1)
---before it ever asks how many items there are
---(SmoothListElement.lua:400), and that resolves the cell type and
---immediately dereferences cellDatabase[name].size
---(SmoothListElement.lua:536). Returning nil for a missing row indexed
---the database with nil and threw "attempt to index nil with 'size'",
---which aborted PDA page registration entirely — the tab never
---appeared in game.
function InGameMenuTransportCompanyFrame:getCellTypeForItemInSection(list, section, index)
    if list == self.detailList then
        return "detailItem"
    end
    return "row"
end

function InGameMenuTransportCompanyFrame:populateCellForItemInSection(list, section, index, cell)
    local row = (list == self.detailList) and self.detailRows[index] or self.rows[index]
    if row == nil then
        return
    end
    -- Only string fields map to cell text; cellName and the attached
    -- contract reference are bookkeeping.
    for name, value in pairs(row) do
        if type(value) == "string" then
            local element = cell:getAttribute(name)
            if element ~= nil then
                element:setText(value)
            end
        end
    end
end
