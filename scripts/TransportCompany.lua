-- =========================================================
-- FS25 Transport Company - Bootstrap
-- =========================================================
-- Entry point loaded last by modDesc extraSourceFiles.
-- Creates the manager singleton, registers mission hooks,
-- the PDA page, intro hints, and console commands.
-- =========================================================

TransportCompanyLog.info("Transport Company v1.2.3.0 loading")

-- Create the manager singleton (g_currentModDirectory is available at load time)
g_transportCompanyManager = TransportCompanyManager.new(
    g_currentModDirectory,
    "FS25_TransportCompany"
)

-- Register mission lifecycle hooks and console commands
g_transportCompanyManager:load()

TransportCompanyLog.info("Transport Company v1.2.3.0 loaded")
