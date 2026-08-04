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

-- ── Stuck-driver watchdog ──────────────────────
-- The base game's own AI driving strategy already retries its route
-- planning while blocked, but on busy town roads it can sit in that
-- retry loop indefinitely (STATE: BLOCKED forever) without ever
-- issuing an AIMessageErrorBlockedByObject that would let us react.
-- Rather than wait on that, we watch the truck's own movement while
-- its job is actively driving (AITaskDriveTo) and, if it covers next
-- to nothing over a window, force-stop and re-issue the job. Starting
-- a fresh AIJobLoadAndDeliver makes the engine recompute the route
-- from the vehicle's current position, which is the same recovery a
-- player gets from manually cancelling and re-hiring.
TransportCompanyManager.STUCK_CHECK_INTERVAL_MS = 20000  -- evaluate every 20s
TransportCompanyManager.STUCK_MIN_DISTANCE_M = 8         -- must cover at least this far
TransportCompanyManager.STUCK_MAX_REPLAN_ATTEMPTS = 3    -- give up after this many forced replans

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

    -- Company-level books. Kept separately from the per-truck books
    -- because a self-hauled delivery cannot be attributed to a truck:
    -- the station hook reports liters and fill position, never the
    -- vehicle that tipped them. Without this the Ledger would show no
    -- revenue for any contract the player hauled personally.
    self.ledger = { revenue = 0, driverWages = 0, jobs = 0 }

    -- Per-contract watchdog state for hired drivers: contractId →
    -- { windowTimer, windowDistance, attempts }. Server-only, never
    -- persisted — a fresh save simply resumes watching from zero.
    self.stuckWatch = {}

    -- Runtime state
    self.isMissionLoaded = false
    self.isMissionStarted = false
    self.isServer = false
    self.tickTimer = 0
    self.deadlineCheckTimer = 0
    self.booksSyncTimer = 0

    -- One-per-session flags (see _ensureMissionStartup). Reset on
    -- mission teardown so a fresh career re-arms them.
    self._startupRan = false
    self._aiSubscribed = false

    return self
end

-- ── Initialization ──────────────────────────────

---Called once at mod load (bootstrap). Registers mission
---hooks and console commands. Does NOT load settings yet
---(savegame directory not available until mission loads).
function TransportCompanyManager:load()
    TransportCompanyLog.info("TransportCompanyManager: load()")

    -- Mission lifecycle hooks (closures capture self).
    --
    -- Only these two exist on Mission00 (mission00.lua:290 and :560).
    -- Earlier versions of this file also appended to onMissionStarted,
    -- onMissionFinished and deleteMission — none of which are engine
    -- functions. Utils.appendedFunction(nil, fn) returns fn unchanged
    -- (Utils.lua:380-386), so those hooks silently defined functions
    -- that nothing ever called and the whole mod stayed inert.
    -- The onStartMission pattern is what the base game itself uses,
    -- see KioskMode.lua:262.
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            self:_onMissionLoaded()
        end
    )

    Mission00.onStartMission = Utils.appendedFunction(
        Mission00.onStartMission,
        function()
            self:_onMissionStarted()
        end
    )

    -- Teardown: Mission00:delete() (mission00.lua:86) is the real
    -- shutdown path.
    Mission00.delete = Utils.prependedFunction(
        Mission00.delete,
        function()
            self:_onDeleteMission()
        end
    )

    -- Per-frame update (for truck sampling, deadline checks)
    FSBaseMission.update = Utils.appendedFunction(
        FSBaseMission.update,
        function(mission, dt)
            if g_transportCompanyManager then
                g_transportCompanyManager:update(dt)
            end
        end
    )

    -- Save hook: persist contracts when the game saves
    if FSCareerMissionInfo and FSCareerMissionInfo.saveToXMLFile then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
            FSCareerMissionInfo.saveToXMLFile,
            function()
                if g_transportCompanyManager then
                    g_transportCompanyManager:_saveContracts()
                end
            end
        )
    end

    -- Delivery detection: credit contracts when goods reach a station
    self:_installDeliveryHooks()

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

    -- Load settings (shared + local).
    -- NOTE: settings values live in settings.config and are read with
    -- settings:get(id). Reading them as plain fields (settings.enabled)
    -- always yields nil, which previously disabled every guarded code
    -- path in this file.
    self.settings:loadSettings()

    -- Contracts and the HQ scan deliberately do NOT run here.
    -- loadMission00Finished fires before placeables are instantiated,
    -- so the placeable and storage systems are still empty: every saved
    -- contract failed to resolve its stations and was discarded
    -- ("Loaded 0 contracts (5 dropped)"), and the HQ scan found
    -- nothing. Both happen in _onMissionStarted instead.

    -- Register PDA page (client only — g_gui is client-side)
    if g_gui ~= nil then
        self:_registerPdaPage()
    end

    -- Register intro hints (appear in base Settings → Gameplay → Hints)
    self:_registerHints()

    TransportCompanyLog.info(
        "TransportCompanyManager: _onMissionLoaded() complete"
    )
end

---Find HQs that already exist in the world and register them.
---Runs once the world is up, not at load: see _onMissionLoaded.
function TransportCompanyManager:_scanForHqs()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return
    end
    if TransportCompanyHq == nil then
        return
    end
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable ~= nil and SpecializationUtil.hasSpecialization(
            TransportCompanyHq, placeable.specializations
        ) then
            -- Placeables found by this scan exist and are live.
            self:onHqChanged(placeable, true)
        end
    end
end

---Called at Mission00.onStartMission (player is in the world,
---fields are populated). Builds the fleet roster and registers
---the AI job completion listener.
function TransportCompanyManager:_onMissionStarted()
    TransportCompanyLog.info("TransportCompanyManager: _onMissionStarted()")

    -- The world exists by now, so stations, placeables and the fill
    -- levels inside their storages all resolve.
    self.isMissionStarted = true

    -- One-per-session setup runs whether or not the company starts
    -- enabled. Saved contracts, the HQ scan, truck enrollment and the
    -- AI completion subscription are all inert while disabled (update()
    -- gates sampling, board generation gates on enabled), and running
    -- them here means switching the company on mid-session resumes
    -- without a reload.
    self:_ensureMissionStartup()

    if not self.settings:get("enabled") then
        TransportCompanyLog.info(
            "TransportCompanyManager: company starts disabled - board fills when it is enabled")
        return
    end

    -- Fill the board if the save had none and an HQ is already standing.
    self:_regenerateContractBoard()

    TransportCompanyLog.info("TransportCompanyManager: _onMissionStarted() complete")
end

---Run the one-per-session mission setup: load saved contracts, register
---existing HQs, start truck sampling and subscribe to hired-driver job
---completion. Called at mission start and never again for that mission
---(the _startupRan flag). The setup used to sit inside the enabled gate,
---so a company toggled on after starting disabled never enrolled trucks
---and never detected a hired driver finishing - both resumed only on a
---reload. Running it unconditionally keeps the enable path working.
function TransportCompanyManager:_ensureMissionStartup()
    if self._startupRan then return end
    self._startupRan = true

    self:_loadContracts()
    self:_scanForHqs()
    self:_startTruckSampling()

    -- Subscribe to AI job completion (hired-driver delivery).
    -- MessageCenter:subscribe returns nothing (MessageCenter.lua:27-49),
    -- so there is no handle to keep; teardown unsubscribes by target.
    if not self._aiSubscribed then
        g_messageCenter:subscribe(
            MessageType.AI_JOB_STOPPED,
            TransportCompanyManager._onAIServerJobStopped,
            self
        )
        self._aiSubscribed = true
    end
end

