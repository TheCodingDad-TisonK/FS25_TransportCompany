local ROOT = ...
local pass, fail = 0, 0
local function ok(c,n,e) if c then pass=pass+1; print("  PASS "..n)
  else fail=fail+1; print("  FAIL "..n..(e and ("  -> "..tostring(e)) or "")) end end
local function approx(a,b) return math.abs(a-b) < 1e-6 end

function Class(target, base)
  local mt = { __index = target }
  if base then setmetatable(target, { __index = base })
    target.superClass = function() return base end end
  target.class = function() return target end
  return mt
end
g_currentModName = "FS25_TransportCompany"
FillType = { UNKNOWN=0, DIESEL=1, WHEAT=2, BARLEY=3 }
MoneyType = { MISSIONS="missions", AI="ai", OTHER="other" }
function printWarning() end
function printError() end
TransportCompanyLog = { info=function() end, debug=function() end,
                        warning=function() end, error=function() end }

-- money ledger the fake mission records into
local booked = {}
g_currentMission = {
  time = 5000,
  hud = {},
  addMoney = function(_, amount, farmId, moneyType)
    assert(farmId ~= 0, "addMoney called with farmId 0")
    table.insert(booked, {amount=amount, farmId=farmId, moneyType=moneyType})
  end,
  addIngameNotification = function() end,
  getFarmId = function() return 1 end,
  vehicleSystem = { vehicleByUniqueId = {} },
}
FSBaseMission = { INGAME_NOTIFICATION_OK = {} }
g_i18n = { getText=function(_,k) return k end,
           formatMoney=function(_,v) return tostring(v) end,
           formatDistance=function(_,v) return tostring(v) end }
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function(_, i)
        return { isPalletType = false, hudOverlayFilename = "hud_wheat.png" }
    end,
}

dofile(ROOT .. "/scripts/transportCompany/TransportCompanyContract.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyTruck.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanySettings.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyCompany.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyManager.lua")

-- event stubs: record broadcasts instead of sending them
local sent = {}
TransportCompanyContractEvent = { TYPE_ADD=1, TYPE_UPDATE=2, TYPE_STATE_CHANGE=3, TYPE_REMOVE=4,
  sendEvent=function(t,c,s) table.insert(sent,{t=t,id=c and c.contractId,s=s}) end }
TransportCompanyMoneyEvent = { TYPE_CONTRACT_REWARD=1, TYPE_HIRED_DRIVER_CUT=2,
  TYPE_TRUCK_REVENUE=3, TYPE_EXPENSE=4, sendEvent=function() end }
TransportCompanyBooksEvent = { new=function() return {} end, sendEvent=function() end }

local C = TransportCompanyContract
local mgr = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
mgr.isServer, mgr.isMissionLoaded = true, true
mgr._regenerateContractBoard = function() end   -- no world to generate from
g_transportCompanyManager = mgr
-- Farm 1's company holds the board, trucks and ledger.
local comp = mgr:getOrCreateCompany(1)

local STATION_A, STATION_B = {name="A"}, {name="B"}
local function makeContract(id, amount, litersPerUnit, reward, dest, hired)
  local c = C.new()
  c.contractId, c.amount, c.litersPerUnit, c.reward = id, amount, litersPerUnit, reward
  c.fillTypeIndex = FillType.WHEAT
  c.getDestStation = function() return dest end
  c:accept(1, "", hired == true)
  c.isHiredDriver = hired == true
  comp.contracts[id] = c
  return c
end

print("\n-- delivery credits the right contract --")
local c1 = makeContract("c1", 10000, 1, 5000, STATION_A)
local c2 = makeContract("c2", 10000, 1, 5000, STATION_B)
mgr:onGoodsDelivered(STATION_A, 1, 3000, FillType.WHEAT)
ok(approx(c1.delivered, 3000), "destination contract credited", c1.delivered)
ok(approx(c2.delivered, 0), "other station untouched", c2.delivered)

print("\n-- wrong farm / wrong filltype are ignored --")
mgr:onGoodsDelivered(STATION_A, 2, 5000, FillType.WHEAT)
ok(approx(c1.delivered, 3000), "different farm ignored", c1.delivered)
mgr:onGoodsDelivered(STATION_A, 1, 5000, FillType.BARLEY)
ok(approx(c1.delivered, 3000), "different fill type ignored", c1.delivered)

