-- =========================================================
-- FS25 Transport Company - Contract Event
-- =========================================================
-- Server -> Clients state sync for the contract board.
--
-- The server is the single source of truth for contracts (the
-- manager only mutates contracts on the server; hired-driver AI
-- jobs are server-side too). This event broadcasts the relevant
-- contract so every client can render the PDA dispatch board and
-- run deadline/notification logic locally. It carries the farmId
-- of the company the contract belongs to, so in multiplayer each
-- farm only applies events for its own board.
--
-- Mirrors the proven FS25 event pattern used by the user's other
-- mods (InitEventClass + emptyNew/new + writeStream/readStream/run,
-- see FS25_FuelCosts NetworkEvents.lua).
-- =========================================================

TransportCompanyContractEvent = {}
local TransportCompanyContractEvent_mt = Class(TransportCompanyContractEvent, Event)
InitEventClass(TransportCompanyContractEvent, "TransportCompanyContractEvent")

-- Event types
TransportCompanyContractEvent.TYPE_ADD = 1       -- new contract on the board
TransportCompanyContractEvent.TYPE_UPDATE = 2    -- progress / deadline changed
TransportCompanyContractEvent.TYPE_STATE_CHANGE = 3 -- accepted / completed / expired
TransportCompanyContractEvent.TYPE_REMOVE = 4    -- declined / removed from board

function TransportCompanyContractEvent.emptyNew()
    return Event.new(TransportCompanyContractEvent_mt)
end

function TransportCompanyContractEvent.new(eventType, contract, state, farmId)
    local self = TransportCompanyContractEvent.emptyNew()
    self.eventType = eventType
    self.contract = contract
    self.state = state
    self.farmId = farmId
    return self
end

--- Broadcast to all connected clients (server only).
function TransportCompanyContractEvent.sendEvent(eventType, contract, state, farmId)
    if g_server == nil then
        return
    end
    g_server:broadcastEvent(TransportCompanyContractEvent.new(eventType, contract, state, farmId))
end

function TransportCompanyContractEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.eventType)
    local contract = self.contract
    if contract == nil then
        streamWriteBool(streamId, false)
    else
        streamWriteBool(streamId, true)
        contract:writeStream(streamId, connection)
    end
    streamWriteInt8(streamId, self.state or TransportCompanyContract.STATE_AVAILABLE)
    streamWriteInt32(streamId, self.farmId or 0)
end

function TransportCompanyContractEvent:readStream(streamId, connection)
    self.eventType = streamReadInt8(streamId)
    if streamReadBool(streamId) then
        self.contract = TransportCompanyContract.new()
        self.contract:readStream(streamId, connection)
    else
        self.contract = nil
    end
    self.state = streamReadInt8(streamId)
    self.farmId = streamReadInt32(streamId)
    self:run(connection)
end

function TransportCompanyContractEvent:run(connection)
    if g_transportCompanyManager == nil then
        return
    end
    g_transportCompanyManager:onContractEvent(
        self.eventType, self.contract, self.state, self.farmId
    )
end