---Tear down subscriptions and stop sampling. Reached via
---_onDeleteMission (Mission00:delete).
function TransportCompanyManager:_onMissionFinished()
    TransportCompanyLog.info("TransportCompanyManager: _onMissionFinished()")

    -- Unsubscribe from the message center.
    -- unsubscribe() takes (messageType, callbackTarget, callback)
    -- (MessageCenter.lua:53) — there is no handle-based form, so drop
    -- everything registered against this manager in one call.
    g_messageCenter:unsubscribeAll(self)

    self.isMissionLoaded = false
end

---Called from Mission00:delete (mission00.lua:86). Full cleanup.
function TransportCompanyManager:_onDeleteMission()
    TransportCompanyLog.info("TransportCompanyManager: _onDeleteMission()")

    self:_onMissionFinished()

    self.contracts = {}
    self.hqPlaceables = {}
    self.trucks = {}
    self.stuckWatch = {}
    self.isMissionStarted = false
    self.ledger = { revenue = 0, driverWages = 0, jobs = 0 }
    self.isMissionLoaded = false
    self._startupRan = false
    self._aiSubscribed = false
end

-- ── Settings ────────────────────────────────────

---Reload settings from disk (called from console command).
function TransportCompanyManager:reloadSettings()
    self.settings:loadSettings()
    TransportCompanyLog.info("TransportCompanyManager: settings reloaded")
end

-- ── PDA Page Registration ──────────────────────

---Register our PDA sub-tab on the in-game menu. Uses the
---proven MarketDynamics pattern (pagingElement addElement +
---exposeControlsAsFields + registerPage + addPageTab +
---rebuildTabList, all pcall-guarded). The tab is hidden
---when the player has no HQ.
function TransportCompanyManager:_registerPdaPage()
    local success, errorMsg = pcall(function()
        if g_gui == nil then return end
        if self.pdaFrame ~= nil then return end   -- already registered

        -- Get the InGameMenu instance
        local inGameMenu = g_inGameMenu
        if inGameMenu == nil then
            TransportCompanyLog.error("InGameMenu instance not found")
            return
        end

        -- Load the frame XML.
        --
        -- loadGui(xmlFilename, name, controller, isFrame) dereferences
        -- the controller immediately (`controller.name = name`,
        -- Gui.lua:200) — passing nil for it threw every time, which is
        -- why the PDA page never appeared. The controller IS the frame
        -- instance; this mirrors InGameMenuContractsFrame.register()
        -- at InGameMenuContractsFrame.lua:15-18.
        local xmlPath = self.modDirectory .. "gui/InGameMenuTransportCompanyFrame.xml"

        -- The GUI name is deliberately not the file name. PagingElement
        -- titles a tab from g_i18n "ui_" .. element.name
        -- (PagingElement.lua:47-50), and element.name is whatever is
        -- passed here — so naming it after the file would look for
        -- "ui_InGameMenuTransportCompanyFrame" and leave the tab title
        -- blank. This matches the ui_transportCompanyPage key instead.
        local guiName = "transportCompanyPage"

        local screen = InGameMenuTransportCompanyFrame.new()
        g_gui:loadGui(xmlPath, guiName, screen, true)
        self.pdaFrame = screen

        -- loadGui already calls exposeControlsAsFields (Gui.lua:216),
        -- so it must not be called a second time here.

        -- Nothing calls a frame's initialize() automatically —
        -- InGameMenu does it by hand for each of its own pages
        -- (InGameMenu.lua:203-223), so a mod page must do the same or
        -- its element references stay nil.
        --
        -- Guarded separately: an error in here used to abort the whole
        -- registration below it, so the tab never appeared at all. A
        -- half-populated page is still far better than no page.
        local initOk, initErr = pcall(screen.initialize, screen)
        if not initOk then
            TransportCompanyLog.error("PDA frame initialize failed: %s", tostring(initErr))
        end

        -- Add to the paging element (avoid duplicates)
        if inGameMenu.pagingElement ~= nil then
            local alreadyAdded = false
            for _, el in ipairs(inGameMenu.pagingElement.elements) do
                if el == screen then
                    alreadyAdded = true
                    break
                end
            end
            if not alreadyAdded then
                inGameMenu.pagingElement:addElement(screen)
            end
        end

        -- Update paging layout
        if type(inGameMenu.pagingElement.updateAbsolutePosition) == "function" then
            pcall(inGameMenu.pagingElement.updateAbsolutePosition, inGameMenu.pagingElement)
        end
        if type(inGameMenu.pagingElement.updatePageMapping) == "function" then
            pcall(inGameMenu.pagingElement.updatePageMapping, inGameMenu.pagingElement)
        end

        -- The page stays enabled even with no HQ.
        --
        -- It used to be gated on _hasHq(), which is re-evaluated every
        -- time the menu opens (TabbedMenu:updatePages, TabbedMenu.lua:79)
        -- so it did work — but a tab that is simply absent until you
        -- happen to buy the right building is undiscoverable, and reads
        -- as "the mod is broken". The frame now shows a message telling
        -- the player to place an HQ instead of hiding itself.
        local enablePredicate = function()
            return true
        end

        if type(inGameMenu.registerPage) == "function" then
            pcall(inGameMenu.registerPage, inGameMenu, screen, nil, enablePredicate)
        end

        -- Add the tab button (icon from mod textures).
        --
        -- getUVs must be given the STRING form for a full-texture icon.
        -- A table is treated as pixel values and divided by the 1024
        -- reference size (GuiUtils.lua:31), so {0,0,1,1} would select a
        -- single pixel; "0 0 1 1" is passed through untouched.
        local iconFile = Utils.getFilename("textures/tab_transportCompany.dds", self.modDirectory)
        if type(inGameMenu.addPageTab) == "function" and GuiUtils ~= nil then
            pcall(inGameMenu.addPageTab, inGameMenu, screen, iconFile, GuiUtils.getUVs("0 0 1 1"))
        end

        -- Rebuild the tab list so the new tab appears
        if type(inGameMenu.rebuildTabList) == "function" then
            pcall(inGameMenu.rebuildTabList, inGameMenu)
        end

        TransportCompanyLog.info("PDA page '%s' registered", guiName)
    end)

    if not success then
        TransportCompanyLog.error("PDA page registration failed: %s", tostring(errorMsg))
    end
end

---The farm that owns the company, taken from any placed HQ.
---Used for stock access when generating contracts.
---@return number farmId, 0 when there is no HQ
function TransportCompanyManager:_getCompanyFarmId()
    for _, placeable in pairs(self.hqPlaceables) do
        if placeable ~= nil and placeable.getOwnerFarmId ~= nil then
            local farmId = placeable:getOwnerFarmId()
            if farmId ~= nil and farmId > 0 then
                return farmId
            end
        end
    end
    return 0
end

---Check whether the local player's own farm has at least one HQ.
---Drives the PDA tab's enabling predicate, so in multiplayer it must
---not be satisfied by a rival farm's headquarters.
---@return boolean
function TransportCompanyManager:_hasHq()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return false
    end
    local farmId = g_currentMission:getFarmId()
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable ~= nil and SpecializationUtil.hasSpecialization(
            TransportCompanyHq, placeable.specializations
        ) and (farmId == nil or farmId <= 0 or placeable:getOwnerFarmId() == farmId) then
            return true
        end
    end
    return false
end

-- ── Hooks ──────────────────────────────────────

