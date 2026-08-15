-- =========================================================
-- FS25 Transport Company - Settings
-- =========================================================
-- Single source of truth for all Transport Company settings.
--
-- Server-shared settings (contract board size, deadline length,
-- notifications) are saved into the server savegame directory so
-- every player in a multiplayer game uses the same company rules.
-- They are per-COMPANY: each farm that owns an HQ carries its own
-- board size, deadline and wage share (see TransportCompanyCompany),
-- so the shared file is named per farm.
--
-- Local-only settings (debug output) are saved per-player into the
-- user profile (modSettings/FS25_TransportCompany/...) so they
-- survive reconnects on dedicated servers.
--
-- Mirror of the proven SettingsSchema/SettingsManager pattern used
-- by the user's other FS25 mods; consolidated into one file because
-- the Transport Company surface is small.
--
-- Ground truth:
--   - g_currentMission.missionInfo.savegameDirectory is the per-save
--     server directory (FSCareerMissionInfo) - server-shared config
--     belongs next to the savegame.
--   - getUserProfileAppPath() + createFolder() are the profile helpers
--     used for per-player files (base game user profile layout).
--   - Only the server writes the server-shared file (g_server present
--     or singleplayer: g_client ~= nil and g_server == nil means a
--     client-only process; it must NOT write).
-- =========================================================

local modName = g_currentModName or "FS25_TransportCompany"

---@class TransportCompanySettings
TransportCompanySettings = {}
local TransportCompanySettings_mt = Class(TransportCompanySettings)

-- XML root tag inside the savegame-side config file.
TransportCompanySettings.XMLTAG = "transportCompanyConfig"

