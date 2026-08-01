-- =========================================================
-- FS25 Transport Company - Manager
-- =========================================================
-- Singleton that orchestrates the entire mod:
--   * Settings load/save
--   * Contract board generation & lifecycle
--   * Truck enrollment & per-truck bookkeeping
--   * Hired-driver AI job dispatch & completion
--   * PDA page registration (on Mission00.loadMission00Finished)
--   * MP event routing (ContractEvent, MoneyEvent)
--   * Intro hints registration (base Settings → Gameplay → Hints)
--
-- Pattern mirrors the user's proven mods (SoilFertilizer,
-- MarketDynamics, NPCFavor): instance created at load time,
-- mission hooks appended via Utils.appendedFunction,
-- settings persisted per savegame.
-- =========================================================

TransportCompanyManager = {}
local TransportCompanyManager_mt = Class(TransportCompanyManager)

TransportCompanyManager.INSTANCE = nil
TransportCompanyManager.MOD_NAME = "FS25_TransportCompany"
TransportCompanyManager.MOD_DIRECTORY = nil

-- ── Singleton ─────────────────────────────────

---@return TransportCompanyManager
function TransportCompanyManager.getInstance()
    return TransportCompanyManager.INSTANCE
end

---@param modDirectory string Path to mod directory
---@param modName string Name of the mod
---@return TransportCompanyManager
function TransportCompanyManager.new(modDirectory, modName)
    local self = setmetatable({}, TransportCompanyManager_mt)

    TransportCompanyManager.INSTANCE = self
    TransportCompanyManager.MOD_DIRECTORY = modDirectory
    TransportCompanyManager.MOD_NAME = modName or TransportCompanyManager.MOD_NAME

    self.modDirectory = modDirectory or TransportCompanyManager.MOD_DIRECTORY
    self.modName = TransportCompanyManager.MOD_NAME

    -- Sub-systems
    self.settings = TransportCompanySettings.new()
    self.trucks = {}          -- uniqueId → TransportCompanyTruck
    self.contracts = {}       -- contractId → TransportCompanyContract
    self.hqPlaceables = {}    -- placeableUniqueId → placeable ref

    -- Runtime state
    self.isMissionLoaded = false
    self.isServer = false
    self.tickTimer = 0
    self.deadlineCheckTimer = 0

    -- Message center subscriptions (stored for cleanup)
    self._messageSubscriptions = {}

    return self
end

-- ── Initialization ──────────────────────────────

---Called once at mod load (bootstrap). Registers mission
---hooks and console commands. Does NOT load settings yet
---(savegame directory not available until mission loads).
function TransportCompanyManager:load()
    TransportCompanyLog.info("TransportCompanyManager: load()")

    -- Mission lifecycle hooks (closures capture self)
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            self:_onMissionLoaded()
        end
    )

    Mission00.onMissionStarted = Utils.appendedFunction(
        Mission00.onMissionStarted,
        function()
            self:_onMissionStarted()
        end
    )

    Mission00.onMissionFinished = Utils.appendedFunction(
        Mission00.onMissionFinished,
        function()
            self:_onMissionFinished()
        end
    )

    Mission00.deleteMission = Utils.appendedFunction(
        Mission00.deleteMission,
        function()
            self:_onDeleteMission()
        end
    )

    -- Save hook: persist contracts when the game saves
    if FSCareerMissionInfo and FSCareerMissionInfo.saveToXMLFile then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
            FSCareerMissionInfo.saveToXMLFile,
            function()
                self:_saveContracts()
            end
        )
    end

    -- Console commands (debug/test behind debugMode gate)
    self:_registerConsoleCommands()

    TransportCompanyLog.info("TransportCompanyManager: load() complete")
end