---Called by the TransportCompanyHq spec on placement, sell and
---delete. Regenerates the contract board when HQ presence changes.
---
---@param placeable table The HQ placeable
---@param isActive boolean True when the HQ is now live, false when it
---       is being sold or deleted. The caller has to say which: the
---       specialization is still attached during onSell/onDelete, so
---       testing hasSpecialization here would report every removal as
---       a placement and leave the sold HQ registered forever.
function TransportCompanyManager:onHqChanged(placeable, isActive)
    if placeable == nil then return end

    -- A placeable mid-teardown can have no uniqueId, and in LuaJIT
    -- t[nil] = nil raises "table index is nil" — so bail out rather
    -- than index the table with it.
    local uniqueId = placeable:getUniqueId()
    if uniqueId == nil or uniqueId == "" then
        self:_regenerateContractBoard()
        return
    end

    if isActive then
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

    -- Nothing before the mission actually starts. Placeables exist during
    -- loading but their storages have not read their fill levels from the
    -- savegame yet, so every station reports empty and the board fills
    -- with jobs whose sources look bare. _onMissionStarted regenerates.
    if not self.isMissionStarted then
        TransportCompanyLog.debug("board: mission not started, deferring generation")
        return
    end
    -- A disabled company generates nothing, including on HQ change while
    -- it is switched off. The enable path calls this again, so the board
    -- fills the moment the company is turned back on.
    if not self.settings:get("enabled") then
        TransportCompanyLog.debug("board: company disabled, nothing generated")
        return
    end
    if not self:_hasHq() then
        TransportCompanyLog.debug("board: no HQ, nothing generated")
        return
    end

    local maxActive = self.settings:get("maxActiveContracts") or 5
    local activeCount = 0

    for _, contract in pairs(self.contracts) do
        if contract.state == TransportCompanyContract.STATE_AVAILABLE or
           contract.state == TransportCompanyContract.STATE_ACCEPTED then
            activeCount = activeCount + 1
        end
    end

    local deadlineDays = self.settings:get("contractDeadlineDays") or 7
    local boardFarmId = self:_getCompanyFarmId()
    while activeCount < maxActive do
        local contract = TransportCompanyContract.generate(deadlineDays, boardFarmId)
        if contract == nil then break end
        self.contracts[contract.contractId] = contract
        activeCount = activeCount + 1

        -- Broadcast the new contract to all clients
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_ADD, contract
        )
    end

    -- Always report, not just on a shortfall. A full board built entirely
    -- from non-AI routes looks healthy but leaves "Hire driver" refusing
    -- every time, and that is invisible without these numbers.
    local ai, stocked, routes, stations, orphan =
        TransportCompanyContract.countRoutes(boardFarmId)
    TransportCompanyLog.info(
        "board: %d/%d contracts (farm %s; %d loading stations, %d without a "
        .. "placeable, %d routes, %d stocked, %d AI-haulable)",
        activeCount, maxActive, tostring(boardFarmId),
        stations, orphan, routes, stocked, ai
    )
    if ai == 0 and routes > 0 then
        TransportCompanyLog.info(
            "board: no AI-haulable route on this map for farm %s -- hired "
            .. "drivers will be refused; these jobs must be hauled in person",
            tostring(boardFarmId)
        )
    end
end

-- ── Contract Persistence ──────────────────────

---Save contracts and the truck ledger to a dedicated XML file in
---the savegame directory. Called from the FSCareerMissionInfo save
---hook. Server-authoritative state, so only the server writes it.
---
---Uses the XMLFile object API throughout. The contract and truck
---save/load methods call xmlFile:setString/:getInt etc., which only
---exist on an XMLFile object — the procedural createXMLFile /
---getXMLString handles used previously are plain integers and made
---every save and load throw.
function TransportCompanyManager:_saveContracts()
    if not self.isMissionLoaded or not self.isServer then return end

    local filePath = self:_getContractsFilePath()
    if filePath == nil then return end

    local xmlFile = XMLFile.create(
        "transportCompanyContracts", filePath, "transportCompany"
    )
    if xmlFile == nil then
        TransportCompanyLog.error("Could not create '%s'", filePath)
        return
    end

    local idx = 0
    for _, contract in pairs(self.contracts) do
        contract:saveToXMLFile(
            xmlFile, string.format("transportCompany.contracts.contract(%d)", idx)
        )
        idx = idx + 1
    end

    local truckIdx = 0
    for _, truck in pairs(self.trucks) do
        truck:saveToXMLFile(
            xmlFile, string.format("transportCompany.trucks.truck(%d)", truckIdx)
        )
        truckIdx = truckIdx + 1
    end

    xmlFile:setFloat("transportCompany.ledger#revenue", self.ledger.revenue)
    xmlFile:setFloat("transportCompany.ledger#driverWages", self.ledger.driverWages)
    xmlFile:setInt("transportCompany.ledger#jobs", self.ledger.jobs)

    xmlFile:save()
    xmlFile:delete()

    TransportCompanyLog.debug("Saved %d contracts, %d trucks", idx, truckIdx)
end

---Load contracts and the truck ledger from the savegame XML file.
function TransportCompanyManager:_loadContracts()
    local filePath = self:_getContractsFilePath()
    if filePath == nil or not fileExists(filePath) then return end

    local xmlFile = XMLFile.load("transportCompanyContracts", filePath)
    if xmlFile == nil then return end

    local loaded, dropped, stale = 0, 0, 0
    local idx = 0
    while true do
        local key = string.format("transportCompany.contracts.contract(%d)", idx)
        local id = xmlFile:getString(key .. "#contractId")
        if id == nil or id == "" then break end

        local contract = TransportCompanyContract.new()
        contract:loadFromXMLFile(xmlFile, key)

        -- Drop anything an older generator wrote: those contracts can
        -- reference sources that cannot supply them, and no amount of
        -- retrying fixes that. A station demolished since the last save
        -- is dropped for the same reason.
        local isStale = (contract.generatorVersion or 0)
            < TransportCompanyContract.GENERATOR_VERSION
        if isStale then
            stale = stale + 1
        elseif contract:_resolveStationRefs() then
            self.contracts[contract.contractId] = contract
            loaded = loaded + 1
        else
            dropped = dropped + 1
        end
        idx = idx + 1
    end

    local truckIdx = 0
    while true do
        local key = string.format("transportCompany.trucks.truck(%d)", truckIdx)
        local uniqueId = xmlFile:getString(key .. "#uniqueId")
        if uniqueId == nil or uniqueId == "" then break end

        local truck = TransportCompanyTruck.loadFromXMLFile(xmlFile, key)
        self.trucks[truck.uniqueId] = truck
        truckIdx = truckIdx + 1
    end

    self.ledger.revenue = xmlFile:getFloat("transportCompany.ledger#revenue", 0)
    self.ledger.driverWages = xmlFile:getFloat("transportCompany.ledger#driverWages", 0)
    self.ledger.jobs = xmlFile:getInt("transportCompany.ledger#jobs", 0)

    xmlFile:delete()

    TransportCompanyLog.info(
        "Loaded %d contracts (%d dropped, %d stale), %d trucks from savegame",
        loaded, dropped, stale, truckIdx
    )
end

---Path of the mod's savegame file, or nil before a savegame exists.
---@return string|nil
function TransportCompanyManager:_getContractsFilePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil or savegameDir == "" then
        return nil
    end
    return savegameDir .. "/transportCompany_contracts.xml"
end

-- ── Truck Sampling ──────────────────────────────

---Start the per-frame truck sampling timer (server only).
function TransportCompanyManager:_startTruckSampling()
    self.tickTimer = 0
    self.deadlineCheckTimer = 0
    self.enrollTimer = 0
    self:_enrollTrucks()
end

