-- =========================================================
-- FS25 Transport Company - Driver Request Event
-- =========================================================
-- Client -> Server request to manage the named driver roster and the
-- HQ upgrade tier. Both are company state, server-authoritative, so a
-- client sends a request and the server applies it, then pushes a
-- fresh TransportCompanyBooksEvent so everyone sees the new roster.
--
-- Actions:
--   HIRE    - add a named driver to the payroll (costs HIRE_COST)
--   FIRE    - remove a driver (no severance; the wage just stops)
--   ASSIGN  - set a driver's truck (or clear with "")
--   UPGRADE - raise the HQ one tier (costs from HQ_UPGRADE_COST)
--
-- Mirrors the proven FS25 event pattern used by the user's other mods.
-- =========================================================

TransportCompanyDriverEvent = {}
local TransportCompanyDriverEvent_mt = Class(TransportCompanyDriverEvent, Event)
InitEventClass(TransportCompanyDriverEvent, "TransportCompanyDriverEvent")

TransportCompanyDriverEvent.ACTION_HIRE = 1
TransportCompanyDriverEvent.ACTION_FIRE = 2
TransportCompanyDriverEvent.ACTION_ASSIGN = 3
TransportCompanyDriverEvent.ACTION_UPGRADE = 4

function TransportCompanyDriverEvent.emptyNew()
    return Event.new(TransportCompanyDriverEvent_mt)
end

---@param action number ACTION_*
---@param farmId number Farm whose company is affected
---@param driverId string|nil
---@param truckUniqueId string|nil
function TransportCompanyDriverEvent.new(action, farmId, driverId, truckUniqueId)
    local self = TransportCompanyDriverEvent.emptyNew()
    self.action = action
    self.farmId = farmId
    self.driverId = driverId
    self.truckUniqueId = truckUniqueId
    return self
end

--- Send the request to the server, or handle it inline when we are
--- the server already.
function TransportCompanyDriverEvent.sendEvent(action, farmId, driverId, truckUniqueId)
    if g_server ~= nil then
        if g_transportCompanyManager ~= nil then
            g_transportCompanyManager:onDriverRequest(action, farmId, driverId, truckUniqueId)
        end
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            TransportCompanyDriverEvent.new(action, farmId, driverId, truckUniqueId)
        )
    end
end

function TransportCompanyDriverEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action or 0)
    streamWriteInt32(streamId, self.farmId or 0)
    streamWriteString(streamId, self.driverId or "")
    streamWriteString(streamId, self.truckUniqueId or "")
end

function TransportCompanyDriverEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.farmId = streamReadInt32(streamId)
    self.driverId = streamReadString(streamId)
    self.truckUniqueId = streamReadString(streamId)
    self:run(connection)
end

function TransportCompanyDriverEvent:run(connection)
    -- A client must never act on this: it is a request TO the server.
    if connection:getIsServer() then
        return
    end
    if g_transportCompanyManager == nil then
        return
    end

    -- Resolve the sender's real farm, never the payload's.
    local farmId = self.farmId
    if g_currentMission ~= nil and g_currentMission.userManager ~= nil then
        local userId = g_currentMission.userManager:getUserIdByConnection(connection)
        if userId ~= nil then
            local farm = g_farmManager:getFarmByUserId(userId)
            if farm ~= nil then
                farmId = farm.farmId
            end
        end
    end

    g_transportCompanyManager:onDriverRequest(
        self.action, farmId, self.driverId, self.truckUniqueId
    )
end
