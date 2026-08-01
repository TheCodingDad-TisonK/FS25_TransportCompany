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

-- Base reward curve (kept conservative, tuned by the manager via
-- economy prices; these are fallbacks when no price exists).
TransportCompanyContract.REWARD_PER_LITER = 0.005
TransportCompanyContract.REWARD_PER_OBJECT = 350

-- Delivery is always measured in LITERS, because that is the only
-- quantity the engine reports at a station
-- (UnloadingStation:addFillLevelFromTool returns moved liters).
-- A pallet contract expresses its amount in pallets, so it carries a
-- conversion factor. 1000 L is the standard FS pallet capacity; the
-- game's pallet XMLs live outside dataS and cannot be read here, so
-- this is a deliberate fixed assumption rather than a lookup.
TransportCompanyContract.LITERS_PER_PALLET = 1000

---@class TransportCompanyContract
TransportCompanyContract_mt = Class(TransportCompanyContract)

function TransportCompanyContract.new()
    local self = setmetatable({}, TransportCompanyContract_mt)
    self.contractId = nil
    self.contractType = TransportCompanyContract.CONTRACT_TYPE_BULK
    self.state = TransportCompanyContract.STATE_AVAILABLE
    self.fillTypeIndex = nil
    self.amount = 0              -- liters (BULK) or pallets (PALLET)
    self.delivered = 0           -- same unit as amount
    self.litersPerUnit = 1       -- 1 for BULK, LITERS_PER_PALLET for PALLET
    self.reward = 0              -- total reward on completion
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
    return self
end

-- ── Persistence ────────────────────────────────────────────

--- Network sync: write the contract state for TransportCompanyContractEvent.
function TransportCompanyContract:writeStream(streamId, connection)
    streamWriteString(streamId, self.contractId or "")
    streamWriteInt8(streamId, self.contractType)
    streamWriteInt8(streamId, self.state)
    streamWriteInt16(streamId, self.fillTypeIndex or FillType.UNKNOWN)
    streamWriteFloat32(streamId, self.amount)
    streamWriteFloat32(streamId, self.delivered)
    streamWriteFloat32(streamId, self.reward)
    streamWriteFloat32(streamId, self.litersPerUnit or 1)
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
    self.state = streamReadInt8(streamId)
    self.fillTypeIndex = streamReadInt16(streamId)
    self.amount = streamReadFloat32(streamId)
    self.delivered = streamReadFloat32(streamId)
    self.reward = streamReadFloat32(streamId)
    self.litersPerUnit = streamReadFloat32(streamId)
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
    xmlFile:setInt(key .. "#state", self.state)
    xmlFile:setInt(key .. "#fillTypeIndex", self.fillTypeIndex or FillType.UNKNOWN)
    xmlFile:setFloat(key .. "#amount", self.amount)
    xmlFile:setFloat(key .. "#delivered", self.delivered)
    xmlFile:setFloat(key .. "#reward", self.reward)
    xmlFile:setFloat(key .. "#litersPerUnit", self.litersPerUnit or 1)
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
end

---Load contract data from XML (instance method — populates self).
function TransportCompanyContract:loadFromXMLFile(xmlFile, key)
    self.contractId = xmlFile:getString(key .. "#contractId")
    self.contractType = xmlFile:getInt(key .. "#contractType", TransportCompanyContract.CONTRACT_TYPE_BULK)
    self.state = xmlFile:getInt(key .. "#state", TransportCompanyContract.STATE_AVAILABLE)
    self.fillTypeIndex = xmlFile:getInt(key .. "#fillTypeIndex", FillType.UNKNOWN)
    self.amount = xmlFile:getFloat(key .. "#amount", 0)
    self.delivered = xmlFile:getFloat(key .. "#delivered", 0)
    self.reward = xmlFile:getFloat(key .. "#reward", 0)
    self.litersPerUnit = xmlFile:getFloat(key .. "#litersPerUnit", 1)
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
function TransportCompanyContract:getAmountUnitText()
    if self.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET then
        return g_i18n:getText("transportCompany_unitObjects")
    end
    return g_i18n:getText("unit_liter")
end

