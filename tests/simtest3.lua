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
dofile(ROOT.."/scripts/transportCompany/TransportCompanyManager.lua")

TransportCompanyContractEvent={TYPE_ADD=1,TYPE_UPDATE=2,TYPE_STATE_CHANGE=3,TYPE_REMOVE=4,sendEvent=function() end}
TransportCompanyMoneyEvent={TYPE_CONTRACT_REWARD=1,TYPE_HIRED_DRIVER_CUT=2,sendEvent=function() end}
TransportCompanyAcceptEvent={MODE_SELF=1,MODE_HIRE=2}

local C=TransportCompanyContract
local mgr=TransportCompanyManager.new("/mods/tc/","FS25_TransportCompany")
mgr.isServer,mgr.isMissionLoaded=true,true
mgr._regenerateContractBoard=function() end
g_transportCompanyManager=mgr

local DEST={name="dest"}
local function add(id)
  local c=C.new(); c.contractId=id; c.amount=1000; c.litersPerUnit=1; c.reward=500
  c.fillTypeIndex=FillType.WHEAT
  c.getDestStation=function() return DEST end
  c.getSourceStation=function() return {name="src"} end
  mgr.contracts[id]=c; return c
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
ok(mgr.ledger.jobs==1, "ledger counted the job", mgr.ledger.jobs)

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
