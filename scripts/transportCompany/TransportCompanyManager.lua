-- =========================================================
-- FS25 Transport Company - Manager
-- =========================================================
-- Registrar + controller that orchestrates the entire mod:
--   * Mission lifecycle hooks (load, start, delete)
--   * HQ scan and per-farm company creation/archival
--   * Contract board generation & lifecycle (per company)
--   * Truck enrollment & per-truck bookkeeping (per company)
--   * Hired-driver AI job dispatch & completion
--   * PDA page registration (on Mission00.loadMission00Finished)
--   * MP event routing (ContractEvent, MoneyEvent, BooksEvent)
--   * Intro hints registration (base Settings → Gameplay → Hints)
--
-- Business state no longer lives here. Each farm that owns an HQ
-- has a TransportCompanyCompany (its board, ledger, truck books,
-- shared settings and stuck-watch); the manager is the single
-- place that owns the company map, the world scan and the MP
-- routing so that per-farm companies stay in sync in multiplayer.
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

-- ── Company registry ───────────────────────────

---Get or create the company for a farm. Companies are created on
---HQ placement / scan and archived when the last HQ is sold, but a
---caller that holds a valid farmId can safely ask for the company
---object even mid-teardown.
---@param farmId number
---@return TransportCompanyCompany|nil
function TransportCompanyManager:getOrCreateCompany(farmId)
    if farmId == nil or farmId <= 0 then
        return nil
    end
    local company = self.companies[farmId]
    if company == nil then
        company = TransportCompanyCompany.new(farmId)
        -- Load this farm's server-shared settings (board size, deadline,
        -- wage share, ...) from its per-company config file.
        company.settings:loadSettings()
        self.companies[farmId] = company
    end
    return company
end

---Get an existing company without creating one.
---@param farmId number
---@return TransportCompanyCompany|nil
function TransportCompanyManager:getCompany(farmId)
    if farmId == nil then return nil end
    return self.companies[farmId]
end

---The local player's own company (what the PDA shows).
---@return TransportCompanyCompany|nil
function TransportCompanyManager:getLocalCompany()
    if g_currentMission == nil then return nil end
    return self:getCompany(g_currentMission:getFarmId())
end

---Resolve the truck books that belong to a company.
---@param company TransportCompanyCompany
---@return table uniqueId → TransportCompanyTruck
function TransportCompanyManager:_companyTrucks(company)
    if company == nil then return {} end
    return company.trucks
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
    self.settings = TransportCompanySettings.new()      -- global/local-only (debugMode)
    self.companies = {}          -- farmId → TransportCompanyCompany
    self.hqPlaceables = {}       -- placeableUniqueId → placeable ref

    -- Runtime state
    self.isMissionLoaded = false
    self.isMissionStarted = false
    self.isServer = false
    self.enrollTimer = 0
    self.tickTimer = 0
    self.deadlineCheckTimer = 0

    -- Change-only board diagnostics: farmId → last logged snapshot.
    self._lastBoardSnapshot = {}

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

    -- Load the global/local-only settings (debugMode). Per-company
    -- server-shared settings load when each company is created in
    -- _scanForHqs / onHqChanged.
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

---Find HQs that already exist in the world and register them,
---creating a per-farm company for each owner. Board regeneration is
---suppressed here: saved contracts load after the scan, and the board
---must not be pre-filled before that or it would exceed maxActive.
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
            self:onHqChanged(placeable, true, true)
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

    -- Fill the board for every live company that starts enabled. A
    -- company that starts disabled fills when it is turned on (the
    -- enable path calls _regenerateContractBoard itself).
    local filledAny = false
    for farmId, company in pairs(self.companies) do
        if company ~= nil and not company.isArchived
           and company.settings:get("enabled") then
            self:_regenerateContractBoard(farmId)
            filledAny = true
        end
    end
    if not filledAny then
        TransportCompanyLog.info(
            "TransportCompanyManager: no live company starts enabled - boards fill when enabled")
    end

    TransportCompanyLog.info("TransportCompanyManager: _onMissionStarted() complete")
end

