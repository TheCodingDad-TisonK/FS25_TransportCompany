-- =========================================================
-- FS25 Transport Company - Company (per-farm business state)
-- =========================================================
-- One company exists per farm that owns a Transport Company HQ.
-- All gameplay state that used to live directly on the manager
-- is scoped to a company, so two farms in one multiplayer game
-- each run their own board, their own books and their own fleet
-- without cross-crediting each other.
--
-- Ownership rules:
--   * A company is created the moment its farm places an HQ and
--     archived when the last HQ of that farm is sold/deleted.
--     Archiving keeps the books but clears the active board.
--   * Contracts are generated for THIS farm's stock access and
--     routed to THIS farm's stations.
--   * Trucks belong to the company of the farm that owns them.
--   * Server-shared settings are per company; debugMode stays a
--     global per-player setting on the manager.
-- =========================================================

---@class TransportCompanyCompany
TransportCompanyCompany = {}
local TransportCompanyCompany_mt = Class(TransportCompanyCompany)

---@param farmId number Farm that owns this company
function TransportCompanyCompany.new(farmId)
    local self = setmetatable({}, TransportCompanyCompany_mt)

    self.farmId = farmId or 0

    -- Server-shared settings live here. Each company has its own
    -- copy so farm A's board size does not leak into farm B's.
    -- Local-only settings (debugMode) stay on the manager and are
    -- shared by every company in this process.
    self.settings = TransportCompanySettings.new(farmId)

    -- contractId → TransportCompanyContract (the board + history)
    self.contracts = {}

    -- Truck books for trucks this farm owns. Books for a sold truck
    -- are kept -- the ledger is a history, not a live roster.
    self.trucks = {}

    -- Company-level books. Kept separately from the per-truck books
    -- because a self-hauled delivery cannot be pinned to a specific
    -- truck in all cases: the station hook reports liters and fill
    -- position, never the vehicle that tipped them.
    self.ledger = { revenue = 0, driverWages = 0, jobs = 0 }

    -- Per-contract watchdog state for hired drivers: contractId →
    -- { windowTimer, windowDistance, attempts }. Server-only, never
    -- persisted -- a fresh save simply resumes watching from zero.
    self.stuckWatch = {}

    -- Company was archived (last HQ sold). The books survive; the
    -- board and all bookkeeping pause until an HQ is placed again.
    self.isArchived = false

    -- Per-company timer buckets (board top-up, books sync), server.
    self.boardTimer = 0
    self.booksSyncTimer = 0

    return self
end

---Is this company live and allowed to do business?
---@return boolean
function TransportCompanyCompany:getIsActive()
    return not self.isArchived and self.settings:get("enabled") ~= false
end

---Trucks this farm owns, from the company roster.
---@return table uniqueId → TransportCompanyTruck
function TransportCompanyCompany:getTrucks()
    return self.trucks
end

---Reset runtime-only state (contracts, stuck-watch, timers). Called
---on archive and on mission teardown. The ledger and truck books are
---intentionally left intact.
function TransportCompanyCompany:clearRuntime()
    self.contracts = {}
    self.stuckWatch = {}
    self.boardTimer = 0
    self.booksSyncTimer = 0
end

---Archive the company: pause operations but keep the books.
function TransportCompanyCompany:archive()
    self.isArchived = true
    self:clearRuntime()
end

---Restore a company whose farm placed an HQ again.
function TransportCompanyCompany:restore()
    self.isArchived = false
    self:clearRuntime()
end
