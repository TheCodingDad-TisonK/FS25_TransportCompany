-- simtest5: exercise the REAL contract generator against a stubbed
-- storage system.
--
-- The generator (TransportCompanyContract.generate) is the most complex
-- and historically bug-prone function in the mod, but earlier suites
-- stubbed _regenerateContractBoard, so it was never executed by the
-- tests. This suite builds a fake storageSystem (loading/unloading
-- stations with owning placeables, stock and AI support) and runs the
-- shipped generator for real: pool selection, station-index
-- persistence, amount/reward math, deadline and nil-safety.
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
FillType = { UNKNOWN = 0, DIESEL = 1, WHEAT = 2, BARLEY = 3, FERTILIZER = 4 }
function printWarning() end
function printError() end
TransportCompanyLog = { info = function() end, debug = function() end,
                        warning = function() end, error = function() end }
g_i18n = { getText = function(_, k) return k end,
           formatMoney = function(_, v) return tostring(v) end }
g_fillTypeManager = {
    getFillTypeNameByIndex = function() return "wheat" end,
    getFillTypeTitleByIndex = function() return "Wheat" end,
    getFillTypeByIndex = function(_, i)
        -- BARLEY is a pallet-type good here so pallet contracts generate.
        return { isPalletType = i == FillType.BARLEY, hudOverlayFilename = "hud_wheat.png" }
    end,
}

-- ── stub storage system ────────────────────────────────────────
-- A station is a table with an owningPlaceable and the station APIs
-- the generator reads. Station <-> index mapping is per placeable.
local placeables = {}
local loadingByPlaceable = {}    -- placeable -> {station -> index}  (persistence map)
local loadingIndexByPlaceable = {} -- placeable -> {index -> station} (reverse lookup)
local unloadingByPlaceable = {}   -- placeable -> {station -> index}
local unloadingIndexByPlaceable = {} -- placeable -> {index -> station}

local function makePlaceable(id, x, z)
    local p = { placeableId = id, x = x, z = z, rootNode = { id = id } }
    p.getUniqueId = function() return "placeable_" .. id end
    p.getOwnerFarmId = function() return 1 end
    placeables[p.getUniqueId()] = p
    return p
end

local function makeLoadingStation(placeable, name, supported, stock, aiSupported)
    local s = {
        name = name,
        owningPlaceable = placeable,
        sourceStorages = {},
    }
    s.getSupportedFillTypes = function()
        local t = {}
        for _, ft in ipairs(supported) do t[ft] = true end
        return t
    end
    s.getIsFillTypeSupported = function() return true end
    s.getIsFillTypeAISupported = function(_, ft)
        if aiSupported == nil then return false end
        for _, f in ipairs(aiSupported) do if f == ft then return true end end
        return false
    end
    s.getFillLevel = function(_, ft, farm) return stock[ft] or 0 end
    s.getAITargetPositionAndDirection = function() return 0, 0, 0, 0, {} end
    s.getName = function() return name end
    if loadingByPlaceable[placeable] == nil then loadingByPlaceable[placeable] = {} end
    local index = #loadingByPlaceable[placeable] + 1
    loadingByPlaceable[placeable][s] = index
    if loadingIndexByPlaceable[placeable] == nil then loadingIndexByPlaceable[placeable] = {} end
    loadingIndexByPlaceable[placeable][index] = s
    return s
end

local function makeUnloadingStation(placeable, name, supported, capacity)
    local s = {
        name = name,
        owningPlaceable = placeable,
        supported = supported,
        capacity = capacity or 100000,
    }
    s.getSupportedFillTypes = function()
        local t = {}
        for _, ft in ipairs(supported) do t[ft] = true end
        return t
    end
    s.getIsFillTypeSupported = function(_, ft)
        for _, f in ipairs(supported) do if f == ft then return true end end
        return false
    end
    s.getIsFillTypeAISupported = function(_, ft)
        for _, f in ipairs(supported) do if f == ft then return true end end
        return false
    end
    s.getFreeCapacity = function() return s.capacity end
    s.getAITargetPositionAndDirection = function() return 0, 0, 0, 0, {} end
    s.getName = function() return name end
    if unloadingByPlaceable[placeable] == nil then unloadingByPlaceable[placeable] = {} end
    local index = #unloadingByPlaceable[placeable] + 1
    unloadingByPlaceable[placeable][s] = index
    if unloadingIndexByPlaceable[placeable] == nil then unloadingIndexByPlaceable[placeable] = {} end
    unloadingIndexByPlaceable[placeable][index] = s
    return s
