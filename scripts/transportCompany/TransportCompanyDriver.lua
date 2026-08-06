-- =========================================================
-- FS25 Transport Company - Driver
-- =========================================================
-- A named employee on a company's payroll. Drivers are hired at the
-- HQ, paid a weekly base wage, assigned to a truck, and gain
-- experience with every completed contract. When a hired-driver
-- contract is run with a truck that has an assigned driver, that
-- driver's record moves (jobs, experience) on top of the per-job
-- reward split the manager already applies.
--
-- Driver records are company state: server-authoritative, persisted
-- per farm, synced to clients through TransportCompanyBooksEvent.
-- =========================================================

local modName = g_currentModName

TransportCompanyDriver = {}
local TransportCompanyDriver_mt = Class(TransportCompanyDriver)

-- Weekly wage progression. New hires start at the base; experience
-- raises it by one step every WAGE_EXPERIENCE_STEP experience points.
TransportCompanyDriver.BASE_WEEKLY_WAGE = 800
TransportCompanyDriver.WAGE_EXPERIENCE_STEP = 10
TransportCompanyDriver.WAGE_STEP = 150
TransportCompanyDriver.MAX_EXPERIENCE = 100
TransportCompanyDriver.HIRE_COST = 5000

-- First/last name pools for generated drivers. Names need no
-- translation; they are chosen per hire.
TransportCompanyDriver.FIRST_NAMES = {
    "Alex", "Ben", "Carla", "Dan", "Eva", "Finn", "Greta", "Hugo",
    "Ines", "Jonas", "Karin", "Lars", "Maja", "Nils", "Olga", "Piet",
}
TransportCompanyDriver.LAST_NAMES = {
    "Bauer", "Berg", "Fischer", "Hofmann", "Keller", "Lorenz", "Meier",
    "Neumann", "Ost", "Peters", "Reuter", "Schmidt", "Thiel", "Vogel",
    "Wagner", "Zimmermann",
}

---@class TransportCompanyDriver
function TransportCompanyDriver.new(name, weeklyWage)
    local self = setmetatable({}, TransportCompanyDriver_mt)
    self.driverId = nil                 -- assigned by the company
    self.name = name or "Driver"
    self.weeklyWage = weeklyWage or TransportCompanyDriver.BASE_WEEKLY_WAGE
    self.experience = 0                 -- 0..MAX_EXPERIENCE
    self.jobsDone = 0
    self.assignedTruckUniqueId = ""     -- "" = unassigned
    return self
end

---Generate a random driver name from the pools.
---@return string
function TransportCompanyDriver.randomName()
    local first = TransportCompanyDriver.FIRST_NAMES[
        math.random(1, #TransportCompanyDriver.FIRST_NAMES)]
    local last = TransportCompanyDriver.LAST_NAMES[
        math.random(1, #TransportCompanyDriver.LAST_NAMES)]
    return string.format("%s %s", first, last)
end

---Current weekly wage after experience progression.
---@return number
function TransportCompanyDriver:getCurrentWage()
    local steps = math.floor(self.experience / TransportCompanyDriver.WAGE_EXPERIENCE_STEP)
    return self.weeklyWage + steps * TransportCompanyDriver.WAGE_STEP
end

---Experience after completing a contract (capped).
---@param amount number
function TransportCompanyDriver:addExperience(amount)
    self.experience = math.min(TransportCompanyDriver.MAX_EXPERIENCE,
        self.experience + math.max(0, amount or 0))
end

---Record one completed contract on this driver's truck.
---@param amount number Experience to grant
function TransportCompanyDriver:addJob(amount)
    self.jobsDone = self.jobsDone + 1
    self:addExperience(amount)
end

---Is this driver assigned to a specific truck?
---@param truckUniqueId string
---@return boolean
function TransportCompanyDriver:isAssignedTo(truckUniqueId)
    return self.assignedTruckUniqueId ~= nil
        and self.assignedTruckUniqueId == truckUniqueId
end

---@return boolean
function TransportCompanyDriver:getIsHired()
    return true
end

-- ── Persistence ────────────────────────────────────────────

function TransportCompanyDriver:saveToXMLFile(xmlFile, key)
    xmlFile:setString(key .. "#driverId", self.driverId or "")
    xmlFile:setString(key .. "#name", self.name or "")
    xmlFile:setFloat(key .. "#weeklyWage", self.weeklyWage or TransportCompanyDriver.BASE_WEEKLY_WAGE)
    xmlFile:setFloat(key .. "#experience", self.experience or 0)
    xmlFile:setInt(key .. "#jobsDone", self.jobsDone or 0)
    xmlFile:setString(key .. "#assignedTruckUniqueId", self.assignedTruckUniqueId or "")
end

function TransportCompanyDriver.loadFromXMLFile(xmlFile, key)
    local self = setmetatable({}, TransportCompanyDriver_mt)
    self.driverId = xmlFile:getString(key .. "#driverId", "")
    self.name = xmlFile:getString(key .. "#name", "Driver")
    self.weeklyWage = xmlFile:getFloat(key .. "#weeklyWage", TransportCompanyDriver.BASE_WEEKLY_WAGE)
    self.experience = xmlFile:getFloat(key .. "#experience", 0)
    self.jobsDone = xmlFile:getInt(key .. "#jobsDone", 0)
    self.assignedTruckUniqueId = xmlFile:getString(key .. "#assignedTruckUniqueId", "")
    return self
end

---Network sync: write the driver record for TransportCompanyBooksEvent.
function TransportCompanyDriver:writeStream(streamId)
    streamWriteString(streamId, self.driverId or "")
    streamWriteString(streamId, self.name or "")
    streamWriteFloat64(streamId, self.weeklyWage or TransportCompanyDriver.BASE_WEEKLY_WAGE)
    streamWriteFloat64(streamId, self.experience or 0)
    streamWriteInt32(streamId, self.jobsDone or 0)
    streamWriteString(streamId, self.assignedTruckUniqueId or "")
end

function TransportCompanyDriver.readStream(streamId)
    local self = setmetatable({}, TransportCompanyDriver_mt)
    self.driverId = streamReadString(streamId)
    self.name = streamReadString(streamId)
    self.weeklyWage = streamReadFloat64(streamId)
    self.experience = streamReadFloat64(streamId)
    self.jobsDone = streamReadInt32(streamId)
    self.assignedTruckUniqueId = streamReadString(streamId)
    return self
end
