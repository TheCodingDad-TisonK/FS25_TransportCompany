-- =========================================================
-- FS25 Transport Company - Contract Model
-- =========================================================
-- A transport contract: haul a load from a source station to a
-- destination station for a reward.
--
-- Two contract kinds are generated (mirrors the base game's own
-- TransportMission split):
--
--   BULK   - deliver N liters of a fill type. Executed by the
--            player (load at the source trigger, unload at the
--            destination trigger) or by a hired driver via the
--            base game AI (AIJobLoadAndDeliver).
--   PALLET - deliver N objects of a pallet-producing fill type.
--            Counted by object triggers at the destination.
--
-- Ground truth (decompiled base game):
--   - TransportMission.lua constants: CONTRACT_DURATION=115200000,
--     CONTRACT_DURATION_VAR=57600000, REWARD_PER_METER=0.5,
--     REWARD_PER_OBJECT=350, NUM_OBJECTS_PER_DRIVE=5.
--   - LoadingStation:getSupportedFillTypes() / :getIsFillTypeSupported()
--     (LoadingStation.lua:156-165); UnloadingStation equivalents
--     (UnloadingStation.lua:195-205).
--   - Station references persist via placeable uniqueId + station
--     index (AIParameterLoadingStation:setLoadingStationFromUniqueId,
--     StorageSystem:getPlaceableLoadingStation(placeable, index)).
--   - Money: server-only g_currentMission:addMoney(amount, farmId,
--     moneyType, addChange, forceShowChange); farmId 0 rejected.
-- =========================================================

local modName = g_currentModName

TransportCompanyContract = {}
TransportCompanyContract.CONTRACT_TYPE_BULK = 1
TransportCompanyContract.CONTRACT_TYPE_PALLET = 2

-- Contract lifecycle states.
TransportCompanyContract.STATE_AVAILABLE = 1
TransportCompanyContract.STATE_ACCEPTED = 2
TransportCompanyContract.STATE_COMPLETED = 3
TransportCompanyContract.STATE_EXPIRED = 4

-- Day length in ms (base game: 86400000).
TransportCompanyContract.DAY_LENGTH = 86400000

-- Base reward curve. The bulk reward is distance-driven: goods value
-- and a per-meter haul component. RATE_PER_METER is calibrated so the
-- 1.0-era reward (amount × price × 0.15) is the low band and a long
-- haul pays meaningfully more than a short one. The base game's own
-- TransportMission pays REWARD_PER_METER=0.5, but its exact call is
-- not in the reference set; straight-line distance is the documented
-- proxy (calcDistanceFrom, Node.md), so the rate is tuned in-game.
-- A truck burns roughly EST_FUEL_L_PER_KM on a loaded run; that feed
-- is only an estimate for the PDA economics panel, never a charge.
TransportCompanyContract.REWARD_PER_LITER = 0.005
TransportCompanyContract.REWARD_PER_OBJECT = 350
TransportCompanyContract.RATE_PER_METER = 0.2
TransportCompanyContract.PALLET_PRICE_FACTOR = 0.8
TransportCompanyContract.EST_FUEL_L_PER_KM = 0.4
TransportCompanyContract.MIN_ROUTE_DISTANCE_M = 50
TransportCompanyContract.MAX_TRIPS_PER_JOB = 3

-- Difficulty tiers. Standard is the default; URGENT pays more for a
-- shorter deadline; BULK moves more volume for a tighter margin.
TransportCompanyContract.CONTRACT_TIER_STANDARD = 1
TransportCompanyContract.CONTRACT_TIER_URGENT = 2
TransportCompanyContract.CONTRACT_TIER_BULK = 3

-- Delivery is always measured in LITERS, because that is the only
-- quantity the engine reports at a station
-- (UnloadingStation:addFillLevelFromTool returns moved liters).
-- A pallet contract expresses its amount in pallets, so it carries a
-- conversion factor. 1000 L is the standard FS pallet capacity; the
-- game's pallet XMLs live outside dataS and cannot be read here, so
-- this is a deliberate fixed assumption rather than a lookup.
TransportCompanyContract.LITERS_PER_PALLET = 1000

-- Bumped whenever generation changes in a way that makes older saved
-- contracts unplayable. Contracts written by an earlier generator are
-- dropped on load rather than sitting on the board failing forever:
-- before this existed, a save carried five jobs whose source stations
-- could not supply them, and every hire attempt was refused.
TransportCompanyContract.GENERATOR_VERSION = 4

---@class TransportCompanyContract
TransportCompanyContract_mt = Class(TransportCompanyContract)

function TransportCompanyContract.new()
    local self = setmetatable({}, TransportCompanyContract_mt)
    self.contractId = nil
    self.contractType = TransportCompanyContract.CONTRACT_TYPE_BULK
    self.tier = TransportCompanyContract.CONTRACT_TIER_STANDARD
    self.state = TransportCompanyContract.STATE_AVAILABLE
    self.fillTypeIndex = nil
    self.amount = 0              -- liters (BULK) or pallets (PALLET)
    self.delivered = 0           -- same unit as amount
    self.litersPerUnit = 1       -- 1 for BULK, LITERS_PER_PALLET for PALLET
    self.reward = 0              -- total reward on completion
    self.routeDistanceM = 0      -- straight-line source→dest distance
    -- Source station reference: placeable uniqueId + station index
    -- (matches AIParameterLoadingStation persistence: owningPlaceable
    -- uniqueId + getPlaceableLoadingStationIndex, see
    -- AIParameterLoadingStation.lua:11-17)
    self.sourceUniqueId = nil
    self.sourceStationIndex = nil
    self.sourceName = ""
    -- Destination station reference
    self.destUniqueId = nil
    self.destStationIndex = nil
    self.destName = ""
    -- Timing (game ms, g_currentMission.time). 0 means "not set" —
    -- never nil, so every comparison below is safe without a guard.
    self.acceptedTime = 0
    self.deadline = 0
    -- Execution bookkeeping.
    -- Vehicle uniqueIds are STRINGS ("vehicle" .. md5, see
    -- Utils.getUniqueId / VehicleSystem.lua:170), so "" is the empty
    -- value here, not 0.
    self.acceptedTruckUniqueId = ""
    self.farmId = 0                  -- farm that accepted the contract
    self.isHiredDriver = false
    self.hiredDriverJobId = 0        -- base game AI job id while driving
    self.completedTime = 0
    self.generatorVersion = TransportCompanyContract.GENERATOR_VERSION
    return self
