-- =========================================================
-- FS25 Transport Company - Bootstrap
-- =========================================================
-- Entry point loaded last by modDesc extraSourceFiles.
-- Creates the manager singleton, registers mission hooks,
-- the PDA page, intro hints, and console commands.
-- =========================================================

TransportCompanyLog.info("Transport Company v0.1.0 loading")

-- Create the manager singleton
g_transportCompanyManager = TransportCompanyManager.new(
    g_currentMission.modDirectory,
    "FS25_TransportCompany"
)

-- Register mission lifecycle hooks and console commands
g_transportCompanyManager:load()

TransportCompanyLog.info("Transport Company v0.1.0 loaded")