---Scan the live vehicle list and enroll every qualifying truck that
---is not already on the books. Nothing previously populated
---self.trucks, so the Fleet and Ledger tabs were permanently empty.
---
---A vehicle qualifies when Motorized classifies it as a truck
---(Motorized.lua:451-453) and it belongs to a real farm. Books for a
---sold truck are kept — the ledger is a history, not a live roster.
---
---Runs on clients too: the vehicle list is synced everywhere, so a
---client can build the same roster locally and let the money events
---fill in the figures. Only the sampling (fuel, distance) is
---server-authoritative.
function TransportCompanyManager:_enrollTrucks()
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return
    end

    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle ~= nil and not vehicle:getIsBeingDeleted()
           and TransportCompanyTruck.getIsTruck(vehicle) then
            local uniqueId = vehicle:getUniqueId()
            local farmId = vehicle:getOwnerFarmId()
            if uniqueId ~= nil and uniqueId ~= ""
               and farmId ~= nil and farmId > 0 then
                local truck = self.trucks[uniqueId]
                if truck == nil then
                    truck = TransportCompanyTruck.new(vehicle)
                    self.trucks[uniqueId] = truck
                    TransportCompanyLog.debug(
                        "Enrolled truck %s (%s)", uniqueId, truck.vehicleName
                    )
                end
                if not truck.isEnrolled then
                    truck.isEnrolled = true
                    truck.farmId = farmId
                    truck:beginSampling(vehicle)
                end
            end
        end
    end
end

---Per-frame update hook (appended to FSBaseMission.update).
---Drives truck sampling (every 1s) and deadline checks (every 5s).
---@param dt number Delta time in milliseconds
function TransportCompanyManager:update(dt)
    if not self.isMissionLoaded then return end
    if not self.settings:get("enabled") then return end

    -- Roster upkeep runs everywhere so clients can render the Fleet tab.
    self.enrollTimer = (self.enrollTimer or 0) + dt
    if self.enrollTimer >= 10000 then
        self.enrollTimer = 0
        self:_enrollTrucks()
    end

    -- Everything below mutates authoritative state.
    if not self.isServer then return end

    self.tickTimer = self.tickTimer + dt
    self.deadlineCheckTimer = self.deadlineCheckTimer + dt

    -- Distance must be sampled EVERY frame. lastMovedDistance is the
    -- distance moved in the last physics tick (Vehicle.lua:1484), not a
    -- running total, so reading it once a second discarded roughly
    -- 59/60ths of every journey — a truck driven across the map showed
    -- up as half a metre.
    self:_sampleDistance()

    -- Fuel is a fill-level delta, so once a second is plenty and keeps
    -- the per-frame cost down.
    if self.tickTimer >= 1000 then
        self.tickTimer = 0
        self:_sampleTrucks(dt)
    end

    -- Check deadlines every 5 seconds
    if self.deadlineCheckTimer >= 5000 then
        self.deadlineCheckTimer = 0
        self:_checkDeadlines()
    end

    -- Watch hired drivers for a job that is driving but not actually
    -- covering ground (blocked in traffic, stuck on an object, etc.)
    -- and force a route replan when it has gone nowhere for too long.
    self:_checkStuckDrivers(dt)

    -- Top the board up every 30s. Generation can legitimately fail
    -- (a station demolished, no route for a fill type), and without a
    -- retry the board would stay short until the next HQ change.
    self.boardTimer = (self.boardTimer or 0) + dt
    if self.boardTimer >= 30000 then
        self.boardTimer = 0
        self:_regenerateContractBoard()
    end

    -- Keep client books current. Fuel and distance accumulate every
    -- frame on the server, and there is no per-tick event for them, so
    -- a snapshot is pushed periodically. Clients joining mid-game get
    -- the current state within one interval instead of waiting for the
    -- next payout.
    self.booksSyncTimer = (self.booksSyncTimer or 0) + dt
    if self.booksSyncTimer >= 30000 then
        self.booksSyncTimer = 0
        self:_broadcastBooks()
    end
end

---Accumulate per-tick distance for every enrolled truck. Called every
---frame; see the note in update().
function TransportCompanyManager:_sampleDistance()
    for _, truck in pairs(self.trucks) do
        if truck.isEnrolled then
            local vehicle = truck:getVehicle()
            if vehicle ~= nil and not vehicle:getIsBeingDeleted() then
                truck:sampleDistance(vehicle)
            end
        end
    end
end

---Sample fuel for all enrolled trucks, and retire the ones that are gone.
function TransportCompanyManager:_sampleTrucks(dt)
    for _, truck in pairs(self.trucks) do
        local vehicle = truck:getVehicle()
        if vehicle ~= nil and not vehicle:getIsBeingDeleted() then
            truck:sampleFuel(vehicle, dt)
        elseif truck.isEnrolled then
            -- Truck sold or deleted: stop sampling, keep the books.
            truck.isEnrolled = false
        end
    end
end

---Check contract deadlines and expire overdue contracts.
---Expire overdue contracts and refill the board.
---
---Both states time out, for different reasons. An ACCEPTED contract
---that runs out is a job the player failed, so it is marked EXPIRED
---and kept until cleanup sweeps it. An AVAILABLE one is just a stale
---listing nobody took: it is dropped outright, which keeps the
---savegame lean and lets a fresh job take the slot. Without this the
---board froze with the same jobs forever and then slowly emptied.
function TransportCompanyManager:_checkDeadlines()
    local now = g_currentMission.time
    local changed = false

    for contractId, contract in pairs(self.contracts) do
        if contract:getIsExpired(now) then
            if contract.state == TransportCompanyContract.STATE_ACCEPTED then
                contract:expire()
                TransportCompanyContractEvent.sendEvent(
                    TransportCompanyContractEvent.TYPE_STATE_CHANGE, contract,
                    TransportCompanyContract.STATE_EXPIRED
                )
                self:_notify(string.format(
                    g_i18n:getText("transportCompany_contractExpired"),
                    contract:getLocalizedFillType()
                ))
                changed = true
            elseif contract.state == TransportCompanyContract.STATE_AVAILABLE then
                self.contracts[contractId] = nil
                TransportCompanyContractEvent.sendEvent(
                    TransportCompanyContractEvent.TYPE_REMOVE, contract
                )
                changed = true
            end
        end
    end

    if changed then
        self:_regenerateContractBoard()
    end
end

-- ── Accepting a contract ───────────────────────

---Server-side handler for an accept request. Reached from the PDA
---button (directly on a listen server, via TransportCompanyAcceptEvent
---from a client). Validates, accepts, and for MODE_HIRE also starts a
---base game AI job.
---@param contractId string
---@param mode number TransportCompanyAcceptEvent.MODE_SELF or MODE_HIRE
---@param farmId number
---@return boolean accepted
function TransportCompanyManager:onAcceptRequest(contractId, mode, farmId)
    if not self.isServer then return false end

    local contract = self.contracts[contractId]
    if contract == nil then
        return false
    end
    if farmId == nil or farmId <= 0 then
        return false
    end

    local isHire = mode == TransportCompanyAcceptEvent.MODE_HIRE

    -- Hiring a driver for a job you already took is a normal thing to
    -- want: take it, look at the route, decide to hand it over. That
    -- used to be impossible because both buttons disappeared the moment
    -- a contract left AVAILABLE.
    if contract.state == TransportCompanyContract.STATE_ACCEPTED then
        if isHire and not contract.isHiredDriver and contract.farmId == farmId then
            return self:_hireForAcceptedContract(contract, farmId)
        end
        return false
    end

    if contract.state ~= TransportCompanyContract.STATE_AVAILABLE then
        return false
    end

    -- The deadline clock starts now, not at generation time.
    local deadlineDays = self.settings:get("contractDeadlineDays") or 7
    contract.deadline = g_currentMission.time
        + TransportCompanyContract.DAY_LENGTH * deadlineDays

    local truck = isHire and self:_findTruckForContract(contract, farmId) or nil

    if isHire then
        -- Check the job before touching contract state, so a refusal
        -- leaves the board exactly as it was.
        local haulable, reasonKey = contract:getIsAiHaulable(farmId)
        if not haulable then
            TransportCompanyLog.info(
                "Hire refused for %s: %s", tostring(contractId), tostring(reasonKey))
            self:_notify(g_i18n:getText(reasonKey))
            return false
        end
    end

    if isHire and truck == nil then
        TransportCompanyLog.info(
            "Accept refused for %s: no AI-capable truck on farm %d",
            tostring(contractId), farmId
        )
        -- Say so: a button that silently does nothing reads as broken.
        self:_notify(g_i18n:getText("transportCompany_noTruck"))
        return false
    end

    if not contract:accept(farmId, truck ~= nil and truck.uniqueId or "", isHire) then
        return false
    end

    if isHire then
        local started, reason = self:_dispatchHiredDriver(contract, truck)
        if not started then
            -- Could not start the AI job — hand the contract back rather
            -- than leaving it accepted with no driver.
            contract.state = TransportCompanyContract.STATE_AVAILABLE
            contract.isHiredDriver = false
            contract.acceptedTruckUniqueId = ""
            contract.farmId = 0
            self:_notify(reason or g_i18n:getText("transportCompany_noTruck"))
            return false
        end
    end

    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_UPDATE, contract
    )
    self:_notify(string.format(
        g_i18n:getText("transportCompany_contractAccepted"),
        contract:getLocalizedFillType(), contract.destName,
        g_i18n:formatMoney(contract.reward, 0, true, true)
    ))
    return true
