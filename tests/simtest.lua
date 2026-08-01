-- Runtime harness: stub the engine surface these files touch, load them
-- for real, and exercise the contract / truck / settings logic.
local ROOT = ...
local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then pass = pass + 1; print("  PASS " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function approx(a,b) return math.abs(a-b) < 1e-6 end

-- ── engine stubs ──────────────────────────────────────────
function Class(target, base)
  local mt = { __index = target }
  if base then setmetatable(target, { __index = base })
    target.superClass = function() return base end end
  target.class = function() return target end
  return mt
end
g_currentModName = "FS25_TransportCompany"
FillType = { UNKNOWN = 0, DIESEL = 1, WHEAT = 2 }
g_currentMission = { time = 1000 }
g_i18n = { getText = function(_, k) return k end }
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function(_, i)
        return { isPalletType = false, hudOverlayFilename = "hud_wheat.png" }
    end,
}
function printWarning(s) end
function printError(s) end
TransportCompanyLog = { info=function() end, debug=function() end,
                        warning=function() end, error=function() end }

dofile(ROOT .. "/scripts/transportCompany/TransportCompanyContract.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanyTruck.lua")
dofile(ROOT .. "/scripts/transportCompany/TransportCompanySettings.lua")

local C = TransportCompanyContract

print("\n-- contract lifecycle --")
local c = C.new()
c.amount, c.litersPerUnit, c.reward = 10000, 1, 5000
c.deadline = 0
ok(c.state == C.STATE_AVAILABLE, "starts AVAILABLE")
ok(c:getIsExpired() == false, "no deadline => not expired")
ok(c:accept(1, "vehicleABC", false), "accept succeeds")
ok(c.state == C.STATE_ACCEPTED and c.farmId == 1, "accept records farm+state")
ok(c:accept(1, "x", false) == false, "double accept refused")

print("\n-- bulk delivery in liters --")
local consumed, done = c:addDeliveredLiters(4000)
ok(approx(consumed,4000) and not done, "partial delivery credits liters", consumed)
ok(approx(c.delivered,4000), "delivered tracks units", c.delivered)
consumed, done = c:addDeliveredLiters(9000)
ok(approx(consumed,6000), "only consumes what is still needed", consumed)
ok(done, "completion reported")
ok(approx(c.delivered, c.amount), "delivered clamped to amount")
consumed, done = c:addDeliveredLiters(500)
ok(consumed == 0 and not done, "completed contract consumes nothing")

print("\n-- pallet unit conversion --")
local p = C.new()
p.contractType, p.amount, p.litersPerUnit = C.CONTRACT_TYPE_PALLET, 5, C.LITERS_PER_PALLET
p:accept(1, "", false)
ok(approx(p:getRemainingLiters(), 5000), "5 pallets = 5000 L", p:getRemainingLiters())
local cons = p:addDeliveredLiters(2000)
ok(approx(p.delivered, 2), "2000 L credits 2 pallets", p.delivered)
cons, done = p:addDeliveredLiters(99999)
ok(approx(cons, 3000) and done, "surplus clamped to remaining 3000 L", cons)

print("\n-- complete / expire are idempotent --")
local d = C.new(); d.amount = 100
ok(d:complete() == true, "first complete returns true")
ok(d:complete() == false, "second complete returns false")
ok(d.completedTime == g_currentMission.time, "completedTime stamped")
local e = C.new(); e.amount = 100; e.deadline = 500
ok(e:getIsExpired(1000) == true, "past deadline is expired")
ok(e:expire() == true and e:expire() == false, "expire idempotent")
local f = C.new(); f:complete()
ok(f:expire() == false, "completed contract cannot expire")

print("")
print("-- station stock is physical, not access-gated --")
-- LoadingStation:getFillLevel filters every storage through
-- hasFarmAccessToStorage, so a map elevator reports 0 to the player and
-- everything reports 0 for farmId 0. Gating generation on it emptied
-- the board completely.
local storage = { getFillLevel = function(_, ft) return ft == FillType.WHEAT and 5000 or 0 end }
local mapStation = { sourceStorages = { storage }, getFillLevel = function() return 0 end }
ok(C.getStationStock(mapStation, FillType.WHEAT, 0) == 5000, "stock seen with farmId 0")
ok(C.getStationStock(mapStation, FillType.WHEAT, 1) == 5000, "stock seen regardless of access")
ok(C.getStationStock(mapStation, FillType.DIESEL, 1) == 0, "absent fill type reports zero")

local shop = { getFillLevel = function() return 777 end }
ok(C.getStationStock(shop, FillType.WHEAT, 1) == 777, "no sourceStorages falls back")
ok(C.getStationStock(shop, FillType.WHEAT, 0) == 0, "fallback needs a real farm")

-- The regression that emptied the board a second time: sourceStorages
-- PRESENT but EMPTY is not the same as no stock. Plenty of stations
-- model no storage; returning 0 there marked the whole map unstocked.
local emptyList = { sourceStorages = {}, getFillLevel = function() return 4200 end }
ok(C.getStationStock(emptyList, FillType.WHEAT, 1) == 4200,
   "empty sourceStorages falls through to the station query",
   C.getStationStock(emptyList, FillType.WHEAT, 1))
local reallyEmpty = { sourceStorages = {}, getFillLevel = function() return 0 end }
ok(C.getStationStock(reallyEmpty, FillType.WHEAT, 1) == 0,
   "genuinely empty station still reports zero")

-- A station can dispense goods with no storage behind it at all:
-- basicFillTypes is declared in the station XML and never runs out.
-- Reading those as empty made a whole map look barren -- 26 stations,
-- 108 routes, every one reporting zero.
local shopStation = {
  basicFillTypes = { [FillType.WHEAT] = true },
  sourceStorages = {},
  getFillLevel = function() return 0 end,
}
ok(C.getStationStock(shopStation, FillType.WHEAT, 1) == C.UNLIMITED_STOCK,
   "basicFillTypes reports unlimited supply",
   C.getStationStock(shopStation, FillType.WHEAT, 1))
ok(C.getStationStock(shopStation, FillType.DIESEL, 1) == 0,
   "a type the shop does not stock is still zero")

print("\n-- truck books --")
local veh = { getUniqueId=function() return "vehicleXYZ" end,
              getFullName=function() return "Scania" end,
              getOwnerFarmId=function() return 1 end }
local t = TransportCompanyTruck.new(veh)
ok(type(t.uniqueId)=="string", "uniqueId is a string")
t:addRevenue(1000); t:addExpense(150); t.fuelCost = 200; t:addJob()
ok(approx(t:getProfit(), 650), "profit = revenue - fuel - other", t:getProfit())
ok(t.fuelCost == 200 and t.otherCost == 150, "wages not folded into fuel")
ok(t.jobsDelivered == 1, "job counted")

print("\n-- settings --")
local s = TransportCompanySettings.new()
ok(s:get("enabled") == true, "default enabled")
ok(s:get("debugMode") == false, "default debugMode false")
s:set("maxActiveContracts", 999)
ok(s:get("maxActiveContracts") == 12, "clamped to max", s:get("maxActiveContracts"))
s:set("maxActiveContracts", -5)
ok(s:get("maxActiveContracts") == 1, "clamped to min")
s:set("hiredDriverRewardShare", 35)
ok(s:get("hiredDriverRewardShare") == 35, "in-range value kept")
ok(s:set("nonexistent", 1) == false, "unknown setting rejected")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
