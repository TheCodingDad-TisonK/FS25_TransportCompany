local ROOT = ...
local pass, fail = 0, 0
local function ok(c,n,e) if c then pass=pass+1; print("  PASS "..n)
  else fail=fail+1; print("  FAIL "..n..(e and ("  -> "..tostring(e)) or "")) end end

function Class(target, base)
  local mt = { __index = target }
  if base then setmetatable(target,{__index=base}); target.superClass=function() return base end end
  target.class=function() return target end; return mt
end
g_currentModName="FS25_TransportCompany"
FillType={UNKNOWN=0,DIESEL=1,WHEAT=2}
MoneyType={MISSIONS="missions",AI="ai"}
function printWarning() end function printError() end
TransportCompanyLog={info=function() end,debug=function() end,warning=function() end,error=function() end}
g_currentMission={ time=5000, hud={}, addMoney=function() end,
  addIngameNotification=function() end, getFarmId=function() return 1 end }
FSBaseMission={INGAME_NOTIFICATION_OK={}}
g_i18n={getText=function(_,k) return k end, formatMoney=function(_,v) return tostring(v) end}
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function(_, i)
        return { isPalletType = false, hudOverlayFilename = "hud_wheat.png" }
    end,
}

dofile(ROOT.."/scripts/transportCompany/TransportCompanyContract.lua")
dofile(ROOT.."/scripts/transportCompany/TransportCompanyTruck.lua")
dofile(ROOT.."/scripts/transportCompany/TransportCompanySettings.lua")
dofile(ROOT.."/scripts/transportCompany/TransportCompanyCompany.lua")
dofile(ROOT.."/scripts/transportCompany/TransportCompanyManager.lua")

TransportCompanyContractEvent={TYPE_ADD=1,TYPE_UPDATE=2,TYPE_STATE_CHANGE=3,TYPE_REMOVE=4,sendEvent=function() end}
TransportCompanyMoneyEvent={TYPE_CONTRACT_REWARD=1,TYPE_HIRED_DRIVER_CUT=2,sendEvent=function() end}
TransportCompanyAcceptEvent={MODE_SELF=1,MODE_HIRE=2}

local C=TransportCompanyContract
local mgr=TransportCompanyManager.new("/mods/tc/","FS25_TransportCompany")
mgr.isServer,mgr.isMissionLoaded=true,true
mgr._regenerateContractBoard=function() end
g_transportCompanyManager=mgr
-- Farm 1's company holds the board and ledger.
local comp = mgr:getOrCreateCompany(1)

-- A real UnloadingStation always exposes an AI drive target
-- (getAITargetPositionAndDirection); it returns nil only when no trigger
-- on the station supports AI. The mocks below model AI-capable stations.
local DEST={
    name="dest",
    getAITargetPositionAndDirection = function() return 0, 0, 0, 0 end,
}
local function add(id)
  local c=C.new(); c.contractId=id; c.amount=1000; c.litersPerUnit=1; c.reward=500
  c.fillTypeIndex=FillType.WHEAT
  c.getDestStation=function() return DEST end
  c.getSourceStation=function() return {name="src"} end
  comp.contracts[id]=c; return c
end

print("\n-- accept for self --")
local c1=add("a1")
ok(mgr:onAcceptRequest("a1", TransportCompanyAcceptEvent.MODE_SELF, 1), "accept succeeds")
ok(c1.state==C.STATE_ACCEPTED, "state ACCEPTED")
ok(c1.farmId==1, "farm recorded")
ok(c1.isHiredDriver==false, "not a hired driver")
ok(c1.deadline > g_currentMission.time, "deadline starts at accept time", c1.deadline)

print("\n-- refusals --")
ok(mgr:onAcceptRequest("a1", 1, 1)==false, "cannot accept twice")
ok(mgr:onAcceptRequest("nope", 1, 1)==false, "unknown contract refused")
local c2=add("a2")
ok(mgr:onAcceptRequest("a2", 1, 0)==false, "farmId 0 refused")
ok(c2.state==C.STATE_AVAILABLE, "refused contract stays available")
mgr.isServer=false
ok(mgr:onAcceptRequest("a2", 1, 1)==false, "client cannot accept locally")
mgr.isServer=true