---Called at Mission00.loadMission00Finished. Settings are
---loaded here (savegameDirectory is now available). PDA page
---is registered, contracts are restored from savegame, and
---intro hints are registered.
function TransportCompanyManager:_onMissionLoaded()
    TransportCompanyLog.info("TransportCompanyManager: _onMissionLoaded()")

    self.isMissionLoaded = true
    self.isServer = g_server ~= nil

    -- Load settings (shared + local)
    self.settings:load()

    -- Restore contracts from savegame (if any)
    self:_loadContracts()

    -- Register PDA page (client only — g_gui is client-side)
    if g_gui ~= nil then
        self:_registerPdaPage()
    end

    -- Register intro hints (appear in base Settings → Gameplay → Hints)
    self:_registerHints()

    -- Notify HQ specs that manager is ready (idempotent)
    if g_transportCompanyManager ~= nil and TransportCompanyHq ~= nil then
        for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
            if placeable ~= nil and SpecializationUtil.hasSpecialization(
                TransportCompanyHq, placeable.specializations
            ) then
                self:onHqChanged(placeable)
            end
        end
    end

    TransportCompanyLog.info(
        "TransportCompanyManager: _onMissionLoaded() complete"
    )
end

---Called at Mission00.onMissionStarted (player is in the
---world, fields are populated). Starts truck sampling and
---registers the AI job completion listener.
function TransportCompanyManager:_onMissionStarted()
    TransportCompanyLog.info("TransportCompanyManager: _onMissionStarted()")

    if not self.settings.enabled then
        return
    end

    -- Start truck sampling (server only — clients don't run AI jobs)
    if self.isServer then
        self:_startTruckSampling()
    end

    -- Subscribe to AI job completion (hired-driver delivery)
    local subscription = g_messageCenter:subscribe(
        MessageType.AI_JOB_STOPPED,
        TransportCompanyManager._onAIServerJobStopped,
        self
    )
    table.insert(self._messageSubscriptions, subscription)

    TransportCompanyLog.info("TransportCompanyManager: _onMissionStarted() complete")
end

---Called at Mission00.onMissionFinished. Unsubscribes from
---message center and stops truck sampling.
function TransportCompanyManager:_onMissionFinished()
    TransportCompanyLog.info("TransportCompanyManager: _onMissionFinished()")

    -- Unsubscribe from message center
    for _, sub in ipairs(self._messageSubscriptions) do
        g_messageCenter:unsubscribe(sub)
    end
    self._messageSubscriptions = {}

    self.isMissionLoaded = false
end

---Called at Mission00.deleteMission. Full cleanup.
function TransportCompanyManager:_onDeleteMission()
    TransportCompanyLog.info("TransportCompanyManager: _onDeleteMission()")

    self:_onMissionFinished()

    self.contracts = {}
    self.hqPlaceables = {}
    self.trucks = {}
    self.isMissionLoaded = false
end

-- ── Settings ────────────────────────────────────

---Reload settings from disk (called from console command).
function TransportCompanyManager:reloadSettings()
    self.settings:load()
    TransportCompanyLog.info("TransportCompanyManager: settings reloaded")
end

-- ── PDA Page Registration ──────────────────────

---Register our PDA sub-tab on the in-game menu. Uses the
---proven MarketDynamics pattern (pagingElement addElement +
---exposeControlsAsFields + registerPage + addPageTab, all
---pcall-guarded). The tab is hidden when the player has no HQ.
function TransportCompanyManager:_registerPdaPage()
    local success, errorMsg = pcall(function()
        if g_gui == nil then return end

        -- Load the frame XML
        local frameName = "InGameMenuTransportCompanyFrame"
        local xmlPath = self.modDirectory .. "gui/" .. frameName .. ".xml"

        g_gui:loadGui(xmlPath, frameName, nil, true)

        local screen = _G[frameName]
        if screen == nil then
            TransportCompanyLog.error("Failed to load PDA frame: %s", frameName)
            return
        end

        -- Get the InGameMenu instance (MarketDynamics pattern)
        local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
        if inGameMenu == nil then
            TransportCompanyLog.error("InGameMenu instance not found")
            return
        end

        -- Expose controls as fields so the paging system can find them
        screen:exposeControlsAsFields()

        -- Add to the paging element
        if inGameMenu.pagingElement ~= nil then
            inGameMenu.pagingElement:addElement(screen)
        end

        -- Update paging layout
        if type(inGameMenu.pagingElement.updateAbsolutePosition) == "function" then
            pcall(inGameMenu.pagingElement.updateAbsolutePosition, inGameMenu.pagingElement)
        end
        if type(inGameMenu.pagingElement.updatePageMapping) == "function" then
            pcall(inGameMenu.pagingElement.updatePageMapping, inGameMenu.pagingElement)
        end

        -- Register as a page with an enabling predicate (hidden when no HQ)
        local enablePredicate = function()
            return self:_hasHq()
        end

        if type(inGameMenu.registerPage) == "function" then
            pcall(inGameMenu.registerPage, inGameMenu, screen, nil, enablePredicate)
        end

        -- Add the tab button (icon from mod textures)
        local iconFile = self.modDirectory .. "textures/tab_transportCompany.png"
        local uvs = {0, 0, 1, 1}
        if type(inGameMenu.addPageTab) == "function" and GuiUtils ~= nil then
            pcall(inGameMenu.addPageTab, inGameMenu, screen, iconFile, GuiUtils.getUVs(uvs))
        end

        TransportCompanyLog.info("PDA page '%s' registered", frameName)
    end)

    if not success then
        TransportCompanyLog.error("PDA page registration failed: %s", tostring(errorMsg))
    end
end

---Check whether the local player owns at least one HQ.
---@return boolean
function TransportCompanyManager:_hasHq()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return false
    end
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable ~= nil and SpecializationUtil.hasSpecialization(
            TransportCompanyHq, placeable.specializations
        ) then
            return true
        end
    end
    return false
end

-- ── Hooks ──────────────────────────────────────

---Called by TransportCompanyHq spec onPlaceableFinalizePlacement /
---onPostFinalizePlacement / onSell / onDelete. Regenerates the
---contract board when HQ presence changes.
---@param placeable table The HQ placeable
function TransportCompanyManager:onHqChanged(placeable)
    if placeable == nil then return end

    local uniqueId = placeable:getUniqueId()
    local hasSpec = SpecializationUtil.hasSpecialization(
        TransportCompanyHq, placeable.specializations
    )

    if hasSpec and uniqueId ~= nil and uniqueId ~= "" then
        self.hqPlaceables[uniqueId] = placeable
        TransportCompanyLog.info("HQ placed: %s", uniqueId)
    else
        self.hqPlaceables[uniqueId] = nil
        TransportCompanyLog.info("HQ removed: %s", uniqueId)
    end

    -- Regenerate contract board to match HQ availability
    self:_regenerateContractBoard()
end

-- ── Contract Board ─────────────────────────────

---Generate contracts up to maxActiveContracts, respecting HQ
---presence. Called on HQ change and on a timer.
function TransportCompanyManager:_regenerateContractBoard()
    if not self.isServer then return end
    if not self:_hasHq() then return end

    local maxActive = self.settings.maxActiveContracts or 5
    local activeCount = 0

    for _, contract in pairs(self.contracts) do
        if contract.state == TransportCompanyContract.STATE_AVAILABLE or
           contract.state == TransportCompanyContract.STATE_ACCEPTED then
            activeCount = activeCount + 1
        end
    end

    while activeCount < maxActive do
        local contract = TransportCompanyContract.generate()
        if contract == nil then break end
        self.contracts[contract.contractId] = contract
        activeCount = activeCount + 1

        -- Broadcast the new contract to all clients
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_ADD, contract
        )
    end