end

---Put a driver on a contract this farm already accepted.
---@return boolean started
function TransportCompanyManager:_hireForAcceptedContract(contract, farmId)
    local haulable, reasonKey = contract:getIsAiHaulable(farmId)
    if not haulable then
        TransportCompanyLog.info(
            "Hire refused for %s: %s", tostring(contract.contractId), tostring(reasonKey))
        self:_notify(g_i18n:getText(reasonKey))
        return false
    end

    local truck = self:_findTruckForContract(contract, farmId)
    if truck == nil then
        self:_notify(g_i18n:getText("transportCompany_noTruck"))
        return false
    end

    local previousTruck = contract.acceptedTruckUniqueId
    contract.isHiredDriver = true
    contract.acceptedTruckUniqueId = truck.uniqueId

    local started, reason = self:_dispatchHiredDriver(contract, truck)
    if not started then
        -- Leave the contract accepted and player-hauled, as it was.
        contract.isHiredDriver = false
        contract.acceptedTruckUniqueId = previousTruck
        self:_notify(reason or g_i18n:getText("transportCompany_noTruck"))
        return false
    end

    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_UPDATE, contract
    )
    self:_notify(string.format(
        g_i18n:getText("transportCompany_driverDispatched"),
        truck.vehicleName or "", contract:getLocalizedFillType()
    ))
    return true
end

---Pick an enrolled truck on this farm that the base game AI will
---actually accept for a load-and-deliver job.
---@return TransportCompanyTruck|nil
function TransportCompanyManager:_findTruckForContract(contract, farmId)
    local probe = g_currentMission.aiJobTypeManager:createJob(AIJobType.LOAD_AND_DELIVER)
    if probe == nil then
        TransportCompanyLog.info("hire: could not create a LOAD_AND_DELIVER probe job")
        return nil
    end

    local considered = 0
    for _, truck in pairs(self.trucks) do
        if truck.farmId == farmId then
            considered = considered + 1
            local vehicle = truck:getVehicle()
            -- getIsAvailableForVehicle is the engine's own suitability
            -- test (AIJobLoadAndDeliver.lua:376): AI-capable, not in
            -- use, and has both loading and discharge nodes.
            if vehicle ~= nil and not vehicle:getIsBeingDeleted()
               and probe:getIsAvailableForVehicle(vehicle) then
                return truck
            end
            self:_logHireRejection(truck, vehicle)
        end
    end

    TransportCompanyLog.info(
        "hire: no usable truck on farm %s (%d considered, %d enrolled)",
        tostring(farmId), considered, self:_countTrucks()
    )
    return nil
end

function TransportCompanyManager:_countTrucks()
    local n = 0
    for _ in pairs(self.trucks) do n = n + 1 end
    return n
end

---Explain why a truck the player can plainly see was not usable.
---
---getIsAvailableForVehicle only returns a bare false, which is
---indistinguishable from "you own no trucks". Re-checking each gate
---here turns a confusing refusal into an actionable log line.
function TransportCompanyManager:_logHireRejection(truck, vehicle)
    local name = truck.vehicleName or truck.uniqueId or "?"

    if vehicle == nil then
        TransportCompanyLog.info("hire: '%s' rejected — vehicle not found in the world", name)
        return
    end

    local function has(fn) return vehicle[fn] ~= nil end
    local spec = vehicle.spec_aiJobVehicle

    local canStart = has("getCanStartAIVehicle") and vehicle:getCanStartAIVehicle() or false
    local dischargeNodes, fillUnits = 0, 0
    if vehicle.getChildVehicles ~= nil then
        for _, child in ipairs(vehicle:getChildVehicles()) do
            if child.getAIDischargeNodes ~= nil then
                for _ in pairs(child:getAIDischargeNodes()) do
                    dischargeNodes = dischargeNodes + 1
                end
            end
            if child.getAIFillUnits ~= nil then
                for _ in pairs(child:getAIFillUnits()) do
                    fillUnits = fillUnits + 1
                end
            end
        end
    end

    TransportCompanyLog.info(
        "hire: '%s' rejected — createAgent=%s setAITarget=%s canStartAI=%s "
        .. "supportsAIJobs=%s aiStartAllowed=%s dirNode=%s aiActive=%s broken=%s "
        .. "jobSupported=%s dischargeNodes=%d aiFillUnits=%d",
        name,
        tostring(has("createAgent")), tostring(has("setAITarget")), tostring(canStart),
        tostring(spec ~= nil and spec.supportsAIJobs),
        tostring(spec ~= nil and spec.isAIStartAllowed),
        tostring(has("getAIDirectionNode") and vehicle:getAIDirectionNode() ~= nil),
        tostring(has("getIsAIActive") and vehicle:getIsAIActive()),
        tostring(vehicle.isBroken),
        tostring(has("getIsAIJobSupported") and vehicle:getIsAIJobSupported("AIJobLoadAndDeliver")),
        dischargeNodes, fillUnits
    )
end

---Build and start an AIJobLoadAndDeliver for a contract.
---@return boolean started
function TransportCompanyManager:_dispatchHiredDriver(contract, truck)
    local vehicle = truck ~= nil and truck:getVehicle() or nil
    local sourceStation = contract:getSourceStation()
    local destStation = contract:getDestStation()
    if vehicle == nil or sourceStation == nil or destStation == nil then
        return false
    end

    local reason = nil
    local ok, result = pcall(function()
        local job = g_currentMission.aiJobTypeManager:createJob(AIJobType.LOAD_AND_DELIVER)
        if job == nil then return false end

        job.vehicleParameter:setVehicle(vehicle)
        job.loadingStationParameter:setLoadingStation(sourceStation)
        job.unloadingStationParameter:setUnloadingStation(destStation)
        job.fillTypeParameter:setFillTypeIndex(contract.fillTypeIndex)
        -- One run, not a loop: the contract has a fixed amount.
        job.loopingParameter:setIsLooping(false)

        -- setValues populates the loading/discharge node info that
        -- validate() then checks (AIJobLoadAndDeliver.lua:45,152).
        job:setValues()
        local isValid, errorMessage = job:validate(contract.farmId)
        if not isValid then
            TransportCompanyLog.info(
                "Hired driver rejected for %s: %s",
                tostring(contract.contractId), tostring(errorMessage)
            )
            -- Hand the reason back; validate returns a localized string
            -- like "Loading station is empty!", which is far more use
            -- than a blanket "no suitable truck".
            reason = errorMessage
            return false
        end

        -- startJob assigns the id we later match in AI_JOB_STOPPED
        -- (AISystem.lua:355-362).
        g_currentMission.aiSystem:startJob(job, contract.farmId)
        contract.hiredDriverJobId = job.jobId or 0
        return true
    end)

    if not ok then
        TransportCompanyLog.error("Hired driver dispatch failed: %s", tostring(result))
        return false
    end
    return result == true, reason
