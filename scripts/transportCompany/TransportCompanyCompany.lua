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
--
-- Business-sim state (R4) also lives here: the named driver roster,
-- reputation/level progression, the HQ upgrade tier and the ledger's
-- rolling P&L history.
-- =========================================================

---@class TransportCompanyCompany
TransportCompanyCompany = {}
local TransportCompanyCompany_mt = Class(TransportCompanyCompany)

-- Reputation gates: completing a job on time raises reputation, an
-- expired or returned contract lowers it. Level is derived from
-- reputation and unlocks capacity, never spendable.
TransportCompanyCompany.REPUTATION_ON_COMPLETE = 2
TransportCompanyCompany.REPUTATION_ON_EXPIRE = -2
TransportCompanyCompany.REPUTATION_MAX = 100
TransportCompanyCompany.REPUTATION_PER_LEVEL = 20

-- HQ upgrade tiers: each level above the base adds driver capacity
-- and a board-size bonus. Upgrading costs money, in-PDA.
TransportCompanyCompany.HQ_BASE_LEVEL = 1
TransportCompanyCompany.HQ_MAX_LEVEL = 5
TransportCompanyCompany.HQ_UPGRADE_COST = { 25000, 50000, 100000, 200000 }

-- Driver capacity and board bonus per reputation level.
TransportCompanyCompany.BASE_DRIVER_CAP = 2

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

    -- Per-company timer buckets (board top-up, books sync), server. These
    -- two are real-time housekeeping intervals, so accumulated dt is the
    -- right clock for them.
    self.boardTimer = 0
    self.booksSyncTimer = 0
    -- Payroll is NOT: it falls due on a game day (getGameDay), so it is a
    -- watermark rather than a dt bucket. nil means "not seeded yet"; the
    -- update loop sets it a week out the first time it sees the company.
    self.nextWageDay = nil

    -- ── Business-sim state (R4) ──────────────────────────────
    -- driverId → TransportCompanyDriver (the payroll).
    self.drivers = {}
    -- 0..REPUTATION_MAX; level = floor(reputation / PER_LEVEL) + 1.
    self.reputation = 0
    -- HQ upgrade tier, 1..HQ_MAX_LEVEL. Bought in-PDA.
    self.hqLevel = TransportCompanyCompany.HQ_BASE_LEVEL
    -- Rolling P&L by 7-day period (period index → {revenue, wages,
    -- jobs, km}). Kept small; rolled up from the live ledger.
    self.ledgerHistory = {}

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
    self.nextWageDay = nil
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

-- ── Reputation & level ─────────────────────────────────────

---Current reputation level (1+). Every REPUTATION_PER_LEVEL points of
---reputation adds one level; level gates driver capacity and board
---size, which is the progression the player earns by running jobs.
---@return number
function TransportCompanyCompany:getLevel()
    return math.floor(self.reputation / TransportCompanyCompany.REPUTATION_PER_LEVEL) + 1
end

---Change reputation and clamp. Completing on time adds; expiring or
---returning a contract subtracts.
---@param delta number
function TransportCompanyCompany:addReputation(delta)
    self.reputation = math.max(0, math.min(
        TransportCompanyCompany.REPUTATION_MAX, self.reputation + (delta or 0)))
end

---Maximum number of drivers this company may employ.
---@return number
function TransportCompanyCompany:getDriverCap()
    local levelBonus = self:getLevel() - 1
    local hqBonus = math.max(0, self.hqLevel - TransportCompanyCompany.HQ_BASE_LEVEL)
    return TransportCompanyCompany.BASE_DRIVER_CAP + levelBonus + hqBonus
end

---Board size, including the HQ tier bonus (applied on top of the
---maxActiveContracts setting).
---@return number
function TransportCompanyCompany:getBoardSize()
    local base = self.settings:get("maxActiveContracts") or 5
    local hqBonus = math.max(0, self.hqLevel - TransportCompanyCompany.HQ_BASE_LEVEL)
    return base + hqBonus
end

---Cost to raise the HQ one tier, or nil at max level.
---@return number|nil
function TransportCompanyCompany:getNextHqUpgradeCost()
    if self.hqLevel >= TransportCompanyCompany.HQ_MAX_LEVEL then
        return nil
    end
    return TransportCompanyCompany.HQ_UPGRADE_COST[self.hqLevel - TransportCompanyCompany.HQ_BASE_LEVEL + 1]
end

---Raise the HQ tier if the farm could afford it.
---
---NOTE: this checks affordability and upgrades, but does NOT move any
---money — the caller must charge the farm. The shipped path into the HQ
---tier is TransportCompanyManager:_upgradeHq, which charges and then calls
---hqUpgrade() directly; this helper exists for callers that have already
---settled up.
---@return boolean upgraded
function TransportCompanyCompany:tryUpgradeHq()
    local cost = self:getNextHqUpgradeCost()
    if cost == nil then
        return false
    end
    -- The balance lives on the Farm, not on the mission: FS25 has no
    -- g_currentMission:getFarmMoney (it is Farm:getBalance, reached via
    -- g_farmManager), so the old call would have thrown on first use.
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(self.farmId) or nil
    if farm == nil or farm.getBalance == nil or (farm:getBalance() or 0) < cost then
        return false
    end
    self:hqUpgrade()
    return true
end

---Raise the HQ tier unconditionally (called after the farm paid).
function TransportCompanyCompany:hqUpgrade()
    self.hqLevel = math.min(
        TransportCompanyCompany.HQ_MAX_LEVEL, self.hqLevel + 1)
end

-- ── Payroll ────────────────────────────────────────────────

---Total weekly base wage of all drivers on the payroll.
---@return number
function TransportCompanyCompany:getTotalWeeklyWage()
    local total = 0
    for _, driver in pairs(self.drivers) do
        total = total + driver:getCurrentWage()
    end
    return total
end

---Number of drivers currently on the payroll.
---@return number
function TransportCompanyCompany:getDriverCount()
    local n = 0
    for _ in pairs(self.drivers) do n = n + 1 end
    return n
end

---Find the driver assigned to a truck, if any.
---@param truckUniqueId string
---@return TransportCompanyDriver|nil
function TransportCompanyCompany:getDriverForTruck(truckUniqueId)
    if truckUniqueId == nil or truckUniqueId == "" then return nil end
    for _, driver in pairs(self.drivers) do
        if driver.assignedTruckUniqueId == truckUniqueId then
            return driver
        end
    end
    return nil
end