end

---Apply the contractDeadlineDays setting to all available contracts
---that don't yet have a deadline (first-time generation).
function TransportCompanyManager:_applyDeadlineSettings()
    local deadlineDays = self.settings.contractDeadlineDays or 7
    local now = g_currentMission.time

    for _, contract in pairs(self.contracts) do
        if contract.state == TransportCompanyContract.STATE_AVAILABLE and
           contract.deadline == 0 then
            contract.deadline = now + (TransportCompanyContract.DAY_LENGTH * deadlineDays)
        end
    end
end

-- ── Contract Persistence ──────────────────────

---Save contracts to a dedicated XML file in the savegame
---directory. Called on mission finish / save.
function TransportCompanyManager:_saveContracts()
    if not self.isMissionLoaded then return end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil or savegameDir == "" then return end

    local filePath = savegameDir .. "/transportCompany_contracts.xml"
    local xmlFile = createXMLFile("transportCompanyContracts", filePath)

    if xmlFile == 0 then return end

    local idx = 0
    for contractId, contract in pairs(self.contracts) do
        local key = string.format("contracts.contract(%d)", idx)
        contract:saveToXMLFile(xmlFile, key)
        idx = idx + 1
    end

    saveXMLFile(xmlFile)
    deleteXMLFile(xmlFile)
