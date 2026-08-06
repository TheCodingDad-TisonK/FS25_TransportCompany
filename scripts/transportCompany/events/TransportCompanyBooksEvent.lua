-- =========================================================
-- FS25 Transport Company - Books Sync Event
-- =========================================================
-- Server -> Clients full snapshot of one company's ledger and every
-- truck's books.
--
-- The server samples fuel and distance every tick and applies all
-- money itself; none of that is sent per-tick, so without this event a
-- client in multiplayer would show zero fuel, zero distance and a zero
-- company ledger in the Fleet and Ledger tabs. The manager broadcasts
-- it on every contract completion and periodically (every 30s), and
-- the client replaces its company ledger and truck figures with the
-- snapshot. The event carries the farmId of the company it belongs to,
-- so in multiplayer each client only applies its own books.
--
-- Mirrors the other Transport Company events (InitEventClass +
-- emptyNew/new + writeStream/readStream/run).
-- =========================================================

TransportCompanyBooksEvent = {}
local TransportCompanyBooksEvent_mt = Class(TransportCompanyBooksEvent, Event)
InitEventClass(TransportCompanyBooksEvent, "TransportCompanyBooksEvent")

function TransportCompanyBooksEvent.emptyNew()
    return Event.new(TransportCompanyBooksEvent_mt)
end

--- New event; the caller (manager) fills the ledger and truck fields
--- before sending.
---@param farmId number Company these books belong to
function TransportCompanyBooksEvent.new(farmId)
    local self = TransportCompanyBooksEvent.emptyNew()
    self.farmId = farmId or 0
    self.ledgerRevenue = 0
    self.ledgerDriverWages = 0
    self.ledgerJobs = 0
    self.trucks = {}
    return self
end

--- Broadcast to all connected clients (server only).
function TransportCompanyBooksEvent.sendEvent(event)
    if g_server == nil then
        return
    end
    g_server:broadcastEvent(event)
end

function TransportCompanyBooksEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId or 0)
    streamWriteFloat64(streamId, self.ledgerRevenue or 0)
    streamWriteFloat64(streamId, self.ledgerDriverWages or 0)
    streamWriteInt32(streamId, self.ledgerJobs or 0)
    streamWriteFloat32(streamId, self.reputation or 0)
    streamWriteInt8(streamId, self.hqLevel or 1)

    local trucks = self.trucks or {}
    streamWriteInt16(streamId, #trucks)
    for _, t in ipairs(trucks) do
        streamWriteString(streamId, t.uniqueId or "")
        streamWriteString(streamId, t.vehicleName or "")
        streamWriteInt32(streamId, t.farmId or 0)
        streamWriteFloat64(streamId, t.revenue or 0)
        streamWriteFloat64(streamId, t.fuelCost or 0)
        streamWriteFloat64(streamId, t.otherCost or 0)
        streamWriteFloat64(streamId, t.distanceM or 0)
        streamWriteInt32(streamId, t.jobsDelivered or 0)
    end

    -- Named driver roster (business sim).
    local drivers = self.drivers or {}
    streamWriteInt16(streamId, #drivers)
    for _, d in ipairs(drivers) do
        d:writeStream(streamId)
    end

    -- Weekly P&L history.
    local history = self.ledgerHistory or {}
    streamWriteInt16(streamId, #history)
    for _, p in ipairs(history) do
        streamWriteInt32(streamId, p.index or 0)
        streamWriteFloat64(streamId, p.revenue or 0)
        streamWriteFloat64(streamId, p.wages or 0)
        streamWriteInt32(streamId, p.jobs or 0)
        streamWriteFloat64(streamId, p.km or 0)
    end
end

function TransportCompanyBooksEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.ledgerRevenue = streamReadFloat64(streamId)
    self.ledgerDriverWages = streamReadFloat64(streamId)
    self.ledgerJobs = streamReadInt32(streamId)
    self.reputation = streamReadFloat32(streamId)
    self.hqLevel = streamReadInt8(streamId)

    local n = streamReadInt16(streamId)
    self.trucks = {}
    for i = 1, n do
        table.insert(self.trucks, {
            uniqueId = streamReadString(streamId),
            vehicleName = streamReadString(streamId),
            farmId = streamReadInt32(streamId),
            revenue = streamReadFloat64(streamId),
            fuelCost = streamReadFloat64(streamId),
            otherCost = streamReadFloat64(streamId),
            distanceM = streamReadFloat64(streamId),
            jobsDelivered = streamReadInt32(streamId),
        })
    end

    local nd = streamReadInt16(streamId)
    self.drivers = {}
    for i = 1, nd do
        local d = TransportCompanyDriver.readStream(streamId)
        table.insert(self.drivers, d)
    end

    local nh = streamReadInt16(streamId)
    self.ledgerHistory = {}
    for i = 1, nh do
        table.insert(self.ledgerHistory, {
            index = streamReadInt32(streamId),
            revenue = streamReadFloat64(streamId),
            wages = streamReadFloat64(streamId),
            jobs = streamReadInt32(streamId),
            km = streamReadFloat64(streamId),
        })
    end

    self:run(connection)
end

function TransportCompanyBooksEvent:run(connection)
    if g_transportCompanyManager == nil then
        return
    end
    g_transportCompanyManager:onBooksEvent(self, self.farmId)
end
