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
InGameMenuTransportCompanyFrame.TAB_SETTINGS = 4
InGameMenuTransportCompanyFrame.TAB_DRIVERS = 5

-- Bare l10n keys. g_i18n:getText expects the key itself — the
-- "$l10n_" prefix is only for XML attribute values.
InGameMenuTransportCompanyFrame.TAB_NAMES = {
    "transportCompany_tabDispatch",
    "transportCompany_tabFleet",
    "transportCompany_tabLedger",
    "transportCompany_tabSettings",
    "transportCompany_tabDrivers"
}

function InGameMenuTransportCompanyFrame.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or InGameMenuTransportCompanyFrame_mt)

    self.hasCustomMenuButtons = true
    self.currentTab = InGameMenuTransportCompanyFrame.TAB_DISPATCH

    -- Flattened rows for the current tab, rebuilt on every refresh.
    -- Each row is { cellName = <ListItem name>, contract = ..., ... }.
    self.rows = {}
    self.detailRows = {}
    self.isOpen = false

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
    self.changeButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("transportCompany_settingChange"),
        callback = function()
            self:onButtonChangeSetting()
        end
    }
    self.resetButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("transportCompany_settingReset"),
        callback = function()
            self:onButtonResetSetting()
        end
    }
    self.hireDriverButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("transportCompany_driverHire"),
        callback = function()
            self:onButtonHireDriver()
        end
    }
    self.assignDriverButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("transportCompany_driverAssign"),
        callback = function()
            self:onButtonAssignDriver()
        end
    }
    self.fireDriverButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("transportCompany_driverFire"),
        callback = function()
            self:onButtonFireDriver()
        end
    }
    self.upgradeHqButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("transportCompany_hqUpgrade"),
        callback = function()
            self:onButtonUpgradeHq()
        end
    }
    self.helpButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("transportCompany_help"),
        callback = function()
            self:onButtonHelp()
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
    self.rewardLabel    = self:getDescendantById("rewardLabel")
    self.rewardText     = self:getDescendantById("rewardText")
    if self.detailList ~= nil then
        self.detailList:setDataSource(self)
    end
end

function InGameMenuTransportCompanyFrame:onFrameOpen()
    InGameMenuTransportCompanyFrame:superClass().onFrameOpen(self)
    self.isOpen = true
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onFrameClose()
    InGameMenuTransportCompanyFrame:superClass().onFrameClose(self)
    self.isOpen = false
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
    -- The PDA always shows the local player's own company. In
    -- multiplayer each farm that owns an HQ has its own board, fleet
    -- and ledger, and a client must not see a rival farm's books.
    local company = manager ~= nil and manager:getLocalCompany() or nil
    self._company = company

    if manager ~= nil then
        if self.currentTab == InGameMenuTransportCompanyFrame.TAB_DISPATCH then
            self:_buildDispatchRows(manager, company)
        elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_FLEET then
            self:_buildFleetRows(manager, company)
        elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_LEDGER then
            self:_buildLedgerRows(manager, company)
        elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_SETTINGS then
            self:_buildSettingsRows(manager, company)
        elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_DRIVERS then
            self:_buildDriverRows(manager, company)
        end
    end

    self:_updateEmptyText(manager, company)

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
function InGameMenuTransportCompanyFrame:_updateEmptyText(manager, company)
    if self.emptyText == nil then return end

    local key = "transportCompany_noContracts"
    if self.currentTab == InGameMenuTransportCompanyFrame.TAB_SETTINGS then
        -- Settings never depend on owning an HQ.
        key = "transportCompany_tabSettings"
    elseif company == nil or not company:getIsActive() then
        key = "transportCompany_noHq"
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_FLEET then
        key = "transportCompany_fleetNoTrucks"
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_DRIVERS then
        key = "transportCompany_driversEmpty"
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_LEDGER then
        key = "transportCompany_noHistory"
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

    if self.currentTab == InGameMenuTransportCompanyFrame.TAB_SETTINGS then
        if self:getSelectedSetting() ~= nil then
            table.insert(buttons, self.changeButtonInfo)
            table.insert(buttons, self.resetButtonInfo)
        end
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_DRIVERS then
        -- The Drivers tab always offers Hire; if a driver is selected,
        -- also offer Assign and Fire.
        table.insert(buttons, self.hireDriverButtonInfo)
        if self:getSelectedDriver() ~= nil then
            table.insert(buttons, self.assignDriverButtonInfo)
            table.insert(buttons, self.fireDriverButtonInfo)
        end
        table.insert(buttons, self.upgradeHqButtonInfo)
    else
        local contract = self:getSelectedContract()
        if contract ~= nil then
            -- Only offer Hire when the engine would actually accept the
            -- job. A button that refuses every time reads as broken, and
            -- on maps with no AI-loadable source it would refuse always.
            local canHire = self:_getCanHire(contract)

            if contract.state == TransportCompanyContract.STATE_AVAILABLE then
                table.insert(buttons, self.acceptButtonInfo)
                if canHire then
                    table.insert(buttons, self.hireButtonInfo)
                end
            elseif contract.state == TransportCompanyContract.STATE_ACCEPTED
                   and not contract.isHiredDriver and canHire then
                -- A job you took can still be handed to a driver.
                table.insert(buttons, self.hireButtonInfo)
            end
        end
    end

    -- Help is available on every tab: a guide to how the company works,
    -- including what to do when a hired driver gets stuck.
    table.insert(buttons, self.helpButtonInfo)

    self:setMenuButtonInfo(buttons)
    self:setMenuButtonInfoDirty()
