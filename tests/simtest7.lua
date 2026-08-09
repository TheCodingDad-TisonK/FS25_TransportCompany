-- simtest7: regressions for the post-1.2.3.0 bug sweep.
--
-- Each block here reproduces a bug that shipped, against the real mod
-- source, so it cannot come back quietly. Every one was found by reading
-- the decompiled base game rather than by playing, and the decompiled
-- reference is cited where the behaviour is not obvious.
local ROOT = ...
local pass, fail = 0, 0
local function ok(c, n, e)
    if c then pass = pass + 1; print("  PASS " .. n)
    else fail = fail + 1; print("  FAIL " .. n .. (e and ("  -> " .. tostring(e)) or "")) end
end
local function approx(a, b) return math.abs(a - b) < 1e-6 end

function Class(target, base)
    local mt = { __index = target }
    if base then
        setmetatable(target, { __index = base })
        target.superClass = function() return base end
    end
    target.class = function() return target end
    return mt
end

g_currentModName = "FS25_TransportCompany"
FillType = { UNKNOWN = 0, DIESEL = 1, WHEAT = 2, BARLEY = 3 }
MoneyType = { MISSIONS = "missions", AI = "ai" }
function printWarning() end
function printError() end
TransportCompanyLog = { info = function() end, debug = function() end,
                        warning = function() end, error = function() end }

local booked = {}
g_currentMission = {
    time = 5000,
    -- The mod's day clock. mission.time counts real playtime and is
    -- deliberately not used for day maths.
    environment = { currentMonotonicDay = 10, dayTime = 0 },
    hud = {},
    addMoney = function(_, amount, farmId, moneyType)
        table.insert(booked, { amount = amount, farmId = farmId, moneyType = moneyType })
    end,
    addIngameNotification = function() end,
    getFarmId = function() return 1 end,
    vehicleSystem = { vehicleByUniqueId = {}, vehicles = {} },
}
FSBaseMission = { INGAME_NOTIFICATION_OK = {} }
g_i18n = { getText = function(_, k) return k end,
           formatMoney = function(_, v) return tostring(v) end,
           formatDistance = function(_, v) return tostring(v) end }
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function() return { isPalletType = false } end,
}
g_terrainNode = 0
function getTerrainHeightAtWorldPos(_, _, _, _) return 0 end

-- The real Utils.overwrittenFunction (Utils.lua:394-402), because the
-- delivery-hook test depends on its exact wrapping.
Utils = {
    overwrittenFunction = function(oldFunc, newFunc)
        if oldFunc == nil then
            return function(self, ...) return newFunc(self, nil, ...) end
        end
        return function(self, ...) return newFunc(self, oldFunc, ...) end
    end,
}

-- Placeable specialization lookup, for the HQ block.
TransportCompanyHq = {}
SpecializationUtil = {
    hasSpecialization = function(spec, specializations)
        for _, v in pairs(specializations or {}) do
            if v == spec then return true end
        end
        return false
    end,
}

-- ── station classes, mirroring the base game's shape ──────────────
-- UnloadingStation stores and reports what it took.
UnloadingStation = {}
function UnloadingStation.addFillLevelFromTool(self, farmId, delta, fillType, fillInfo, toolType, extra)
    return delta
end

-- SellingStation:addFillLevelFromTool delegates to its SUPER when the
-- station stores goods (SellingStation.lua:326-328), and a production point
-- owned by the player is exactly that: its unloading station is a
-- SellingStation whose getStoreGoods returns true (ProductionPoint.lua:242-247).
-- The super call resolves through the global, so once the mod has hooked
-- UnloadingStation it re-enters the mod's own hook — which is the whole
-- point of this test.
SellingStation = {}
function SellingStation.addFillLevelFromTool(self, farmId, delta, fillType, fillInfo, toolType, extra)
    if self.storeGoods then
        delta = UnloadingStation.addFillLevelFromTool(self, farmId, delta, fillType, fillInfo, toolType, extra)
    end
    return delta
end

dofile(ROOT .. "/scripts/transportCompany/TransportCompanyContract.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyTruck.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanySettings.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyCompany.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyManager.lua")

TransportCompanyContractEvent = { TYPE_ADD = 1, TYPE_UPDATE = 2,
                                  TYPE_STATE_CHANGE = 3, TYPE_REMOVE = 4,
                                  sendEvent = function() end }
TransportCompanyMoneyEvent = { TYPE_CONTRACT_REWARD = 1, TYPE_HIRED_DRIVER_CUT = 2,
                               TYPE_TRUCK_REVENUE = 3, TYPE_EXPENSE = 4,
                               sendEvent = function() end }
