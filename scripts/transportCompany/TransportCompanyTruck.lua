-- =========================================================
-- FS25 Transport Company - Truck Registry
-- =========================================================
-- Per-truck books for every truck owned by the company farm.
--
-- The base game only keeps farm-level statistics (FarmStats
-- traveledDistance / fuelUsage); there is no per-vehicle ledger.
-- This registry samples the verified per-vehicle sources instead:
--
--   - Distance : Vehicle.lastMovedDistance (m per physics tick,
--     server-side, set in Vehicle.lua:1484). The base game's own
--     Motorized traveledDistance stat uses exactly this source
--     (Motorized.lua:883-889).
--   - Fuel     : fill-level deltas on the truck's diesel fill units.
--     Fuel burned (negative delta) is valued at the current economy
--     diesel price (EconomyManager:getCostPerLiter, verified).
--     Refuelling (positive delta) is not charged here - the player
--     pays at the pump through the base game.
--   - Revenue  : credited by the manager when a contract is
--     delivered with this truck (server-side addMoney).
--
-- Trucks qualify when motorized.statsType == "truck" (Motorized
-- accepts only "tractor"/"car"/"truck", Motorized.lua:451-453) and
-- the vehicle is owned by the company farm. Enrollment happens
-- lazily while scanning the live vehicle list; books persist across
-- save/load through the manager's savegame file (server-shared).
-- =========================================================

local modName = g_currentModName

---@class TransportCompanyTruck
TransportCompanyTruck = {}
local TransportCompanyTruck_mt = Class(TransportCompanyTruck)

function TransportCompanyTruck.new(vehicle)
    local self = setmetatable({}, TransportCompanyTruck_mt)
    -- uniqueId is a STRING: Utils.getUniqueId builds "vehicle" .. md5
    -- (VehicleSystem.lua:170), so it must never be written as an int.
    self.uniqueId = vehicle:getUniqueId()          -- stable id (Vehicle.lua:3058)
    self.vehicleName = vehicle:getFullName()       -- localized display name (Vehicle.lua:2886)
    self.farmId = vehicle:getOwnerFarmId()
    self.revenue = 0                               -- money earned on contracts
    self.fuelCost = 0                              -- cost of fuel burned (economy price)
    self.otherCost = 0                             -- driver wages and other charges
    self.distanceM = 0                             -- meters driven while enrolled
    self.jobsDelivered = 0                         -- contracts completed with this truck
    self.isEnrolled = false
    -- Per-tick sampling state (server only)
    self.sampleFillLevels = {}
    self.lastSampledDistance = 0
    return self
end

-- ── Persistence ────────────────────────────────────────────

function TransportCompanyTruck:saveToXMLFile(xmlFile, key)
    xmlFile:setString(key .. "#uniqueId", self.uniqueId or "")
    xmlFile:setString(key .. "#vehicleName", self.vehicleName or "")
    xmlFile:setInt(key .. "#farmId", self.farmId or 0)
    xmlFile:setFloat(key .. "#revenue", self.revenue)
    xmlFile:setFloat(key .. "#fuelCost", self.fuelCost)
    xmlFile:setFloat(key .. "#otherCost", self.otherCost or 0)
    xmlFile:setFloat(key .. "#distanceM", self.distanceM)
    xmlFile:setInt(key .. "#jobsDelivered", self.jobsDelivered)
    xmlFile:setBool(key .. "#isEnrolled", self.isEnrolled)
end

function TransportCompanyTruck.loadFromXMLFile(xmlFile, key)
    local self = setmetatable({}, TransportCompanyTruck_mt)
    self.uniqueId = xmlFile:getString(key .. "#uniqueId", "")
    self.vehicleName = xmlFile:getString(key .. "#vehicleName", "Truck")
    self.farmId = xmlFile:getInt(key .. "#farmId", 0)
    self.revenue = xmlFile:getFloat(key .. "#revenue", 0)
    self.fuelCost = xmlFile:getFloat(key .. "#fuelCost", 0)
    self.otherCost = xmlFile:getFloat(key .. "#otherCost", 0)
    self.distanceM = xmlFile:getFloat(key .. "#distanceM", 0)
    self.jobsDelivered = xmlFile:getInt(key .. "#jobsDelivered", 0)
    self.isEnrolled = xmlFile:getBool(key .. "#isEnrolled", true)
    self.sampleFillLevels = {}
    self.lastSampledDistance = 0
    return self
end

-- ── Runtime helpers ────────────────────────────────────────

function TransportCompanyTruck:getProfit()
    return self.revenue - self.fuelCost - (self.otherCost or 0)
end

--- Credit contract revenue to this truck's books.
function TransportCompanyTruck:addRevenue(amount)
    self.revenue = self.revenue + (amount or 0)
