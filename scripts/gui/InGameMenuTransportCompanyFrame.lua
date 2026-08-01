-- =========================================================
-- FS25 Transport Company - PDA Frame
-- =========================================================
-- TabbedMenuFrameElement with sub-tabs: Dispatch, Fleet,
-- Ledger. Uses base-game list patterns, zero custom drawing.
--
-- Mirrors the InGameMenuContractsFrame pattern:
-- subCategorySelector for sub-tabs, SmoothList for content,
-- base-game profiles for all visual elements.
-- =========================================================

InGameMenuTransportCompanyFrame = {}
local InGameMenuTransportCompanyFrame_mt = Class(InGameMenuTransportCompanyFrame, TabbedMenuFrameElement)

-- Sub-tab indices
InGameMenuTransportCompanyFrame.TAB_DISPATCH = 1
InGameMenuTransportCompanyFrame.TAB_FLEET = 2
InGameMenuTransportCompanyFrame.TAB_LEDGER = 3

InGameMenuTransportCompanyFrame.TAB_NAMES = {
    "$l10n_transportCompany_tabDispatch",
    "$l10n_transportCompany_tabFleet",
    "$l10n_transportCompany_tabLedger"
}

function InGameMenuTransportCompanyFrame.register()
    local frame = InGameMenuTransportCompanyFrame.new()
    g_gui:loadGui(
        g_currentMission.modDirectory .. "gui/InGameMenuTransportCompanyFrame.xml",
        "InGameMenuTransportCompanyFrame",
        frame,
        true
    )
end

function InGameMenuTransportCompanyFrame.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or InGameMenuTransportCompanyFrame_mt)

    self.hasCustomMenuButtons = false
    self.currentTab = InGameMenuTransportCompanyFrame.TAB_DISPATCH
    self.contractList = {}
    self.truckList = {}

    return self
end

function InGameMenuTransportCompanyFrame:initialize()
    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK
    }

    -- Sub-category selector (Dispatch / Fleet / Ledger tabs)
    self.subCategorySelector = self:getGuiElement("subCategorySelector")
    self.subCategoryDotBox = self:getGuiElement("subCategoryDotBox")
    self.subCategoryDotTemplate = self:getGuiElement("subCategoryDotTemplate")

    if self.subCategorySelector ~= nil and self.subCategoryDotBox ~= nil and self.subCategoryDotTemplate ~= nil then
        local selectorTexts = {}
        for _, name in ipairs(InGameMenuTransportCompanyFrame.TAB_NAMES) do
            table.insert(selectorTexts, g_i18n:getText(name))
        end

        -- Clone dot indicators for each sub-tab
        for i = 1, #selectorTexts do
            self.subCategoryDotTemplate:clone(self.subCategoryDotBox).getIsSelected = function()
                return self.subCategorySelector:getState() == i
            end
        end

        self.subCategoryDotBox:invalidateLayout()
        self.subCategorySelector:setTexts(selectorTexts)
        self.subCategorySelector:setState(self.currentTab, true)
    end

    -- Content list
    self.contentList = self:getGuiElement("contentList")

    -- Update the visible tab content
    self:updateTabContent()
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

---Update the content list based on the current sub-tab.
function InGameMenuTransportCompanyFrame:updateTabContent()
    if self.contentList == nil then return end

    -- Clear existing entries
    self.contentList:clearItems()

    local manager = TransportCompanyManager.getInstance()
    if manager == nil then return end

    if self.currentTab == InGameMenuTransportCompanyFrame.TAB_DISPATCH then
        self:_updateDispatchTab(manager)
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_FLEET then
        self:_updateFleetTab(manager)
    elseif self.currentTab == InGameMenuTransportCompanyFrame.TAB_LEDGER then
        self:_updateLedgerTab(manager)
    end
end