end

-- ── Stuck-driver watchdog ───────────────────────

---Check every active hired-driver contract for a truck that is
---nominally driving but not making progress, and force a fresh route
---plan when it has been stuck too long.
---
---Measures net displacement (straight-line distance between the start
---and end of a window), not cumulative distance travelled. A truck
---wedged against an obstacle often revs and rocks back and forth
---trying to free itself — that can add up to several metres of actual
---wheel movement over a window while its position barely changes, and
---summing lastMovedDistance let that jitter reset the timer every
---cycle, so the watchdog never fired.
---@param dt number Delta time in milliseconds
function TransportCompanyManager:_checkStuckDrivers(dt)
    for contractId, contract in pairs(self.contracts) do
        local isActiveHiredDriver = contract.isHiredDriver
            and contract.state == TransportCompanyContract.STATE_ACCEPTED
            and contract.hiredDriverJobId ~= nil
            and contract.hiredDriverJobId > 0

        if not isActiveHiredDriver then
            self.stuckWatch[contractId] = nil
        else
            local job = g_currentMission.aiSystem:getJobById(contract.hiredDriverJobId)
            local truck = self.trucks[contract.acceptedTruckUniqueId]
            local vehicle = truck ~= nil and truck:getVehicle() or nil

            if job == nil or vehicle == nil or vehicle.rootNode == nil then
                -- Job already gone (caught by _onAIServerJobStopped) or
                -- truck no longer resolvable — nothing to watch.
                self.stuckWatch[contractId] = nil
            else
                -- Only count time while the job is actually trying to
                -- drive somewhere. Loading/unloading/waiting tasks are
                -- legitimately stationary and must not trip the watchdog.
                local currentTask = job:getTaskByIndex(job.currentTaskIndex)
                local isDriving = currentTask ~= nil and currentTask.isa ~= nil
                    and currentTask:isa(AITaskDriveTo)

                local watch = self.stuckWatch[contractId]
                if watch == nil then
                    watch = { windowTimer = 0, anchorX = nil, anchorZ = nil, attempts = 0 }
                    self.stuckWatch[contractId] = watch
                end

                if isDriving then
                    local x, _, z = getWorldTranslation(vehicle.rootNode)

                    if watch.anchorX == nil then
                        -- First tick of a fresh window: drop the anchor.
                        watch.anchorX, watch.anchorZ = x, z
                        watch.windowTimer = 0
                    else
                        watch.windowTimer = watch.windowTimer + dt

                        if watch.windowTimer >= TransportCompanyManager.STUCK_CHECK_INTERVAL_MS then
                            local dx, dz = x - watch.anchorX, z - watch.anchorZ
                            local netDistance = math.sqrt(dx * dx + dz * dz)

                            if netDistance < TransportCompanyManager.STUCK_MIN_DISTANCE_M then
                                watch.attempts = watch.attempts + 1
                                self:_replanStuckDriver(contract, truck, watch.attempts)
                            else
                                watch.attempts = 0
                            end

                            -- New window either way, anchored from here.
                            watch.anchorX, watch.anchorZ = x, z
                            watch.windowTimer = 0
                        end
                    end
                else
                    -- Not currently a driving task: don't accumulate,
                    -- but don't wipe attempts either — a truck that
                    -- gets stuck again shortly after loading shouldn't
                    -- get a full fresh set of retries. Clear the anchor
                    -- so driving resumes with a clean window.
                    watch.windowTimer = 0
                    watch.anchorX, watch.anchorZ = nil, nil
                end
            end
        end
    end
end

---Force-stop a hired driver's current job and immediately re-dispatch
---a fresh one, which makes the engine recompute the route from the
---vehicle's current position instead of waiting on a jam that may
---never clear on its own.
---@param contract TransportCompanyContract
---@param truck TransportCompanyTruck|nil
---@param attempt number How many times this contract has been replanned
function TransportCompanyManager:_replanStuckDriver(contract, truck, attempt)
    TransportCompanyLog.info(
        "Hired driver for contract %s looks stuck (attempt %d) — forcing a route replan",
        tostring(contract.contractId), attempt
    )

    if contract.hiredDriverJobId ~= nil and contract.hiredDriverJobId > 0 then
        -- Publishing AI_JOB_STOPPED runs _onAIServerJobStopped
        -- synchronously before stopJobById returns. Without this guard
        -- its generic release logic would flip isHiredDriver off right
        -- before _dispatchHiredDriver below turns around and starts a
        -- fresh job for the same contract.
        self._suppressReleaseForContractId = contract.contractId
        g_currentMission.aiSystem:stopJobById(
            contract.hiredDriverJobId, AIMessageErrorBlockedByObject.new()
        )
        self._suppressReleaseForContractId = nil
        contract.hiredDriverJobId = 0
    end

    if attempt > TransportCompanyManager.STUCK_MAX_REPLAN_ATTEMPTS then
        TransportCompanyLog.info(
            "Contract %s exceeded max replan attempts — releasing the driver",
            tostring(contract.contractId)
        )
        contract.isHiredDriver = false
        self.stuckWatch[contract.contractId] = nil
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_UPDATE, contract
        )
        self:_notify(string.format(
            g_i18n:getText("transportCompany_driverStuck"),
            (truck ~= nil and truck.vehicleName) or "", contract:getLocalizedFillType()
        ))
        self:_refreshDispatchUI()
        return
    end

    local started, reason = self:_dispatchHiredDriver(contract, truck)
    if not started then
        TransportCompanyLog.info(
            "Replan dispatch failed for contract %s: %s",
            tostring(contract.contractId), tostring(reason)
        )
    end
end

-- ── Delivery detection ─────────────────────────

---Install the delivery hooks. A station reports goods arriving
---through addFillLevelFromTool and returns how much it actually took,
---which is exactly the quantity a contract should be credited with.
---
---SellingStation overrides the method and only sometimes calls its
---super (SellingStation.lua:305-327), so both classes are hooked and a
---depth counter keeps the inner super call from crediting twice.
function TransportCompanyManager:_installDeliveryHooks()
    local function makeHook(className)
        return function(station, superFunc, farmId, deltaFillLevel, fillType, fillInfo, toolType, extraAttributes)
            local moved = superFunc(station, farmId, deltaFillLevel, fillType, fillInfo, toolType, extraAttributes)
            local mgr = g_transportCompanyManager
            if mgr ~= nil then
                mgr._deliveryDepth = (mgr._deliveryDepth or 0) + 1
                if mgr._deliveryDepth == 1 and moved ~= nil and moved > 0 then
                    local ok, err = pcall(
                        mgr.onGoodsDelivered, mgr, station, farmId, moved, fillType
                    )
                    if not ok then
                        TransportCompanyLog.error(
                            "%s delivery credit failed: %s", className, tostring(err)
                        )
                    end
                end
                mgr._deliveryDepth = mgr._deliveryDepth - 1
            end
            return moved
        end
    end

    UnloadingStation.addFillLevelFromTool = Utils.overwrittenFunction(
        UnloadingStation.addFillLevelFromTool, makeHook("UnloadingStation")
    )
    if SellingStation ~= nil then
        SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(
            SellingStation.addFillLevelFromTool, makeHook("SellingStation")
        )
    end
end