end

-- World layout:
--  A: farm-owned silo holding wheat+barley, AI-loadable -> aiStations
--  B: map-owned elevator holding wheat, no AI loading           -> stockedStations
--  C: sell point for wheat/barley (unloading)
--  D: dairy accepting wheat (unloading)
local placeableA = makePlaceable("A", 0, 0)
local placeableB = makePlaceable("B", 1000, 0)
local placeableC = makePlaceable("C", 2000, 0)
local placeableD = makePlaceable("D", 3000, 0)

local siloA = makeLoadingStation(placeableA, "Farm Silo",
    { FillType.WHEAT, FillType.BARLEY },
    { [FillType.WHEAT] = 50000, [FillType.BARLEY] = 30000 },
    { FillType.WHEAT, FillType.BARLEY })
local elevatorB = makeLoadingStation(placeableB, "Map Elevator",
    { FillType.WHEAT },
    { [FillType.WHEAT] = 80000 },
    nil)  -- no AI loading

local sellC = makeUnloadingStation(placeableC, "Sell Point",
    { FillType.WHEAT, FillType.BARLEY })
local dairyD = makeUnloadingStation(placeableD, "Dairy",
    { FillType.WHEAT })

g_currentMission = {
    time = 1000000,
    storageSystem = {
        loadingStations = { [siloA] = true, [elevatorB] = true },
        unloadingStations = { [sellC] = true, [dairyD] = true },
        getPlaceableLoadingStation = function(_, placeable, index)
            return loadingIndexByPlaceable[placeable] ~= nil and loadingIndexByPlaceable[placeable][index] or nil
        end,
        getPlaceableUnloadingStation = function(_, placeable, index)
            return unloadingIndexByPlaceable[placeable] ~= nil and unloadingIndexByPlaceable[placeable][index] or nil
        end,
        getPlaceableLoadingStationIndex = function(_, placeable, station)
            return loadingByPlaceable[placeable] ~= nil and loadingByPlaceable[placeable][station] or 0
        end,
        getPlaceableUnloadingStationIndex = function(_, placeable, station)
            return unloadingByPlaceable[placeable] ~= nil and unloadingByPlaceable[placeable][station] or 0
        end,
    },
    placeableSystem = {
        getPlaceableByUniqueId = function(_, uniqueId) return placeables[uniqueId] end,
    },
    economyManager = {
        getPricePerLiter = function(_, ft)
            if ft == FillType.WHEAT then return 0.6 end
            if ft == FillType.BARLEY then return 0.4 end
            return 0.05
        end,
    },
}

dofile(ROOT .. "/scripts/transportCompany/TransportCompanyContract.lua")
local C = TransportCompanyContract

print("\n-- generator produces valid contracts --")
local seenIds = {}
local generated = 0
math.randomseed(42)
for i = 1, 40 do
    local c = C.generate(7, 1)
    if c == nil then
        -- A small chance of failure is fine (random dest pick), but the
        -- pool here is rich enough that it should basically never fail.
        fail = fail + 1; print("  FAIL generate returned nil on iteration " .. i)
        break
    end
    generated = generated + 1

    if seenIds[c.contractId] then
        fail = fail + 1; print("  FAIL duplicate contractId " .. c.contractId)
    end
    seenIds[c.contractId] = true
end
ok(generated > 30, "generator succeeds on the rich stub map", generated)

print("\n-- contract fields are coherent --")
local c = C.generate(7, 1)
if c == nil then
    fail = fail + 1; print("  FAIL could not generate a probe contract")