print("\n-- completion pays exactly once --")
booked = {}
mgr:onGoodsDelivered(STATION_A, 1, 7000, FillType.WHEAT)
ok(c1.state == C.STATE_COMPLETED, "contract completed")
ok(#booked == 1 and approx(booked[1].amount, 5000), "paid full reward once", #booked)
ok(booked[1].farmId == 1, "paid the accepting farm")
ok(approx(comp.ledger.revenue, 5000) and comp.ledger.jobs == 1, "ledger updated")
booked = {}
mgr:onGoodsDelivered(STATION_A, 1, 5000, FillType.WHEAT)
ok(#booked == 0, "already-complete contract does not pay again", #booked)

print("\n-- hired driver: wage split --")
booked = {}
comp.settings:set("hiredDriverRewardShare", 20)
local c3 = makeContract("c3", 1000, 1, 1000, STATION_A, true)
mgr:onGoodsDelivered(STATION_A, 1, 1000, FillType.WHEAT)
ok(#booked == 2, "two money entries (revenue + wage)", #booked)
ok(approx(booked[1].amount, 800) and booked[1].moneyType == MoneyType.MISSIONS, "company gets 80%", booked[1].amount)
ok(approx(booked[2].amount, -200) and booked[2].moneyType == MoneyType.AI, "driver wage debited", booked[2].amount)
ok(approx(comp.ledger.driverWages, 200), "wages tracked in ledger", comp.ledger.driverWages)

print("\n-- AI job stop is a backstop, never a second payout --")
booked = {}
mgr:_completeHiredDriverContract(comp, c3, {jobId=1})
ok(#booked == 0, "no double payout from AI stop handler", #booked)

print("\n-- surplus rolls over to a second open contract --")
booked = {}
local d1 = makeContract("d1", 1000, 1, 100, STATION_B)
local d2 = makeContract("d2", 1000, 1, 100, STATION_B)
mgr:onGoodsDelivered(STATION_B, 1, 2500, FillType.WHEAT)
local bothDone = d1.state == C.STATE_COMPLETED and d2.state == C.STATE_COMPLETED
ok(bothDone, "one tip can finish two contracts")
ok(#booked == 2, "each paid once", #booked)

print("\n-- farmId 0 never reaches addMoney --")
booked = {}
local z = makeContract("z", 100, 1, 500, STATION_A)
z.farmId = 0
local okcall = pcall(function() mgr:onGoodsDelivered(STATION_A, 0, 100, FillType.WHEAT) end)
ok(okcall and #booked == 0, "spectator farm delivery refused, no crash")

print("\n-- disabled company ignores deliveries --")
local e1 = makeContract("e1", 100, 1, 50, STATION_A)
comp.settings:set("enabled", false)
mgr:onGoodsDelivered(STATION_A, 1, 100, FillType.WHEAT)
ok(approx(e1.delivered, 0), "no credit while disabled", e1.delivered)
comp.settings:set("enabled", true)

print("\n-- self-haul attribution: the tipping truck is credited --")
-- A truck whose trailer reports it is discharging into STATION_C must
-- get the revenue and job count when the delivery completes, even
-- though no truck was assigned to the contract up front.
local STATION_C = {name="C"}
booked = {}
local dispVeh = {
    getUniqueId = function() return "vehicleTip" end,
    getFullName = function() return "Tipper" end,
    getOwnerFarmId = function() return 1 end,
    getIsBeingDeleted = function() return false end,
    getChildVehicles = function()
        return { {
            getCurrentDischargeNode = function() return {} end,
            getCurrentDischargeObject = function(_, node) return STATION_C end,
        } }
    end,
}
local tipTruck = TransportCompanyTruck.new(dispVeh)
tipTruck.farmId = 1
tipTruck.isEnrolled = true
comp.trucks["vehicleTip"] = tipTruck
g_currentMission.vehicleSystem.vehicleByUniqueId["vehicleTip"] = dispVeh
local attrib = makeContract("att", 1000, 1, 500, STATION_C)
mgr:onGoodsDelivered(STATION_C, 1, 1000, FillType.WHEAT)
ok(attrib.state == C.STATE_COMPLETED, "self-haul contract completes", attrib.state)
ok(tipTruck.revenue == 500, "tipping truck credited the full reward", tipTruck.revenue)
ok(tipTruck.jobsDelivered == 1, "tipping truck got the job count", tipTruck.jobsDelivered)
ok(#booked == 1, "payout still happens exactly once", #booked)
-- A truck NOT discharging at the station must not be credited.
local idleVeh = {
    getUniqueId = function() return "vehicleIdle" end,
    getFullName = function() return "Idle" end,
    getOwnerFarmId = function() return 1 end,
    getIsBeingDeleted = function() return false end,
    getChildVehicles = function()
        return { {
            getCurrentDischargeNode = function() return {} end,
            getCurrentDischargeObject = function() return {} end,  -- not STATION_C
        } }
    end,
}
local idleTruck = TransportCompanyTruck.new(idleVeh)
idleTruck.farmId = 1
idleTruck.isEnrolled = true
comp.trucks["vehicleIdle"] = idleTruck
g_currentMission.vehicleSystem.vehicleByUniqueId["vehicleIdle"] = idleVeh
booked = {}
local attrib2 = makeContract("att2", 1000, 1, 500, STATION_C)
mgr:onGoodsDelivered(STATION_C, 1, 1000, FillType.WHEAT)
ok(attrib2.state == C.STATE_COMPLETED, "second self-haul contract completes")
ok(idleTruck.revenue == 0 and idleTruck.jobsDelivered == 0,
   "non-discharging truck is not credited", idleTruck.revenue)
-- And with NO truck discharging, the delivery still pays (additive only).
comp.trucks["vehicleTip"] = nil
comp.trucks["vehicleIdle"] = nil
booked = {}
local attrib3 = makeContract("att3", 1000, 1, 500, STATION_C)
mgr:onGoodsDelivered(STATION_C, 1, 1000, FillType.WHEAT)
ok(attrib3.state == C.STATE_COMPLETED, "delivery completes with no truck matched")
ok(#booked == 1, "payout independent of attribution", #booked)

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
