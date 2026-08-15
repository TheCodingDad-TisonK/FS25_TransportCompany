-- =========================================================
-- FS25 Transport Company - Reset Board Request Event
-- =========================================================
-- Client -> Server request to clear the dispatch board and build a
-- fresh one. Raised by the PDA's "Reset Board" footer button, which is
-- the in-game equivalent of the tc_reset_board console command.
--
-- The board is server-authoritative like every other piece of company
-- state, so a client only asks. The server rebuilds and pushes the
-- result back as ordinary TransportCompanyContractEvent traffic
-- (REMOVE for each cleared job, ADD for each new one), which is what
-- makes every open PDA refresh live rather than on the next reopen.
--
-- Mirrors the other Transport Company events (InitEventClass +
-- emptyNew/new + writeStream/readStream/run).
-- =========================================================

TransportCompanyResetBoardEvent = {}
local TransportCompanyResetBoardEvent_mt = Class(TransportCompanyResetBoardEvent, Event)
InitEventClass(TransportCompanyResetBoardEvent, "TransportCompanyResetBoardEvent")

function TransportCompanyResetBoardEvent.emptyNew()
    return Event.new(TransportCompanyResetBoardEvent_mt)
end

---@param farmId number Farm whose board should be rebuilt
function TransportCompanyResetBoardEvent.new(farmId)
    local self = TransportCompanyResetBoardEvent.emptyNew()
    self.farmId = farmId
    return self
end

--- Send the request to the server, or handle it inline when we are
--- the server already.
function TransportCompanyResetBoardEvent.sendEvent(farmId)
    if g_server ~= nil then
        if g_transportCompanyManager ~= nil then
            g_transportCompanyManager:onResetBoardRequest(farmId)
        end
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            TransportCompanyResetBoardEvent.new(farmId)
        )
    end
end

function TransportCompanyResetBoardEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId or 0)
end

function TransportCompanyResetBoardEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self:run(connection)
end

function TransportCompanyResetBoardEvent:run(connection)
    -- A client must never act on this: it is a request TO the server.
    if connection:getIsServer() then
        return
    end
    if g_transportCompanyManager == nil then
        return
    end

    -- Resolve the sender's real farm, never the payload's, so a crafted
    -- packet cannot wipe another farm's board.
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

    g_transportCompanyManager:onResetBoardRequest(farmId)
end