end

---Could a hired driver run this contract right now?
---@return boolean canHire, string|nil reasonKey
function InGameMenuTransportCompanyFrame:_getCanHire(contract)
    if contract == nil or contract.getIsAiHaulable == nil then
        return false, nil
    end
    return contract:getIsAiHaulable(g_currentMission:getFarmId())
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
function InGameMenuTransportCompanyFrame:_buildDispatchRows(manager, company)
    if company == nil then return end
    for _, contract in pairs(company.contracts) do
        if contract.state ~= TransportCompanyContract.STATE_COMPLETED and
           contract.state ~= TransportCompanyContract.STATE_EXPIRED then

            local stateText = ""
            if contract.state == TransportCompanyContract.STATE_AVAILABLE then
                stateText = g_i18n:getText("transportCompany_stateAvailable")
            elseif contract.state == TransportCompanyContract.STATE_ACCEPTED then
                stateText = g_i18n:getText("transportCompany_stateAccepted")
            end

            local fillType = g_fillTypeManager:getFillTypeByIndex(contract.fillTypeIndex)

            table.insert(self.rows, {
                cellName = "row",
                contract = contract,
                icon     = fillType ~= nil and fillType.hudOverlayFilename or nil,
                primary  = contract:getLocalizedFillType(),
                left     = g_i18n:formatMoney(contract.reward, 0, true, true),
                right    = stateText,
            })
        end
    end
end

---Fleet tab: one row per enrolled truck in this company.
function InGameMenuTransportCompanyFrame:_buildFleetRows(manager, company)
    if company == nil then return end
    for uniqueId, truck in pairs(company.trucks) do
        table.insert(self.rows, {
            cellName = "row",
            truck    = truck,
            primary  = truck.vehicleName or uniqueId,
            left     = g_i18n:formatMoney(truck:getProfit(), 0, true, true),
            right    = string.format("%d", truck.jobsDelivered),
        })
    end
end

---Ledger tab: a company summary entry followed by finished jobs.
---
---This list used to repeat the very same figures the detail panel was
---already showing. It now indexes the panel instead: pick the summary
---for company totals, or any past job to see how it went.
function InGameMenuTransportCompanyFrame:_buildLedgerRows(manager, company)
    if company == nil then return end
    table.insert(self.rows, {
        cellName = "row",
        summary  = true,
        primary  = g_i18n:getText("transportCompany_companySummary"),
        left     = g_i18n:formatMoney(
            company.ledger.revenue - company.ledger.driverWages, 0, true, true),
        right    = string.format("%d", company.ledger.jobs),
    })

    -- Newest first; pairs order is undefined so this has to be sorted.
    local history = {}
    for _, contract in pairs(company.contracts) do
        if contract.state == TransportCompanyContract.STATE_COMPLETED or
           contract.state == TransportCompanyContract.STATE_EXPIRED then
            table.insert(history, contract)
        end
    end
    table.sort(history, function(a, b)
        return (a.completedTime or 0) > (b.completedTime or 0)
    end)

    for _, contract in ipairs(history) do
        local done = contract.state == TransportCompanyContract.STATE_COMPLETED
        local fillType = g_fillTypeManager:getFillTypeByIndex(contract.fillTypeIndex)
        table.insert(self.rows, {
            cellName = "row",
            contract = contract,
            icon     = fillType ~= nil and fillType.hudOverlayFilename or nil,
            primary  = contract:getLocalizedFillType(),
            left     = done and g_i18n:formatMoney(contract.reward, 0, true, true) or "",
            right    = g_i18n:getText(done and "transportCompany_statusCompleted"
                                           or "transportCompany_statusExpired"),
        })
    end