end

-- ── Persistence ────────────────────────────────────────────

--- Network sync: write the contract state for TransportCompanyContractEvent.
function TransportCompanyContract:writeStream(streamId, connection)
    streamWriteString(streamId, self.contractId or "")
    streamWriteInt8(streamId, self.contractType)
    streamWriteInt8(streamId, self.tier or TransportCompanyContract.CONTRACT_TIER_STANDARD)
    streamWriteInt8(streamId, self.state)
    streamWriteInt16(streamId, self.fillTypeIndex or FillType.UNKNOWN)
    streamWriteFloat32(streamId, self.amount)
    streamWriteFloat32(streamId, self.delivered)
    streamWriteFloat32(streamId, self.reward)
    streamWriteFloat32(streamId, self.litersPerUnit or 1)
    streamWriteFloat32(streamId, self.routeDistanceM or 0)
    streamWriteString(streamId, self.sourceUniqueId or "")
    streamWriteInt16(streamId, self.sourceStationIndex or 0)
    streamWriteString(streamId, self.sourceName or "")
    streamWriteString(streamId, self.destUniqueId or "")
    streamWriteInt16(streamId, self.destStationIndex or 0)
    streamWriteString(streamId, self.destName or "")
    streamWriteFloat32(streamId, self.acceptedTime or 0)
    streamWriteFloat32(streamId, self.deadline or 0)
    streamWriteString(streamId, self.acceptedTruckUniqueId or "")
    streamWriteInt32(streamId, self.farmId or 0)
    streamWriteBool(streamId, self.isHiredDriver)
    streamWriteInt32(streamId, self.hiredDriverJobId or 0)
    streamWriteFloat32(streamId, self.completedTime or 0)
end

--- Network sync: read the contract state (TransportCompanyContractEvent).
function TransportCompanyContract:readStream(streamId, connection)
    self.contractId = streamReadString(streamId)
    self.contractType = streamReadInt8(streamId)
    self.tier = streamReadInt8(streamId)
    self.state = streamReadInt8(streamId)
    self.fillTypeIndex = streamReadInt16(streamId)
    self.amount = streamReadFloat32(streamId)
    self.delivered = streamReadFloat32(streamId)
    self.reward = streamReadFloat32(streamId)
    self.litersPerUnit = streamReadFloat32(streamId)
    self.routeDistanceM = streamReadFloat32(streamId)
    self.sourceUniqueId = streamReadString(streamId)
    self.sourceStationIndex = streamReadInt16(streamId)
    self.sourceName = streamReadString(streamId)
    self.destUniqueId = streamReadString(streamId)
    self.destStationIndex = streamReadInt16(streamId)
    self.destName = streamReadString(streamId)
    self.acceptedTime = streamReadFloat32(streamId)
    self.deadline = streamReadFloat32(streamId)
    self.acceptedTruckUniqueId = streamReadString(streamId)
    self.farmId = streamReadInt32(streamId)
    self.isHiredDriver = streamReadBool(streamId)
    self.hiredDriverJobId = streamReadInt32(streamId)
    self.completedTime = streamReadFloat32(streamId)
end

function TransportCompanyContract:saveToXMLFile(xmlFile, key)
    xmlFile:setString(key .. "#contractId", self.contractId or "")
    xmlFile:setInt(key .. "#contractType", self.contractType)
    xmlFile:setInt(key .. "#tier", self.tier or TransportCompanyContract.CONTRACT_TIER_STANDARD)
    xmlFile:setInt(key .. "#state", self.state)
    xmlFile:setInt(key .. "#fillTypeIndex", self.fillTypeIndex or FillType.UNKNOWN)
    xmlFile:setFloat(key .. "#amount", self.amount)
    xmlFile:setFloat(key .. "#delivered", self.delivered)
    xmlFile:setFloat(key .. "#reward", self.reward)
    xmlFile:setFloat(key .. "#litersPerUnit", self.litersPerUnit or 1)
    xmlFile:setFloat(key .. "#routeDistanceM", self.routeDistanceM or 0)
    xmlFile:setString(key .. "#sourceUniqueId", self.sourceUniqueId or "")
    xmlFile:setInt(key .. "#sourceStationIndex", self.sourceStationIndex or 0)
    xmlFile:setString(key .. "#sourceName", self.sourceName or "")
    xmlFile:setString(key .. "#destUniqueId", self.destUniqueId or "")
    xmlFile:setInt(key .. "#destStationIndex", self.destStationIndex or 0)
    xmlFile:setString(key .. "#destName", self.destName or "")
    xmlFile:setFloat(key .. "#acceptedTime", self.acceptedTime or 0)
    xmlFile:setFloat(key .. "#deadline", self.deadline or 0)
    xmlFile:setString(key .. "#acceptedTruckUniqueId", self.acceptedTruckUniqueId or "")
    xmlFile:setInt(key .. "#farmId", self.farmId or 0)
    xmlFile:setBool(key .. "#isHiredDriver", self.isHiredDriver)
    xmlFile:setInt(key .. "#hiredDriverJobId", self.hiredDriverJobId or 0)
    xmlFile:setFloat(key .. "#completedTime", self.completedTime or 0)
    xmlFile:setInt(key .. "#generatorVersion", self.generatorVersion or 0)