else
    ok(c.amount > 0 and c.reward > 0, "amount and reward positive",
       string.format("amount=%d reward=%d", c.amount, c.reward))
    ok(c.state == C.STATE_AVAILABLE, "generated contracts are AVAILABLE")
    ok(c.generatorVersion == C.GENERATOR_VERSION, "generator version stamped")
    ok(c.deadline == 1000000 + 86400000 * 7, "deadline = now + configured days", c.deadline)
    ok(c.sourceUniqueId ~= nil and c.sourceUniqueId ~= "", "source uniqueId persisted")
    ok(c.sourceStationIndex ~= nil and c.sourceStationIndex > 0, "source index persisted", c.sourceStationIndex)
    ok(c.destUniqueId ~= nil and c.destUniqueId ~= "", "dest uniqueId persisted")
    ok(c.destStationIndex ~= nil and c.destStationIndex > 0, "dest index persisted", c.destStationIndex)
    ok(c:getSourceStation() ~= nil, "source resolves against the stub world")
    ok(c:getDestStation() ~= nil, "dest resolves against the stub world")
    ok(c:getSourceStation() ~= c:getDestStation(), "source and dest are distinct stations")

    -- Fill type matches the source's supported set.
    local src = c:getSourceStation()
    local ft = c.fillTypeIndex
    local srcSupports = src:getSupportedFillTypes()[ft] == true
    ok(srcSupports, "fill type is one the source supports")
end

print("\n-- bulk contract math --")
local bulkCount, palletCount = 0, 0
for i = 1, 60 do
    local g = C.generate(7, 1)
    if g ~= nil then
        if g.contractType == C.CONTRACT_TYPE_BULK then
            bulkCount = bulkCount + 1
            local price = g_currentMission.economyManager:getPricePerLiter(g.fillTypeIndex)
            -- reward = floor(amount * price * 0.15)
            local expect = math.floor(g.amount * price * 0.15)
            if not approx(g.reward, expect) then
                fail = fail + 1; print(string.format("  FAIL bulk reward %d != %d (amount=%d price=%s)",
                    g.reward, expect, g.amount, tostring(price)))
            end
            if g.amount < 8000 or g.amount > 24000 then
                fail = fail + 1; print("  FAIL bulk amount out of range " .. g.amount)
            end
            if g.litersPerUnit ~= 1 then
                fail = fail + 1; print("  FAIL bulk litersPerUnit should be 1")
            end
        else
            palletCount = palletCount + 1
            -- pallet reward = amount * 350
            local expect = g.amount * C.REWARD_PER_OBJECT
            if not approx(g.reward, expect) then
                fail = fail + 1; print(string.format("  FAIL pallet reward %d != %d", g.reward, expect))
            end
            if g.litersPerUnit ~= C.LITERS_PER_PALLET then
                fail = fail + 1; print("  FAIL pallet litersPerUnit should be 1000")
            end
        end
    end
end
ok(bulkCount > 0, "bulk contracts generated", bulkCount)
ok(palletCount > 0, "pallet contracts generated", palletCount)

print("\n-- AI-availability preference --")
-- With an AI-capable source (siloA) stocked and AI-capable dests, the
-- generator should prefer AI-stations so hired drivers can run jobs.
local aiFound = 0
for i = 1, 40 do
    local g = C.generate(7, 1)
    if g ~= nil then
        local src = g:getSourceStation()
        local aiOk = src.getIsFillTypeAISupported ~= nil
            and src:getIsFillTypeAISupported(g.fillTypeIndex)
        if aiOk then aiFound = aiFound + 1 end
    end
end
ok(aiFound >= 30, "AI-capable source preferred when available", aiFound)

print("\n-- no source stock caps the amount --")
-- elevatorB holds 80000 wheat with no AI. A contract drawn from it
-- must not ask for more than the physical stock.
local capOk = true
for i = 1, 30 do
    local g = C.generate(7, 1)
    if g ~= nil and g:getSourceStation() == elevatorB then
        if g.amount > 80000 then
            capOk = false
            print("  FAIL amount " .. g.amount .. " exceeds source stock")
        end
    end
end
ok(capOk, "amount capped by available stock")

print(string.format("\n%d passed, %d failed", pass, fail))
return fail