end

---Load contracts from the savegame XML file.
function TransportCompanyManager:_loadContracts()
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil or savegameDir == "" then return end

    local filePath = savegameDir .. "/transportCompany_contracts.xml"
    if not fileExists(filePath) then return end

    local xmlFile = loadXMLFile("transportCompanyContracts", filePath)
    if xmlFile == 0 then return end

    local idx = 0
    while true do
        local key = string.format("contracts.contract(%d)", idx)
        local id = getXMLString(xmlFile, key .. "#contractId")
        if id == nil or id == "" then break end

        local contract = TransportCompanyContract.new()
        contract:loadFromXMLFile(xmlFile, key)

        -- Resolve station references (string uniqueId → station object)
        contract:_resolveStationRefs()

        self.contracts[contract.contractId] = contract
        idx = idx + 1
    end

    deleteXMLFile(xmlFile)

    TransportCompanyLog.info("Loaded %d contracts from savegame", idx)
end

-- ── Truck Sampling ──────────────────────────────

---Start the per-frame truck sampling timer (server only).
function TransportCompanyManager:_startTruckSampling()
    self.tickTimer = 0
end

---Sample fuel and distance for all enrolled trucks.
function TransportCompanyManager:_sampleTrucks(dt)
    for uniqueId, truck in pairs(self.trucks) do
        local vehicle = truck:getVehicle()
        if vehicle ~= nil and not vehicle:getIsBeingDeleted() then
            truck:sampleFuel(vehicle, dt)
            truck:sampleDistance(vehicle)
        end
    end
end

---Check contract deadlines and expire overdue contracts.
function TransportCompanyManager:_checkDeadlines()
    local now = g_currentMission.time

    for contractId, contract in pairs(self.contracts) do
        if contract.state == TransportCompanyContract.STATE_ACCEPTED and
           contract:getIsExpired(now) then
            contract:expire()
            TransportCompanyContractEvent.sendEvent(
                TransportCompanyContractEvent.TYPE_STATE_CHANGE, contract,
                TransportCompanyContract.STATE_EXPIRED
            )
        end
    end
end

-- ── AI Job Completion (Hired Driver) ────────────

---Called when an AI job stops. If the job was a hired-driver
---delivery for one of our contracts, mark the contract as
---completed and pay out.
---@param job table The AI job that stopped
---@param aiMessage table The stop message (AIMessageSuccessFinishedJob on success)
function TransportCompanyManager:_onAIServerJobStopped(job, aiMessage)
    if job == nil or aiMessage == nil then return end

    -- Check if this is a successful delivery job
    if not aiMessage.isa or not aiMessage:isa(AIMessageSuccessFinishedJob) then
        return
    end

    -- Find the contract that matches this job
    for _, contract in pairs(self.contracts) do
        if contract.isHiredDriver and contract.hiredDriverJobId == job.jobId then
            self:_completeHiredDriverContract(contract, job)
            break
        end
    end
end