print("\n-- hire with no usable truck is refused cleanly --")
local c3=add("a3")
g_currentMission.aiJobTypeManager={ createJob=function() return {
  getIsAvailableForVehicle=function() return false end } end }
AIJobType={LOAD_AND_DELIVER=5}
ok(mgr:onAcceptRequest("a3", TransportCompanyAcceptEvent.MODE_HIRE, 1)==false, "hire refused without truck")
ok(c3.state==C.STATE_AVAILABLE, "contract not left half-accepted")
ok(c3.farmId==0 and c3.isHiredDriver==false, "no residue on refused hire")

print("\n-- accepted contract then delivers and pays --")
mgr:onGoodsDelivered(DEST, 1, 1000, FillType.WHEAT)
ok(c1.state==C.STATE_COMPLETED, "self-accepted contract completes on delivery")
ok(comp.ledger.jobs==1, "ledger counted the job", comp.ledger.jobs)

print("")
print("-- hiring a driver for a job already accepted --")
-- Accepting used to hide both buttons, so a job you took could never be
-- handed over. It also has to survive the AI's own checks, which are
-- stricter than contract generation: AI-supported fill type, and stock
-- the FARM can draw (AIParameterLoadingStation:validate).
local STATION_OK = {
    name = "ok",
    getIsFillTypeAISupported = function() return true end,
    getFillLevel = function(_, ft, farm) return farm == 1 and 9000 or 0 end,
    getAITargetPositionAndDirection = function() return 0, 0, 0, 0 end,
}
local STATION_EMPTY = {
    name = "empty",
    getIsFillTypeAISupported = function() return true end,
    getFillLevel = function() return 0 end,
    getAITargetPositionAndDirection = function() return 0, 0, 0, 0 end,
}
local STATION_NOAI = {
    name = "noai",
    getIsFillTypeAISupported = function() return false end,
    getFillLevel = function() return 9000 end,
    getAITargetPositionAndDirection = function() return 0, 0, 0, 0 end,
}

local function jobWith(id, src)
    local c = C.new()
    c.contractId, c.amount, c.litersPerUnit, c.reward = id, 1000, 1, 500
    c.fillTypeIndex = FillType.WHEAT
    c.getSourceStation = function() return src end
    c.getDestStation = function() return DEST end
    comp.contracts[id] = c
    return c
end

local h1 = jobWith("h1", STATION_OK)
ok(select(1, h1:getIsAiHaulable(1)) == true, "haulable when stocked and AI-supported")
ok(select(1, h1:getIsAiHaulable(0)) == false, "not haulable without a farm")
local h2 = jobWith("h2", STATION_EMPTY)
local haul, why = h2:getIsAiHaulable(1)
ok(haul == false and why == "transportCompany_hireStationEmpty",
   "empty station reported precisely", why)
local h3 = jobWith("h3", STATION_NOAI)
haul, why = h3:getIsAiHaulable(1)
ok(haul == false and why == "transportCompany_hireNotAiFillType",
   "non-AI fill type reported precisely", why)

-- accept for self, then hand it to a driver
g_currentMission.aiJobTypeManager = { createJob = function() return {
    getIsAvailableForVehicle = function() return false end } end }
AIJobType = { LOAD_AND_DELIVER = 5 }
ok(mgr:onAcceptRequest("h1", TransportCompanyAcceptEvent.MODE_SELF, 1),
   "accept for self succeeds")
ok(h1.state == C.STATE_ACCEPTED and h1.isHiredDriver == false, "self-hauled")
-- no usable truck, so the hire is refused -- but it must be REACHED,
-- not rejected up front for being already accepted
ok(mgr:onAcceptRequest("h1", TransportCompanyAcceptEvent.MODE_HIRE, 1) == false,
   "hire on an accepted job is attempted and refused cleanly")