---Credit goods that just arrived at a station against open contracts.
---Server-side only: contract state and payouts are authoritative.
---@param station table The receiving station
---@param farmId number Farm that delivered
---@param liters number Liters the station actually accepted
---@param fillType number Fill type index
function TransportCompanyManager:onGoodsDelivered(station, farmId, liters, fillType)
    if not self.isServer or not self.isMissionLoaded then return end
    if not self.settings:get("enabled") then return end
    if station == nil or farmId == nil or farmId <= 0 then return end

    local remaining = liters
    for _, contract in pairs(self.contracts) do
        if remaining <= 0 then break end
        if contract.state == TransportCompanyContract.STATE_ACCEPTED
           and contract.farmId == farmId
           and contract.fillTypeIndex == fillType
           and contract:getDestStation() == station then

            local consumed, isComplete = contract:addDeliveredLiters(remaining)
            if consumed > 0 then
                remaining = remaining - consumed
                if isComplete then
                    self:_completeContract(contract)
                else
                    TransportCompanyContractEvent.sendEvent(
                        TransportCompanyContractEvent.TYPE_UPDATE, contract
                    )
                end
            end
        end
    end
end

---Pay out a finished contract. This is the single completion path:
---both the player tipping the last liters at the destination and a
---hired driver's AI job finishing land here, and contract:complete()
---returns false on the second caller, so a contract can never pay
---twice.
function TransportCompanyManager:_completeContract(contract)
    if not contract:complete() then return end

    local truck = self.trucks[contract.acceptedTruckUniqueId]

    -- addMoney rejects farmId 0 outright ("Can't change money of
    -- spectator farm", FSBaseMission.lua:2006).
    local farmId = contract.farmId
    if (farmId == nil or farmId <= 0) and truck ~= nil then
        farmId = truck.farmId
    end
    if farmId == nil or farmId <= 0 then
        TransportCompanyLog.warning(
            "Contract %s completed with no owning farm — no payout",
            tostring(contract.contractId)
        )
        return
    end

    -- A hired driver keeps a share as a wage; the company banks the
    -- rest. Both hit the same farm balance, so they are booked as two
    -- entries under different money types to keep the base game
    -- finance screen readable.
    local driverCut = 0
    if contract.isHiredDriver then
        local rewardShare = self.settings:get("hiredDriverRewardShare") or 20
        driverCut = math.floor(contract.reward * rewardShare / 100)
    end
    local companyRevenue = contract.reward - driverCut

    self:_addMoney(companyRevenue, farmId, MoneyType.MISSIONS)
    if driverCut > 0 then
        self:_addMoney(-driverCut, farmId, MoneyType.AI)
    end

    -- Company books always move, whether or not a truck was assigned.
    self.ledger.revenue = self.ledger.revenue + companyRevenue
    self.ledger.driverWages = self.ledger.driverWages + driverCut
    self.ledger.jobs = self.ledger.jobs + 1

    if truck ~= nil then
        truck:addRevenue(companyRevenue)
        truck:addJob()
        TransportCompanyMoneyEvent.sendEvent(
            TransportCompanyMoneyEvent.TYPE_CONTRACT_REWARD,
            companyRevenue, farmId, contract.contractId, truck.uniqueId
        )
        if driverCut > 0 then
            truck:addExpense(driverCut)
            TransportCompanyMoneyEvent.sendEvent(
                TransportCompanyMoneyEvent.TYPE_HIRED_DRIVER_CUT,
                driverCut, farmId, contract.contractId, truck.uniqueId
            )
        end
    end

    -- Push the updated ledger and truck books to clients in one
    -- authoritative snapshot (the money events above already nudge the
    -- per-truck numbers; the snapshot keeps the company totals right).
    self:_broadcastBooks()

    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_STATE_CHANGE, contract,
        TransportCompanyContract.STATE_COMPLETED
    )
    self:_notify(string.format(
        g_i18n:getText("transportCompany_contractDelivered"),
        contract:getLocalizedFillType(),
        g_i18n:formatMoney(companyRevenue, 0, true, true)
    ))

    TransportCompanyLog.info(
        "Contract %s completed: reward=%d driverCut=%d company=%d",
        contract.contractId, contract.reward, driverCut, companyRevenue
    )

    -- Free the board slot so a fresh job appears.
    self:_regenerateContractBoard()
end

---Show a base-game side notification, when the player wants them.
---Needs a local HUD, which a dedicated server does not have — there
---the call is simply skipped.
function TransportCompanyManager:_notify(text)
    if not self.settings:get("showNotifications") then return end
    if g_currentMission == nil or g_currentMission.hud == nil then return end
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
end

-- ── AI Job Completion (Hired Driver) ────────────

---Called when an AI job stops, for any reason. A clean delivery
---(AIMessageSuccessFinishedJob) completes and pays out the contract.
---Anything else — the player pressing H, running out of fuel, the
---vehicle breaking down, being deleted, or our own watchdog forcing a
---stop before it replans — ends the job without a delivery, and the
---contract must not be left silently claiming a hired driver that no
---longer exists. Releasing it here is what makes the Hire button
---reappear for that contract.
---@param job table The AI job that stopped
---@param aiMessage table The stop message
function TransportCompanyManager:_onAIServerJobStopped(job, aiMessage)
    if job == nil or aiMessage == nil then return end

    if aiMessage.isa and aiMessage:isa(AIMessageSuccessFinishedJob) then
        for _, contract in pairs(self.contracts) do
            if contract.isHiredDriver and contract.hiredDriverJobId == job.jobId then
                self:_completeHiredDriverContract(contract, job)
                break
            end
        end
        return
    end

    for _, contract in pairs(self.contracts) do
        if contract.isHiredDriver and contract.hiredDriverJobId == job.jobId then
            if self._suppressReleaseForContractId == contract.contractId then
                -- The watchdog is stopping this exact job on purpose so
                -- it can immediately start a fresh one for the same
                -- contract; don't hand control back to the player out
                -- from under that redispatch.
                return
            end

            TransportCompanyLog.info(
                "Hired driver job for contract %s ended without delivering — returning control",
                tostring(contract.contractId)
            )
            contract.isHiredDriver = false
            contract.hiredDriverJobId = 0
            self.stuckWatch[contract.contractId] = nil
            TransportCompanyContractEvent.sendEvent(
                TransportCompanyContractEvent.TYPE_UPDATE, contract
            )
            self:_refreshDispatchUI()
            break
        end
    end
end

---Complete a hired-driver contract.
---
---Delivery detection usually gets there first: the AI tips the load at
---the destination, which credits the contract through the same station
---hook a player would trigger. This is the backstop for the case where
---the job reports success without a crediting tip, and it delegates to
---the one completion path so the driver's cut is applied identically.
---@param contract TransportCompanyContract
---@param job table The completed AI job
function TransportCompanyManager:_completeHiredDriverContract(contract, job)
    self:_completeContract(contract)
end

---Book money against a farm. Server-only (addMoney refuses to run on
---a client, FSBaseMission.lua:2021) and never with farmId 0, which the
---engine rejects as the spectator farm (FSBaseMission.lua:2006).
---@param amount number Positive credits, negative debits
---@param farmId number Must be > 0
---@param moneyType table A MoneyType constant
function TransportCompanyManager:_addMoney(amount, farmId, moneyType)
    if not self.isServer or farmId == nil or farmId <= 0 or amount == 0 then
        return
    end
    g_currentMission:addMoney(amount, farmId, moneyType, true, true)
end

-- ── Money Event Handling ──────────────────────

---Build and broadcast a full snapshot of the company ledger and every
---truck's books. Server only. Clients have no other source for fuel
---and distance (both are sampled per-tick on the server and never sent
---individually), and the ledger totals live only on the server, so
---without this a client in multiplayer would show zero fuel, distance
---and company revenue in the Fleet and Ledger tabs.
---
---Sent on every contract completion (authoritative right after a
---payout) and periodically (see update()) so drifting figures and late
---joins converge within one interval.
function TransportCompanyManager:_broadcastBooks()
    if not self.isServer then return end
    if next(self.trucks) == nil and self.ledger.jobs == 0 then
        return
    end

    local event = TransportCompanyBooksEvent.new()
    event.ledgerRevenue = self.ledger.revenue
    event.ledgerDriverWages = self.ledger.driverWages
    event.ledgerJobs = self.ledger.jobs
    event.trucks = {}
    for uniqueId, truck in pairs(self.trucks) do
        table.insert(event.trucks, {
            uniqueId = uniqueId,
            vehicleName = truck.vehicleName or "",
            farmId = truck.farmId or 0,
            revenue = truck.revenue or 0,
            fuelCost = truck.fuelCost or 0,
            otherCost = truck.otherCost or 0,
            distanceM = truck.distanceM or 0,
            jobsDelivered = truck.jobsDelivered or 0,
        })
    end
    TransportCompanyBooksEvent.sendEvent(event)