end

---Load contract data from XML (instance method — populates self).
function TransportCompanyContract:loadFromXMLFile(xmlFile, key)
    self.contractId = xmlFile:getString(key .. "#contractId")
    self.contractType = xmlFile:getInt(key .. "#contractType", TransportCompanyContract.CONTRACT_TYPE_BULK)
    self.tier = xmlFile:getInt(key .. "#tier", TransportCompanyContract.CONTRACT_TIER_STANDARD)
    self.state = xmlFile:getInt(key .. "#state", TransportCompanyContract.STATE_AVAILABLE)
    self.fillTypeIndex = xmlFile:getInt(key .. "#fillTypeIndex", FillType.UNKNOWN)
    self.amount = xmlFile:getFloat(key .. "#amount", 0)
    self.delivered = xmlFile:getFloat(key .. "#delivered", 0)
    self.reward = xmlFile:getFloat(key .. "#reward", 0)
    self.litersPerUnit = xmlFile:getFloat(key .. "#litersPerUnit", 1)
    self.routeDistanceM = xmlFile:getFloat(key .. "#routeDistanceM", 0)
    self.sourceUniqueId = xmlFile:getString(key .. "#sourceUniqueId")
    self.sourceStationIndex = xmlFile:getInt(key .. "#sourceStationIndex", 1)
    self.sourceName = xmlFile:getString(key .. "#sourceName", "")
    self.destUniqueId = xmlFile:getString(key .. "#destUniqueId")
    self.destStationIndex = xmlFile:getInt(key .. "#destStationIndex", 1)
    self.destName = xmlFile:getString(key .. "#destName", "")
    self.acceptedTime = xmlFile:getFloat(key .. "#acceptedTime", 0)
    self.deadline = xmlFile:getFloat(key .. "#deadline", 0)
    self.acceptedTruckUniqueId = xmlFile:getString(key .. "#acceptedTruckUniqueId", "")
    self.farmId = xmlFile:getInt(key .. "#farmId", 0)
    self.isHiredDriver = xmlFile:getBool(key .. "#isHiredDriver", false)
    self.hiredDriverJobId = xmlFile:getInt(key .. "#hiredDriverJobId", 0)
    self.completedTime = xmlFile:getFloat(key .. "#completedTime", 0)
    -- absent on contracts written before versioning existed
    self.generatorVersion = xmlFile:getInt(key .. "#generatorVersion", 0)
end

---Validate the saved station references against the live world.
---Called after loading from XML, once the placeable system is up.
---
---The saved (uniqueId, index) pair IS the reference — nothing needs
---converting. StorageSystem:getPlaceableLoadingStationIndex takes a
---station OBJECT and returns its index (StorageSystem.lua:103), so
---feeding it the stored index would be meaningless. All this does is
---confirm the pair still resolves; a contract whose station was
---demolished between saves is unplayable and reports false.
---@return boolean isValid
function TransportCompanyContract:_resolveStationRefs()
    return self:getSourceStation() ~= nil and self:getDestStation() ~= nil
end

-- ── Station resolution (live objects) ──────────────────────

--- Resolve the source station object via placeable uniqueId + index.
function TransportCompanyContract:getSourceStation()
    if self.sourceUniqueId == nil then
        return nil
    end
    local placeable = g_currentMission.placeableSystem:getPlaceableByUniqueId(self.sourceUniqueId)
    if placeable == nil then
        return nil
    end
    return g_currentMission.storageSystem:getPlaceableLoadingStation(placeable, self.sourceStationIndex)
end

--- Resolve the destination station object.
function TransportCompanyContract:getDestStation()
    if self.destUniqueId == nil then
        return nil
    end
    local placeable = g_currentMission.placeableSystem:getPlaceableByUniqueId(self.destUniqueId)
    if placeable == nil then
        return nil
    end
    return g_currentMission.storageSystem:getPlaceableUnloadingStation(placeable, self.destStationIndex)
end

-- ── Progress / completion helpers ──────────────────────────

function TransportCompanyContract:getFillTypeName()
    if self.fillTypeIndex == nil then
        return ""
    end
    return g_fillTypeManager:getFillTypeNameByIndex(self.fillTypeIndex) or ""
end

--- Display name of the hauled goods.
---
--- getFillTypeTitleByIndex already returns a localized title
--- (FillTypeManager.lua:295 reads indexToTitle, which FillTypeDesc
--- resolved at load). Passing it through g_i18n:getText a second time
--- looked it up as if it were a key, and because a mod gets its own
--- mod-scoped g_i18n the miss surfaced in the UI as
--- "Missing 'Soybeans' in l10n_en.xml".
function TransportCompanyContract:getLocalizedFillType()
    if self.fillTypeIndex == nil then
        return ""
    end
    return g_fillTypeManager:getFillTypeTitleByIndex(self.fillTypeIndex) or ""
end

function TransportCompanyContract:getProgressRatio()
    if self.amount <= 0 then
        return 0
    end
    return math.min(1, self.delivered / self.amount)
end

--- Is the contract complete (delivered >= amount)?
function TransportCompanyContract:getIsComplete()
    return self.state == TransportCompanyContract.STATE_COMPLETED
        or (self.delivered >= self.amount - 0.001)
end

--- Time remaining in ms; nil when no deadline is set.
function TransportCompanyContract:getTimeLeft()
    if self.deadline == nil or self.deadline == 0 or g_currentMission == nil then
        return nil
    end
    return self.deadline - g_currentMission.time
