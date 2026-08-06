-- simtest6: business-sim layer (R4) — driver roster, reputation,
-- HQ upgrades, maintenance, weekly wages and ledger P&L rollup.
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
FillType = { UNKNOWN = 0, DIESEL = 1, WHEAT = 2 }
MoneyType = { MISSIONS = "missions", AI = "ai" }
InputAction = { MENU_BACK = 1, MENU_ACTIVATE = 2, MENU_EXTRA_1 = 3, MENU_EXTRA_2 = 4 }
function printWarning() end
function printError() end
TransportCompanyLog = { info = function() end, debug = function() end,
                        warning = function() end, error = function() end }

local booked = {}
local farmMoney = 1000000
local farmObj = {
    getBalance = function() return farmMoney end,
}
g_farmManager = {
    getFarmById = function(_, farmId)
        return farmId == 1 and farmObj or nil
    end,
}
g_currentMission = {
    time = 5000,
    hud = {},
    addMoney = function(_, amount, farmId, moneyType)
        farmMoney = farmMoney + amount
        table.insert(booked, { amount = amount, farmId = farmId, moneyType = moneyType })
    end,
    addIngameNotification = function() end,
    getFarmId = function() return 1 end,
    vehicleSystem = { vehicleByUniqueId = {} },
}
FSBaseMission = { INGAME_NOTIFICATION_OK = {} }
g_i18n = { getText = function(_, k) return k end,
           formatMoney = function(_, v) return tostring(v) end,
           formatDistance = function(_, v) return tostring(v) end }
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function(_, i)
        return { isPalletType = false, hudOverlayFilename = "hud_wheat.png" }
    end,
}
MessageType = { AI_JOB_STOPPED = 1 }
g_messageCenter = { subscribe = function() end }

dofile(ROOT .. "/scripts/transportCompany/TransportCompanyContract.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyTruck.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanySettings.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyDriver.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyCompany.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyManager.lua")

TransportCompanyContractEvent = { TYPE_ADD = 1, TYPE_UPDATE = 2, TYPE_STATE_CHANGE = 3,
                                  TYPE_REMOVE = 4, sendEvent = function() end }
TransportCompanyMoneyEvent = { TYPE_CONTRACT_REWARD = 1, TYPE_HIRED_DRIVER_CUT = 2,
                               TYPE_TRUCK_REVENUE = 3, TYPE_EXPENSE = 4, sendEvent = function() end }
TransportCompanyAcceptEvent = { MODE_SELF = 1, MODE_HIRE = 2 }
TransportCompanyDriverEvent = { ACTION_HIRE = 1, ACTION_FIRE = 2, ACTION_ASSIGN = 3,
                                ACTION_UPGRADE = 4 }

local C = TransportCompanyContract
local D = TransportCompanyDriver
local CC = TransportCompanyCompany

local mgr = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
mgr.isServer, mgr.isMissionLoaded = true, true
mgr._regenerateContractBoard = function() end
mgr._broadcastBooks = function() end
g_transportCompanyManager = mgr
local comp = mgr:getOrCreateCompany(1)

print("\n-- driver roster --")
ok(comp:getDriverCap() == CC.BASE_DRIVER_CAP, "base driver cap", comp:getDriverCap())
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 1, nil, nil),
   "hire first driver")
ok(comp:getDriverCount() == 1, "one driver on payroll", comp:getDriverCount())
local dId
for id, d in pairs(comp.drivers) do dId = id end
local drv = comp.drivers[dId]
ok(drv ~= nil and drv.name ~= "" and drv.weeklyWage > 0, "driver has name and wage")
ok(drv:getCurrentWage() == drv.weeklyWage, "new driver at base wage")
ok(approx(farmMoney, 1000000 - D.HIRE_COST), "hire cost deducted",
   string.format("money=%d", farmMoney))