ok(h1.state == C.STATE_ACCEPTED, "still accepted after a failed hire")
ok(h1.isHiredDriver == false, "no phantom driver left behind")
ok(mgr:onAcceptRequest("h1", TransportCompanyAcceptEvent.MODE_HIRE, 2) == false,
   "another farm cannot hire for it")

print("\n-- books broadcast builds a full snapshot (server) --")
local lastBooks = nil
TransportCompanyBooksEvent = {
    new = function() return {} end,
    sendEvent = function(ev) lastBooks = ev end,
}
local bm = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
bm.isServer, bm.isMissionLoaded = true, true
local bcomp = bm:getOrCreateCompany(1)
bcomp.ledger.revenue, bcomp.ledger.driverWages, bcomp.ledger.jobs = 500, 100, 4
local bveh = { getUniqueId = function() return "v9" end,
               getFullName = function() return "Volvo" end,
               getOwnerFarmId = function() return 1 end }
bcomp.trucks["v9"] = TransportCompanyTruck.new(bveh)
bcomp.trucks["v9"].fuelCost, bcomp.trucks["v9"].distanceM = 12, 5000
bm:_broadcastBooks(1)
ok(lastBooks ~= nil and lastBooks.ledgerRevenue == 500 and lastBooks.ledgerJobs == 4,
   "broadcast carries the ledger snapshot", lastBooks and lastBooks.ledgerRevenue)
ok(lastBooks.trucks ~= nil and lastBooks.trucks[1].uniqueId == "v9"
   and lastBooks.trucks[1].fuelCost == 12 and lastBooks.trucks[1].distanceM == 5000,
   "broadcast carries every truck's books",
   lastBooks ~= nil and lastBooks.trucks ~= nil and lastBooks.trucks[1] ~= nil
   and lastBooks.trucks[1].fuelCost)

print("\n-- client applies the books snapshot --")
local cm = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
cm.isServer = false
cm:onBooksEvent({
    ledgerRevenue = 1234, ledgerDriverWages = 100, ledgerJobs = 3,
    trucks = {
        { uniqueId = "v1", vehicleName = "Scania", farmId = 1,
          revenue = 900, fuelCost = 50, otherCost = 20, distanceM = 10000, jobsDelivered = 2 },
    },
}, 1)
local ccomp = cm:getCompany(1)
ok(ccomp ~= nil and ccomp.ledger.revenue == 1234 and ccomp.ledger.driverWages == 100 and ccomp.ledger.jobs == 3,
   "client ledger synced from the snapshot", ccomp ~= nil and ccomp.ledger.revenue)
local c1 = ccomp ~= nil and ccomp.trucks["v1"]
ok(c1 ~= nil and c1.revenue == 900 and c1.fuelCost == 50 and c1.distanceM == 10000,
   "client truck books synced", c1 ~= nil and c1.distanceM)
ok(c1 ~= nil and c1:getProfit() == 830, "placeholder truck still has methods", c1 and c1:getProfit())

print("\n-- company enabled mid-session resumes --")
MessageType = { AI_JOB_STOPPED = 1 }
g_messageCenter = { subscribe = function() end }
local rm = TransportCompanyManager.new("/mods/tc/", "FS25_TransportCompany")
rm.isServer = true
local rcomp = rm:getOrCreateCompany(1)
rcomp.settings:set("enabled", false)
local boardCalls = 0
rm._regenerateContractBoard = function() boardCalls = boardCalls + 1 end
rm:_onMissionStarted()
ok(rm._startupRan == true, "mission setup runs even when the company starts disabled")
ok(rm._aiSubscribed == true, "AI completion listener is subscribed from the start")
ok(boardCalls == 0, "board is not filled while the company is disabled", boardCalls)
rcomp.settings:set("enabled", true)
rm:_regenerateContractBoard(1)
ok(boardCalls == 1, "board fills when the company is turned on", boardCalls)

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