end

--- Is the contract past its deadline?
---@param now number|nil Optional clock override (defaults to mission time)
function TransportCompanyContract:getIsExpired(now)
    if self.deadline == nil or self.deadline == 0 then
        return false
    end
    now = now or (g_currentMission ~= nil and g_currentMission.time)
    if now == nil then
        return false
    end
    return self.deadline - now <= 0
end

--- Can the base game AI actually run this job for a farm?
---
--- AIParameterLoadingStation:validate applies two tests my generation
--- does not: the fill type has to be AI-supported (a narrower set than
--- getSupportedFillTypes), and getFillLevel is farm-access gated. A
--- station can hold plenty and still be "empty" to a given farm, which
--- is why hiring failed on contracts that looked perfectly fine.
---@return boolean haulable, string|nil reasonKey
function TransportCompanyContract:getIsAiHaulable(farmId)
    if farmId == nil or farmId <= 0 then
        return false, "transportCompany_hireNoFarm"
    end

    local source = self:getSourceStation()
    if source == nil then
        return false, "transportCompany_hireNoStation"
    end
    if self:getDestStation() == nil then
        return false, "transportCompany_hireNoStation"
    end

    local dest = self:getDestStation()

    -- Source, mirroring AIParameterLoadingStation:validate
    if source.getIsFillTypeAISupported ~= nil
       and not source:getIsFillTypeAISupported(self.fillTypeIndex) then
        return false, "transportCompany_hireNotAiFillType"
    end

    if source.getFillLevel ~= nil
       and (source:getFillLevel(self.fillTypeIndex, farmId) or 0) <= 0 then
        return false, "transportCompany_hireStationEmpty"
    end

    -- Destination, mirroring AIParameterUnloadingStation:validate
    -- (AIParameterUnloadingStation.lua:112-119). None of this was
    -- checked before, which is why a job could pass every source test,
    -- dispatch a driver, and then fail with the station full or the
    -- target unreachable once the AI was already rolling.
    if dest.getIsFillTypeAISupported ~= nil
       and not dest:getIsFillTypeAISupported(self.fillTypeIndex) then
        return false, "transportCompany_hireDestNotAi"
    end

    if dest.getFreeCapacity ~= nil
       and (dest:getFreeCapacity(self.fillTypeIndex, farmId) or 0) <= 0 then
        return false, "transportCompany_hireDestFull"
    end

    -- Both ends need somewhere the AI can actually drive to. A station
    -- with no AI-capable trigger returns nil here, and the driver sets
    -- off only to report the target unreachable.
    if not TransportCompanyContract.getHasAiTarget(source, self.fillTypeIndex)
       or not TransportCompanyContract.getHasAiTarget(dest, self.fillTypeIndex) then
        return false, "transportCompany_hireNoRoute"
    end

    return true, nil
end

---Does a station expose a position the AI can drive to?
---LoadingStation and UnloadingStation both return nil when no trigger
---supports AI (LoadingStation.lua:312, UnloadingStation.lua:312-325).
function TransportCompanyContract.getHasAiTarget(station, fillTypeIndex)
    if station == nil or station.getAITargetPositionAndDirection == nil then
        return false
    end
    local ok, x = pcall(station.getAITargetPositionAndDirection, station, fillTypeIndex)
    return ok and x ~= nil
end

-- ── Lifecycle transitions ──────────────────────────────────
-- Server-side state changes. The manager broadcasts a
-- TransportCompanyContractEvent after each of these so clients
-- follow along.

--- Accept the contract for a farm, optionally assigning a truck.
---@param farmId number Farm taking the job
---@param truckUniqueId string|nil Vehicle uniqueId (a STRING, see new())
---@param isHiredDriver boolean|nil Job is hauled by the base game AI
---@return boolean accepted
function TransportCompanyContract:accept(farmId, truckUniqueId, isHiredDriver)
    if self.state ~= TransportCompanyContract.STATE_AVAILABLE then
        return false
    end
    self.state = TransportCompanyContract.STATE_ACCEPTED
    self.farmId = farmId or 0
    self.acceptedTruckUniqueId = truckUniqueId or ""
    self.isHiredDriver = isHiredDriver == true
    self.acceptedTime = g_currentMission ~= nil and g_currentMission.time or 0
    return true
end

--- Mark the contract completed and stamp the completion time.
---@return boolean changed False when it was already completed
function TransportCompanyContract:complete()
    if self.state == TransportCompanyContract.STATE_COMPLETED then
        return false
    end
    self.state = TransportCompanyContract.STATE_COMPLETED
    self.delivered = self.amount
    self.completedTime = g_currentMission ~= nil and g_currentMission.time or 0
    return true
end

--- Mark the contract expired (deadline passed without delivery).
---@return boolean changed
function TransportCompanyContract:expire()
    if self.state == TransportCompanyContract.STATE_COMPLETED or
       self.state == TransportCompanyContract.STATE_EXPIRED then
        return false
    end
    self.state = TransportCompanyContract.STATE_EXPIRED
    self.completedTime = g_currentMission ~= nil and g_currentMission.time or 0
    return true
end

--- Add delivered amount in contract units. Returns true when this
--- delivery pushed the contract to completion.
function TransportCompanyContract:addDelivered(delta)
    if delta <= 0 or self:getIsComplete() then
        return false
    end
    self.delivered = self.delivered + delta
    if self.delivered >= self.amount then
        self.delivered = self.amount
        return true
    end
    return false
end

--- How many more LITERS this contract still needs.
function TransportCompanyContract:getRemainingLiters()
    local remainingUnits = self.amount - self.delivered
    if remainingUnits <= 0 then
        return 0
    end
    return remainingUnits * (self.litersPerUnit or 1)
end