---Run the one-per-session mission setup: register existing HQs (which
---creates each farm's company), load saved per-company state, start
---truck sampling and subscribe to hired-driver job completion. Called
---at mission start and never again for that mission (the _startupRan
---flag). The setup used to sit inside the enabled gate, so a company
---toggled on after starting disabled never enrolled trucks and never
---detected a hired driver finishing - both resumed only on a reload.
---Running it unconditionally keeps the enable path working.
function TransportCompanyManager:_ensureMissionStartup()
    if self._startupRan then return end
    self._startupRan = true

    -- Scan HQs FIRST: companies are created here, and _loadContracts
    -- needs the company map to know which per-farm files to read.
    self:_scanForHqs()
    self:_loadContracts()
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

    self.hqPlaceables = {}
    self.companies = {}
    self._lastBoardSnapshot = {}
    self.isMissionStarted = false
    self.isMissionLoaded = false
    self._startupRan = false
    self._aiSubscribed = false
end

-- ── Settings ────────────────────────────────────

---Reload settings from disk (called from console command).
function TransportCompanyManager:reloadSettings()
    self.settings:loadSettings()
    for _, company in pairs(self.companies) do
        if company ~= nil then
            company.settings:loadSettings()
        end
    end
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

---The farm that owns the given HQ, from any placed HQ.
---@param placeable table|nil
---@return number farmId, 0 when there is no HQ
function TransportCompanyManager:_getHqFarmId(placeable)
    if placeable ~= nil and placeable.getOwnerFarmId ~= nil then
        local farmId = placeable:getOwnerFarmId()
        if farmId ~= nil and farmId > 0 then
            return farmId
        end
    end
    return 0
end

---The farm the current dispatch board belongs to: the local farm when
---it owns a company, otherwise the first HQ-owning farm found.
---Used for stock access when generating contracts.
---@return number farmId, 0 when there is no company
function TransportCompanyManager:_getCompanyFarmId()
    local localFarmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if self:getCompany(localFarmId) ~= nil then
        return localFarmId
    end
    for farmId, company in pairs(self.companies) do
        if company ~= nil and not company.isArchived then
            return farmId
        end
    end
    return 0
end

---Check whether the given farm has at least one HQ.
---Drives the PDA tab's enabling predicate, so in multiplayer it must
---not be satisfied by a rival farm's headquarters.
---@param farmId number|nil Defaults to the local farm
---@return boolean
function TransportCompanyManager:_hasHq(farmId)
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return false
    end
    if farmId == nil or farmId <= 0 then
        farmId = g_currentMission:getFarmId()
    end
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable ~= nil and SpecializationUtil.hasSpecialization(
            TransportCompanyHq, placeable.specializations
        ) then
            local owner = self:_getHqFarmId(placeable)
            if owner == farmId then
                return true
            end
        end
    end
    return false
end

-- ── Hooks ──────────────────────────────────────

---Called by the TransportCompanyHq spec on placement, sell and
---delete. Creates/archives the per-farm company and regenerates its
---contract board when HQ presence changes.
---
---@param placeable table The HQ placeable
---@param isActive boolean True when the HQ is now live, false when it
---       is being sold or deleted. The caller has to say which: the
---       specialization is still attached during onSell/onDelete, so
---       testing hasSpecialization here would report every removal as
---       a placement and leave the sold HQ registered forever.
---@param suppressBoard boolean|nil Skip board regeneration (used by the
---       initial world scan, before saved contracts are loaded).
function TransportCompanyManager:onHqChanged(placeable, isActive, suppressBoard)
    if placeable == nil then return end

    -- A placeable mid-teardown can have no uniqueId, and in LuaJIT
    -- t[nil] = nil raises "table index is nil" — so bail out rather
    -- than index the table with it.
    local uniqueId = placeable:getUniqueId()
    if uniqueId == nil or uniqueId == "" then
        local farmId = self:_getHqFarmId(placeable)
        if farmId > 0 and isActive and not suppressBoard then
            self:_regenerateContractBoard(farmId)
        end
        return
    end

    local farmId = self:_getHqFarmId(placeable)
    local company = self:getOrCreateCompany(farmId)

    if isActive then
        self.hqPlaceables[uniqueId] = placeable
        TransportCompanyLog.info("HQ placed: %s (farm %s)", uniqueId, tostring(farmId))
        if company ~= nil then
            if company.isArchived then
                company:restore()
                TransportCompanyLog.info("Company restored for farm %s", tostring(farmId))
            end
            -- Regenerate contract board to match HQ availability (not
            -- during the initial scan: contracts load afterwards).
            if not suppressBoard then
                self:_regenerateContractBoard(farmId)
            end
        end
    else
        self.hqPlaceables[uniqueId] = nil
        TransportCompanyLog.info("HQ removed: %s (farm %s)", uniqueId, tostring(farmId))
        -- Archive the company only when this farm has no HQ left.
        if company ~= nil and not self:_hasHq(farmId) then
            company:archive()
            TransportCompanyLog.info("Company archived for farm %s", tostring(farmId))
        end
    end
end

-- ── Contract Board ─────────────────────────────

---Generate contracts up to maxActiveContracts for one farm's
---company, respecting HQ presence. Called on HQ change and on a
---timer. Server only.
---@param farmId number Farm whose board should be topped up
function TransportCompanyManager:_regenerateContractBoard(farmId)
    if not self.isServer then return end

    -- Nothing before the mission actually starts. Placeables exist during
    -- loading but their storages have not read their fill levels from the
    -- savegame yet, so every station reports empty and the board fills
    -- with jobs whose sources look bare. _onMissionStarted regenerates.
    if not self.isMissionStarted then
        TransportCompanyLog.debug("board: mission not started, deferring generation")
        return
    end

    local company = self:getCompany(farmId)
    if company == nil or company.isArchived then
        TransportCompanyLog.debug("board: no live company for farm %s", tostring(farmId))
        return
    end
    -- A disabled company generates nothing, including on HQ change while
    -- it is switched off. The enable path calls this again, so the board
    -- fills the moment the company is turned back on.
    if not company.settings:get("enabled") then
        TransportCompanyLog.debug("board: company disabled, nothing generated")
        return
    end
    if not self:_hasHq(farmId) then
        TransportCompanyLog.debug("board: no HQ, nothing generated")
        return
    end

    -- Board size includes the HQ upgrade bonus.
    local maxActive = company:getBoardSize()
    local activeCount = 0

    for _, contract in pairs(company.contracts) do
        if contract.state == TransportCompanyContract.STATE_AVAILABLE or
           contract.state == TransportCompanyContract.STATE_ACCEPTED then
            activeCount = activeCount + 1
        end
    end

    local deadlineDays = company.settings:get("contractDeadlineDays") or 7
    local added = 0
    while activeCount < maxActive do
        local contract = TransportCompanyContract.generate(deadlineDays, farmId)
        if contract == nil then break end
        company.contracts[contract.contractId] = contract
        activeCount = activeCount + 1
        added = added + 1

        -- Broadcast the new contract to all clients
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_ADD, contract, nil, farmId
        )
    end

    -- Always report, not just on a shortfall. A full board built entirely
    -- from non-AI routes looks healthy but leaves "Hire driver" refusing
    -- every time, and that is invisible without these numbers. Gated so
    -- the 30-second top-up timer does not spam the log with identical
    -- lines every cycle — the diagnostics only print when something
    -- actually changed.
    local ai, stocked, routes, stations, orphan =
        TransportCompanyContract.countRoutes(farmId)
    local snapshot = string.format("%d/%d a%d s%d", activeCount, maxActive, ai, stocked)
    if added > 0 or self._lastBoardSnapshot[farmId] ~= snapshot then
        self._lastBoardSnapshot[farmId] = snapshot
        TransportCompanyLog.info(
            "board (farm %s): %d/%d contracts (added %d; %d loading stations, %d without a "
            .. "placeable, %d routes, %d stocked, %d AI-haulable)",
            tostring(farmId), activeCount, maxActive, added,
            stations, orphan, routes, stocked, ai
        )
        if ai == 0 and routes > 0 then
            TransportCompanyLog.info(
                "board (farm %s): no AI-haulable route on this map for farm %s -- hired "
                .. "drivers will be refused; these jobs must be hauled in person",
                tostring(farmId), tostring(farmId)
            )
        end
    end
end

-- ── Contract Persistence ──────────────────────

---Save every company's contracts and truck ledger to dedicated XML
---files in the savegame directory. Called from the FSCareerMissionInfo
---save hook. Server-authoritative state, so only the server writes it.
---
---Uses the XMLFile object API throughout. The contract and truck
---save/load methods call xmlFile:setString/:getInt etc., which only
---exist on an XMLFile object — the procedural createXMLFile /
---getXMLString handles used previously are plain integers and made
---every save and load throw.
function TransportCompanyManager:_saveContracts()
    if not self.isMissionLoaded or not self.isServer then return end

    local anyFile = false
    for farmId, company in pairs(self.companies) do
        local filePath = self:_getContractsFilePath(farmId)
        if filePath ~= nil then
            local ok = self:_saveCompanyToFile(company, filePath)
            if ok then anyFile = true end
        end
    end
    if not anyFile then return end

    -- Migrate a legacy (pre-per-farm) savegame file: once the new
    -- per-company files have been written, the old single-file
    -- transportCompany_contracts.xml is stale. It is left in place
    -- (never deleted — the game may be rolled back) but load no
    -- longer consults it once per-company files exist.
end

---Write one company's contracts, trucks and ledger to an XML file.
---@param company TransportCompanyCompany
---@param filePath string
---@return boolean wrote
function TransportCompanyManager:_saveCompanyToFile(company, filePath)
    if company == nil or filePath == nil then return false end

    local xmlFile = XMLFile.create(
        "transportCompanyContracts_" .. tostring(company.farmId),
        filePath, "transportCompany"
    )
    if xmlFile == nil then
        TransportCompanyLog.error("Could not create '%s'", filePath)
        return false
    end

    local idx = 0
    for _, contract in pairs(company.contracts) do
        contract:saveToXMLFile(
            xmlFile, string.format("transportCompany.contracts.contract(%d)", idx)
        )
        idx = idx + 1
    end

    local truckIdx = 0
    for _, truck in pairs(company.trucks) do
        truck:saveToXMLFile(
            xmlFile, string.format("transportCompany.trucks.truck(%d)", truckIdx)
        )
        truckIdx = truckIdx + 1
    end

    local driverIdx = 0
    for _, driver in pairs(company.drivers) do
        driver:saveToXMLFile(
            xmlFile, string.format("transportCompany.drivers.driver(%d)", driverIdx)
        )
        driverIdx = driverIdx + 1
    end

    xmlFile:setFloat("transportCompany.ledger#revenue", company.ledger.revenue)
    xmlFile:setFloat("transportCompany.ledger#driverWages", company.ledger.driverWages)
    xmlFile:setInt("transportCompany.ledger#jobs", company.ledger.jobs)

    -- Business-sim state (R4)
    xmlFile:setFloat("transportCompany.reputation#value", company.reputation or 0)
    xmlFile:setInt("transportCompany.hq#level", company.hqLevel or TransportCompanyCompany.HQ_BASE_LEVEL)
    local histIdx = 0
    for _, period in ipairs(company.ledgerHistory or {}) do
        local key = string.format("transportCompany.history.period(%d)", histIdx)
        xmlFile:setInt(key .. "#index", period.index or 0)
        xmlFile:setFloat(key .. "#revenue", period.revenue or 0)
        xmlFile:setFloat(key .. "#wages", period.wages or 0)
        xmlFile:setInt(key .. "#jobs", period.jobs or 0)
        xmlFile:setFloat(key .. "#km", period.km or 0)
        histIdx = histIdx + 1
    end

    xmlFile:save()
    xmlFile:delete()

    TransportCompanyLog.debug(
        "Saved farm %s: %d contracts, %d trucks, %d drivers",
        tostring(company.farmId), idx, truckIdx, driverIdx
    )
    return true
