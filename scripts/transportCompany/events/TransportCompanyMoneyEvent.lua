-- =========================================================
-- FS25 Transport Company - Money Event
-- =========================================================
-- Server -> Clients notification that company money moved.
--
-- All money is applied on the server only (base game rule:
-- g_currentMission:addMoney is server-side; farmId 0 rejected;
-- Farm:changeBalance drives the finance stats). Clients receive
-- this event to update their PDA ledger and per-truck books.
-- =========================================================

TransportCompanyMoneyEvent = {}
local TransportCompanyMoneyEvent_mt = Class(TransportCompanyMoneyEvent, Event)
InitEventClass(TransportCompanyMoneyEvent, "TransportCompanyMoneyEvent")

-- Money types
TransportCompanyMoneyEvent.TYPE_CONTRACT_REWARD = 1   -- + contract paid out
TransportCompanyMoneyEvent.TYPE_HIRED_DRIVER_CUT = 2 -- - driver kept their share
TransportCompanyMoneyEvent.TYPE_TRUCK_REVENUE = 3    -- per-truck revenue entry
TransportCompanyMoneyEvent.TYPE_EXPENSE = 4          -- - company expense

function TransportCompanyMoneyEvent.emptyNew()
    return Event.new(TransportCompanyMoneyEvent_mt)
end

function TransportCompanyMoneyEvent.new(moneyType, amount, farmId, contractId, truckUniqueId)
    local self = TransportCompanyMoneyEvent.emptyNew()
    self.moneyType = moneyType
    self.amount = amount
    self.farmId = farmId
    self.contractId = contractId
    self.truckUniqueId = truckUniqueId
    return self
end

--- Broadcast to all connected clients (server only).
function TransportCompanyMoneyEvent.sendEvent(moneyType, amount, farmId, contractId, truckUniqueId)
    if g_server == nil then
        return
    end
    g_server:broadcastEvent(TransportCompanyMoneyEvent.new(moneyType, amount, farmId, contractId, truckUniqueId))
end

function TransportCompanyMoneyEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.moneyType)
    streamWriteFloat32(streamId, self.amount)
    streamWriteInt32(streamId, self.farmId or 0)
    streamWriteString(streamId, self.contractId or "")
    -- Vehicle uniqueIds are strings ("vehicle" .. md5, VehicleSystem.lua:170)
    streamWriteString(streamId, self.truckUniqueId or "")
end

function TransportCompanyMoneyEvent:readStream(streamId, connection)
    self.moneyType = streamReadInt8(streamId)
    self.amount = streamReadFloat32(streamId)
    self.farmId = streamReadInt32(streamId)
    self.contractId = streamReadString(streamId)
    self.truckUniqueId = streamReadString(streamId)
    self:run(connection)
end

function TransportCompanyMoneyEvent:run(connection)
    if g_transportCompanyManager == nil then
        return
    end
    g_transportCompanyManager:onMoneyEvent(self.moneyType, self.amount, self.farmId, self.contractId, self.truckUniqueId)
end