--- Credit a delivery measured in liters (what a station reports).
--- Only consumes what the contract still needs, so the surplus of an
--- over-large tipper can roll on to another open contract.
---@param liters number Liters just unloaded at the destination
---@return number consumedLiters, boolean isNowComplete
function TransportCompanyContract:addDeliveredLiters(liters)
    if liters == nil or liters <= 0 or self:getIsComplete() then
        return 0, false
    end
    local consumed = math.min(liters, self:getRemainingLiters())
    if consumed <= 0 then
        return 0, false
    end
    local isComplete = self:addDelivered(consumed / (self.litersPerUnit or 1))
    return consumed, isComplete
end

--- Reward to pay out on completion (hired driver share is applied
--- by the manager: driver keeps hiredDriverRewardShare %).
function TransportCompanyContract:getCompletionReward()
    return self.reward
end

--- Build the display unit suffix for the amount (liters / objects).
--- The liter unit is shipped by the mod itself: the base-game key is not
--- part of the mod's translation scope, so referencing it can surface as
--- a missing-key string in the UI.
function TransportCompanyContract:getAmountUnitText()
    if self.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET then
        return g_i18n:getText("transportCompany_unitObjects")
    end
    return g_i18n:getText("transportCompany_unitLiters")
end

-- ── Contract generator ─────────────────────────────────────
-- Scans the live station lists and emits a fresh contract.
-- Returns a new contract or nil when no valid route exists.

-- A source has to hold at least this much before a contract is offered
-- for it, so the job is actually haulable when it appears.
TransportCompanyContract.MIN_SOURCE_LITERS = 1000

-- Reported for a fill type a station dispenses with no storage behind
-- it. These are declared straight in the station XML
-- (LoadingStation.lua:47-61) and never run out -- a shop selling seed,
-- fertilizer or lime. Treating them as empty made every map look
-- barren: 26 stations and 108 routes all reading zero.
TransportCompanyContract.UNLIMITED_STOCK = 1000000