end

---Load every company's contracts and truck ledger from the per-farm
---savegame XML files. Falls back to a legacy pre-per-farm single file
---for the first company found, so a 1.0.x save upgrades in place.
function TransportCompanyManager:_loadContracts()
    local loadedAny = false
    local firstCompany = nil
    for _, company in pairs(self.companies) do
        if firstCompany == nil then firstCompany = company end
        local filePath = self:_getContractsFilePath(company.farmId)
        if filePath ~= nil and fileExists(filePath) then
            self:_loadCompanyFromFile(company, filePath)
            loadedAny = true
        end
    end

    -- Legacy migration: no per-company files but a pre-per-farm file
    -- exists. Attribute it to the first HQ-owning company.
    if not loadedAny and firstCompany ~= nil then
        local legacyPath = self:_getLegacyContractsFilePath()
        if legacyPath ~= nil and fileExists(legacyPath) then
            TransportCompanyLog.info(
                "Migrating legacy single-file save into farm %s",
                tostring(firstCompany.farmId)
            )
            self:_loadCompanyFromFile(firstCompany, legacyPath)
        end
    end
end

---Load one company from an XML file (contracts, trucks, ledger).
---@param company TransportCompanyCompany
---@param filePath string
function TransportCompanyManager:_loadCompanyFromFile(company, filePath)
    local xmlFile = XMLFile.load(
        "transportCompanyContracts_" .. tostring(company.farmId), filePath
    )
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
            company.contracts[contract.contractId] = contract
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
        -- A truck saved before the maintenance feature existed (or that
        -- already had odometer distance) must not be serviced for miles
        -- it drove before. Normalise the milestone at load.
        truck:normalizeService()
        company.trucks[truck.uniqueId] = truck
        truckIdx = truckIdx + 1
    end

    local driverIdx = 0
    while true do
        local key = string.format("transportCompany.drivers.driver(%d)", driverIdx)
        local driverId = xmlFile:getString(key .. "#driverId")
        if driverId == nil or driverId == "" then break end

        local driver = TransportCompanyDriver.loadFromXMLFile(xmlFile, key)
        company.drivers[driver.driverId] = driver
        driverIdx = driverIdx + 1
    end

    company.ledger.revenue = xmlFile:getFloat("transportCompany.ledger#revenue", 0)
    company.ledger.driverWages = xmlFile:getFloat("transportCompany.ledger#driverWages", 0)
    company.ledger.jobs = xmlFile:getInt("transportCompany.ledger#jobs", 0)

    -- Business-sim state (R4). Defaults keep pre-R4 saves working.
    company.reputation = xmlFile:getFloat("transportCompany.reputation#value", 0)
    company.hqLevel = xmlFile:getInt("transportCompany.hq#level", TransportCompanyCompany.HQ_BASE_LEVEL)
    local histIdx = 0
    while true do
        local key = string.format("transportCompany.history.period(%d)", histIdx)
        local index = xmlFile:getInt(key .. "#index", -1)
        if index < 0 then break end
        table.insert(company.ledgerHistory, {
            index = index,
            revenue = xmlFile:getFloat(key .. "#revenue", 0),
            wages = xmlFile:getFloat(key .. "#wages", 0),
            jobs = xmlFile:getInt(key .. "#jobs", 0),
            km = xmlFile:getFloat(key .. "#km", 0),
        })
        histIdx = histIdx + 1
    end

    xmlFile:delete()

    TransportCompanyLog.info(
        "Loaded farm %s: %d contracts (%d dropped, %d stale), %d trucks, %d drivers from savegame",
        tostring(company.farmId), loaded, dropped, stale, truckIdx, driverIdx
    )
end

---Path of one farm's mod savegame file, or nil before a savegame exists.
---@param farmId number
---@return string|nil
function TransportCompanyManager:_getContractsFilePath(farmId)
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil or savegameDir == "" then
        return nil
    end
    return savegameDir .. "/transportCompany_contracts_" .. tostring(farmId) .. ".xml"
end

---Path of the legacy pre-per-farm savegame file, or nil.
---@return string|nil
function TransportCompanyManager:_getLegacyContractsFilePath()
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