---Complete a hired-driver contract: calculate reward, pay
---the company, pay the driver their share, and broadcast
---the result.
---@param contract TransportCompanyContract
---@param job table The completed AI job
function TransportCompanyManager:_completeHiredDriverContract(contract, job)
    if contract.state == TransportCompanyContract.STATE_COMPLETED then return end

    -- Mark completed
    contract:complete()

    -- Calculate the driver's share (hiredDriverRewardShare % of reward)
    local rewardShare = self.settings.hiredDriverRewardShare or 20
    local driverCut = math.floor(contract.reward * rewardShare / 100)
    local companyRevenue = contract.reward - driverCut

    -- Pay company (add to company bank)
    local ok, err = pcall(function()
        g_currentMission:addMoney(
            companyRevenue, 0, MoneyType.OTHER, true, true
        )
    end)
    if not ok then
        TransportCompanyLog.error("Failed to add company revenue: %s", tostring(err))
    end

    -- Pay driver (add to driver's farm if we can determine it)
    -- The hired driver runs on the farm that owns the truck.
    -- We stored the truck's farmId when the contract was accepted.
    if contract.acceptedTruckUniqueId and contract.acceptedTruckUniqueId ~= 0 then
        local truck = self.trucks[contract.acceptedTruckUniqueId]
        if truck and truck.farmId and truck.farmId > 0 then
            local ok2, err2 = pcall(function()
                g_currentMission:addMoney(driverCut, truck.farmId, MoneyType.AI, true, true)
            end)
            if not ok2 then
                TransportCompanyLog.error("Failed to add driver cut: %s", tostring(err2))
            end
        end
    end

    -- Broadcast completion to all clients
    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_STATE_CHANGE, contract,
        TransportCompanyContract.STATE_COMPLETED
    )

    TransportCompanyLog.info(
        "Hired-driver contract %s completed: reward=%d, driverCut=%d, company=%d",
        contract.contractId, contract.reward, driverCut, companyRevenue
    )
end

-- ── Money Event Handling ──────────────────────

---Called when a TransportCompanyMoneyEvent is received (client
---side). Updates the per-truck books and ledger display.
---@param moneyType number
---@param amount number
---@param farmId number
---@param contractId string
---@param truckUniqueId number
function TransportCompanyManager:onMoneyEvent(moneyType, amount, farmId, contractId, truckUniqueId)
    if truckUniqueId == nil or truckUniqueId == 0 then return end

    local truck = self.trucks[truckUniqueId]
    if truck == nil then return end

    if moneyType == TransportCompanyMoneyEvent.TYPE_CONTRACT_REWARD then
        truck:addRevenue(amount)
    elseif moneyType == TransportCompanyMoneyEvent.TYPE_HIRED_DRIVER_CUT then
        truck:addExpense(amount)
    elseif moneyType == TransportCompanyMoneyEvent.TYPE_EXPENSE then
        truck:addExpense(amount)
    end
end

-- ── Contract Event Handling ───────────────────

---Called when a TransportCompanyContractEvent is received.
---@param eventType number (TYPE_ADD, TYPE_UPDATE, TYPE_STATE_CHANGE, TYPE_REMOVE)
---@param contract TransportCompanyContract|nil
---@param state number
function TransportCompanyManager:onContractEvent(eventType, contract, state)
    if contract == nil then return end

    if eventType == TransportCompanyContractEvent.TYPE_ADD then
        self.contracts[contract.contractId] = contract
    elseif eventType == TransportCompanyContractEvent.TYPE_UPDATE then
        self.contracts[contract.contractId] = contract
    elseif eventType == TransportCompanyContractEvent.TYPE_STATE_CHANGE then
        contract.state = state
        if state == TransportCompanyContract.STATE_COMPLETED then
            self:_cleanupCompletedContracts()
        end
    elseif eventType == TransportCompanyContractEvent.TYPE_REMOVE then
        self.contracts[contract.contractId] = nil
    end
end

---Remove contracts that are completed/expired and older than
---7 days to keep the savegame XML lean.
function TransportCompanyManager:_cleanupCompletedContracts()
    local now = g_currentMission.time
    local maxAge = TransportCompanyContract.DAY_LENGTH * 7

    for contractId, contract in pairs(self.contracts) do
        if contract.state == TransportCompanyContract.STATE_COMPLETED or
           contract.state == TransportCompanyContract.STATE_EXPIRED then
            if contract.completedTime > 0 and (now - contract.completedTime) > maxAge then
                self.contracts[contractId] = nil
            end
        end
    end
