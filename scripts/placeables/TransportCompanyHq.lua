-- =========================================================
-- FS25 Transport Company - Headquarters Placeable Specialization
-- =========================================================
--
-- The Headquarters is the building that activates the Transport
-- Company. While the player owns and has placed an HQ, the
-- dispatch office (PDA page) is available and the manager runs
-- the company (contract board, fleet registry, ledger).
--
-- This specialization is intentionally thin: it only tracks the
-- placeable lifecycle and notifies the global manager. All logic,
-- savegame data and multiplayer sync live in TransportCompanyManager
-- and its helper classes.
--
-- Lifecycle notes (verified against decompiled base game):
--   - Placeable:onBuy  (Placeable.lua:862)  - bought in shop, before placement
--   - onFinalizePlacement / onPostFinalizePlacement (Placeable.lua:537-538)
--   - SellPlaceableEvent:run calls onSell() THEN placeable:delete()
--     (SellPlaceableEvent.lua:68,81) -> onSell AND onDelete both fire on sell.
--     onDelete also fires on deletion (Placeable.lua:577).
-- =========================================================

local modName = g_currentModName

---@class TransportCompanyHq
TransportCompanyHq = {}
TransportCompanyHq.SPEC_TABLE_NAME = "spec_" .. modName .. ".transportCompanyHq"

function TransportCompanyHq.prerequisitesPresent(...)
    return true
end

function TransportCompanyHq.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",                  TransportCompanyHq)
    SpecializationUtil.registerEventListener(placeableType, "onPostFinalizePlacement", TransportCompanyHq)
    SpecializationUtil.registerEventListener(placeableType, "onSell",                  TransportCompanyHq)
    SpecializationUtil.registerEventListener(placeableType, "onDelete",                TransportCompanyHq)
end

function TransportCompanyHq.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TransportCompanyHq")
    -- The HQ currently carries no per-instance XML data. The empty
    -- <transportCompanyHq /> tag in the placeable XML is the marker
    -- that activates this specialization's behavior.
    schema:setXMLSpecializationType()
end

function TransportCompanyHq.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TransportCompanyHq")
    -- No per-instance savegame data: the placeable itself (position,
    -- owner farm, rotation) is saved by the base game. Company state
    -- (contracts, fleet, ledger) is saved by the manager into the mod
    -- savegame file.
    schema:setXMLSpecializationType()
end

-- ─── onLoad ──────────────────────────────────────────────

function TransportCompanyHq:onLoad(savegame)
    local spec = {}
    self[TransportCompanyHq.SPEC_TABLE_NAME] = spec
    spec.isActive = true
    spec.savegame = savegame
end

-- ─── onPostFinalizePlacement ─────────────────────────────

function TransportCompanyHq:onPostFinalizePlacement()
    local spec = self[TransportCompanyHq.SPEC_TABLE_NAME]
    if spec == nil then return end

    spec.isActive = true
    spec.savegame = nil

    -- Notify the manager so it can refresh the company/HQ state.
    -- The manager decides what to update (PDA availability, contract
    -- board, hints); it works the same on server and client.
    if g_transportCompanyManager ~= nil then
        g_transportCompanyManager:onHqChanged(self)
    end
end

-- ─── onSell ──────────────────────────────────────────────

function TransportCompanyHq:onSell()
    local spec = self[TransportCompanyHq.SPEC_TABLE_NAME]
    if spec == nil then return end

    spec.isActive = false

    if g_transportCompanyManager ~= nil then
        g_transportCompanyManager:onHqChanged(self)
    end
end

-- ─── onDelete ────────────────────────────────────────────

function TransportCompanyHq:onDelete()
    local spec = self[TransportCompanyHq.SPEC_TABLE_NAME]
    if spec == nil then return end

    -- onSell already fired for a sell (and already notified the
    -- manager), so only notify here when we are still active.
    local wasActive = spec.isActive
    spec.isActive = false
    self[TransportCompanyHq.SPEC_TABLE_NAME] = nil

    if wasActive and g_transportCompanyManager ~= nil then
        g_transportCompanyManager:onHqChanged(self)
    end
end