---How much of a fill type a station lets THIS farm load.
---
---A contract is only runnable if the farm can actually take goods from
---the source. The load prompt (R) only appears when
---LoadTrigger:getIsFillableObjectAvailable passes, which requires
---source:getIsFillAllowedToFarm(farmId) (LoadTrigger.lua:299). For a
---plain LoadingStation that is gated on hasFarmAccessToStorage /
---accessHandler:canFarmAccess (LoadingStation.lua:239-252): the farm
---must own the storage, or the storage must be public. Buying stations
---(seed/fertilizer/lime shops) always allow (BuyingStation.lua:123).
---
---Earlier versions counted PHYSICAL stock by reading sourceStorage
---fill levels directly, which filled the board with contracts from
---stations the player could not load from ("no trigger to load when I
---arrive"). Stock is now access-aware: an inaccessible source reports
---zero and is never offered.
---@return number liters
function TransportCompanyContract.getStationStock(station, fillTypeIndex, farmId)
    -- A job is only runnable if the farm can actually load here. This is
    -- the exact gate the LoadTrigger applies before showing the prompt.
    if farmId ~= nil and farmId > 0 and station.getIsFillAllowedToFarm ~= nil then
        if not station:getIsFillAllowedToFarm(farmId) then
            return 0
        end
    end

    -- Infinite-supply goods first: no storage will ever back these.
    -- Buying stations (which always allow access) are the shops selling
    -- seed, fertilizer or lime.
    if station.basicFillTypes ~= nil and station.basicFillTypes[fillTypeIndex] then
        return TransportCompanyContract.UNLIMITED_STOCK
    end

    -- Access-gated fill level: LoadingStation:getFillLevel already
    -- filters every source storage through hasFarmAccessToStorage, so
    -- this is exactly what the player could physically draw right now.
    if station.getFillLevel ~= nil and farmId ~= nil and farmId > 0 then
        return station:getFillLevel(fillTypeIndex, farmId) or 0
    end

    -- Fallback for farmId 0 / unowned diagnostic contexts: physical stock.
    local total = 0
    if station.sourceStorages ~= nil then
        for _, storage in pairs(station.sourceStorages) do
            if storage.getFillLevel ~= nil then
                total = total + (storage:getFillLevel(fillTypeIndex) or 0)
            end
        end
    end
    return total
end

---Count what the map can actually offer, for diagnostics.
---@return number aiHaulable, number stocked, number routes, number stations, number withoutPlaceable
function TransportCompanyContract.countRoutes(farmId)
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem
    if storageSystem == nil then
        return 0, 0
    end

    local ai, stocked, any, stations, orphan = 0, 0, 0, 0, 0
    for station, _ in pairs(storageSystem.loadingStations) do
        if station ~= nil then
            stations = stations + 1
            if station.owningPlaceable == nil then
                orphan = orphan + 1
            else
                local fillTypes = station:getSupportedFillTypes()
                if fillTypes ~= nil then
                    for fillTypeIndex, _ in pairs(fillTypes) do
                        if fillTypeIndex ~= FillType.UNKNOWN then
                            any = any + 1
                            local stock = TransportCompanyContract.getStationStock(
                                station, fillTypeIndex, farmId)
                            if stock >= TransportCompanyContract.MIN_SOURCE_LITERS then
                                stocked = stocked + 1
                            end
                            local aiOk =
                                (station.getIsFillTypeAISupported == nil
                                 or station:getIsFillTypeAISupported(fillTypeIndex))
                                and farmId ~= nil and farmId > 0
                                and (station:getFillLevel(fillTypeIndex, farmId) or 0) > 0
                            if aiOk then
                                ai = ai + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return ai, stocked, any, stations, orphan
end

---@param deadlineDays number|nil Deadline in game days (default 3)
---@param farmId number|nil Farm the board belongs to, for stock access
function TransportCompanyContract.generate(deadlineDays, farmId)
    local storageSystem = g_currentMission.storageSystem
    if storageSystem == nil then
        return nil
    end

    -- loadingStations is a map keyed by the station object itself
    -- (StorageSystem.lua:71). Station -> placeable index comes from
    -- owningPlaceable (AIParameterLoadingStation.lua:11-17).
    -- Only stations that hang off a placeable can be persisted, because
    -- the saved reference is (placeable uniqueId, station index). A
    -- station without an owningPlaceable would save as an empty ref and
    -- come back unresolvable, so it is skipped at generation time.
    -- getSupportedFillTypes lists what a station CAN dispense, not what
    -- it currently holds. Offering jobs from an empty silo produced
    -- contracts nobody could run: the player had nothing to load, and a
    -- hired driver was refused outright with "Loading station is empty!"
    -- from AIParameterLoadingStation:validate. Only stations holding
    -- real stock are considered.
    -- Three pools, in descending order of how good the job will be:
    --   aiStations      a hired driver could run it right now
    --   stockedStations the farm can load it right now (access-gated)
    --   anyStations     the station handles this type at all
    --
    -- Stock is access-gated by getStationStock: a source the farm does
    -- not have access to reports zero and is never offered. Without
    -- that gate the board filled with contracts the player could not
    -- load ("no trigger to load when I arrive"). Shops (basicFillTypes
    -- / BuyingStation) count as unlimited and are always loadable.
    -- anyStations is kept for the diagnostic count only; it is never
    -- drawn from, for the reason given at the pool selection below.
    local aiStations, stockedStations, anyStations = {}, {}, {}
    for station, _ in pairs(storageSystem.loadingStations) do
        if station ~= nil and station.owningPlaceable ~= nil then
            local fillTypes = station:getSupportedFillTypes()
            if fillTypes ~= nil then
                for fillTypeIndex, _ in pairs(fillTypes) do
                    if fillTypeIndex ~= FillType.UNKNOWN then
                        local available = TransportCompanyContract.getStationStock(
                            station, fillTypeIndex, farmId)
                        local entry = {
                            ["station"] = station,
                            ["fillTypeIndex"] = fillTypeIndex,
                            ["name"] = station:getName(),
                            ["available"] = available,
                        }
                        table.insert(anyStations, entry)

                        if available >= TransportCompanyContract.MIN_SOURCE_LITERS then
                            table.insert(stockedStations, entry)
                        end

                        -- Exactly the pair AIParameterLoadingStation:validate
                        -- applies, so a job from this pool can be driven.
                        local aiOk =
                            (station.getIsFillTypeAISupported == nil
                             or station:getIsFillTypeAISupported(fillTypeIndex))
                            and farmId ~= nil and farmId > 0
                            and (station:getFillLevel(fillTypeIndex, farmId) or 0) > 0
                        if aiOk then
                            table.insert(aiStations, entry)
                        end
                    end
                end
            end
        end
    end

    -- No fallback to "any station that handles the type". A source with
    -- nothing in it produces a job neither the player nor a driver can
    -- load, and a board of those is worse than a shorter board. With
    -- basicFillTypes counted, genuinely stocked routes exist on any
    -- normal map anyway.
    local pool = stockedStations
    if #aiStations > 0 then
        pool = aiStations
    end
    if #pool == 0 then
        return nil
    end

    -- Pick a random source + fill type.
    local source = pool[math.random(1, #pool)]
    local contract = TransportCompanyContract.new()
    contract.fillTypeIndex = source.fillTypeIndex
    contract.sourceName = source.name or ""

    -- Pallet contracts only make sense for pallet-producible fill types
    -- (FillTypeDesc.isPalletType, FillTypeDesc.lua:69).
    local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(contract.fillTypeIndex)
    local isPalletFillType = fillTypeDesc ~= nil and fillTypeDesc.isPalletType
    if isPalletFillType and math.random() < 0.4 then
        contract.contractType = TransportCompanyContract.CONTRACT_TYPE_PALLET
    else
        contract.contractType = TransportCompanyContract.CONTRACT_TYPE_BULK
    end

    -- Persist station refs: owningPlaceable uniqueId (string) + index.
    local sourcePlaceable = source.station.owningPlaceable
    if sourcePlaceable ~= nil then
        contract.sourceUniqueId = sourcePlaceable:getUniqueId()
        contract.sourceStationIndex = storageSystem:getPlaceableLoadingStationIndex(sourcePlaceable, source.station)
    end

    -- Find a destination station that accepts this fill type.
    -- Same placeable-ownership requirement as the source, and never
    -- route a load back into the station it was collected from, or to
    -- one so close the job is a pointless shuffle (MIN_ROUTE_DISTANCE_M).
    -- Split the destinations the same way as the sources. Picking an
    -- AI-capable source and then pairing it with any old destination is
    -- what let a job pass every check, dispatch a driver, and only then
    -- fail with the station full or the target unreachable.
    -- A destination the farm cannot access would silently reject the tip
    -- (UnloadingStation:addFillLevelFromTool gates on
    -- hasFarmAccessToStorage, UnloadingStation.lua:247), so destinations
    -- are gated on getIsFillAllowedFromFarm just like the sources.
    local destCandidates, aiDests = {}, {}
    for station, _ in pairs(storageSystem.unloadingStations) do
        if station ~= nil and station.owningPlaceable ~= nil
           and station.owningPlaceable ~= source.station.owningPlaceable
           and station:getIsFillTypeSupported(contract.fillTypeIndex) then
            -- The player must be able to tip here. Buying/selling points
            -- always allow; a station whose storage the farm cannot reach
            -- is skipped the same way the load side is.
            if station.getIsFillAllowedFromFarm ~= nil and farmId ~= nil and farmId > 0
               and not station:getIsFillAllowedFromFarm(farmId) then
                -- inaccessible destination: skip
            else
                -- Route distance drives the reward, so it is measured at
                -- generation time (straight-line proxy, see RATE_PER_METER).
                local distanceM = TransportCompanyContract.getRouteDistanceM(
                    source.station.owningPlaceable, station.owningPlaceable
                )
                if distanceM >= TransportCompanyContract.MIN_ROUTE_DISTANCE_M then
                    local entry = {
                        ["station"] = station,
                        ["name"] = station:getName(),
                        ["distanceM"] = distanceM,
                    }
                    table.insert(destCandidates, entry)

                    -- Exactly what AIParameterUnloadingStation:validate applies,
                    -- plus a target the driver can actually reach.
                    local aiOk =
                        (station.getIsFillTypeAISupported == nil
                         or station:getIsFillTypeAISupported(contract.fillTypeIndex))
                        and (station.getFreeCapacity == nil
                             or (station:getFreeCapacity(contract.fillTypeIndex, farmId) or 0) > 0)
                        and TransportCompanyContract.getHasAiTarget(station, contract.fillTypeIndex)
                    if aiOk then
                        table.insert(aiDests, entry)
                    end
                end
            end
        end
    end
    if #destCandidates == 0 then
        return nil
    end

    -- Only claim the job is AI-runnable if BOTH ends are.
    local sourceIsAi = TransportCompanyContract.getHasAiTarget(
        source.station, contract.fillTypeIndex)
    local destPool = destCandidates
    if sourceIsAi and #aiDests > 0 then
        destPool = aiDests
    end

    -- Pick a destination. Prefer longer routes: longer hauls are worth
    -- more, so among a few random candidates we take the farthest. That
    -- biases the board toward meaty jobs without ever forcing one.
    local dest = TransportCompanyContract.pickFarthest(destPool)
    contract.destName = dest.name or ""
    contract.routeDistanceM = dest.distanceM or 0
    local destPlaceable = dest.station.owningPlaceable
    if destPlaceable ~= nil then
        contract.destUniqueId = destPlaceable:getUniqueId()
        contract.destStationIndex = storageSystem:getPlaceableUnloadingStationIndex(destPlaceable, dest.station)
    end

    -- Difficulty tier: Standard by default, URGENT pays more for a
    -- shorter deadline, BULK moves more volume for a tighter margin.
    local roll = math.random()
    if roll < 0.2 then
        contract.tier = TransportCompanyContract.CONTRACT_TIER_URGENT
    elseif roll < 0.4 then
        contract.tier = TransportCompanyContract.CONTRACT_TIER_BULK
    end

    -- Amount + reward: scale with the base economy price so high-value
    -- goods pay more, and with the route length so long hauls pay more.
    -- Fall back to a conservative price when none is found.
    local economy = g_currentMission.economyManager
    local pricePerLiter = economy:getPricePerLiter(contract.fillTypeIndex)
    if pricePerLiter == nil or pricePerLiter <= 0 then
        pricePerLiter = 0.05
    end

    -- How much the farm's biggest rig can move in one trip. A job must
    -- never ask for more than a few trips' worth, or a player with a
    -- small trailer is handed an impossible one-trip contract.
    local maxTripCapacity = TransportCompanyContract.getMaxTripCapacity(farmId)

    -- Cap the ask at what the source holds, but only when it reports a
    -- stock level at all. A station that models no storage reports 0,
    -- and capping to that would ask for nothing.
    local available = source.available or 0
    local knowsStock = available > 0

    local tierRewardFactor = 1
    local tierAmountFactor = 1
    if contract.tier == TransportCompanyContract.CONTRACT_TIER_URGENT then
        tierRewardFactor = 1.5
    elseif contract.tier == TransportCompanyContract.CONTRACT_TIER_BULK then
        tierAmountFactor = 1.5
        tierRewardFactor = 0.85
    end

    if contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET then
        -- Pallet contract: counted in pallets, delivered in liters.
        -- Reward is the per-object base scaled by the live price, so a
        -- pallet of gold pays more than a pallet of flour.
        local amount = math.random(4, 12)
        if knowsStock then
            amount = math.min(amount,
                math.floor(available / TransportCompanyContract.LITERS_PER_PALLET))
        end
        -- The biggest rig can carry at most MAX_TRIPS_PER_JOB loads.
        if maxTripCapacity > 0 then
            amount = math.min(amount, math.floor(
                maxTripCapacity * TransportCompanyContract.MAX_TRIPS_PER_JOB
                / TransportCompanyContract.LITERS_PER_PALLET))
        end
        if amount < 1 then
            return nil
        end
        contract.amount = math.max(1, math.floor(amount * tierAmountFactor))
        contract.litersPerUnit = TransportCompanyContract.LITERS_PER_PALLET
        contract.reward = TransportCompanyContract.computePalletReward(
            contract.amount, pricePerLiter, contract.tier)
    else
        local amount = math.random(8000, 24000)
        if knowsStock then
            amount = math.min(amount, math.floor(available))
        end
        -- Never more than a few trips with the biggest rig.
        if maxTripCapacity > 0 then
            amount = math.min(amount,
                math.floor(maxTripCapacity * TransportCompanyContract.MAX_TRIPS_PER_JOB))
        end
        if amount < TransportCompanyContract.MIN_SOURCE_LITERS then
            return nil
        end
        contract.amount = math.max(TransportCompanyContract.MIN_SOURCE_LITERS,
            math.floor(amount * tierAmountFactor))
        contract.litersPerUnit = 1
        contract.reward = TransportCompanyContract.computeBulkReward(
            contract.amount, pricePerLiter, contract.routeDistanceM, contract.tier)
    end

    -- Unique id: time-based + random suffix (no os.time on FS).
    contract.contractId = string.format("tc_%d_%d", g_currentMission.time, math.random(10000, 99999))

    -- Deadline from the configured contractDeadlineDays setting; the
    -- base TransportMission uses ~3.2 game days as its own reference.
    -- Urgent jobs run on half the clock (never less than a day).
    local deadlineDays = deadlineDays or 3
    if contract.tier == TransportCompanyContract.CONTRACT_TIER_URGENT then
        deadlineDays = math.max(1, math.ceil(deadlineDays * 0.5))
    end
    contract.deadline = g_currentMission.time
        + TransportCompanyContract.DAY_LENGTH * deadlineDays

    -- A contract nobody can resolve is worse than no contract at all.
    if not contract:_resolveStationRefs() then
        return nil
    end
    return contract
end

---Straight-line distance between two owning placeables (m). The
---documented proxy for road length: the FS25 reference set exposes no
---path-length API, and the base game's own TransportMission distance
---call is not in the references.
---@param sourcePlaceable table|nil
---@param destPlaceable table|nil
---@return number meters
function TransportCompanyContract.getRouteDistanceM(sourcePlaceable, destPlaceable)
    if sourcePlaceable == nil or destPlaceable == nil
       or sourcePlaceable.rootNode == nil or destPlaceable.rootNode == nil then
        return 0
    end
    return calcDistanceFrom(sourcePlaceable.rootNode, destPlaceable.rootNode) or 0
end

---Pick the farthest of a few random candidates from a pool. Prefers
---longer routes (worth more) while keeping the board varied.
---@param pool table List of entries carrying a distanceM field
---@return table entry
function TransportCompanyContract.pickFarthest(pool)
    local samples = math.min(3, #pool)
    local best, bestDistance = pool[1], -1
    for i = 1, samples do
        local entry = pool[math.random(1, #pool)]
        local d = entry.distanceM or 0
        if d > bestDistance then
            best, bestDistance = entry, d
        end
    end
    return best
end

---Bulk contract reward: goods value plus a per-meter haul component,
---scaled by the tier. Exposed as a pure function so the reward curve
---is unit-testable without a world.
---@param amount number Liters
---@param pricePerLiter number
---@param distanceM number
---@param tier number CONTRACT_TIER_*
---@return number reward
function TransportCompanyContract.computeBulkReward(amount, pricePerLiter, distanceM, tier)
    local tierRewardFactor = TransportCompanyContract.getTierRewardFactor(tier)
    local goodsReward = amount * (pricePerLiter or 0.05) * 0.15
    local haulReward = (distanceM or 0) * TransportCompanyContract.RATE_PER_METER
    return math.floor((goodsReward + haulReward) * tierRewardFactor)
end

---Pallet contract reward: per-object base scaled by the live price and
---the tier. Pure function for the same reason as computeBulkReward.
---@param amount number Pallets
---@param pricePerLiter number
---@param tier number CONTRACT_TIER_*
---@return number reward
function TransportCompanyContract.computePalletReward(amount, pricePerLiter, tier)
    local tierRewardFactor = TransportCompanyContract.getTierRewardFactor(tier)
    local priceFactor = 0.5 + (pricePerLiter or 0.05) * TransportCompanyContract.PALLET_PRICE_FACTOR
    return math.floor(amount * TransportCompanyContract.REWARD_PER_OBJECT
        * priceFactor * tierRewardFactor)
end

---Reward multiplier for a difficulty tier.
---@param tier number CONTRACT_TIER_*
---@return number
function TransportCompanyContract.getTierRewardFactor(tier)
    if tier == TransportCompanyContract.CONTRACT_TIER_URGENT then
        return 1.5
    elseif tier == TransportCompanyContract.CONTRACT_TIER_BULK then
        return 0.85
    end
    return 1
end

---Largest AI hauling capacity available to a farm across all its trucks
---(truck + attached trailers), in liters. 0 when the farm owns no truck
---or no fill capacity is readable. Used to size contracts so no job
---needs more than MAX_TRIPS_PER_JOB loads with the biggest rig.
---@param farmId number
---@return number liters
function TransportCompanyContract.getMaxTripCapacity(farmId)
    if farmId == nil or farmId <= 0 then return 0 end
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then return 0 end

    local best = 0
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle ~= nil and not vehicle:getIsBeingDeleted()
           and vehicle.spec_motorized ~= nil
           and vehicle.spec_motorized.statsType == "truck"
           and vehicle:getOwnerFarmId() == farmId then
            local cap = TransportCompanyContract.getVehicleAiCapacity(vehicle)
            if cap > best then best = cap end
        end
    end
    return best
end

---Sum the AI fill-unit capacities of a vehicle and its attached
---trailers (the load the base game AI can actually move in one run).
---Mirrors AIJobLoadAndDeliver: vehicle:getAIFillUnits plus each child
---vehicle's (AIJobLoadAndDeliver.lua:242-253).
---@param vehicle table
---@return number liters
function TransportCompanyContract.getVehicleAiCapacity(vehicle)
    if vehicle == nil then return 0 end

    local total = 0
    local function addFor(v)
        if v.getAIFillUnits ~= nil then
            local units = v:getAIFillUnits()
            if units ~= nil then
                for _, fillUnit in ipairs(units) do
                    if fillUnit.capacity ~= nil then
                        total = total + fillUnit.capacity
                    end
                end
            end
        end
    end

    addFor(vehicle)
    if vehicle.getChildVehicles ~= nil then
        for _, child in ipairs(vehicle:getChildVehicles() or {}) do
            addFor(child)
        end
    end
    return total
end