end

---Settings tab: one row per setting, value on the right. Settings are
---read from this company's server-shared settings, except debugMode
---which is a global per-player setting on the manager.
function InGameMenuTransportCompanyFrame:_buildSettingsRows(manager, company)
    local settings = company ~= nil and company.settings or manager.settings
    for _, def in ipairs(TransportCompanySettings.definitions) do
        table.insert(self.rows, {
            cellName = "row",
            setting  = def,
            primary  = g_i18n:getText(TransportCompanySettings.getLabelKey(def.id)),
            left     = TransportCompanySettings.getIsEditable(def) and "" or
                       g_i18n:getText("transportCompany_settingLocal"),
            right    = settings:getDisplayValue(def.id),
        })
    end
end

---Drivers tab: one row per named driver on the payroll, plus a final
---row for the HQ upgrade so the player can read its effect.
function InGameMenuTransportCompanyFrame:_buildDriverRows(manager, company)
    if company == nil then return end

    for driverId, driver in pairs(company.drivers) do
        local truckName = ""
        if driver.assignedTruckUniqueId ~= nil and driver.assignedTruckUniqueId ~= "" then
            local truck = company.trucks[driver.assignedTruckUniqueId]
            truckName = truck ~= nil and truck.vehicleName
                or g_i18n:getText("transportCompany_fleetTruckName")
        end
        table.insert(self.rows, {
            cellName = "row",
            driver   = driver,
            primary  = driver.name or driverId,
            left     = g_i18n:formatMoney(driver:getCurrentWage(), 0, true, true),
            right    = truckName ~= "" and truckName
                or string.format("%d jobs", driver.jobsDone),
        })
    end

    -- HQ tier row: lets the player see and trigger the upgrade.
    local cost = company:getNextHqUpgradeCost()
    table.insert(self.rows, {
        cellName = "row",
        hqUpgrade = true,
        primary  = g_i18n:getText("transportCompany_hqLevel"),
        left     = g_i18n:getText("transportCompany_hqTier")
            .. " " .. tostring(company.hqLevel),
        right    = cost ~= nil and g_i18n:formatMoney(cost, 0, true, true) or "",
    })
end

---The driver under the cursor, when the Drivers tab is open.
function InGameMenuTransportCompanyFrame:getSelectedDriver()
    if self.contentList == nil then return nil end
    local row = self.rows[self.contentList.selectedIndex]
    return row ~= nil and row.driver or nil
end

function InGameMenuTransportCompanyFrame:onButtonHireDriver()
    local manager = TransportCompanyManager.getInstance()
    if manager == nil then return end
    TransportCompanyDriverEvent.sendEvent(
        TransportCompanyDriverEvent.ACTION_HIRE,
        g_currentMission:getFarmId(), nil, nil
    )
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onButtonAssignDriver()
    local driver = self:getSelectedDriver()
    if driver == nil then return end
    local manager = TransportCompanyManager.getInstance()
    if manager == nil then return end
    local company = manager:getLocalCompany()
    if company == nil then return end

    -- Cycle: unassigned -> first truck -> unassigned. Simple one-button
    -- assignment; assigning picks the first enrolled truck that has no
    -- driver yet, or clears if all are taken.
    local target = ""
    for _, truck in pairs(company.trucks) do
        if truck.uniqueId ~= driver.assignedTruckUniqueId
           and company:getDriverForTruck(truck.uniqueId) == nil then
            target = truck.uniqueId
            break
        end
    end
    TransportCompanyDriverEvent.sendEvent(
        TransportCompanyDriverEvent.ACTION_ASSIGN,
        g_currentMission:getFarmId(), driver.driverId, target
    )
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onButtonFireDriver()
    local driver = self:getSelectedDriver()
    if driver == nil then return end
    TransportCompanyDriverEvent.sendEvent(
        TransportCompanyDriverEvent.ACTION_FIRE,
        g_currentMission:getFarmId(), driver.driverId, nil
    )
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onButtonUpgradeHq()
    TransportCompanyDriverEvent.sendEvent(
        TransportCompanyDriverEvent.ACTION_UPGRADE,
        g_currentMission:getFarmId(), nil, nil
    )
    self:updateTabContent()