end

--- Charge a non-fuel expense (driver wages) to this truck's books.
--- Kept separate from fuelCost so the Fleet tab does not report a
--- driver's wage as diesel burned. Amounts are stored positive;
--- getProfit subtracts them.
function TransportCompanyTruck:addExpense(amount)
    self.otherCost = (self.otherCost or 0) + math.abs(amount or 0)
end

--- Count one completed delivery.
function TransportCompanyTruck:addJob()
    self.jobsDelivered = self.jobsDelivered + 1
end

--- Find the live vehicle object for this registry entry.
--- VehicleSystem keeps a uniqueId index (VehicleSystem.lua:11), so
--- there is no reason to walk the whole vehicle list.
function TransportCompanyTruck:getVehicle()
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return nil
    end
    return g_currentMission.vehicleSystem.vehicleByUniqueId[self.uniqueId]
end

-- ── Server-side sampling (called from manager update) ──────
-- Only meaningful on the server; the manager guards the call.

--- Accumulate fuel burn from the diesel fill units.
--- Returns the fuel cost (money) burned this tick.
--- NOTE: fillUnits is a map keyed by fillUnitIndex (base game uses
--- pairs(...), see FertilizeMission.lua:63), not a dense array.
function TransportCompanyTruck:sampleFuel(vehicle, dt)
    local index = TransportCompanyTruck.getFuelFillUnitIndex(vehicle)
    if index == nil then
        return 0
    end

    local level = vehicle:getFillUnitFillLevel(index)
    if level == nil then
        return 0
    end

    local cost = 0
    local last = self.sampleFillLevels[index]
    if last ~= nil then
        local delta = level - last
        if delta < -0.001 then
            -- Fuel burned: value at the current economy price.
            -- getCostPerLiter (EconomyManager.lua:371) can return nil for
            -- a fill type with no configured cost, so it is guarded.
            local liters = -delta
            local price = g_currentMission.economyManager:getCostPerLiter(FillType.DIESEL)
            if price ~= nil and price > 0 then
                cost = liters * price
                self.fuelCost = self.fuelCost + cost
            end
        end
    end
    self.sampleFillLevels[index] = level
    return cost
end

--- Locate the diesel fill unit for a vehicle.
--- Motorized exposes getConsumerFillUnitIndex (Motorized.lua:1923) —
--- authoritative when present. Falls back to scanning the fill units,
--- which is a map keyed by fillUnitIndex, not a dense array.
---@return number|nil fillUnitIndex
function TransportCompanyTruck.getFuelFillUnitIndex(vehicle)
    if vehicle.getConsumerFillUnitIndex ~= nil then
        local index = vehicle:getConsumerFillUnitIndex(FillType.DIESEL)
        if index ~= nil then
            return index
        end
    end
    if vehicle.getFillUnits == nil then
        return nil
    end
    local fillUnits = vehicle:getFillUnits()
    if fillUnits == nil then
        return nil
    end
    for index, fillUnit in pairs(fillUnits) do
        if fillUnit.fillType == FillType.DIESEL then
            return index
        end
    end
    return nil
end

--- Accumulate distance from the vehicle's last moved distance.
function TransportCompanyTruck:sampleDistance(vehicle)
    local moved = vehicle.lastMovedDistance
    if moved ~= nil and moved > 0.001 then
        self.distanceM = self.distanceM + moved
        return moved
    end
    return 0
end

--- Called when the truck starts being tracked: seed fill levels.
function TransportCompanyTruck:beginSampling(vehicle)
    self.sampleFillLevels = {}
    local index = TransportCompanyTruck.getFuelFillUnitIndex(vehicle)
    if index ~= nil then
        self.sampleFillLevels[index] = vehicle:getFillUnitFillLevel(index)
    end
    self.lastSampledDistance = vehicle.lastMovedDistance or 0
end

--- Does this vehicle qualify as a company truck?
--- Motorized normalises statsType to tractor/car/truck
--- (Motorized.lua:451-453); only "truck" enrolls.
---@return boolean
function TransportCompanyTruck.getIsTruck(vehicle)
    if vehicle == nil or vehicle.spec_motorized == nil then
        return false
    end
    return vehicle.spec_motorized.statsType == "truck"
end

--- Try to find the live vehicle; returns (vehicle, shouldUnenroll).
--- A truck that no longer exists (sold/deleted) is removed from the
--- active fleet but its books remain in the registry.
function TransportCompanyTruck:resolveVehicle()
    local vehicle = self:getVehicle()
    if vehicle ~= nil and vehicle:getIsBeingDeleted() then
        vehicle = nil
    end
    return vehicle
end