---Scan the live vehicle list and enroll every qualifying truck into
---the company of the farm that owns it. Nothing previously populated
---the books, so the Fleet and Ledger tabs were permanently empty.
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
                local company = self:getOrCreateCompany(farmId)
                if company ~= nil then
                    local truck = company.trucks[uniqueId]
                    if truck == nil then
                        truck = TransportCompanyTruck.new(vehicle)
                        company.trucks[uniqueId] = truck
                        TransportCompanyLog.debug(
                            "Enrolled truck %s (%s) for farm %s",
                            uniqueId, truck.vehicleName, tostring(farmId)
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
end

---Per-frame update hook (appended to FSBaseMission.update).
---Drives truck sampling (every 1s) and deadline checks (every 5s).
---@param dt number Delta time in milliseconds
function TransportCompanyManager:update(dt)
    if not self.isMissionLoaded then return end

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
        self:_checkMaintenance()
    end

    -- Check deadlines every 5 seconds
    if self.deadlineCheckTimer >= 5000 then
        self.deadlineCheckTimer = 0
        self:_checkDeadlines()
    end

    -- Per-company housekeeping: stuck-driver watch, board top-up,
    -- books sync. Each runs for every live (enabled, unarchived)
    -- company.
    for farmId, company in pairs(self.companies) do
        if company ~= nil and company:getIsActive() then
            -- Watch hired drivers for a job that is driving but not
            -- actually covering ground and force a route replan.
            self:_checkStuckDrivers(company, dt)

            -- Top the board up every 30s. Generation can legitimately
            -- fail (a station demolished, no route for a fill type), and
            -- without a retry the board would stay short until the next
            -- HQ change.
            company.boardTimer = (company.boardTimer or 0) + dt
            if company.boardTimer >= 30000 then
                company.boardTimer = 0
                self:_regenerateContractBoard(farmId)
            end

            -- Keep client books current. Fuel and distance accumulate
            -- every frame on the server, and there is no per-tick event
            -- for them, so a snapshot is pushed periodically. Clients
            -- joining mid-game get the current state within one interval
            -- instead of waiting for the next payout.
            company.booksSyncTimer = (company.booksSyncTimer or 0) + dt
            if company.booksSyncTimer >= 30000 then
                company.booksSyncTimer = 0
                self:_broadcastBooks(farmId)
            end

            -- Pay the drivers' weekly base wages once a game week.
            company.wageTimer = (company.wageTimer or 0) + dt
            if company.wageTimer >= TransportCompanyContract.DAY_LENGTH * 7 then
                company.wageTimer = 0
                self:_payWeeklyWages(company)
            end
        end
    end
end

---Check maintenance on every enrolled truck across all companies and
---book a service when one is due. Runs once a second (the odometer is
---already accumulated every frame).
function TransportCompanyManager:_checkMaintenance()
    for _, company in pairs(self.companies) do
        if company ~= nil and company:getIsActive() then
            for _, truck in pairs(company.trucks) do
                local cost = truck:checkService()
                if cost > 0 then
                    -- Service costs come out of the farm balance and are
                    -- booked as an expense on both the company and the
                    -- truck, so the Fleet tab shows a truck's real cost.
                    self:_addMoney(-cost, company.farmId, MoneyType.AI)
                    company.ledger.driverWages = company.ledger.driverWages + cost
                    TransportCompanyLog.info(
                        "Service for %s (farm %s): cost=%d",
                        truck.vehicleName or truck.uniqueId or "?", tostring(company.farmId), cost
                    )
                    TransportCompanyMoneyEvent.sendEvent(
                        TransportCompanyMoneyEvent.TYPE_EXPENSE,
                        cost, company.farmId, "", truck.uniqueId
                    )
                end
            end
        end
    end
end

---Pay each company's drivers their weekly base wage, out of the farm
---balance. The per-job reward split a hired driver keeps is handled at
---completion; this is the standing payroll for keeping them employed.
function TransportCompanyManager:_payWeeklyWages(company)
    if company == nil or company.farmId <= 0 then return end
    local total = company:getTotalWeeklyWage()
    if total <= 0 then return end

    self:_addMoney(-total, company.farmId, MoneyType.AI)
    company.ledger.driverWages = company.ledger.driverWages + total
    self:_rollLedgerPeriod(company, 0, total, 0, 0)

    TransportCompanyLog.info(
        "Weekly wages paid for farm %s: %d", tostring(company.farmId), total
    )
    TransportCompanyMoneyEvent.sendEvent(
        TransportCompanyMoneyEvent.TYPE_EXPENSE,
        total, company.farmId, "", ""
    )
end

---Roll the live ledger totals into the current 7-day period bucket so
---the Ledger tab can show how the company is doing per week.
---@param company TransportCompanyCompany
---@param revenue number
---@param wages number
---@param jobs number
---@param km number
function TransportCompanyManager:_rollLedgerPeriod(company, revenue, wages, jobs, km)
    local periodIndex = math.floor(g_currentMission.time / (TransportCompanyContract.DAY_LENGTH * 7))
    local history = company.ledgerHistory or {}
    local last = history[#history]
    if last == nil or last.index ~= periodIndex then
        last = { index = periodIndex, revenue = 0, wages = 0, jobs = 0, km = 0 }
        table.insert(history, last)
        -- Keep only the last ~16 weeks so the savegame XML stays lean.
        if #history > 16 then
            table.remove(history, 1)
        end
    end
    last.revenue = last.revenue + (revenue or 0)
    last.wages = last.wages + (wages or 0)
    last.jobs = last.jobs + (jobs or 0)
    last.km = last.km + (km or 0)
    company.ledgerHistory = history
end

---Accumulate per-tick distance for every enrolled truck across all
---companies. Called every frame; see the note in update().
function TransportCompanyManager:_sampleDistance()
    for _, company in pairs(self.companies) do
        if company ~= nil then
            for _, truck in pairs(company.trucks) do
                if truck.isEnrolled then
                    local vehicle = truck:getVehicle()
                    if vehicle ~= nil and not vehicle:getIsBeingDeleted() then
                        truck:sampleDistance(vehicle)
                    end
                end
            end
        end
    end
end

---Sample fuel for all enrolled trucks, and retire the ones that are gone.
function TransportCompanyManager:_sampleTrucks(dt)
    for _, company in pairs(self.companies) do
        if company ~= nil then
            for _, truck in pairs(company.trucks) do
                local vehicle = truck:getVehicle()
                if vehicle ~= nil and not vehicle:getIsBeingDeleted() then
                    truck:sampleFuel(vehicle, dt)
                elseif truck.isEnrolled then
                    -- Truck sold or deleted: stop sampling, keep the books.
                    truck.isEnrolled = false
                end
            end
        end
    end
end

---Check every company's contract deadlines and expire overdue
---contracts, then refill the boards that changed.
---
---Both states time out, for different reasons. An ACCEPTED contract
---that runs out is a job the player failed, so it is marked EXPIRED
---and kept until cleanup sweeps it. An AVAILABLE one is just a stale
---listing nobody took: it is dropped outright, which keeps the
---savegame lean and lets a fresh job take the slot. Without this the
---board froze with the same jobs forever and then slowly emptied.
function TransportCompanyManager:_checkDeadlines()
    local now = g_currentMission.time

    for farmId, company in pairs(self.companies) do
        if company ~= nil and company:getIsActive() then
            local changed = false

            for contractId, contract in pairs(company.contracts) do
                if contract:getIsExpired(now) then
                    if contract.state == TransportCompanyContract.STATE_ACCEPTED then
                        contract:expire()
                        -- A failed job costs reputation: clients who miss
                        -- deadlines are less trusted with the next load.
                        company:addReputation(TransportCompanyCompany.REPUTATION_ON_EXPIRE)
                        TransportCompanyContractEvent.sendEvent(
                            TransportCompanyContractEvent.TYPE_STATE_CHANGE, contract,
                            TransportCompanyContract.STATE_EXPIRED, farmId
                        )
                        self:_notify(string.format(
                            g_i18n:getText("transportCompany_contractExpired"),
                            contract:getLocalizedFillType()
                        ), farmId)
                        changed = true
                    elseif contract.state == TransportCompanyContract.STATE_AVAILABLE then
                        company.contracts[contractId] = nil
                        TransportCompanyContractEvent.sendEvent(
                            TransportCompanyContractEvent.TYPE_REMOVE, contract, nil, farmId
                        )
                        changed = true
                    end
                end
            end

            if changed then
                self:_regenerateContractBoard(farmId)
            end
        end
    end
end

-- ── Accepting a contract ───────────────────────

---Server-side handler for a driver/hq request. Reached from the PDA
---(directly on a listen server, via TransportCompanyDriverEvent from a
---client). All roster and HQ state is authoritative here; clients get
---the result through the next TransportCompanyBooksEvent snapshot.
---@param action number TransportCompanyDriverEvent.ACTION_*
---@param farmId number
---@param driverId string|nil
---@param truckUniqueId string|nil
---@return boolean applied
function TransportCompanyManager:onDriverRequest(action, farmId, driverId, truckUniqueId)
    if not self.isServer then return false end

    local company = self:getCompany(farmId)
    if company == nil or company.isArchived then return false end
    if farmId == nil or farmId <= 0 then return false end

    local applied = false
    if action == TransportCompanyDriverEvent.ACTION_HIRE then
        applied = self:_hireDriver(company, farmId)
    elseif action == TransportCompanyDriverEvent.ACTION_FIRE then
        applied = self:_fireDriver(company, driverId)
    elseif action == TransportCompanyDriverEvent.ACTION_ASSIGN then
        applied = self:_assignDriver(company, driverId, truckUniqueId)
    elseif action == TransportCompanyDriverEvent.ACTION_UPGRADE then
        applied = self:_upgradeHq(company, farmId)
    end

    if applied then
        -- Refresh everyone's roster/books in one authoritative snapshot.
        self:_broadcastBooks(farmId)
    end
    return applied
end

---Hire a named driver onto the payroll, if under the cap and able to
---pay the hiring cost.
---@return boolean
function TransportCompanyManager:_hireDriver(company, farmId)
    if company:getDriverCount() >= company:getDriverCap() then
        self:_notify(g_i18n:getText("transportCompany_driverCapReached"), farmId)
        return false
    end

    local cost = TransportCompanyDriver.HIRE_COST
    if self:_getFarmMoney(farmId) < cost then
        self:_notify(g_i18n:getText("transportCompany_noMoney"), farmId)
        return false
    end

    local driver = TransportCompanyDriver.new(
        TransportCompanyDriver.randomName(), TransportCompanyDriver.BASE_WEEKLY_WAGE)
    driver.driverId = string.format("drv_%d_%d",
        g_currentMission.time, math.random(10000, 99999))
    company.drivers[driver.driverId] = driver

    self:_addMoney(-cost, farmId, MoneyType.AI)
    company.ledger.driverWages = company.ledger.driverWages + cost
    self:_rollLedgerPeriod(company, 0, cost, 0, 0)

    self:_notify(string.format(
        g_i18n:getText("transportCompany_driverHired"),
        driver.name, g_i18n:formatMoney(cost, 0, true, true)
    ), farmId)
    return true
end

---Remove a driver from the payroll. No severance; the wage simply
---stops next week.
---@return boolean
function TransportCompanyManager:_fireDriver(company, driverId)
    local driver = company.drivers[driverId]
    if driver == nil then return false end
    company.drivers[driverId] = nil
    return true
end

---Assign (or clear) a driver's truck. Clearing releases the driver.
---@return boolean
function TransportCompanyManager:_assignDriver(company, driverId, truckUniqueId)
    local driver = company.drivers[driverId]
    if driver == nil then return false end
    driver.assignedTruckUniqueId = truckUniqueId or ""
    return true
end

---Raise the HQ one tier, charging the farm the upgrade cost.
---@return boolean
function TransportCompanyManager:_upgradeHq(company, farmId)
    local cost = company:getNextHqUpgradeCost()
    if cost == nil then
        self:_notify(g_i18n:getText("transportCompany_hqMaxLevel"), farmId)
        return false
    end
    if self:_getFarmMoney(farmId) < cost then
        self:_notify(g_i18n:getText("transportCompany_noMoney"), farmId)
        return false
    end

    company:hqUpgrade()
    self:_addMoney(-cost, farmId, MoneyType.AI)

    self:_notify(string.format(
        g_i18n:getText("transportCompany_hqUpgraded"),
        tostring(company.hqLevel),
        g_i18n:formatMoney(cost, 0, true, true)
    ), farmId)

    -- A bigger office means a bigger board.
    self:_regenerateContractBoard(farmId)
    return true
end

---Server-side handler for an accept request. Reached from the PDA
---button (directly on a listen server, via TransportCompanyAcceptEvent
---from a client). Validates, accepts, and for MODE_HIRE also starts a
---base game AI job. Operates on the requesting farm's company.
---@param contractId string
---@param mode number TransportCompanyAcceptEvent.MODE_SELF or MODE_HIRE
---@param farmId number
---@return boolean accepted
function TransportCompanyManager:onAcceptRequest(contractId, mode, farmId)
    if not self.isServer then return false end

    local company = self:getCompany(farmId)
    if company == nil or company.isArchived then
        return false
    end

    local contract = company.contracts[contractId]
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
            return self:_hireForAcceptedContract(company, contract)
        end
        return false
    end

    if contract.state ~= TransportCompanyContract.STATE_AVAILABLE then
        return false
    end

    -- The deadline clock starts now, not at generation time.
    local deadlineDays = company.settings:get("contractDeadlineDays") or 7
    contract.deadline = g_currentMission.time
        + TransportCompanyContract.DAY_LENGTH * deadlineDays

    local truck = isHire and self:_findTruckForContract(company, contract, farmId) or nil

    if isHire then
        -- Check the job before touching contract state, so a refusal
        -- leaves the board exactly as it was.
        local haulable, reasonKey = contract:getIsAiHaulable(farmId)
        if not haulable then
            TransportCompanyLog.info(
                "Hire refused for %s: %s", tostring(contractId), tostring(reasonKey))
            self:_notify(g_i18n:getText(reasonKey), farmId)
            return false
        end
    end

    if isHire and truck == nil then
        TransportCompanyLog.info(
            "Accept refused for %s: no AI-capable truck on farm %d",
            tostring(contractId), farmId
        )
        -- Say so: a button that silently does nothing reads as broken.
        self:_notify(g_i18n:getText("transportCompany_noTruck"), farmId)
        return false
    end

    if not contract:accept(farmId, truck ~= nil and truck.uniqueId or "", isHire) then
        return false
    end

    if isHire then
        local started, reason = self:_dispatchHiredDriver(company, contract, truck)
        if not started then
            -- Could not start the AI job — hand the contract back rather
            -- than leaving it accepted with no driver.
            contract.state = TransportCompanyContract.STATE_AVAILABLE
            contract.isHiredDriver = false
            contract.acceptedTruckUniqueId = ""
            contract.farmId = 0
            self:_notify(reason or g_i18n:getText("transportCompany_noTruck"), farmId)
            return false
        end
    end

    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_UPDATE, contract, nil, farmId
    )
    self:_notify(string.format(
        g_i18n:getText("transportCompany_contractAccepted"),
        contract:getLocalizedFillType(), contract.destName,
        g_i18n:formatMoney(contract.reward, 0, true, true)
    ), farmId)
    return true
end

---Put a driver on a contract this farm already accepted.
---@param company TransportCompanyCompany
---@param contract TransportCompanyContract
---@return boolean started
function TransportCompanyManager:_hireForAcceptedContract(company, contract)
    local farmId = company.farmId
    local haulable, reasonKey = contract:getIsAiHaulable(farmId)
    if not haulable then
        TransportCompanyLog.info(
            "Hire refused for %s: %s", tostring(contract.contractId), tostring(reasonKey))
        self:_notify(g_i18n:getText(reasonKey), farmId)
        return false
    end

    local truck = self:_findTruckForContract(company, contract, farmId)
    if truck == nil then
        self:_notify(g_i18n:getText("transportCompany_noTruck"), farmId)
        return false
    end

    local previousTruck = contract.acceptedTruckUniqueId
    contract.isHiredDriver = true
    contract.acceptedTruckUniqueId = truck.uniqueId

    local started, reason = self:_dispatchHiredDriver(company, contract, truck)
    if not started then
        -- Leave the contract accepted and player-hauled, as it was.
        contract.isHiredDriver = false
        contract.acceptedTruckUniqueId = previousTruck
        self:_notify(reason or g_i18n:getText("transportCompany_noTruck"), farmId)
        return false
    end

    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_UPDATE, contract, nil, farmId
    )
    self:_notify(string.format(
        g_i18n:getText("transportCompany_driverDispatched"),
        truck.vehicleName or "", contract:getLocalizedFillType()
    ), farmId)
    return true
