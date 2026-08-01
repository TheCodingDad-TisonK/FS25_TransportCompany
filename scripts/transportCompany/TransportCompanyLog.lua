-- =========================================================
-- FS25 Transport Company - Logger
-- =========================================================
-- Centralized logging with [TransportCompany] prefix
-- and debug-mode gating. Mirrors the SoilFertilizer
-- SoilLogger pattern.
-- =========================================================

TransportCompanyLog = {}

local PREFIX = "[TransportCompany]"

-- Settings live in settings.config and must be read through :get();
-- reading settings.debugMode as a field always yields nil.
function TransportCompanyLog.debug(msg, ...)
    if g_transportCompanyManager and g_transportCompanyManager.settings
       and g_transportCompanyManager.settings:get("debugMode") then
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