end

function InGameMenuTransportCompanyFrame:onButtonHelp()
    if TransportCompanyHelpDialog ~= nil and TransportCompanyHelpDialog.show ~= nil then
        TransportCompanyHelpDialog.show()
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

    if row ~= nil and row.setting ~= nil then
        hasDetail = self:_buildSettingDetail(row.setting)
    elseif row ~= nil and row.summary then
        hasDetail = self:_buildCompanyDetail()
    elseif row ~= nil and row.hqUpgrade then
        hasDetail = self:_buildHqDetail()
    elseif row ~= nil and row.driver ~= nil then
        hasDetail = self:_buildDriverDetail(row.driver)
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

    -- The scroll hint tells the player the detail rows continue below.
    -- Only show it when the list actually overflows, so a short detail
    -- panel does not advertise scrolling that is not there.
    if self.scrollHint ~= nil then
        self.scrollHint:setVisible(hasDetail and #self.detailRows > 6)
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

    -- Difficulty tier, so an urgent premium or bulk discount is visible.
    local tierKey = "transportCompany_tierStandard"
    if contract.tier == TransportCompanyContract.CONTRACT_TIER_URGENT then
        tierKey = "transportCompany_tierUrgent"
    elseif contract.tier == TransportCompanyContract.CONTRACT_TIER_BULK then
        tierKey = "transportCompany_tierBulk"
    end
    self:_addDetail("transportCompany_contractTier", g_i18n:getText(tierKey))

    -- Route economics: what a haul is really worth after the diesel.
    -- Fuel is an estimate (straight-line distance × an assumed burn
    -- rate × the live diesel price), never a charge.
    if contract.routeDistanceM ~= nil and contract.routeDistanceM > 0 then
        self:_addDetail("transportCompany_contractDistance",
            g_i18n:formatDistance(contract.routeDistanceM, 1))
        local dieselPrice = 0
        if g_currentMission ~= nil and g_currentMission.economyManager ~= nil then
            dieselPrice = g_currentMission.economyManager:getCostPerLiter(FillType.DIESEL) or 0
        end
        local fuelLiters = contract.routeDistanceM / 1000
            * TransportCompanyContract.EST_FUEL_L_PER_KM
        local estFuel = fuelLiters * dieselPrice
        self:_addDetail("transportCompany_contractEstFuel",
            g_i18n:formatMoney(estFuel, 0, true, true))
        self:_addDetail("transportCompany_contractEstProfit",
            g_i18n:formatMoney(contract.reward - estFuel, 0, true, true))
    end

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

    -- Whether a driver could take this, stated up front rather than
    -- discovered by pressing a button that refuses.
    if not contract.isHiredDriver then
        local canHire, reasonKey = self:_getCanHire(contract)
        self:_addDetail("transportCompany_hireDriver",
            canHire and g_i18n:getText("transportCompany_hireAvailable")
                    or g_i18n:getText("transportCompany_hireUnavailable"))
        if not canHire and reasonKey ~= nil then
            self:_addDetail("transportCompany_hireReason", g_i18n:getText(reasonKey))
        end
    end

    self:_setProgress(contract:getProgressRatio(), string.format(
        "%d / %d %s", math.floor(contract.delivered),
        math.floor(contract.amount), contract:getAmountUnitText()))

    self:_setReward("transportCompany_contractReward",
        g_i18n:formatMoney(contract.reward, 0, true, true))
    return true
end

---Set the big figure at the bottom of the detail panel, with a label
---so it is not just an unexplained number.
function InGameMenuTransportCompanyFrame:_setReward(labelKey, value)
    if self.rewardLabel ~= nil then
        self.rewardLabel:setText(g_i18n:getText(labelKey))
    end
    if self.rewardText ~= nil then
        self.rewardText:setText(value)
    end
end

---Ledger detail: the company as a whole. Nothing on this tab maps to
---a single contract or truck, so the panel summarises instead of
---sitting blank.
function InGameMenuTransportCompanyFrame:_buildCompanyDetail()
    local manager = TransportCompanyManager.getInstance()
    if manager == nil then return false end

    local company = self._company
    if company == nil then return false end

    local totalFuel, totalDistance, fleet = 0, 0, 0
    for _, truck in pairs(company.trucks) do
        totalFuel = totalFuel + truck.fuelCost
        totalDistance = totalDistance + truck.distanceM
        fleet = fleet + 1
    end

    local open = 0
    for _, contract in pairs(company.contracts) do
        if contract.state == TransportCompanyContract.STATE_ACCEPTED then
            open = open + 1
        end
    end

    local ledger = company.ledger
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

    -- Rolling weekly P&L: the last few periods, newest first.
    local history = company.ledgerHistory or {}
    for i = #history, 1, -1 do
        local p = history[i]
        local label = string.format("%s %d",
            g_i18n:getText("transportCompany_period"), p.index)
        local profit = (p.revenue or 0) - (p.wages or 0)
        table.insert(self.detailRows, {
            cellName = "detailItem",
            label = label,
            value = string.format("%s / %d jobs",
                g_i18n:formatMoney(profit, 0, true, true), p.jobs or 0),
        })
    end

    self:_setProgress(0, "")
    self:_setReward("transportCompany_ledgerProfit", money(profit))
    return true
end

---Detail panel for one setting: what it does, and what it accepts.
function InGameMenuTransportCompanyFrame:_buildSettingDetail(def)
    local manager = TransportCompanyManager.getInstance()
    if manager == nil then return false end

    local settings = self._company ~= nil and self._company.settings or manager.settings

    if self.detailTitle ~= nil then
        self.detailTitle:setText(
            g_i18n:getText(TransportCompanySettings.getLabelKey(def.id)))
    end
    if self.detailSubtitle ~= nil then
        self.detailSubtitle:setText(
            g_i18n:getText(TransportCompanySettings.getDescriptionKey(def.id)))
    end

    self:_addDetail("transportCompany_settingCurrent",
        settings:getDisplayValue(def.id))

    local default = def.default
    if def.type == "boolean" then
        default = g_i18n:getText(default and "transportCompany_on"
                                         or "transportCompany_off")
    end
    self:_addDetail("transportCompany_settingDefault", tostring(default))

    if def.type == "number" and def.min ~= nil and def.max ~= nil then
        self:_addDetail("transportCompany_settingRange",
            string.format("%d - %d", def.min, def.max))
    end

    self:_addDetail("transportCompany_settingScope",
        g_i18n:getText(def.localOnly and "transportCompany_settingLocal"
                                     or "transportCompany_settingShared"))

    if not TransportCompanySettings.getIsEditable(def) then
        self:_addDetail("transportCompany_contractStatus",
            g_i18n:getText("transportCompany_settingReadOnly"))
    end

    self:_setProgress(0, "")
    self:_setReward("transportCompany_settingCurrent",
        settings:getDisplayValue(def.id))
    return true
end

---The setting under the cursor, when the Settings tab is open.
function InGameMenuTransportCompanyFrame:getSelectedSetting()
    if self.contentList == nil then
        return nil
    end
    local row = self.rows[self.contentList.selectedIndex]
    return row ~= nil and row.setting or nil
end

function InGameMenuTransportCompanyFrame:onButtonChangeSetting()
    self:_applySettingChange(function(settings, def)
        return settings:cycle(def.id, 1)
    end)
end

function InGameMenuTransportCompanyFrame:onButtonResetSetting()
    self:_applySettingChange(function(settings, def)
        return settings:set(def.id, def.default)
    end)
end

---Apply a change to the highlighted setting and persist it.
---
---Server-shared values are refused on a client: editing them locally
---would leave that player quietly disagreeing with the server about
---board size, deadlines and wages.
function InGameMenuTransportCompanyFrame:_applySettingChange(fn)
    local def = self:getSelectedSetting()
    if def == nil then
        return
    end

    local manager = TransportCompanyManager.getInstance()
    if manager == nil then
        return
    end

    local settings = self._company ~= nil and self._company.settings or manager.settings

    if not TransportCompanySettings.getIsEditable(def) then
        manager:_notify(g_i18n:getText("transportCompany_settingReadOnly"))
        return
    end

    fn(settings, def)
    settings:save()

    -- Board size and deadline take effect immediately.
    if manager.isServer then
        local farmId = manager:_getCompanyFarmId()
        manager:_regenerateContractBoard(farmId)
    end

    local index = self.contentList ~= nil and self.contentList.selectedIndex or 1
    self:updateTabContent()
    if self.contentList ~= nil and #self.rows >= index then
        self.contentList:setSelectedItem(1, index, false, true)
        self:_updateDetail()
    end
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

    -- Maintenance: how far until the next service.
    if truck.nextServiceKm ~= nil then
        local remaining = math.max(0, truck.nextServiceKm - (truck.distanceM or 0))
        self:_addDetail("transportCompany_truckNextService",
            g_i18n:formatDistance(remaining, 1))
    end

    self:_setProgress(0, "")
    self:_setReward("transportCompany_fleetProfit", money(truck:getProfit()))
    return true
end

---Driver detail: who they are, what they cost, and which truck they run.
function InGameMenuTransportCompanyFrame:_buildDriverDetail(driver)
    if self.detailTitle ~= nil then
        self.detailTitle:setText(driver.name or "")
    end
    if self.detailSubtitle ~= nil then
        self.detailSubtitle:setText(g_i18n:getText("transportCompany_driverTitle"))
    end

    local money = function(v) return g_i18n:formatMoney(v, 0, true, true) end
    self:_addDetail("transportCompany_driverWage", money(driver:getCurrentWage()))
    self:_addDetail("transportCompany_driverExperience",
        string.format("%d / %d", math.floor(driver.experience),
            TransportCompanyDriver.MAX_EXPERIENCE))
    self:_addDetail("transportCompany_driverJobs", tostring(driver.jobsDone))

    local truckName = "-"
    if driver.assignedTruckUniqueId ~= nil and driver.assignedTruckUniqueId ~= "" then
        local company = self._company
        if company ~= nil and company.trucks[driver.assignedTruckUniqueId] ~= nil then
            truckName = company.trucks[driver.assignedTruckUniqueId].vehicleName or truckName
        end
    end
    self:_addDetail("transportCompany_driverAssignedTruck", truckName)

    self:_setProgress(0, "")
    self:_setReward("transportCompany_driverWage", money(driver:getCurrentWage()))
    return true
end

---HQ upgrade detail: what the current tier grants and the next tier
---would cost.
function InGameMenuTransportCompanyFrame:_buildHqDetail()
    local company = self._company
    if company == nil then return false end

    if self.detailTitle ~= nil then
        self.detailTitle:setText(g_i18n:getText("transportCompany_hqLevel"))
    end
    if self.detailSubtitle ~= nil then
        self.detailSubtitle:setText(g_i18n:getText("transportCompany_hqTier")
            .. " " .. tostring(company.hqLevel)
            .. " / " .. tostring(TransportCompanyCompany.HQ_MAX_LEVEL))
    end

    self:_addDetail("transportCompany_hqBoardSize", tostring(company:getBoardSize()))
    self:_addDetail("transportCompany_hqDriverCap", tostring(company:getDriverCap()))
    self:_addDetail("transportCompany_hqReputation",
        string.format("%d / %d", math.floor(company.reputation),
            TransportCompanyCompany.REPUTATION_MAX))
    self:_addDetail("transportCompany_hqLevel",
        g_i18n:getText("transportCompany_hqLevelNum") .. " " .. tostring(company:getLevel()))

    local cost = company:getNextHqUpgradeCost()
    self:_setProgress(0, "")
    self:_setReward("transportCompany_hqUpgradeCost",
        cost ~= nil and g_i18n:formatMoney(cost, 0, true, true)
            or g_i18n:getText("transportCompany_hqMaxLevel"))
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
    -- The icon slot is a Bitmap and takes a filename, the way
    -- SiloDialog.lua:52 sets a fill type icon. Everything else is text.
    local icon = cell:getAttribute("icon")
    if icon ~= nil then
        icon:setVisible(row.icon ~= nil)
        if row.icon ~= nil then
            icon:setImageFilename(row.icon)
        end
    end

    -- Only string fields map to cell text; cellName and the attached
    -- contract or truck reference are bookkeeping.
    for name, value in pairs(row) do
        if name ~= "icon" and type(value) == "string" then
            local element = cell:getAttribute(name)
            if element ~= nil then
                element:setText(value)
            end
        end
    end
end