-- ── Schema ──────────────────────────────────────────────────
-- Each entry fully describes one setting.
--   type      : "boolean" | "number"
--   default   : fallback value
--   localOnly : true  -> per-player, saved in profile (never synced)
--               false -> server-shared, saved next to the savegame
TransportCompanySettings.definitions = {
    {
        id = "enabled",
        type = "boolean",
        default = true,
        -- Master switch for the whole company. When disabled, the
        -- dispatch office shows "Company is closed", no contracts are
        -- generated and no truck keeps books.
    },
    {
        id = "maxActiveContracts",
        type = "number",
        default = 5,
        min = 1,
        max = 12,
        -- How many open contracts the dispatch board holds at once.
        -- New contracts are generated when a slot frees up (delivered,
        -- expired or declined).
    },
    {
        id = "contractDeadlineDays",
        type = "number",
        default = 7,
        min = 1,
        max = 30,
        -- Deadline for accepted contracts, in game days. Driven by the
        -- environment's day counter (TransportCompanyContract.getGameDay),
        -- so it honours the player's day-length setting. It is explicitly
        -- NOT g_currentMission.time, which counts real playtime.
    },
    {
        id = "hiredDriverRewardShare",
        type = "number",
        default = 20,
        min = 0,
        max = 100,
        step = 5,
        -- Percent of the contract reward a hired driver (AI job) keeps
        -- for themselves. The company bank receives the rest. 0 means
        -- drivers haul for free (only the vehicle running costs count).
    },
    {
        id = "showNotifications",
        type = "boolean",
        default = true,
        -- Show base-game style ingame notifications (contract accepted,
        -- delivered, expired, new board, ...). When off, the company
        -- still runs - it just keeps quiet.
    },
    {
        id = "returnTruckToHq",
        type = "boolean",
        default = true,
        -- When a hired driver finishes a contract, drive the truck back
        -- to park at the HQ instead of leaving it at the delivery point.
        -- Off leaves the truck where the job ended (saves the return
        -- trip's fuel and time, but you collect it from the drop-off).
    },
    {
        id = "debugMode",
        type = "boolean",
        default = false,
        localOnly = true,
        -- Verbose log output for development. Never on by default; the
        -- built zip ships with this false (ModHub gate).
    },
}

-- Build lookup + helpers -----------------------------------------------------

TransportCompanySettings.byId = {}
for _, def in ipairs(TransportCompanySettings.definitions) do
    TransportCompanySettings.byId[def.id] = def
end

function TransportCompanySettings.getDefault(id)
    local def = TransportCompanySettings.byId[id]
    if def ~= nil then
        -- Explicit return so boolean defaults of false stay false.
        return def.default
    end
    return nil
end

function TransportCompanySettings.getAllDefaults()
    local defaults = {}
    for _, def in ipairs(TransportCompanySettings.definitions) do
        defaults[def.id] = def.default
    end
    return defaults
end

--- Validate a value against its schema entry.
--- Returns the validated value, or nil when the setting is unknown.
function TransportCompanySettings.validate(id, value)
    local def = TransportCompanySettings.byId[id]
    if def == nil then
        return nil
    end
    if def.type == "boolean" then
        return not not value
    elseif def.type == "number" then
        value = tonumber(value)
        if value == nil then
            return def.default
        end
        if def.min ~= nil and value < def.min then return def.min end
        if def.max ~= nil and value > def.max then return def.max end
        return value
    end
    return value
end

-- ── Instance ────────────────────────────────────────────────

function TransportCompanySettings.new(farmId)
    local self = setmetatable({}, TransportCompanySettings_mt)
    self.farmId = farmId or nil
    self:resetToDefaults()
    return self
end

function TransportCompanySettings:resetToDefaults()
    self.config = TransportCompanySettings.getAllDefaults()
end

function TransportCompanySettings:get(id)
    return self.config[id]
end

function TransportCompanySettings:set(id, value)
    local def = TransportCompanySettings.byId[id]
    if def == nil then
        return false
    end
    local validated = TransportCompanySettings.validate(id, value)
    self.config[id] = validated
    return true
end

-- ── Paths ───────────────────────────────────────────────────

--- Server-shared config path: next to the current savegame, one
--- file per company (per farm). Returns nil before the savegame
--- directory exists (new career) or when this instance holds no
--- farmId (a manager-level local-only settings holder).
function TransportCompanySettings:getSavegameXmlFilePath()
    if self.farmId == nil or self.farmId <= 0 then
        return nil
    end
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo
    if missionInfo ~= nil and missionInfo.savegameDirectory ~= nil then
        return string.format("%s/%s_%d.xml", missionInfo.savegameDirectory, modName, self.farmId)
    end
    return nil
end

--- Local-only config path: user profile modSettings folder.
--- Falls back to the savegame dir with a _local suffix in
--- singleplayer/self-hosted (mirrors the reference pattern).
function TransportCompanySettings:getLocalSettingsPath()
    local ok, profilePath = pcall(getUserProfileAppPath)
    if ok and profilePath ~= nil and profilePath ~= "" then
        if profilePath:sub(-1) ~= "/" and profilePath:sub(-1) ~= "\\" then
            profilePath = profilePath .. "/"
        end
        local base = profilePath .. "modSettings/" .. modName
        pcall(createFolder, profilePath .. "modSettings")
        pcall(createFolder, base)
        pcall(createFolder, base .. "/Settings")
        return base .. "/Settings/local.xml"
    end
    local xmlPath = self:getSavegameXmlFilePath()
    if xmlPath ~= nil then
        return xmlPath:gsub("%.xml$", "_local.xml")
    end
    return nil
end

-- ── Load / save ─────────────────────────────────────────────

function TransportCompanySettings:loadSettings()
    self:resetToDefaults()

    -- Server-shared part
    local xmlPath = self:getSavegameXmlFilePath()
    if xmlPath ~= nil and fileExists(xmlPath) then
        local xml = XMLFile.load(modName .. "_Config", xmlPath)
        if xml ~= nil then
            for _, def in ipairs(TransportCompanySettings.definitions) do
                if not def.localOnly then
                    local key = self.XMLTAG .. "." .. def.id
                    if def.type == "boolean" then
                        self.config[def.id] = xml:getBool(key, def.default)
                    elseif def.type == "number" then
                        self.config[def.id] = xml:getInt(key, def.default)
                    end
                end
            end
            xml:delete()
        end
    end

    -- Local-only part
    local localPath = self:getLocalSettingsPath()
    if localPath ~= nil and fileExists(localPath) then
        local xml = XMLFile.load(modName .. "_LocalConfig", localPath)
        if xml ~= nil then
            for _, def in ipairs(TransportCompanySettings.definitions) do
                if def.localOnly then
                    local key = self.XMLTAG .. "." .. def.id
                    if def.type == "boolean" then
                        self.config[def.id] = xml:getBool(key, def.default)
                    elseif def.type == "number" then
                        self.config[def.id] = xml:getInt(key, def.default)
                    end
                end
            end
            xml:delete()
        end
    end
end

--- Save server-shared settings. Server / singleplayer only.
function TransportCompanySettings:saveSettings()
    local xmlPath = self:getSavegameXmlFilePath()
    if xmlPath == nil then
        return false
    end
    -- Client-only processes must not write the shared file.
    if g_client ~= nil and g_server == nil then
        return false
    end
    if not fileExists(xmlPath) then
        -- Savegame dir may not exist yet on a fresh dedicated server.
        local dir = xmlPath:match("^(.*)[/\\][^/\\]+%.xml$")
        if dir ~= nil and not fileExists(dir) then
            local okCreate = pcall(createFolder, dir)
            if not okCreate then
                return false
            end
        end
    end

    local xml = XMLFile.create(modName .. "_Config", xmlPath, self.XMLTAG)
    if xml == nil then
        return false
    end
    for _, def in ipairs(TransportCompanySettings.definitions) do
        if not def.localOnly then
            local key = self.XMLTAG .. "." .. def.id
            if def.type == "boolean" then
                xml:setBool(key, self.config[def.id])
            elseif def.type == "number" then
                xml:setInt(key, self.config[def.id])
            end
        end
    end
    xml:save()
    xml:delete()
    return true
end

--- Save everything that this process is allowed to write:
--- the server-shared file (server / singleplayer only) and the
--- per-player local file. Returns true when at least one wrote.
function TransportCompanySettings:save()
    local sharedOk = self:saveSettings()
    local localOk = self:saveLocalSettings()
    return sharedOk or localOk
end

--- Save local-only settings (per-player profile).
---
--- Only the manager-level instance (the one with no farmId) owns this file.
--- Every company carries a full copy of the schema, including debugMode, but
--- never receives local-only edits — so letting a company write here rebuilt
--- the shared local.xml from a stale copy and silently reverted the player's
--- debug toggle the next time any company setting was saved.
function TransportCompanySettings:saveLocalSettings()
    if self.farmId ~= nil then
        return false
    end
    local path = self:getLocalSettingsPath()
    if path == nil then
        return false
    end
    local xml = XMLFile.create(modName .. "_LocalConfig", path, self.XMLTAG)
    if xml == nil then
        return false
    end
    for _, def in ipairs(TransportCompanySettings.definitions) do
        if def.localOnly then
            local key = self.XMLTAG .. "." .. def.id
            if def.type == "boolean" then
                xml:setBool(key, self.config[def.id])
            elseif def.type == "number" then
                xml:setInt(key, self.config[def.id])
            end
        end
    end
    xml:save()
    xml:delete()
    return true
end

-- ── UI helpers ──────────────────────────────────────────────
-- Label and description keys follow a fixed convention so the PDA can
-- render any setting without a second table to keep in sync.

function TransportCompanySettings.getLabelKey(id)
    return "transportCompany_setting_" .. id
end

function TransportCompanySettings.getDescriptionKey(id)
    return "transportCompany_settingDesc_" .. id
end

--- Human readable value for a setting.
function TransportCompanySettings:getDisplayValue(id)
    local def = TransportCompanySettings.byId[id]
    if def == nil then
        return ""
    end
    local value = self:get(id)
    if def.type == "boolean" then
        return g_i18n:getText(value and "transportCompany_on" or "transportCompany_off")
    end
    return tostring(value)
end

--- Step a setting to its next value: booleans flip, numbers advance by
--- one step and wrap back to min past the top.
---@return boolean changed
function TransportCompanySettings:cycle(id, direction)
    local def = TransportCompanySettings.byId[id]
    if def == nil then
        return false
    end

    if def.type == "boolean" then
        self:set(id, not self:get(id))
        return true
    end

    local step = def.step or 1
    local value = (tonumber(self:get(id)) or def.default) + step * (direction or 1)
    if def.max ~= nil and value > def.max then
        value = def.min or def.default
    elseif def.min ~= nil and value < def.min then
        value = def.max or def.default
    end
    self:set(id, value)
    return true
end

--- Can this process change the setting?
--- Server-shared values are server-authoritative: a client editing them
--- locally would silently disagree with everyone else.
function TransportCompanySettings.getIsEditable(def)
    if def == nil then
        return false
    end
    if def.localOnly then
        return true
    end
    return g_server ~= nil
end