ok(mgr:_getFarmMoney(1) == farmMoney, "farm balance read via g_farmManager", mgr:_getFarmMoney(1))
ok(mgr:_getFarmMoney(0) == 0, "balance read refuses farmId 0")
ok(mgr:_getFarmMoney(99) == 0, "balance read refuses unknown farm")

print("\n-- driver experience raises the wage --")
drv:addJob(20)
ok(drv.jobsDone == 1, "job counted")
ok(approx(drv:getCurrentWage(), drv.weeklyWage + 2 * D.WAGE_STEP),
   "wage steps with experience", drv:getCurrentWage())

print("\n-- driver cap grows with reputation --")
for _ = 1, 3 do
    mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 1, nil, nil)
end
ok(comp:getDriverCount() == CC.BASE_DRIVER_CAP, "hired up to the cap", comp:getDriverCount())
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 1, nil, nil) == false,
   "hire refused at the cap")
comp:addReputation(CC.REPUTATION_PER_LEVEL * 2)  -- level 3
ok(comp:getDriverCap() == CC.BASE_DRIVER_CAP + 2, "cap grew with level", comp:getDriverCap())
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 1, nil, nil),
   "hire again after level-up")

print("\n-- hire refused when the farm cannot pay --")
farmMoney = 100
local countBefore = comp:getDriverCount()
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 1, nil, nil) == false,
   "hire refused with insufficient funds")
ok(comp:getDriverCount() == countBefore, "no driver added on refused hire")
farmMoney = 1000000

print("\n-- assign driver to a truck --")
local truckVeh = {
    getUniqueId = function() return "vehicleT1" end,
    getFullName = function() return "Scania" end,
    getOwnerFarmId = function() return 1 end,
    getIsBeingDeleted = function() return false end,
    getChildVehicles = function() return {} end,
    getAIFillUnits = function() return { { capacity = 10000 } } end,
}
local truck = TransportCompanyTruck.new(truckVeh)
truck.farmId = 1
truck.isEnrolled = true
comp.trucks["vehicleT1"] = truck
g_currentMission.vehicleSystem.vehicleByUniqueId["vehicleT1"] = truckVeh

local anyDriver
for id, d in pairs(comp.drivers) do anyDriver = d; dId = id; break end
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_ASSIGN, 1, dId, "vehicleT1"),
   "assign driver to truck")
ok(anyDriver:isAssignedTo("vehicleT1"), "driver assigned")
ok(comp:getDriverForTruck("vehicleT1") == anyDriver, "lookup by truck works")
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_FIRE, 1, dId, nil),
   "fire driver")
ok(comp:getDriverForTruck("vehicleT1") == nil, "fired driver released the truck")

print("\n-- reputation --")
comp.reputation = 0
comp:addReputation(CC.REPUTATION_ON_COMPLETE)
ok(approx(comp.reputation, CC.REPUTATION_ON_COMPLETE), "completion raises reputation")
comp:addReputation(CC.REPUTATION_ON_EXPIRE)
ok(approx(comp.reputation, 0), "expiry lowers reputation")
comp.reputation = -50
comp:addReputation(-10)
ok(comp.reputation >= 0, "reputation clamps at 0")
comp.reputation = CC.REPUTATION_MAX + 50
comp:addReputation(10)
ok(comp.reputation <= CC.REPUTATION_MAX, "reputation clamps at max")

print("\n-- HQ upgrades --")
ok(comp.hqLevel == CC.HQ_BASE_LEVEL, "starts at base tier")
farmMoney = 1000000
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_UPGRADE, 1, nil, nil),
   "upgrade HQ once")
ok(comp.hqLevel == CC.HQ_BASE_LEVEL + 1, "tier increased", comp.hqLevel)
ok(comp:getBoardSize() == 5 + 1, "board size grew with tier",
   comp:getBoardSize())