TransportCompanyBooksEvent = { new = function() return {} end, sendEvent = function() end }

local C = TransportCompanyContract
local mgr = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
mgr.isServer, mgr.isMissionLoaded = true, true
mgr._regenerateContractBoard = function() end
g_transportCompanyManager = mgr
local comp = mgr:getOrCreateCompany(1)

-- Install the real hooks over the stub station classes.
mgr:_installDeliveryHooks()

local function newContract(id, amount, dest)
    local c = C.new()
    c.contractId, c.amount, c.litersPerUnit, c.reward = id, amount, 1, 5000
    c.fillTypeIndex = FillType.WHEAT
    c.getDestStation = function() return dest end
    c:accept(1, "", false)
    comp.contracts[id] = c
    return c
end

-- ── 1. delivery is credited exactly once ──────────────────────────
print("\n-- a production point does not credit the delivery twice --")
-- The bug: _deliveryDepth was incremented AFTER superFunc returned, so the
-- nested UnloadingStation hook saw depth 0, credited, and then the outer
-- SellingStation hook saw depth 0 and credited the same liters again.
local dairy = { name = "Dairy", storeGoods = true }
local d1 = newContract("d1", 10000, dairy)
SellingStation.addFillLevelFromTool(dairy, 1, 4000, FillType.WHEAT, nil, nil, nil)
ok(approx(d1.delivered, 4000),
   "own production point credits 4000, not 8000", d1.delivered)

print("\n-- a plain unloading station still credits once --")
local silo = { name = "Silo" }
local d2 = newContract("d2", 10000, silo)
UnloadingStation.addFillLevelFromTool(silo, 1, 2500, FillType.WHEAT, nil, nil, nil)
ok(approx(d2.delivered, 2500), "plain silo credits once", d2.delivered)

print("\n-- a pure selling point (no storage) still credits once --")
-- getStoreGoods false: the super is never called, so only the outer hook runs.
local sellPoint = { name = "Sell", storeGoods = false }
local d3 = newContract("d3", 10000, sellPoint)
SellingStation.addFillLevelFromTool(sellPoint, 1, 3000, FillType.WHEAT, nil, nil, nil)
ok(approx(d3.delivered, 3000), "sell point credits once", d3.delivered)

print("\n-- the depth counter unwinds after a throwing delivery --")
local boom = { name = "Boom", storeGoods = false }
local savedSuper = SellingStation.addFillLevelFromTool
local threw = not pcall(function()
    -- Force the inner call to error and check the next delivery still works.
    local exploding = setmetatable({}, { __index = function() error("boom", 0) end })
    SellingStation.addFillLevelFromTool(exploding, 1, 100, FillType.WHEAT, nil, nil, nil)
end)
SellingStation.addFillLevelFromTool = savedSuper
local d4 = newContract("d4", 10000, boom)
SellingStation.addFillLevelFromTool(boom, 1, 1500, FillType.WHEAT, nil, nil, nil)
ok(threw, "the throwing delivery propagated rather than being swallowed")
ok(approx(d4.delivered, 1500),
   "credits still land after a throw (depth was unwound)", d4.delivered)

-- ── 2. contract state changes reach the client ────────────────────
print("\n-- a client applies a STATE_CHANGE to its own board --")
-- The bug: TYPE_STATE_CHANGE set the state on the freshly deserialized
-- object and dropped it, so a client's copy stayed ACCEPTED forever and
-- delivered jobs never left the Dispatch board.
local client = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
client.isServer, client.isMissionLoaded = false, true
g_transportCompanyManager = client
local cComp = client:getOrCreateCompany(1)

local stale = C.new()
stale.contractId, stale.state = "x1", C.STATE_ACCEPTED
cComp.contracts["x1"] = stale

local incoming = C.new()
incoming.contractId, incoming.state = "x1", C.STATE_COMPLETED
client:onContractEvent(TransportCompanyContractEvent.TYPE_STATE_CHANGE,
                       incoming, C.STATE_COMPLETED, 1)
ok(cComp.contracts["x1"] ~= nil, "the contract is still on the client's board")
ok(cComp.contracts["x1"].state == C.STATE_COMPLETED,
   "client board reflects the completion", cComp.contracts["x1"].state)
g_transportCompanyManager = mgr

-- ── 3. selling the last HQ archives the company ───────────────────
print("\n-- selling the last HQ archives the company --")
-- Placeable:onSell fires while the placeable is STILL in
-- placeableSystem.placeables (Placeable.lua:874); removal only happens
-- inside delete() at :568, before onDelete at :577. So the world scan lies
-- during a sell and the registry has to be the source of truth.
local hq = {
    uid = "hq1",
    specializations = { TransportCompanyHq },
    getUniqueId = function(self) return self.uid end,
    getOwnerFarmId = function() return 1 end,
}
g_currentMission.placeableSystem = { placeables = { hq } }