end

---Pick an enrolled truck on this farm that the base game AI will
---actually accept for a load-and-deliver job.
---@param company TransportCompanyCompany
---@param contract TransportCompanyContract
---@param farmId number
---@return TransportCompanyTruck|nil
function TransportCompanyManager:_findTruckForContract(company, contract, farmId)
    local probe = g_currentMission.aiJobTypeManager:createJob(AIJobType.LOAD_AND_DELIVER)
    if probe == nil then
        TransportCompanyLog.info("hire: could not create a LOAD_AND_DELIVER probe job")
        return nil
    end

    local considered = 0
    local fallback = nil
    for _, truck in pairs(company.trucks) do
        if truck.farmId == farmId then
            considered = considered + 1
            local vehicle = truck:getVehicle()
            -- getIsAvailableForVehicle is the engine's own suitability
            -- test (AIJobLoadAndDeliver.lua:376): AI-capable, not in
            -- use, and has both loading and discharge nodes.
            if vehicle ~= nil and not vehicle:getIsBeingDeleted()
               and probe:getIsAvailableForVehicle(vehicle) then
                -- Prefer a truck that has a named driver assigned: that
                -- is the truck the player staffed, so the driver's record
                -- moves with the job. First usable truck is the fallback
                -- so hiring never fails just because nobody is assigned.
                if fallback == nil then
                    fallback = truck
                end
                if company:getDriverForTruck(truck.uniqueId) ~= nil then
                    return truck
                end
            end
            self:_logHireRejection(truck, vehicle)
        end
    end

    if fallback ~= nil then
        return fallback
    end

    TransportCompanyLog.info(
        "hire: no usable truck on farm %s (%d considered, %d enrolled)",
        tostring(farmId), considered, self:_countTrucks(company)
    )
    return nil