print("\n-- maintenance --")
local mTruck = TransportCompanyTruck.new(truckVeh)
mTruck.distanceM = TransportCompanyTruck.SERVICE_INTERVAL_KM - 1
ok(mTruck:checkService() == 0, "no service before the milestone")
mTruck.distanceM = TransportCompanyTruck.SERVICE_INTERVAL_KM
local cost = mTruck:checkService()
ok(cost == TransportCompanyTruck.SERVICE_BASE_COST, "first service at base cost", cost)
ok(mTruck.servicesDone == 1, "service counted")
ok(mTruck.otherCost == cost, "service booked as truck expense")
ok(mTruck:checkService() == 0, "no double service immediately after")
mTruck.distanceM = TransportCompanyTruck.SERVICE_INTERVAL_KM * 2
local cost2 = mTruck:checkService()
ok(cost2 > TransportCompanyTruck.SERVICE_BASE_COST, "later services cost more", cost2)

print("\n-- maintenance catch-up charges all due in one bill --")
-- A truck that comes back from a long drive past several milestones
-- must pay for them all in ONE check, not one service per tick.
local catchTruck = TransportCompanyTruck.new(truckVeh)
catchTruck.distanceM = TransportCompanyTruck.SERVICE_INTERVAL_KM * 5
local catchCost = catchTruck:checkService()
ok(catchCost > TransportCompanyTruck.SERVICE_BASE_COST * 4, "catch-up bills all overdue", catchCost)
ok(catchTruck.servicesDone == 5, "catch-up counted all five", catchTruck.servicesDone)
ok(catchTruck:checkService() == 0, "no drip after catch-up")

print("\n-- legacy truck not serviced retroactively --")
-- A truck saved before maintenance existed loads with real distance
-- but a default milestone; normalizeService must push the milestone
-- past that distance so no retroactive bill lands on load.
local legacyTruck = TransportCompanyTruck.new(truckVeh)
legacyTruck.distanceM = 12500
legacyTruck.nextServiceKm = TransportCompanyTruck.SERVICE_INTERVAL_KM  -- default from old save
legacyTruck:normalizeService()
ok(legacyTruck.nextServiceKm > 12500, "milestone rolled past the odometer", legacyTruck.nextServiceKm)
ok(legacyTruck:checkService() == 0, "no service for pre-tracking miles")

print("\n-- weekly wages --")
booked = {}
farmMoney = 1000000
local wdrv = D.new("Wage", D.BASE_WEEKLY_WAGE)
wdrv.driverId = "drv_wage"
comp.drivers["drv_wage"] = wdrv
comp.wageTimer = TransportCompanyContract.DAY_LENGTH * 7 - 1
local totalWage = comp:getTotalWeeklyWage()
ok(totalWage > 0, "weekly wage total positive", totalWage)
mgr:_payWeeklyWages(comp)
ok(approx(farmMoney, 1000000 - totalWage), "weekly wage deducted",
   string.format("money=%d wage=%d", farmMoney, totalWage))
ok(#booked == 1 and booked[1].amount == -totalWage, "wage booked once", #booked)
ok(#comp.ledgerHistory >= 1, "P&L period recorded", #comp.ledgerHistory)

print("\n-- P&L rollup --")
local hist = comp.ledgerHistory[#comp.ledgerHistory]
ok(hist.jobs >= 0 and hist.revenue >= 0, "period carries the rollup fields")
local revenueBefore = comp.ledger.revenue
local jobsBefore = comp.ledger.jobs
mgr:_rollLedgerPeriod(comp, 1000, 100, 1, 5000)
ok(#comp.ledgerHistory >= 1, "second period appended")
ok(comp.ledger.revenue == revenueBefore and comp.ledger.jobs == jobsBefore,
   "ledger unchanged by rollup (rollup is display only)")

print("\n-- driver request validates farm ownership --")
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 0, nil, nil) == false,
   "farmId 0 refused")
ok(mgr:onDriverRequest(TransportCompanyDriverEvent.ACTION_HIRE, 99, nil, nil) == false,
   "company-less farm refused")

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