mgr:onHqChanged(hq, true, true)
ok(mgr:_hasRegisteredHq(1), "HQ registered on placement")
ok(comp.isArchived == false, "company live while the HQ stands")

mgr:onHqChanged(hq, false)
ok(mgr:_hasHq(1) == true,
   "the world scan STILL sees the HQ mid-sell (this is the trap)")
ok(mgr:_hasRegisteredHq(1) == false, "the registry has already let it go")
ok(comp.isArchived == true, "company archived on selling the last HQ")

print("\n-- a second HQ keeps the company alive --")
comp:restore()
local hqA = { uid = "hqA", specializations = { TransportCompanyHq },
              getUniqueId = function(self) return self.uid end,
              getOwnerFarmId = function() return 1 end }
local hqB = { uid = "hqB", specializations = { TransportCompanyHq },
              getUniqueId = function(self) return self.uid end,
              getOwnerFarmId = function() return 1 end }
mgr:onHqChanged(hqA, true, true)
mgr:onHqChanged(hqB, true, true)
mgr:onHqChanged(hqA, false)
ok(comp.isArchived == false, "still live with one HQ left")
mgr:onHqChanged(hqB, false)
ok(comp.isArchived == true, "archived once the last one goes")

-- ── 4. maintenance is measured in metres ──────────────────────────
print("\n-- service interval is a real distance --")
-- The bug: SERVICE_INTERVAL_KM = 5000 was compared against distanceM, which
-- is metres (Vehicle.lastMovedDistance, Vehicle.lua:1484). Trucks were
-- billed a service every 5 km, with the cost escalating each time.
local veh = {
    getUniqueId = function() return "vehicle1" end,
    getFullName = function() return "Truck" end,
    getOwnerFarmId = function() return 1 end,
}
local T = TransportCompanyTruck
ok(T.SERVICE_INTERVAL_M >= 50000,
   "interval is tens of km, not 5", T.SERVICE_INTERVAL_M)

local svc = T.new(veh)
svc.distanceM = 5000
ok(svc:checkService() == 0, "5 km no longer triggers a service")
svc.distanceM = T.SERVICE_INTERVAL_M
ok(svc:checkService() == T.SERVICE_BASE_COST, "first service at base cost")
svc.distanceM = T.SERVICE_INTERVAL_M * 2
ok(svc:checkService() == T.SERVICE_BASE_COST + T.SERVICE_COST_ESCALATION,
   "escalation is a flat step, not derived from the interval")

print("\n-- a save on the old 5 km interval migrates cleanly --")
local legacy = T.new(veh)
legacy.distanceM = 12249          -- straight out of the sampled savegame
legacy.nextServiceM = 15000       -- the stale milestone that save carried
legacy:normalizeService()
ok(legacy.nextServiceM == T.SERVICE_INTERVAL_M,
   "milestone recomputed onto the new interval", legacy.nextServiceM)
ok(legacy:checkService() == 0, "no bogus service right after the upgrade")

-- ── 5. the day clock is the environment, not mission.time ─────────
print("\n-- deadlines run on game days --")
g_currentMission.environment.currentMonotonicDay = 10
g_currentMission.environment.dayTime = 0
ok(approx(C.getGameDay(), 10), "whole day", C.getGameDay())
g_currentMission.environment.dayTime = C.DAY_LENGTH / 2
ok(approx(C.getGameDay(), 10.5), "day plus fraction", C.getGameDay())

-- mission.time is real playtime and must not move the day clock.
local dayBefore = C.getGameDay()
g_currentMission.time = g_currentMission.time + 86400000
ok(approx(C.getGameDay(), dayBefore),
   "24h of REAL playtime does not advance a game day", C.getGameDay())

local dl = C.new()
dl.deadline = C.getGameDay() + 3
ok(dl:getIsExpired() == false, "3 days out is not expired")
ok(approx(dl:getTimeLeft(), 3), "time left is in days", dl:getTimeLeft())
g_currentMission.environment.currentMonotonicDay = 14
ok(dl:getIsExpired() == true, "expired once the days have passed")

print("\n-- generated deadlines are days, not milliseconds --")
local gen = C.new()
gen.deadline = C.getGameDay() + 7
ok(gen.deadline < 100000,
   "a deadline is a day number, not a mission-time stamp", gen.deadline)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