end

function TransportCompanyManager:_countTrucks(company)
    local n = 0
    for _ in pairs(company.trucks) do n = n + 1 end
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
---@param company TransportCompanyCompany
---@param contract TransportCompanyContract
---@param truck TransportCompanyTruck
---@return boolean started
function TransportCompanyManager:_dispatchHiredDriver(company, contract, truck)
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

---Check every active hired-driver contract in one company for a
---truck that is nominally driving but not making progress, and force
---a fresh route plan when it has been stuck too long.
---
---Measures net displacement (straight-line distance between the start
---and end of a window), not cumulative distance travelled. A truck
---wedged against an obstacle often revs and rocks back and forth
---trying to free itself — that can add up to several metres of actual
---wheel movement over a window while its position barely changes, and
---summing lastMovedDistance let that jitter reset the timer every
---cycle, so the watchdog never fired.
---@param company TransportCompanyCompany
---@param dt number Delta time in milliseconds
function TransportCompanyManager:_checkStuckDrivers(company, dt)
    for contractId, contract in pairs(company.contracts) do
        local isActiveHiredDriver = contract.isHiredDriver
            and contract.state == TransportCompanyContract.STATE_ACCEPTED
            and contract.hiredDriverJobId ~= nil
            and contract.hiredDriverJobId > 0

        if not isActiveHiredDriver then
            company.stuckWatch[contractId] = nil
        else
            local job = g_currentMission.aiSystem:getJobById(contract.hiredDriverJobId)
            local truck = company.trucks[contract.acceptedTruckUniqueId]
            local vehicle = truck ~= nil and truck:getVehicle() or nil

            if job == nil or vehicle == nil or vehicle.rootNode == nil then
                -- Job already gone (caught by _onAIServerJobStopped) or
                -- truck no longer resolvable — nothing to watch.
                company.stuckWatch[contractId] = nil
            else
                -- Only count time while the job is actually trying to
                -- drive somewhere. Loading/unloading/waiting tasks are
                -- legitimately stationary and must not trip the watchdog.
                local currentTask = job:getTaskByIndex(job.currentTaskIndex)
                local isDriving = currentTask ~= nil and currentTask.isa ~= nil
                    and currentTask:isa(AITaskDriveTo)

                local watch = company.stuckWatch[contractId]
                if watch == nil then
                    watch = { windowTimer = 0, anchorX = nil, anchorZ = nil, attempts = 0 }
                    company.stuckWatch[contractId] = watch
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
                                self:_replanStuckDriver(company, contract, truck, watch.attempts)
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
---@param company TransportCompanyCompany
---@param contract TransportCompanyContract
---@param truck TransportCompanyTruck|nil
---@param attempt number How many times this contract has been replanned
function TransportCompanyManager:_replanStuckDriver(company, contract, truck, attempt)
    local farmId = company.farmId
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
        company.stuckWatch[contract.contractId] = nil
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_UPDATE, contract, nil, farmId
        )
        self:_notify(string.format(
            g_i18n:getText("transportCompany_driverStuck"),
            (truck ~= nil and truck.vehicleName) or "", contract:getLocalizedFillType()
        ), farmId)
        self:_refreshDispatchUI()
        return
    end

    local started, reason = self:_dispatchHiredDriver(company, contract, truck)
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

---Credit goods that just arrived at a station against open contracts
---of the delivering farm's company.
---Server-side only: contract state and payouts are authoritative.
---@param station table The receiving station
---@param farmId number Farm that delivered
---@param liters number Liters the station actually accepted
---@param fillType number Fill type index
function TransportCompanyManager:onGoodsDelivered(station, farmId, liters, fillType)
    if not self.isServer or not self.isMissionLoaded then return end
    if station == nil or farmId == nil or farmId <= 0 then return end

    local company = self:getCompany(farmId)
    if company == nil or company.isArchived then return end
    if not company.settings:get("enabled") then return end

    -- Self-haul attribution: find the truck that is physically tipping
    -- into this station right now. Only meaningful on the first delivery
    -- tick (the hook fires every tick goods arrive), and only when no
    -- truck was assigned up front. The discharging check reads the
    -- vehicle's own discharge state, so it is additive: if nothing can
    -- be matched, delivery and payout still proceed uncredited to a
    -- truck, exactly as before.
    local dischargeTruck = nil
    if liters > 0 then
        dischargeTruck = self:_findDischargingTruck(company, station)
    end

    local remaining = liters
    for _, contract in pairs(company.contracts) do
        if remaining <= 0 then break end
        if contract.state == TransportCompanyContract.STATE_ACCEPTED
           and contract.farmId == farmId
           and contract.fillTypeIndex == fillType
           and contract:getDestStation() == station then

            -- Attribute a self-hauled delivery to the truck that tipped,
            -- so the Fleet tab shows revenue/jobs for jobs the player
            -- drove themselves, not only hired-driver runs.
            if dischargeTruck ~= nil and not contract.isHiredDriver then
                contract.deliveryTruckUniqueId = dischargeTruck.uniqueId
            end

            local consumed, isComplete = contract:addDeliveredLiters(remaining)
            if consumed > 0 then
                remaining = remaining - consumed
                if isComplete then
                    self:_completeContract(company, contract)
                else
                    TransportCompanyContractEvent.sendEvent(
                        TransportCompanyContractEvent.TYPE_UPDATE, contract, nil, farmId
                    )
                end
            end
        end
    end
end

---Find the enrolled truck whose vehicle (or attached trailer) is
---currently discharging into the given station. Uses the vehicle-side
---discharge state: getCurrentDischargeNode + getCurrentDischargeObject
---(Dischargeable.md:846-895), which is the reliable direction — the
---station's addFillLevelFromTool call carries no vehicle reference.
---@param company TransportCompanyCompany
---@param station table The receiving station
---@return TransportCompanyTruck|nil
function TransportCompanyManager:_findDischargingTruck(company, station)
    if company == nil or station == nil then return nil end

    local function dischargesTo(vehicle)
        if vehicle == nil or vehicle.getCurrentDischargeNode == nil
           or vehicle.getCurrentDischargeObject == nil then
            return false
        end
        local ok, node = pcall(vehicle.getCurrentDischargeNode, vehicle)
        if not ok or node == nil then
            return false
        end
        local ok2, object = pcall(vehicle.getCurrentDischargeObject, vehicle, node)
        return ok2 and object == station
    end

    for _, truck in pairs(company.trucks) do
        local vehicle = truck:getVehicle()
        if vehicle ~= nil and not vehicle:getIsBeingDeleted() then
            if dischargesTo(vehicle) then
                return truck
            end
            -- The trailer is the thing that usually tips; check children.
            if vehicle.getChildVehicles ~= nil then
                for _, child in ipairs(vehicle:getChildVehicles() or {}) do
                    if dischargesTo(child) then
                        return truck
                    end
                end
            end
        end
    end
    return nil
