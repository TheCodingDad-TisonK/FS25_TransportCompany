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

    -- Content list + the message shown when it has nothing in it
    self.contentList = self:getDescendantById("contentList")
    self.emptyText = self:getDescendantById("noContractsText")
    if self.contentList ~= nil then
        self.contentList:setDataSource(self)
    end
end

function InGameMenuTransportCompanyFrame:onFrameOpen()
    InGameMenuTransportCompanyFrame:superClass().onFrameOpen(self)
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onFrameClose()
    InGameMenuTransportCompanyFrame:superClass().onFrameClose(self)
    self.rows = {}
end

---Switch to a sub-tab.
---@param tabIndex number TAB_DISPATCH, TAB_FLEET, or TAB_LEDGER
function InGameMenuTransportCompanyFrame:setTab(tabIndex)
    self.currentTab = tabIndex
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
    end
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

---Selection changed in the list — the buttons may need to appear or
---disappear. Bound from the SmoothList's #onClick.
function InGameMenuTransportCompanyFrame:onListSelectionChanged()
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

---Dispatch tab: open contracts with their status.
function InGameMenuTransportCompanyFrame:_buildDispatchRows(manager)
    for _, contract in pairs(manager.contracts) do
        if contract.state ~= TransportCompanyContract.STATE_COMPLETED and
           contract.state ~= TransportCompanyContract.STATE_EXPIRED then

            local typeText = contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET
                and g_i18n:getText("transportCompany_pallet")
                or g_i18n:getText("transportCompany_bulk")

            local stateText = ""
            if contract.state == TransportCompanyContract.STATE_AVAILABLE then
                stateText = g_i18n:getText("transportCompany_stateAvailable")
            elseif contract.state == TransportCompanyContract.STATE_ACCEPTED then
                stateText = g_i18n:getText("transportCompany_stateAccepted")
            end

            -- A transport job is meaningless without its route, so the
            -- pickup -> dropoff pair is on the row itself rather than
            -- hidden behind a detail panel.
            local route = string.format("%s  >  %s",
                contract.sourceName ~= "" and contract.sourceName or "?",
                contract.destName ~= "" and contract.destName or "?")

            local timeLeft = contract:getTimeLeft()
            if contract.state == TransportCompanyContract.STATE_ACCEPTED and timeLeft ~= nil then
                local days = timeLeft / TransportCompanyContract.DAY_LENGTH
                stateText = string.format("%s  (%.1fd)", stateText, math.max(0, days))
            end

            table.insert(self.rows, {
                cellName = "contractItem",
                contract = contract,
                type = string.format("%s  -  %s", typeText, contract:getLocalizedFillType()),
                route = route,
                state = stateText,
                progress = string.format(
                    "%d / %d %s",
                    math.floor(contract.delivered), math.floor(contract.amount),
                    contract:getAmountUnitText()
                ),
                reward = g_i18n:formatMoney(contract.reward, 0, true, true),
            })
        end
    end
end

---Fleet tab: one row per enrolled truck.
function InGameMenuTransportCompanyFrame:_buildFleetRows(manager)
    for uniqueId, truck in pairs(manager.trucks) do
        table.insert(self.rows, {
            cellName = "fleetItem",
            name = truck.vehicleName or uniqueId,
            revenue = g_i18n:formatMoney(truck.revenue, 0, true, true),
            fuel = g_i18n:formatMoney(truck.fuelCost, 0, true, true),
            distance = g_i18n:formatDistance(truck.distanceM, 1),
            jobs = tostring(truck.jobsDelivered),
            profit = g_i18n:formatMoney(truck:getProfit(), 0, true, true),
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
    local profit = ledger.revenue - ledger.driverWages - totalFuel

    local function addRow(labelKey, value)
        table.insert(self.rows, {
            cellName = "ledgerItem",
            label = g_i18n:getText(labelKey),
            value = value,
        })
    end

    addRow("transportCompany_totalRevenue", g_i18n:formatMoney(ledger.revenue, 0, true, true))
    addRow("transportCompany_totalFuel", g_i18n:formatMoney(totalFuel, 0, true, true))
    addRow("transportCompany_totalWages", g_i18n:formatMoney(ledger.driverWages, 0, true, true))
    addRow("transportCompany_totalDistance", g_i18n:formatDistance(totalDistance, 1))
    addRow("transportCompany_totalJobs", tostring(ledger.jobs))
    addRow("transportCompany_totalProfit", g_i18n:formatMoney(profit, 0, true, true))
end

-- ── SmoothList data source ─────────────────────────────────

function InGameMenuTransportCompanyFrame:getNumberOfItemsInSection(list, section)
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
    local row = self.rows[index]
    if row ~= nil and row.cellName ~= nil then
        return row.cellName
    end
    return self:_defaultCellName()
end

---The cell layout the current tab uses, for probes against an empty list.
function InGameMenuTransportCompanyFrame:_defaultCellName()
    if self.currentTab == InGameMenuTransportCompanyFrame.TAB_FLEET then
        return "fleetItem"
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_LEDGER then
        return "ledgerItem"
    end
    return "contractItem"
end

function InGameMenuTransportCompanyFrame:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
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
