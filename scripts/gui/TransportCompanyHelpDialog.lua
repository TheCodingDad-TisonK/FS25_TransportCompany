-- =========================================================
-- FS25 Transport Company - Help Dialog
-- =========================================================
-- A paged guide shown from the Dispatch Office footer. Players can
-- page through how the company works, what each tab does, the
-- settings, and troubleshooting (including what to do when a hired
-- driver gets stuck).
--
-- Mirrors the proven MessageDialog pattern used by NPCFavor
-- (MessageDialog.new + Class(..., MessageDialog), XML with
-- onCreate/onOpen/onClose callbacks, g_gui:showDialog to open, :close()
-- to dismiss). Page content is read from l10n keys so it localises.
-- =========================================================

TransportCompanyHelpDialog = {}
local TransportCompanyHelpDialog_mt = Class(TransportCompanyHelpDialog, MessageDialog)

-- Page order: each entry is { titleKey, bodyKey }. The body key holds
-- the whole page text; newlines are allowed so pages read naturally.
TransportCompanyHelpDialog.PAGES = {
    { titleKey = "transportCompany_helpPageStartTitle",
      bodyKey  = "transportCompany_helpPageStartBody" },
    { titleKey = "transportCompany_helpPageBoardTitle",
      bodyKey  = "transportCompany_helpPageBoardBody" },
    { titleKey = "transportCompany_helpPageJobsTitle",
      bodyKey  = "transportCompany_helpPageJobsBody" },
    { titleKey = "transportCompany_helpPageDriversTitle",
      bodyKey  = "transportCompany_helpPageDriversBody" },
    { titleKey = "transportCompany_helpPageBusinessTitle",
      bodyKey  = "transportCompany_helpPageBusinessBody" },
    { titleKey = "transportCompany_helpPageStuckTitle",
      bodyKey  = "transportCompany_helpPageStuckBody" },
    { titleKey = "transportCompany_helpPageSettingsTitle",
      bodyKey  = "transportCompany_helpPageSettingsBody" },
}

function TransportCompanyHelpDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or TransportCompanyHelpDialog_mt)
    self.currentPage = 1
    return self
end

function TransportCompanyHelpDialog:onCreate()
    TransportCompanyHelpDialog:superClass().onCreate(self)
end

function TransportCompanyHelpDialog:onOpen()
    TransportCompanyHelpDialog:superClass().onOpen(self)
    self:showPage(1)
end

function TransportCompanyHelpDialog:onClose()
    TransportCompanyHelpDialog:superClass().onClose(self)
end

---Show a page: fill title, body, page counter and enable/disable the
---Prev / Next buttons at the ends.
---@param page number 1-based page index
function TransportCompanyHelpDialog:showPage(page)
    local count = #TransportCompanyHelpDialog.PAGES
    self.currentPage = math.max(1, math.min(count, page or 1))

    local entry = TransportCompanyHelpDialog.PAGES[self.currentPage]
    if entry == nil then return end

    if self.titleText ~= nil then
        self.titleText:setText(g_i18n:getText(entry.titleKey))
    end
    if self.bodyText ~= nil then
        self.bodyText:setText(g_i18n:getText(entry.bodyKey))
    end
    if self.pageCounter ~= nil then
        self.pageCounter:setText(string.format("%d / %d", self.currentPage, count))
    end

    -- Prev / Next buttons are 3-layer: background + hit Button + text.
    local prevEnabled = self.currentPage > 1
    local nextEnabled = self.currentPage < count
    self:_setNavEnabled("Prev", prevEnabled)
    self:_setNavEnabled("Next", nextEnabled)
end

---Toggle a navigation button's enabled state (background + text colour).
function TransportCompanyHelpDialog:_setNavEnabled(suffix, enabled)
    local bgEl   = self["btn" .. suffix .. "Bg"]
    local textEl = self["btn" .. suffix .. "Text"]
    if bgEl ~= nil then
        local c = enabled and {0.15, 0.15, 0.18, 1} or {0.08, 0.08, 0.08, 0.6}
        bgEl:setImageColor(nil, c[1], c[2], c[3], c[4])
    end
    if textEl ~= nil then
        local c = enabled and {1, 1, 1, 1} or {0.4, 0.4, 0.4, 1}
        textEl:setTextColor(c[1], c[2], c[3], c[4])
    end
end

function TransportCompanyHelpDialog:onClickPrev()
    self:showPage(self.currentPage - 1)
end

function TransportCompanyHelpDialog:onClickNext()
    self:showPage(self.currentPage + 1)
end

function TransportCompanyHelpDialog:onClickClose()
    self:close()
end

---Open the help dialog (lazy-loads it into g_gui on first use).
function TransportCompanyHelpDialog.show()
    if g_gui == nil then return end
    if g_transportCompanyHelpDialog == nil then
        local instance = TransportCompanyHelpDialog.new()
        g_gui:loadGui(
            g_currentModDirectory .. "gui/TransportCompanyHelpDialog.xml",
            "transportCompanyHelpDialog",
            instance
        )
        g_transportCompanyHelpDialog = instance
    end
    if g_gui.guis ~= nil and g_gui.guis["transportCompanyHelpDialog"] ~= nil then
        g_gui:showDialog("transportCompanyHelpDialog")
    end
end
