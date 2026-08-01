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
    self.uniqueId = vehicle:getUniqueId()          -- stable id (Vehicle.lua:3058)
    self.name = vehicle:getFullName()              -- localized display name (Vehicle.lua:193)
    self.farmId = vehicle:getOwnerFarmId()
    self.revenue = 0                               -- money earned on contracts
    self.fuelCost = 0                              -- cost of fuel burned (economy price)
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
    xmlFile:setInt(key .. "#uniqueId", self.uniqueId)
    xmlFile:setString(key .. "#name", self.name)
    xmlFile:setInt(key .. "#farmId", self.farmId)
    xmlFile:setFloat(key .. "#revenue", self.revenue)
    xmlFile:setFloat(key .. "#fuelCost", self.fuelCost)
    xmlFile:setFloat(key .. "#distanceM", self.distanceM)
    xmlFile:setInt(key .. "#jobsDelivered", self.jobsDelivered)
    xmlFile:setBool(key .. "#isEnrolled", self.isEnrolled)
end

function TransportCompanyTruck.loadFromXMLFile(xmlFile, key)
    local self = setmetatable({}, TransportCompanyTruck_mt)
    self.uniqueId = xmlFile:getInt(key .. "#uniqueId", 0)
    self.name = xmlFile:getString(key .. "#name", "Truck")
    self.farmId = xmlFile:getInt(key .. "#farmId", 0)
    self.revenue = xmlFile:getFloat(key .. "#revenue", 0)
    self.fuelCost = xmlFile:getFloat(key .. "#fuelCost", 0)
    self.distanceM = xmlFile:getFloat(key .. "#distanceM", 0)
    self.jobsDelivered = xmlFile:getInt(key .. "#jobsDelivered", 0)
    self.isEnrolled = xmlFile:getBool(key .. "#isEnrolled", true)
    self.sampleFillLevels = {}
    self.lastSampledDistance = 0
    return self
end

-- ── Runtime helpers ────────────────────────────────────────

function TransportCompanyTruck:getProfit()
    return self.revenue - self.fuelCost
end

--- Find the live vehicle object for this registry entry.
function TransportCompanyTruck:getVehicle()
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return nil
    end
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle:getUniqueId() == self.uniqueId then
            return vehicle
        end
    end
    return nil
end

-- ── Server-side sampling (called from manager update) ──────
-- Only meaningful on the server; the manager guards the call.

--- Accumulate fuel burn from the diesel fill units.
--- Returns the fuel cost (money) burned this tick.
--- NOTE: fillUnits is a map keyed by fillUnitIndex (base game uses
--- pairs(...), see FertilizeMission.lua:63), not a dense array.
function TransportCompanyTruck:sampleFuel(vehicle, dt)
    local fillUnits = vehicle:getFillUnits()
    if fillUnits == nil then
        return 0
    end
    local cost = 0
    for index, fillUnit in pairs(fillUnits) do
        local fillType = fillUnit.fillType
        if fillType ~= nil and fillType == FillType.DIESEL then
            local level = fillUnit.fillLevel
            if level == nil then
                level = vehicle:getFillUnitFillLevel(index)
            end
            local last = self.sampleFillLevels[index]
            if last ~= nil then
                local delta = level - last
                if delta < -0.001 then
                    -- Fuel burned: value at the current economy price.
                    local liters = -delta
                    local price = g_currentMission.economyManager:getCostPerLiter(fillType)
                    self.fuelCost = self.fuelCost + liters * price
                    cost = cost + liters * price
                end
            end
            self.sampleFillLevels[index] = level
        end
    end
    return cost
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
    local fillUnits = vehicle:getFillUnits()
    if fillUnits ~= nil then
        for index, fillUnit in pairs(fillUnits) do
            if fillUnit.fillType ~= nil and fillUnit.fillType == FillType.DIESEL then
                self.sampleFillLevels[index] = vehicle:getFillUnitFillLevel(index)
            end
        end
    end
    self.lastSampledDistance = vehicle.lastMovedDistance or 0
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
