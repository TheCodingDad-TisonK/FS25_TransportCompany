-- =========================================================
-- FS25 Transport Company - Accept Request Event
-- =========================================================
-- Client -> Server request to take a contract off the board.
--
-- The contract board is server-authoritative: only the server may
-- change a contract's state, start a hired-driver AI job, or move
-- money. A client pressing "Accept" therefore cannot mutate anything
-- locally — it sends this request, the server validates it and
-- broadcasts the result through TransportCompanyContractEvent.
--
-- On a listen server / singleplayer the manager calls the same
-- handler directly, so there is exactly one code path for accepting.
-- =========================================================

TransportCompanyAcceptEvent = {}
local TransportCompanyAcceptEvent_mt = Class(TransportCompanyAcceptEvent, Event)
InitEventClass(TransportCompanyAcceptEvent, "TransportCompanyAcceptEvent")

-- How the player intends to run the job.
TransportCompanyAcceptEvent.MODE_SELF = 1   -- player hauls it
TransportCompanyAcceptEvent.MODE_HIRE = 2   -- base game AI hauls it

function TransportCompanyAcceptEvent.emptyNew()
    return Event.new(TransportCompanyAcceptEvent_mt)
end

---@param contractId string
---@param mode number MODE_SELF or MODE_HIRE
---@param farmId number Farm taking the job
function TransportCompanyAcceptEvent.new(contractId, mode, farmId)
    local self = TransportCompanyAcceptEvent.emptyNew()
    self.contractId = contractId
    self.mode = mode
    self.farmId = farmId
    return self
end

--- Send the request to the server, or handle it inline when we are
--- the server already.
function TransportCompanyAcceptEvent.sendEvent(contractId, mode, farmId)
    if g_server ~= nil then
        if g_transportCompanyManager ~= nil then
            g_transportCompanyManager:onAcceptRequest(contractId, mode, farmId)
        end
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            TransportCompanyAcceptEvent.new(contractId, mode, farmId)
        )
    end
end

function TransportCompanyAcceptEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.contractId or "")
    streamWriteInt8(streamId, self.mode or TransportCompanyAcceptEvent.MODE_SELF)
    streamWriteInt32(streamId, self.farmId or 0)
end

function TransportCompanyAcceptEvent:readStream(streamId, connection)
    self.contractId = streamReadString(streamId)
    self.mode = streamReadInt8(streamId)
    self.farmId = streamReadInt32(streamId)
    self:run(connection)
end

function TransportCompanyAcceptEvent:run(connection)
    -- A client must never act on this: it is a request TO the server.
    -- connection:getIsServer() is true only when the sender was the
    -- server, which would mean a spoofed inbound event.
    if connection:getIsServer() then
        return
    end
    if g_transportCompanyManager == nil then
        return
    end
    g_transportCompanyManager:onAcceptRequest(self.contractId, self.mode, self.farmId)
end
