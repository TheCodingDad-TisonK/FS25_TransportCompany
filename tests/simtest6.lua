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

print("\n-- reset board (PDA button / tc_reset_board) --")
-- Board reset clears everything still in play, keeps the ledger
-- history, and calls off any AI job it orphans.
local stoppedJobs = {}
AIMessageErrorUnknown = { new = function() return {} end }
g_currentMission.aiSystem = {
    stopJobById = function(_, jobId) table.insert(stoppedJobs, jobId); return true end,
}
local removeEvents = {}
local realSend = TransportCompanyContractEvent.sendEvent
TransportCompanyContractEvent.sendEvent = function(eventType, contract)
    if eventType == TransportCompanyContractEvent.TYPE_REMOVE then
        table.insert(removeEvents, contract.contractId)
    end
end

comp.contracts = {}
local avail = C.new()
avail.contractId, avail.state = "r_avail", C.STATE_AVAILABLE
local hired = C.new()
hired.contractId, hired.state = "r_hired", C.STATE_ACCEPTED
hired.isHiredDriver, hired.hiredDriverJobId = true, 4242
local finished = C.new()
finished.contractId, finished.state = "r_done", C.STATE_COMPLETED
comp.contracts[avail.contractId] = avail
comp.contracts[hired.contractId] = hired
comp.contracts[finished.contractId] = finished
comp.stuckWatch["r_hired"] = { attempts = 2 }

local removed, remaining = mgr:resetBoard(1)
ok(removed == 2, "cleared both open jobs", removed)
ok(remaining == 1, "only the completed job remains", remaining)
ok(comp.contracts["r_done"] ~= nil, "completed job kept for the ledger")
ok(comp.contracts["r_avail"] == nil and comp.contracts["r_hired"] == nil,
   "open jobs gone from the board")
ok(#removeEvents == 2, "a REMOVE went out for each cleared job", #removeEvents)
ok(#stoppedJobs == 1 and stoppedJobs[1] == 4242,
   "the hired driver's AI job was stopped", stoppedJobs[1])
ok(comp.stuckWatch["r_hired"] == nil, "stuck watchdog entry cleared")

ok(mgr:onResetBoardRequest(0) == false, "reset refuses farmId 0")
ok(mgr:onResetBoardRequest(99) == false, "reset refuses a company-less farm")
ok(mgr:onResetBoardRequest(1), "reset applies for the owning farm")

TransportCompanyContractEvent.sendEvent = realSend

print("\n-- unstick: blocked detection --")
-- The engine keeps its own verdict on spec_aiDrivable; we read that
-- rather than inferring a stall from position.
AgentState = { DRIVING = 1, BLOCKED = 2, PLANNING = 3,
               NOT_REACHABLE = 4, TARGET_REACHED = 5 }
Drivable = { CRUISECONTROL_STATE_OFF = 0, CRUISECONTROL_STATE_ACTIVE = 1 }
local wheelCalls = {}
WheelsUtil = {
    updateWheelsPhysics = function(_, _, _, acceleration)
        table.insert(wheelCalls, acceleration)
    end,
}
-- Space behind is sampled from the navigation map; flip this to make
-- the world behind the truck solid.
local spaceBehindIsBlocked = false
function getVehicleNavigationMapCostAtWorldPos() return 0, spaceBehindIsBlocked end
function localToWorld(_, _, _, dz) return 0, 0, dz end
g_currentMission.aiSystem = {
    navigationMap = {},
    stopJobById = function() return true end,
    getJobById = function() return nil end,
}

local resumed = nil
local aiVehicle
aiVehicle = {
    rootNode = 1,
    lastSpeedReal = 0,
    movingDirection = 1,
    rotatedTime = 0.4,
    spec_aiDrivable = {
        isRunning = true, lastIsBlocked = false, lastState = AgentState.DRIVING,
        task = { name = "driveTo" },
        targetX = 100, targetY = 5, targetZ = 200,
        targetDirX = 0, targetDirY = 0, targetDirZ = 1,
        maxSpeed = 40, useManualDriving = false,
    },
    getMotor = function() return { setSpeedLimit = function() end } end,
    getCruiseControlState = function() return Drivable.CRUISECONTROL_STATE_ACTIVE end,
    setCruiseControlState = function() end,
    brake = function() end,
    stopVehicle = function() end,
    getIsBeingDeleted = function() return false end,
    setAITarget = function(_, task, x, y, z)
        resumed = { task = task, x = x, y = y, z = z }
        aiVehicle.spec_aiDrivable.isRunning = true
    end,
}
local aiSpec = aiVehicle.spec_aiDrivable

ok(mgr:_getIsAgentBlocked(aiVehicle) == false, "a driving agent is not blocked")
aiSpec.lastIsBlocked = true
ok(mgr:_getIsAgentBlocked(aiVehicle), "lastIsBlocked is read straight from the engine")
aiSpec.lastIsBlocked = false
aiSpec.lastState = AgentState.BLOCKED
ok(mgr:_getIsAgentBlocked(aiVehicle), "AgentState.BLOCKED counts too")
aiSpec.isRunning = false
ok(mgr:_getIsAgentBlocked(aiVehicle) == false, "a paused agent is never blocked")
aiSpec.isRunning = true

print("\n-- unstick: reverse nudge --")
ok(mgr:_hasSpaceBehind(aiVehicle), "clear road behind")
spaceBehindIsBlocked = true
ok(mgr:_hasSpaceBehind(aiVehicle) == false, "solid ground behind is refused")
local nudgeContract = C.new()
nudgeContract.contractId = "n1"
ok(mgr:_startReverseNudge(comp, nudgeContract, aiVehicle) == false,
   "no nudge without room to reverse into")
ok(aiSpec.isRunning, "agent left alone when the nudge is refused")

spaceBehindIsBlocked = false
ok(mgr:_startReverseNudge(comp, nudgeContract, aiVehicle), "nudge starts on a clear road")
ok(aiSpec.isRunning == false, "agent paused so it stops braking against us")
ok(aiVehicle.rotatedTime == 0, "wheels straightened before reversing")

wheelCalls = {}
mgr:_updateReverseNudge("n1", 100)
ok(#wheelCalls == 1 and wheelCalls[1] < 0, "reverses with negative acceleration",
   wheelCalls[1])
ok(mgr._activeNudges["n1"] ~= nil, "manoeuvre still running mid-way")

mgr:_updateReverseNudge("n1", TransportCompanyManager.NUDGE_DURATION_MS)
ok(mgr._activeNudges["n1"] == nil, "manoeuvre finished on the timer")
ok(resumed ~= nil and resumed.x == 100 and resumed.z == 200,
   "the agent got its original target back")
ok(resumed ~= nil and resumed.task == aiSpec.task, "and its original task")
ok(aiSpec.isRunning, "agent running again")

print("\n-- unstick: escalation --")
-- Past the retry budget the nudge is not attempted at all; the driver
-- is released and the truck sent home instead.
local recovered = {}
local realReplan = TransportCompanyManager._replanStuckDriver
TransportCompanyManager._replanStuckDriver = function(_, _, contract, _, attempt)
    table.insert(recovered, attempt)
end
mgr:_recoverBlockedDriver(comp, nudgeContract, nil, aiVehicle,
    TransportCompanyManager.STUCK_MAX_REPLAN_ATTEMPTS + 1)
ok(#recovered == 1, "over budget goes straight to the replan/give-up path")
ok(mgr._activeNudges["n1"] == nil, "and does not start another manoeuvre")
TransportCompanyManager._replanStuckDriver = realReplan

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