-- ── Contract generator ─────────────────────────────────────
-- Scans the live station lists and emits a fresh contract.
-- Returns a new contract or nil when no valid route exists.

-- A source has to hold at least this much before a contract is offered
-- for it, so the job is actually haulable when it appears.
TransportCompanyContract.MIN_SOURCE_LITERS = 1000

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
    local loadingStations = {}
    for station, _ in pairs(storageSystem.loadingStations) do
        if station ~= nil and station.owningPlaceable ~= nil then
            local fillTypes = station:getSupportedFillTypes()
            if fillTypes ~= nil then
                for fillTypeIndex, _ in pairs(fillTypes) do
                    if fillTypeIndex ~= FillType.UNKNOWN then
                        local available = station:getFillLevel(fillTypeIndex, farmId) or 0
                        if available >= TransportCompanyContract.MIN_SOURCE_LITERS then
                            table.insert(loadingStations, {
                                ["station"] = station,
                                ["fillTypeIndex"] = fillTypeIndex,
                                ["name"] = station:getName(),
                                ["available"] = available,
                            })
                        end
                    end
                end
            end
        end
    end

    if #loadingStations == 0 then
        return nil
    end

    -- Pick a random source + fill type.
    local source = loadingStations[math.random(1, #loadingStations)]
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
    -- route a load back into the station it was collected from.
    local destCandidates = {}
    for station, _ in pairs(storageSystem.unloadingStations) do
        if station ~= nil and station.owningPlaceable ~= nil
           and station.owningPlaceable ~= source.station.owningPlaceable
           and station:getIsFillTypeSupported(contract.fillTypeIndex) then
            table.insert(destCandidates, {
                ["station"] = station,
                ["name"] = station:getName(),
            })
        end
    end
    if #destCandidates == 0 then
        return nil
    end

    local dest = destCandidates[math.random(1, #destCandidates)]
    contract.destName = dest.name or ""
    local destPlaceable = dest.station.owningPlaceable
    if destPlaceable ~= nil then
        contract.destUniqueId = destPlaceable:getUniqueId()
        contract.destStationIndex = storageSystem:getPlaceableUnloadingStationIndex(destPlaceable, dest.station)
    end

    -- Amount + reward: scale with the base economy price so high-value
    -- goods pay more. Fall back to constants when no price is found.
    local economy = g_currentMission.economyManager
    local pricePerLiter = economy:getPricePerLiter(contract.fillTypeIndex)
    if pricePerLiter == nil or pricePerLiter <= 0 then
        pricePerLiter = 0.05
    end

    -- Never ask for more than the source can actually supply.
    local available = source.available or 0

    if contract.contractType == TransportCompanyContract.CONTRACT_TYPE_PALLET then
        -- Pallet contract: counted in pallets, delivered in liters.
        -- REWARD_PER_OBJECT mirrors TransportMission.
        local maxPallets = math.floor(available / TransportCompanyContract.LITERS_PER_PALLET)
        local amount = math.min(math.random(4, 12), maxPallets)
        if amount < 1 then
            return nil
        end
        contract.amount = amount
        contract.litersPerUnit = TransportCompanyContract.LITERS_PER_PALLET
        contract.reward = amount * TransportCompanyContract.REWARD_PER_OBJECT
    else
        local amount = math.min(math.random(8000, 24000), math.floor(available))
        if amount < TransportCompanyContract.MIN_SOURCE_LITERS then
            return nil
        end
        contract.amount = amount
        contract.litersPerUnit = 1
        contract.reward = math.floor(amount * pricePerLiter * 0.15)
    end

    -- Unique id: time-based + random suffix (no os.time on FS).
    contract.contractId = string.format("tc_%d_%d", g_currentMission.time, math.random(10000, 99999))

    -- Deadline from the configured contractDeadlineDays setting; the
    -- base TransportMission uses ~3.2 game days as its own reference.
    contract.deadline = g_currentMission.time
        + TransportCompanyContract.DAY_LENGTH * (deadlineDays or 3)

    -- A contract nobody can resolve is worse than no contract at all.
    if not contract:_resolveStationRefs() then
        return nil
    end
    return contract
end