end

-- ── Console Commands ──────────────────────────

function TransportCompanyManager:_registerConsoleCommands()
    addConsoleCommand(
        "tc_debug",
        "Toggle Transport Company debug mode",
        "consoleCommandDebug",
        self
    )

    addConsoleCommand(
        "tc_generate_contract",
        "Generate a new transport contract (debug)",
        "consoleCommandGenerateContract",
        self
    )

    addConsoleCommand(
        "tc_list_contracts",
        "List all active transport contracts",
        "consoleCommandListContracts",
        self
    )

    addConsoleCommand(
        "tc_list_trucks",
        "List all enrolled trucks",
        "consoleCommandListTrucks",
        self
    )

    addConsoleCommand(
        "tc_reset_settings",
        "Reset Transport Company settings to defaults",
        "consoleCommandResetSettings",
        self
    )
end

function TransportCompanyManager:consoleCommandDebug()
    if not self.settings.debugMode then
        self.settings.debugMode = true
        print("TransportCompany: debug mode ON")
    else
        self.settings.debugMode = false
        print("TransportCompany: debug mode OFF")
    end
    self.settings:save()
end

function TransportCompanyManager:consoleCommandGenerateContract()
    if not self.isServer then
        print("TransportCompany: only server can generate contracts")
        return
    end

    local contract = TransportCompanyContract.generate()
    if contract then
        self.contracts[contract.contractId] = contract
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_ADD, contract
        )
        local typeStr = contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET
            and "pallet" or "bulk"
        print(string.format(
            "TransportCompany: generated contract %s (type=%s, reward=%d)",
            contract.contractId, typeStr, contract.reward
        ))
    else
        print("TransportCompany: failed to generate contract")
    end
end

function TransportCompanyManager:consoleCommandListContracts()
    local count = 0
    for id, contract in pairs(self.contracts) do
        count = count + 1
        local typeStr = contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET
            and "pallet" or "bulk"
        print(string.format(
            "  %s: type=%s state=%s reward=%d delivered=%d/%d",
            id, typeStr, contract.state, contract.reward,
            contract.delivered, contract.amount
        ))
    end
    print(string.format("TransportCompany: %d contracts total", count))
end

function TransportCompanyManager:consoleCommandListTrucks()
    local count = 0
    for uniqueId, truck in pairs(self.trucks) do
        count = count + 1
        print(string.format(
            "  %s (%s): revenue=%d fuel=%d dist=%d jobs=%d profit=%d",
            uniqueId, truck.vehicleName or "unknown",
            truck.revenue, truck.fuelCost, truck.distanceM,
            truck.jobsDelivered, truck:getProfit()
        ))
    end
    print(string.format("TransportCompany: %d trucks enrolled", count))
end

function TransportCompanyManager:consoleCommandResetSettings()
    self.settings:resetToDefaults()
    self.settings:save()
    print("TransportCompany: settings reset to defaults")
end

-- ── Hints Registration ──────────────────────────

---Register intro hints that appear in the base Settings →
---Gameplay → Hints page automatically (no custom drawing).
function TransportCompanyManager:_registerHints()
    local success, errorMsg = pcall(function()
        if g_currentMission == nil or g_currentMission.introductionHelpSystem == nil then
            return
        end

        g_currentMission.introductionHelpSystem:registerHint(
            "transportCompany_dispatch",
            g_i18n:getText("transportCompany_hint_dispatch"),
            true
        )

        g_currentMission.introductionHelpSystem:registerHint(
            "transportCompany_fleet",
            g_i18n:getText("transportCompany_hint_fleet"),
            false
        )

        TransportCompanyLog.info("Intro hints registered")
    end)

    if not success then
        TransportCompanyLog.error("Hint registration failed: %s", tostring(errorMsg))
    end
end

-- ── Cleanup ────────────────────────────────────

function TransportCompanyManager:delete()
    self:_onDeleteMission()
    TransportCompanyManager.INSTANCE = nil
end