end

---Apply a TransportCompanyBooksEvent snapshot (client side). Replaces
---the company ledger and the listed trucks' books with the server's
---authoritative values. A truck the client has not enrolled yet gets a
---placeholder entry so the Fleet and Ledger tabs render immediately;
---_enrollTrucks replaces it with the live vehicle on its next pass.
function TransportCompanyManager:onBooksEvent(event)
    if event == nil or self.isServer then return end

    self.ledger.revenue = event.ledgerRevenue or 0
    self.ledger.driverWages = event.ledgerDriverWages or 0
    self.ledger.jobs = event.ledgerJobs or 0

    for _, t in ipairs(event.trucks or {}) do
        if t.uniqueId ~= nil and t.uniqueId ~= "" then
            local truck = self.trucks[t.uniqueId]
            if truck == nil then
                truck = TransportCompanyTruck.new({
                    getUniqueId = function() return t.uniqueId end,
                    getFullName = function() return t.vehicleName or "Truck" end,
                    getOwnerFarmId = function() return t.farmId or 0 end,
                })
                self.trucks[t.uniqueId] = truck
            end
            truck.revenue = t.revenue or 0
            truck.fuelCost = t.fuelCost or 0
            truck.otherCost = t.otherCost or 0
            truck.distanceM = t.distanceM or 0
            truck.jobsDelivered = t.jobsDelivered or 0
        end
    end

    self:_refreshDispatchUI()
end

---Called when a TransportCompanyMoneyEvent is received (client
---side). Updates the per-truck books and ledger display.
---@param moneyType number
---@param amount number
---@param farmId number
---@param contractId string
---@param truckUniqueId string Vehicle uniqueId (a string, not an int)
function TransportCompanyManager:onMoneyEvent(moneyType, amount, farmId, contractId, truckUniqueId)
    -- The server already updated its own books before broadcasting;
    -- applying the event there too would double-count.
    if self.isServer then return end
    if truckUniqueId == nil or truckUniqueId == "" then return end

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
---Refresh the Transport Company PDA page if the player currently has
---it open. Contract state changes driven by the server in the
---background — a completed delivery, an expired deadline, or the
---stuck-driver watchdog releasing a driver — mutate the contract
---object directly but nothing else tells the open page to redraw its
---footer buttons, so a just-cancelled driver's "Hire" button would
---stay hidden until the player switched tabs or reopened the page.
function TransportCompanyManager:_refreshDispatchUI()
    if self.pdaFrame ~= nil and self.pdaFrame.isOpen then
        self.pdaFrame:updateTabContent()
    end
end

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

    self:_refreshDispatchUI()
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
        "tc_stations",
        "List every loading station, its stock and whether the AI can load there",
        "consoleCommandStations",
        self
    )

    addConsoleCommand(
        "tc_reset_board",
        "Clear every contract and regenerate the dispatch board",
        "consoleCommandResetBoard",
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
    local enabled = not self.settings:get("debugMode")
    self.settings:set("debugMode", enabled)
    self.settings:save()
    print("TransportCompany: debug mode " .. (enabled and "ON" or "OFF"))
end

function TransportCompanyManager:consoleCommandGenerateContract()
    if not self.isServer then
        print("TransportCompany: only server can generate contracts")
        return
    end

    local contract = TransportCompanyContract.generate(
        self.settings:get("contractDeadlineDays") or 7,
        self:_getCompanyFarmId()
    )
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

---Dump every loading station the map offers, with the two facts that
---decide whether a hired driver can ever run a job from it.
---
---A route is AI-haulable only when the station has a load trigger
---flagged for AI loading (LoadingStation.lua:145-149) AND the farm can
---draw stock from it (getFillLevel is access gated). Neither can be
---manufactured by this mod, so when "Hire driver" is never available
---this says which of the two is missing.
function TransportCompanyManager:consoleCommandStations()
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem
    if storageSystem == nil then
        print("TransportCompany: no storage system")
        return
    end

    local farmId = self:_getCompanyFarmId()
    if farmId <= 0 then
        farmId = g_currentMission:getFarmId()
    end
    print(string.format("TransportCompany: loading stations (farm %s)", tostring(farmId)))

    local stations, routes, aiTriggered, haulable = 0, 0, 0, 0
    for station, _ in pairs(storageSystem.loadingStations) do
        if station ~= nil then
            stations = stations + 1
            local fillTypes = station:getSupportedFillTypes() or {}
            local owner = station.owningPlaceable ~= nil
                and station.owningPlaceable:getOwnerFarmId() or "-"
            local anyAiTrigger = false
            local lines = {}

            for fillTypeIndex, _ in pairs(fillTypes) do
                if fillTypeIndex ~= FillType.UNKNOWN then
                    routes = routes + 1
                    local aiType = station.getIsFillTypeAISupported ~= nil
                        and station:getIsFillTypeAISupported(fillTypeIndex) or false
                    local physical = TransportCompanyContract.getStationStock(
                        station, fillTypeIndex, farmId)
                    local reachable = station.getFillLevel ~= nil
                        and (station:getFillLevel(fillTypeIndex, farmId) or 0) or 0
                    if aiType then
                        anyAiTrigger = true
                    end
                    if aiType and reachable > 0 then
                        haulable = haulable + 1
                    end
                    local basic = station.basicFillTypes ~= nil
                        and station.basicFillTypes[fillTypeIndex] or false
                    table.insert(lines, string.format(
                        "      %-22s physical=%-10s reachable=%-10d aiLoadable=%s",
                        g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or "?",
                        basic and "unlimited" or tostring(physical),
                        reachable, tostring(aiType)))
                end
            end

            if #lines > 0 then
                if anyAiTrigger then
                    aiTriggered = aiTriggered + 1
                end
                print(string.format("  %-34s owner=%s placeable=%s",
                    station:getName() or "?", tostring(owner),
                    tostring(station.owningPlaceable ~= nil)))
                for _, line in ipairs(lines) do
                    print(line)
                end
            end
        end
    end

    print(string.format(
        "TransportCompany: %d stations, %d routes, %d stations with an AI load "
        .. "trigger, %d routes a driver could run now",
        stations, routes, aiTriggered, haulable))
    if haulable == 0 then
        if aiTriggered == 0 then
            print("TransportCompany: no station on this map has an AI-capable load "
                .. "trigger, so hired drivers cannot load anywhere. Haul in person.")
        else
            print("TransportCompany: stations support AI loading but hold nothing "
                .. "your farm can draw. Fill a silo you own and routes will appear.")
        end
    end
end

---Throw the whole board away and build a fresh one. Useful after a
---generation change, when a save still holds contracts the current
---rules would never have produced.
function TransportCompanyManager:consoleCommandResetBoard()
    if not self.isServer then
        print("TransportCompany: only the server can reset the board")
        return
    end

    local removed = 0
    for id, contract in pairs(self.contracts) do
        if contract.state ~= TransportCompanyContract.STATE_COMPLETED then
            self.contracts[id] = nil
            removed = removed + 1
        end
    end

    self:_regenerateContractBoard()

    local now = 0
    for _ in pairs(self.contracts) do now = now + 1 end
    print(string.format(
        "TransportCompany: cleared %d contract(s), board now holds %d",
        removed, now))
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