end

---Pay out a finished contract. This is the single completion path:
---both the player tipping the last liters at the destination and a
---hired driver's AI job finishing land here, and contract:complete()
---returns false on the second caller, so a contract can never pay
---twice.
---@param company TransportCompanyCompany
---@param contract TransportCompanyContract
function TransportCompanyManager:_completeContract(company, contract)
    if not contract:complete() then return end

    local farmId = company.farmId
    -- A hired driver was assigned a truck up front. A self-hauled job
    -- may carry the truck that actually tipped (deliveryTruckUniqueId,
    -- set by onGoodsDelivered); fall back to that so the Fleet tab
    -- credits jobs the player drove themselves.
    local truck = company.trucks[contract.acceptedTruckUniqueId]
    if truck == nil and contract.deliveryTruckUniqueId ~= nil
       and contract.deliveryTruckUniqueId ~= "" then
        truck = company.trucks[contract.deliveryTruckUniqueId]
    end

    -- addMoney rejects farmId 0 outright ("Can't change money of
    -- spectator farm", FSBaseMission.lua:2006).
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
        local rewardShare = company.settings:get("hiredDriverRewardShare") or 20
        driverCut = math.floor(contract.reward * rewardShare / 100)
    end
    local companyRevenue = contract.reward - driverCut

    self:_addMoney(companyRevenue, farmId, MoneyType.MISSIONS)
    if driverCut > 0 then
        self:_addMoney(-driverCut, farmId, MoneyType.AI)
    end

    -- Company books always move, whether or not a truck was assigned.
    company.ledger.revenue = company.ledger.revenue + companyRevenue
    company.ledger.driverWages = company.ledger.driverWages + driverCut
    company.ledger.jobs = company.ledger.jobs + 1

    -- P&L rollup for the Ledger tab's weekly history.
    self:_rollLedgerPeriod(company, companyRevenue, driverCut, 1,
        truck ~= nil and truck.distanceM or 0)

    -- Reputation: an on-time delivery builds the company. Urgent jobs
    -- earn a touch more; bulk a touch less, matching the reward curve.
    local reputationGain = TransportCompanyCompany.REPUTATION_ON_COMPLETE
    if contract.tier == TransportCompanyContract.CONTRACT_TIER_URGENT then
        reputationGain = 3
    elseif contract.tier == TransportCompanyContract.CONTRACT_TIER_BULK then
        reputationGain = 1
    end
    company:addReputation(reputationGain)

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

        -- A named driver assigned to this truck rides the job: their
        -- record gains experience and a job count on top of the money.
        if contract.isHiredDriver then
            local driver = company:getDriverForTruck(truck.uniqueId)
            if driver ~= nil then
                driver:addJob(reputationGain)
            end
        end
    end

    -- Push the updated ledger and truck books to clients in one
    -- authoritative snapshot (the money events above already nudge the
    -- per-truck numbers; the snapshot keeps the company totals right).
    self:_broadcastBooks(farmId)

    TransportCompanyContractEvent.sendEvent(
        TransportCompanyContractEvent.TYPE_STATE_CHANGE, contract,
        TransportCompanyContract.STATE_COMPLETED, farmId
    )
    self:_notify(string.format(
        g_i18n:getText("transportCompany_contractDelivered"),
        contract:getLocalizedFillType(),
        g_i18n:formatMoney(companyRevenue, 0, true, true)
    ), farmId)

    TransportCompanyLog.info(
        "Contract %s completed (farm %s): reward=%d driverCut=%d company=%d",
        contract.contractId, tostring(farmId), contract.reward, driverCut, companyRevenue
    )

    -- Free the board slot so a fresh job appears.
    self:_regenerateContractBoard(farmId)
end

---Show a base-game side notification, when the player wants them.
---Needs a local HUD, which a dedicated server does not have — there
---the call is simply skipped. Notification preference is the company's
---own showNotifications setting.
---@param text string
---@param farmId number|nil Company whose notification setting applies
function TransportCompanyManager:_notify(text, farmId)
    local show = true
    if farmId ~= nil then
        local company = self:getCompany(farmId)
        if company ~= nil then
            show = company.settings:get("showNotifications") ~= false
        end
    else
        show = self.settings:get("showNotifications") ~= false
    end
    if not show then return end
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
        for _, company in pairs(self.companies) do
            for _, contract in pairs(company.contracts) do
                if contract.isHiredDriver and contract.hiredDriverJobId == job.jobId then
                    self:_completeHiredDriverContract(company, contract, job)
                    break
                end
            end
        end
        return
    end

    for _, company in pairs(self.companies) do
        for _, contract in pairs(company.contracts) do
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
                company.stuckWatch[contract.contractId] = nil
                TransportCompanyContractEvent.sendEvent(
                    TransportCompanyContractEvent.TYPE_UPDATE, contract, nil, company.farmId
                )
                self:_refreshDispatchUI()
                break
            end
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
---@param company TransportCompanyCompany
---@param contract TransportCompanyContract
---@param job table The completed AI job
function TransportCompanyManager:_completeHiredDriverContract(company, contract, job)
    self:_completeContract(company, contract)
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

---Read a farm's current account balance. The base game exposes the
---balance on the Farm object, not the mission (Farm:getBalance,
---Farm.md:148-161); g_farmManager:getFarmById resolves the farm.
---@param farmId number
---@return number balance, 0 when the farm cannot be resolved
function TransportCompanyManager:_getFarmMoney(farmId)
    if farmId == nil or farmId <= 0 or g_farmManager == nil then
        return 0
    end
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.getBalance == nil then
        return 0
    end
    return farm:getBalance() or 0
end

-- ── Money Event Handling ──────────────────────

---Build and broadcast a full snapshot of one company's ledger and
---every truck's books. Server only. Clients have no other source for
---fuel and distance (both are sampled per-tick on the server and never
---sent individually), and the ledger totals live only on the server, so
---without this a client in multiplayer would show zero fuel, distance
---and company revenue in the Fleet and Ledger tabs.
---
---Sent on every contract completion (authoritative right after a
---payout) and periodically (see update()) so drifting figures and late
---joins converge within one interval.
---@param farmId number Company whose books to broadcast
function TransportCompanyManager:_broadcastBooks(farmId)
    if not self.isServer then return end

    local company = self:getCompany(farmId)
    if company == nil then return end
    if next(company.trucks) == nil and company.ledger.jobs == 0 then
        return
    end

    local event = TransportCompanyBooksEvent.new(farmId)
    event.ledgerRevenue = company.ledger.revenue
    event.ledgerDriverWages = company.ledger.driverWages
    event.ledgerJobs = company.ledger.jobs
    event.reputation = company.reputation or 0
    event.hqLevel = company.hqLevel or TransportCompanyCompany.HQ_BASE_LEVEL
    event.trucks = {}
    for uniqueId, truck in pairs(company.trucks) do
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
    event.drivers = {}
    for _, driver in pairs(company.drivers) do
        table.insert(event.drivers, driver)
    end
    event.ledgerHistory = company.ledgerHistory or {}
    TransportCompanyBooksEvent.sendEvent(event)
end

---Apply a TransportCompanyBooksEvent snapshot (client side). Replaces
---the company ledger and the listed trucks' books with the server's
---authoritative values. A truck the client has not enrolled yet gets a
---placeholder entry so the Fleet and Ledger tabs render immediately;
---_enrollTrucks replaces it with the live vehicle on its next pass.
---@param event TransportCompanyBooksEvent
---@param farmId number Company the snapshot belongs to
function TransportCompanyManager:onBooksEvent(event, farmId)
    if event == nil or self.isServer then return end

    local company = self:getOrCreateCompany(farmId)
    if company == nil then return end

    company.ledger.revenue = event.ledgerRevenue or 0
    company.ledger.driverWages = event.ledgerDriverWages or 0
    company.ledger.jobs = event.ledgerJobs or 0
    company.reputation = event.reputation or 0
    company.hqLevel = event.hqLevel or TransportCompanyCompany.HQ_BASE_LEVEL

    for _, t in ipairs(event.trucks or {}) do
        if t.uniqueId ~= nil and t.uniqueId ~= "" then
            local truck = company.trucks[t.uniqueId]
            if truck == nil then
                truck = TransportCompanyTruck.new({
                    getUniqueId = function() return t.uniqueId end,
                    getFullName = function() return t.vehicleName or "Truck" end,
                    getOwnerFarmId = function() return t.farmId or farmId end,
                })
                company.trucks[t.uniqueId] = truck
            end
            truck.revenue = t.revenue or 0
            truck.fuelCost = t.fuelCost or 0
            truck.otherCost = t.otherCost or 0
            truck.distanceM = t.distanceM or 0
            truck.jobsDelivered = t.jobsDelivered or 0
        end
    end

    -- Named drivers arrive as records; rebuild the roster keyed by id.
    company.drivers = {}
    for _, d in ipairs(event.drivers or {}) do
        if d.driverId ~= nil and d.driverId ~= "" then
            company.drivers[d.driverId] = d
        end
    end

    company.ledgerHistory = event.ledgerHistory or {}

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

    local company = self:getCompany(farmId)
    if company == nil then return end

    local truck = company.trucks[truckUniqueId]
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
---@param farmId number Company the contract belongs to
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

function TransportCompanyManager:onContractEvent(eventType, contract, state, farmId)
    if contract == nil then return end

    local company = self:getOrCreateCompany(farmId)
    if company == nil then return end

    if eventType == TransportCompanyContractEvent.TYPE_ADD then
        company.contracts[contract.contractId] = contract
    elseif eventType == TransportCompanyContractEvent.TYPE_UPDATE then
        company.contracts[contract.contractId] = contract
    elseif eventType == TransportCompanyContractEvent.TYPE_STATE_CHANGE then
        contract.state = state
        if state == TransportCompanyContract.STATE_COMPLETED then
            self:_cleanupCompletedContracts(company)
        end
    elseif eventType == TransportCompanyContractEvent.TYPE_REMOVE then
        company.contracts[contract.contractId] = nil
    end

    self:_refreshDispatchUI()
end

---Remove contracts that are completed/expired and older than
---7 days to keep the savegame XML lean.
---@param company TransportCompanyCompany
function TransportCompanyManager:_cleanupCompletedContracts(company)
    local now = g_currentMission.time
    local maxAge = TransportCompanyContract.DAY_LENGTH * 7

    for contractId, contract in pairs(company.contracts) do
        if contract.state == TransportCompanyContract.STATE_COMPLETED or
           contract.state == TransportCompanyContract.STATE_EXPIRED then
            if contract.completedTime > 0 and (now - contract.completedTime) > maxAge then
                company.contracts[contractId] = nil
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

    addConsoleCommand(
        "tc_drivers",
        "List drivers on the payroll and their assigned trucks",
        "consoleCommandListDrivers",
        self
    )

    addConsoleCommand(
        "tc_hire_driver",
        "Hire a named driver (debug)",
        "consoleCommandHireDriver",
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

    local farmId = self:_getCompanyFarmId()
    local company = self:getCompany(farmId)
    if company == nil then
        print("TransportCompany: no company (place an HQ first)")
        return
    end

    local contract = TransportCompanyContract.generate(
        company.settings:get("contractDeadlineDays") or 7,
        farmId
    )
    if contract then
        company.contracts[contract.contractId] = contract
        TransportCompanyContractEvent.sendEvent(
            TransportCompanyContractEvent.TYPE_ADD, contract, nil, farmId
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
    local company = self:getLocalCompany()
    if company == nil then
        print("TransportCompany: no company for your farm (place an HQ first)")
        return
    end
    local count = 0
    for id, contract in pairs(company.contracts) do
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
    local company = self:getLocalCompany()
    if company == nil then
        print("TransportCompany: no company for your farm (place an HQ first)")
        return
    end
    local count = 0
    for uniqueId, truck in pairs(company.trucks) do
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
---rules would never have produced. Operates on the calling farm's
---company.
function TransportCompanyManager:consoleCommandResetBoard()
    if not self.isServer then
        print("TransportCompany: only the server can reset the board")
        return
    end

    local farmId = self:_getCompanyFarmId()
    local company = self:getCompany(farmId)
    if company == nil then
        print("TransportCompany: no company (place an HQ first)")
        return
    end

    local removed = 0
    for id, contract in pairs(company.contracts) do
        if contract.state ~= TransportCompanyContract.STATE_COMPLETED then
            company.contracts[id] = nil
            removed = removed + 1
        end
    end

    self:_regenerateContractBoard(farmId)

    local now = 0
    for _ in pairs(company.contracts) do now = now + 1 end
    print(string.format(
        "TransportCompany: cleared %d contract(s), board now holds %d",
        removed, now))
end

function TransportCompanyManager:consoleCommandResetSettings()
    -- Reset the global/local-only settings (debugMode) and the calling
    -- farm's company settings.
    self.settings:resetToDefaults()
    self.settings:save()
    local company = self:getLocalCompany()
    if company ~= nil then
        company.settings:resetToDefaults()
        company.settings:save()
    end
    print("TransportCompany: settings reset to defaults")
end

function TransportCompanyManager:consoleCommandListDrivers()
    local company = self:getLocalCompany()
    if company == nil then
        print("TransportCompany: no company for your farm (place an HQ first)")
        return
    end
    print(string.format("TransportCompany: %d/%d drivers, reputation %d, HQ tier %d",
        company:getDriverCount(), company:getDriverCap(),
        math.floor(company.reputation), company.hqLevel))
    for id, driver in pairs(company.drivers) do
        print(string.format("  %s (%s): wage=%d exp=%d jobs=%d truck=%s",
            id, driver.name or "?", driver:getCurrentWage(),
            math.floor(driver.experience), driver.jobsDone,
            driver.assignedTruckUniqueId ~= "" and driver.assignedTruckUniqueId or "-"))
    end
end

function TransportCompanyManager:consoleCommandHireDriver()
    if not self.isServer then
        print("TransportCompany: only the server can hire drivers")
        return
    end
    local farmId = self:_getCompanyFarmId()
    if self:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, farmId, nil, nil) then
        print("TransportCompany: driver hired")
    else
        print("TransportCompany: could not hire a driver (cap or funds)")
    end
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