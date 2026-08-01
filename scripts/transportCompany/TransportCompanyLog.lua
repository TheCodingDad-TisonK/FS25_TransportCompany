-- =========================================================
-- FS25 Transport Company - Logger
-- =========================================================
-- Centralized logging with [TransportCompany] prefix
-- and debug-mode gating. Mirrors the SoilFertilizer
-- SoilLogger pattern.
-- =========================================================

TransportCompanyLog = {}

local PREFIX = "[TransportCompany]"

function TransportCompanyLog.debug(msg, ...)
    if g_transportCompanyManager and g_transportCompanyManager.settings and g_transportCompanyManager.settings.debugMode then
        local success, formatted = pcall(string.format, PREFIX .. " DEBUG: " .. msg, ...)
        print(success and formatted or (PREFIX .. " DEBUG: " .. tostring(msg)))
    end
end

function TransportCompanyLog.info(msg, ...)
    local success, formatted = pcall(string.format, PREFIX .. " " .. msg, ...)
    print(success and formatted or (PREFIX .. " " .. tostring(msg)))
end

function TransportCompanyLog.warning(msg, ...)
    printWarning(string.format(PREFIX .. " Warning: " .. msg, ...))
end

function TransportCompanyLog.error(msg, ...)
    printError(string.format(PREFIX .. " Error: " .. msg, ...))
end