---Dispatch tab: list active contracts with status.
function InGameMenuTransportCompanyFrame:_updateDispatchTab(manager)
    local contracts = manager.contracts
    if contracts == nil or next(contracts) == nil then
        self.contentList:emptyListSetSize(1)
        return
    end

    local count = 0
    for contractId, contract in pairs(contracts) do
        if contract.state ~= TransportCompanyContract.STATE_COMPLETED and
           contract.state ~= TransportCompanyContract.STATE_EXPIRED then
            count = count + 1

            local item = self.contentList:addItem()
            if item ~= nil then
                -- Contract type label
                local typeText = contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET
                    and g_i18n:getText("transportCompany_pallet")
                    or g_i18n:getText("transportCompany_bulk")

                -- State label
                local stateText = ""
                if contract.state == TransportCompanyContract.STATE_AVAILABLE then
                    stateText = g_i18n:getText("transportCompany_stateAvailable")
                elseif contract.state == TransportCompanyContract.STATE_ACCEPTED then
                    stateText = g_i18n:getText("transportCompany_stateAccepted")
                end

                -- Progress
                local progressText = string.format(
                    "%d / %d", math.floor(contract.delivered), math.floor(contract.amount)
                )

                -- Reward
                local rewardText = string.format("$%d", contract.reward)

                -- Set item text fields (matching XML element names)
                item:setText("type", typeText)
                item:setText("state", stateText)
                item:setText("progress", progressText)
                item:setText("reward", rewardText)
            end
        end
    end

    if count == 0 then
        self.contentList:emptyListSetSize(1)
    end
end

---Fleet tab: list enrolled trucks with stats.
function InGameMenuTransportCompanyFrame:_updateFleetTab(manager)
    local trucks = manager.truckRegistry.trucks
    if trucks == nil or next(trucks) == nil then
        self.contentList:emptyListSetSize(1)
        return
    end

    local count = 0
    for uniqueId, truck in pairs(trucks) do
        count = count + 1

        local item = self.contentList:addItem()
        if item ~= nil then
            item:setText("name", truck.vehicleName or uniqueId)
            item:setText("revenue", string.format("$%d", truck.revenue))
            item:setText("fuel", string.format("$%d", truck.fuelCost))
            item:setText("distance", string.format("%.1f km", truck.distanceM / 1000))
            item:setText("jobs", tostring(truck.jobsDelivered))
            item:setText("profit", string.format("$%d", truck:getProfit()))
        end
    end

    if count == 0 then
        self.contentList:emptyListSetSize(1)
    end
end

---Ledger tab: summary of company finances.
function InGameMenuTransportCompanyFrame:_updateLedgerTab(manager)
    local trucks = manager.truckRegistry.trucks
    local totalRevenue = 0
    local totalFuel = 0
    local totalDistance = 0
    local totalJobs = 0

    for _, truck in pairs(trucks) do
        totalRevenue = totalRevenue + truck.revenue
        totalFuel = totalFuel + truck.fuelCost
        totalDistance = totalDistance + truck.distanceM
        totalJobs = totalJobs + truck.jobsDelivered
    end

    local totalProfit = totalRevenue - totalFuel

    -- Show summary as a single item
    local item = self.contentList:addItem()
    if item ~= nil then
        item:setText("label", g_i18n:getText("transportCompany_totalRevenue"))
        item:setText("value", string.format("$%d", totalRevenue))
    end

    item = self.contentList:addItem()
    if item ~= nil then
        item:setText("label", g_i18n:getText("transportCompany_totalFuel"))
        item:setText("value", string.format("$%d", totalFuel))
    end

    item = self.contentList:addItem()
    if item ~= nil then
        item:setText("label", g_i18n:getText("transportCompany_totalDistance"))
        item:setText("value", string.format("%.1f km", totalDistance / 1000))
    end

    item = self.contentList:addItem()
    if item ~= nil then
        item:setText("label", g_i18n:getText("transportCompany_totalJobs"))
        item:setText("value", tostring(totalJobs))
    end

    item = self.contentList:addItem()
    if item ~= nil then
        item:setText("label", g_i18n:getText("transportCompany_totalProfit"))
        item:setText("value", string.format("$%d", totalProfit))
    end
end

---Handle sub-category selector change.
function InGameMenuTransportCompanyFrame:onChangeSubCategory()
    if self.subCategorySelector ~= nil then
        self:setTab(self.subCategorySelector:getState())
    end
end
