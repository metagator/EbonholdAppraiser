local addonName = ...

local APP_NAME = "Ebonhold Appraiser"
local APP_VERSION = "1.3.7"
local AUTHOR = "Ewbrotha"

local function msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fb8ff" .. APP_NAME .. "|r: " .. tostring(text))
end

local function deepcopyDefaults(dst, src)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = deepcopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local defaults = {
    theme = "dark", -- dark or wow
    goalCopper = 100000, -- 10g default
    lockWindow = false,
    startClosed = true,
    window = { point = "CENTER", x = 0, y = 0, width = 360, height = 285 },
    totals = {
        lifetimeVendorCopper = 0,
        sessionVendorCopper = 0,
        sessionStartTime = 0,
        sessionItems = 0,
        sessionResets = 0,
        sessionElapsedSaved = 0,
        sessionRunning = false,
    },
}

local db
local frame
local ui = {}
local bagSnapshot = nil
local getItemVendorValue

-- forward decl
local applyTheme

local THEMES = {
    dark = {
        bg = {0.06,0.07,0.09,0.96},
        panel = {0.10,0.11,0.14,0.98},
        panel2 = {0.14,0.15,0.18,0.98},
        border = {0.18,0.20,0.24,1},
        title = {0.90,0.92,0.95,1},
        text = {0.72,0.76,0.82,1},
        value = {0.95,0.97,1.00,1},
        accent = {0.25,0.60,1.00,1},
        accent2 = {0.50,0.80,1.00,1},
        warning = {1.00,0.82,0.30,1},
        editbg = {0.07,0.08,0.10,1},
    },
    wow = {
        bg = {0.12,0.08,0.04,0.97},
        panel = {0.18,0.12,0.07,0.98},
        panel2 = {0.24,0.16,0.09,0.98},
        border = {0.52,0.35,0.14,1},
        title = {1.00,0.82,0.35,1},
        text = {0.84,0.76,0.60,1},
        value = {1.00,0.93,0.78,1},
        accent = {0.35,0.82,0.28,1},
        accent2 = {0.58,0.95,0.44,1},
        warning = {1.00,0.85,0.35,1},
        editbg = {0.14,0.09,0.04,1},
    }
}

local function C()
    return THEMES[db and db.theme or "dark"] or THEMES.dark
end

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

local function trim(s)
    return (s and s:gsub("^%s+", ""):gsub("%s+$", "")) or s
end

local function formatTime(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function formatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local neg = copper < 0
    if neg then copper = -copper end
    local g = math.floor(copper / COPPER_PER_GOLD)
    local s = math.floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
    local c = copper % COPPER_PER_SILVER
    local txt
    if g > 0 then
        txt = string.format("%dg %02ds %02dc", g, s, c)
    elseif s > 0 then
        txt = string.format("%ds %02dc", s, c)
    else
        txt = string.format("%dc", c)
    end
    return neg and ("-" .. txt) or txt
end

local function round(n)
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function sessionElapsed()
    if not db then return 0 end
    local saved = db.totals.sessionElapsedSaved or 0
    local running = (db.totals.sessionRunning == true)
    if not running then
        return math.max(0, saved)
    end
    if not db.totals.sessionStartTime or db.totals.sessionStartTime <= 0 then
        return math.max(0, saved)
    end
    return math.max(0, saved + (GetTime() - db.totals.sessionStartTime))
end

local function sessionGPH()
    local elapsed = sessionElapsed()
    if elapsed < 1 then return 0 end
    return (db.totals.sessionVendorCopper / elapsed) * 3600
end

local function parseGoalToCopper(text)
    text = trim(text or "")
    if text == "" then return nil end

    -- Supports: "10000" (copper), "25g", "12g50s", "1g 20s 5c"
    local total = 0
    local found = false

    local g = text:match("(%d+)%s*[gG]")
    local s = text:match("(%d+)%s*[sS]")
    local c = text:match("(%d+)%s*[cC]")
    if g or s or c then
        if g then total = total + tonumber(g) * COPPER_PER_GOLD; found = true end
        if s then total = total + tonumber(s) * COPPER_PER_SILVER; found = true end
        if c then total = total + tonumber(c); found = true end
        if found then return math.max(0, total) end
    end

    local numeric = tonumber(text)
    if numeric then
        return math.max(0, round(numeric))
    end
    return nil
end

local function applyBackdrop(f, bg, border)
    if not f.SetBackdrop then return end
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function createLabel(parent, size, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetFont(STANDARD_TEXT_FONT, size or 12, flags or "")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("MIDDLE")
    return fs
end

local function setButtonText(btn, text)
    if btn.text then btn.text:SetText(text) end
end

local BASE_W, BASE_H = 360, 285

local function setFSScaled(fs, base, flags)
    if not fs then return end
    local scale = (ui and ui.layoutScale) or 1
    fs:SetFont(STANDARD_TEXT_FONT, math.max(8, math.floor(base * scale + 0.5)), flags or fs._eaFlags or "")
end

local function applyResponsiveLayout()
    if not frame or not ui.titleBar then return end
    local w, h = frame:GetWidth(), frame:GetHeight()
    local sx, sy = w / BASE_W, h / BASE_H
    local s = math.max(0.75, math.min(1.8, math.min(sx, sy)))
    ui.layoutScale = s

    local m = math.floor(8 * s + 0.5)
    local gap = math.floor(8 * s + 0.5)
    local rowH = math.floor(18 * s + 0.5)
    local titleH = math.floor(30 * s + 0.5)
    local btnH = math.floor(22 * s + 0.5)
    local progressH = math.floor(24 * s + 0.5)

    ui.titleBar:ClearAllPoints()
    ui.titleBar:SetPoint("TOPLEFT", m, -m)
    ui.titleBar:SetPoint("TOPRIGHT", -m, -m)
    ui.titleBar:SetHeight(titleH)

    if ui.closeBtn then
        ui.closeBtn:SetWidth(math.floor(22 * s + 0.5)); ui.closeBtn:SetHeight(math.floor(22 * s + 0.5))
        ui.closeBtn:ClearAllPoints(); ui.closeBtn:SetPoint("RIGHT", -math.floor(4 * s + 0.5), 0)
    end

    ui.bodyPanel:ClearAllPoints()
    ui.bodyPanel:SetPoint("TOPLEFT", ui.titleBar, "BOTTOMLEFT", 0, -gap)
    ui.bodyPanel:SetPoint("TOPRIGHT", ui.titleBar, "BOTTOMRIGHT", 0, -gap)
    ui.bodyPanel:SetHeight(math.floor(184 * s + 0.5))

    ui.goalPanel:ClearAllPoints()
    ui.goalPanel:SetPoint("TOPLEFT", ui.bodyPanel, "BOTTOMLEFT", 0, -gap)
    ui.goalPanel:SetPoint("TOPRIGHT", ui.bodyPanel, "BOTTOMRIGHT", 0, -gap)
    ui.goalPanel:SetPoint("BOTTOM", frame, "BOTTOM", 0, math.floor(58 * s + 0.5))

    local left = math.floor(10 * s + 0.5)
    local top1 = math.floor(10 * s + 0.5)
    local row1y = math.floor(30 * s + 0.5)
    local rowGap = math.floor(18 * s + 0.5)

    ui.section1:ClearAllPoints(); ui.section1:SetPoint("TOPLEFT", left, -top1)
    if ui.sessionResetBtn then
        local rbW = math.floor(44 * s + 0.5)
        local rbH = math.floor(18 * s + 0.5)
        ui.sessionResetBtn:SetWidth(rbW); ui.sessionResetBtn:SetHeight(rbH)
        ui.sessionResetBtn:ClearAllPoints()
        ui.sessionResetBtn:SetPoint("LEFT", ui.section1, "RIGHT", math.floor(8*s+0.5), 0)
    end
    ui.l1:ClearAllPoints(); ui.l1:SetPoint("TOPLEFT", left, -row1y)
    ui.v1:ClearAllPoints(); ui.v1:SetPoint("TOPRIGHT", -left, -row1y)
    ui.l3:ClearAllPoints(); ui.l3:SetPoint("TOPLEFT", left, -(row1y+rowGap))
    ui.v3:ClearAllPoints(); ui.v3:SetPoint("TOPRIGHT", -left, -(row1y+rowGap))
    ui.l4:ClearAllPoints(); ui.l4:SetPoint("TOPLEFT", left, -(row1y+rowGap*2))
    ui.v4:ClearAllPoints(); ui.v4:SetPoint("TOPRIGHT", -left, -(row1y+rowGap*2))
    ui.l5:ClearAllPoints(); ui.l5:SetPoint("TOPLEFT", left, -(row1y+rowGap*3))
    ui.v5:ClearAllPoints(); ui.v5:SetPoint("TOPRIGHT", -left, -(row1y+rowGap*3))

    if ui.dividers and ui.dividers[1] then
        local d=ui.dividers[1]
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", left, -math.floor(123*s+0.5))
        d:SetPoint("TOPRIGHT", -left, -math.floor(123*s+0.5))
        d:SetHeight(math.max(1, math.floor(s+0.5)))
    end
    ui.section2:ClearAllPoints(); ui.section2:SetPoint("TOPLEFT", left, -math.floor(134*s+0.5))
    ui.l2:ClearAllPoints(); ui.l2:SetPoint("TOPLEFT", left, -math.floor(154*s+0.5))
    ui.v2:ClearAllPoints(); ui.v2:SetPoint("TOPRIGHT", -left, -math.floor(154*s+0.5))

    ui.section3:ClearAllPoints(); ui.section3:SetPoint("TOPLEFT", left, -top1)
    ui.goalLabel:ClearAllPoints(); ui.goalLabel:SetPoint("TOPLEFT", left, -math.floor(30*s+0.5))

    local panelW = ui.goalPanel:GetWidth() > 0 and ui.goalPanel:GetWidth() or (w - m*2)
    local innerW = panelW - left*2
    local topY = math.floor(25*s+0.5)
    local gapBtn = math.floor(6*s+0.5)
    local compact = (w <= 350)
    local veryCompact = (w <= 320)
    local goalLabelW = math.floor((compact and 28 or 40)*s+0.5)
    local themeW = math.floor(((compact and 60 or 94))*s+0.5)
    local setW = math.floor(((compact and 42 or 54))*s+0.5)
    local startW = math.floor(((compact and 48 or 58))*s+0.5)
    local remaining = innerW - goalLabelW - themeW - setW - startW - gapBtn*4
    local goalW = math.max(math.floor((compact and 88 or 74)*s+0.5), remaining)

    ui.goalEdit:SetWidth(goalW); ui.goalEdit:SetHeight(btnH)
    ui.setGoalBtn:SetWidth(setW); ui.setGoalBtn:SetHeight(btnH)
    ui.startStopBtn:SetWidth(startW); ui.startStopBtn:SetHeight(btnH)
    ui.themeBtn:SetWidth(themeW); ui.themeBtn:SetHeight(btnH)

    ui.goalEdit:ClearAllPoints(); ui.goalEdit:SetPoint("TOPLEFT", ui.goalPanel, "TOPLEFT", left + goalLabelW, -topY)
    ui.setGoalBtn:ClearAllPoints(); ui.setGoalBtn:SetPoint("LEFT", ui.goalEdit, "RIGHT", gapBtn, 0)
    ui.startStopBtn:ClearAllPoints(); ui.startStopBtn:SetPoint("LEFT", ui.setGoalBtn, "RIGHT", gapBtn, 0)
    ui.themeBtn:ClearAllPoints(); ui.themeBtn:SetPoint("LEFT", ui.startStopBtn, "RIGHT", gapBtn, 0)

    if compact then
        if ui.goalLabel then ui.goalLabel:SetText("G") else end
        if ui.setGoalBtn then setButtonText(ui.setGoalBtn, "Set") end
        if ui.themeBtn then
            local isDark = (db and db.theme == "dark")
            setButtonText(ui.themeBtn, isDark and "WoW" or "Dark")
        end
        if ui.goalSub then
            ui.goalSub:SetText(veryCompact and "/ea - reset - goal - start/stop" or "/ea toggle - reset - goal 25g - start/stop")
        end
    else
        if ui.goalLabel then ui.goalLabel:SetText("Goal") else end
        if ui.goalSub then ui.goalSub:SetText("/ea to toggle  -  /ea reset  -  /ea goal 25g  -  /ea start|pause") end
        if ui.themeBtn then
            local isDark = (db and db.theme == "dark")
            setButtonText(ui.themeBtn, isDark and "WoW Mode" or "Dark Mode")
        end
    end

    ui.goalSub:ClearAllPoints(); ui.goalSub:SetPoint("TOPLEFT", left, -math.floor(54*s+0.5))

    ui.progressBackdrop:ClearAllPoints()
    ui.progressBackdrop:SetPoint("TOPLEFT", left, -math.floor(74*s+0.5))
    ui.progressBackdrop:SetPoint("TOPRIGHT", -left, -math.floor(74*s+0.5))
    ui.progressBackdrop:SetHeight(progressH)

    ui.hint:ClearAllPoints(); ui.hint:SetPoint("BOTTOMLEFT", math.floor(10*s+0.5), math.floor(8*s+0.5))

    if ui.resize then
      local rw = math.floor(14*s + 0.5)
      ui.resize:SetWidth(rw); ui.resize:SetHeight(rw)
      ui.resize:ClearAllPoints(); ui.resize:SetPoint("BOTTOMRIGHT", -math.floor(5*s+0.5), math.floor(5*s+0.5))
    end

    -- Fonts
    ui.title._eaFlags = "OUTLINE"; setFSScaled(ui.title, 13, "OUTLINE")
    setFSScaled(ui.subtitle, 10, "")
    for _,fs in ipairs({ui.section1,ui.section2,ui.section3}) do fs._eaFlags="OUTLINE"; setFSScaled(fs,11,"OUTLINE") end
    for _,fs in ipairs({ui.l1,ui.l2,ui.l3,ui.l4,ui.l5,ui.goalLabel,ui.goalSub,ui.hint}) do setFSScaled(fs, fs==ui.goalSub and 10 or (fs==ui.hint and 9 or 11), "") end
    for _,fs in ipairs({ui.v1,ui.v2,ui.v3,ui.v4,ui.v5,ui.progressText}) do fs._eaFlags="OUTLINE"; setFSScaled(fs,11,"OUTLINE") end
    if ui.closeBtn and ui.closeBtn.text then ui.closeBtn.text._eaFlags="OUTLINE"; setFSScaled(ui.closeBtn.text,12,"OUTLINE") end
    for _,b in ipairs({ui.setGoalBtn,ui.startStopBtn,ui.themeBtn,ui.sessionResetBtn}) do if b and b.text then b.text._eaFlags="OUTLINE"; setFSScaled(b.text, (b==ui.sessionResetBtn) and 10 or 12, "OUTLINE") end end
    if ui.goalEdit then ui.goalEdit:SetFont(STANDARD_TEXT_FONT, math.max(8, math.floor(12*s + 0.5)), "") end

    if ui.subtitle then
        if w <= 325 then
            ui.subtitle:SetText("V" .. APP_VERSION)
        elseif w <= 365 then
            ui.subtitle:SetText("V" .. APP_VERSION .. " • " .. AUTHOR)
        else
            ui.subtitle:SetText("V" .. APP_VERSION .. "  •  by " .. AUTHOR)
        end
    end

    applyTheme()
end

local function makeButton(parent, w, h, text)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w); b:SetHeight(h)
    applyBackdrop(b, C().panel2, C().border)

    b.text = createLabel(b, 12, "OUTLINE")
    b.text:SetPoint("CENTER")
    b.text:SetText(text or "Button")

    b:SetScript("OnEnter", function(self)
        local c = C()
        self:SetBackdropBorderColor(c.accent[1], c.accent[2], c.accent[3], 1)
    end)
    b:SetScript("OnLeave", function(self)
        local c = C()
        self:SetBackdropBorderColor(c.border[1], c.border[2], c.border[3], c.border[4])
    end)
    b:SetScript("OnMouseDown", function(self)
        self.text:SetPoint("CENTER", 1, -1)
    end)
    b:SetScript("OnMouseUp", function(self)
        self.text:SetPoint("CENTER")
    end)
    return b
end

local function makeEditBox(parent, w, h)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetWidth(w); eb:SetHeight(h)
    applyBackdrop(eb, C().editbg, C().border)
    eb:SetAutoFocus(false)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetTextInsets(6,6,0,0)

    local fs = eb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetAllPoints(eb)
    fs:SetJustifyH("LEFT")
    fs:SetPoint("LEFT", 6, 0)
    eb:SetFont(STANDARD_TEXT_FONT, 12, "")
    eb.fs = fs

    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    eb:SetScript("OnEditFocusGained", function(self)
        self.fs:Hide()
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        self.fs:Show()
    end)
    eb:SetScript("OnTextChanged", function(self)
        self.fs:SetText(self:GetText())
        if self:GetText() == "" and not self:HasFocus() and self.placeholder then
            self.fs:SetText(self.placeholder)
            local c = C()
            self.fs:SetTextColor(c.text[1], c.text[2], c.text[3], 0.55)
        else
            local c = C()
            self.fs:SetTextColor(c.value[1], c.value[2], c.value[3], 1)
        end
    end)

    function eb:SetPlaceholder(text)
        self.placeholder = text
        if (self:GetText() or "") == "" and not self:HasFocus() then
            self.fs:SetText(text)
            local c = C()
            self.fs:SetTextColor(c.text[1], c.text[2], c.text[3], 0.55)
        end
    end

    return eb
end

applyTheme = function()
    if not frame then return end
    local c = C()

    applyBackdrop(frame, c.bg, c.border)
    if ui.titleBar then applyBackdrop(ui.titleBar, c.panel, c.border) end
    if ui.bodyPanel then applyBackdrop(ui.bodyPanel, c.panel, c.border) end
    if ui.goalPanel then applyBackdrop(ui.goalPanel, c.panel, c.border) end

    if ui.title then ui.title:SetTextColor(c.title[1], c.title[2], c.title[3], c.title[4]) end
    if ui.subtitle then ui.subtitle:SetTextColor(c.text[1], c.text[2], c.text[3], 1) end
    if ui.section1 then ui.section1:SetTextColor(c.warning[1], c.warning[2], c.warning[3], 1) end
    if ui.section2 then ui.section2:SetTextColor(c.warning[1], c.warning[2], c.warning[3], 1) end
    if ui.section3 then ui.section3:SetTextColor(c.warning[1], c.warning[2], c.warning[3], 1) end
    if ui.hint then ui.hint:SetTextColor(c.text[1], c.text[2], c.text[3], 0.75) end

    local labels = { ui.l1,ui.l2,ui.l3,ui.l4,ui.l5,ui.goalLabel,ui.goalSub }
    for _, fs in ipairs(labels) do
        if fs then fs:SetTextColor(c.text[1], c.text[2], c.text[3], 1) end
    end
    local vals = { ui.v1,ui.v2,ui.v3,ui.v4,ui.v5 }
    for _, fs in ipairs(vals) do
        if fs then fs:SetTextColor(c.value[1], c.value[2], c.value[3], 1) end
    end

    if ui.progressBackdrop then applyBackdrop(ui.progressBackdrop, c.editbg, c.border) end
    if ui.progressFill then ui.progressFill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar") end
    if ui.progressFill then ui.progressFill:SetVertexColor(c.accent[1], c.accent[2], c.accent[3], 1) end
    if ui.progressGlow then ui.progressGlow:SetTexture("Interface\\Buttons\\WHITE8X8") end
    if ui.progressGlow then ui.progressGlow:SetVertexColor(c.accent2[1], c.accent2[2], c.accent2[3], 0.14) end
    if ui.progressText then ui.progressText:SetTextColor(c.value[1], c.value[2], c.value[3], 1) end

    if ui.goalEdit then
        applyBackdrop(ui.goalEdit, c.editbg, c.border)
        ui.goalEdit:SetScript("OnTextChanged", ui.goalEdit:GetScript("OnTextChanged"))
        local t = ui.goalEdit:GetText()
        ui.goalEdit.fs:SetText((t and t ~= "") and t or (ui.goalEdit.placeholder or ""))
        if (not t or t == "") and not ui.goalEdit:HasFocus() then
            ui.goalEdit.fs:SetTextColor(c.text[1], c.text[2], c.text[3], 0.55)
        else
            ui.goalEdit.fs:SetTextColor(c.value[1], c.value[2], c.value[3], 1)
        end
    end

    if ui.themeBtn then
        local compactTheme = frame and frame.GetWidth and frame:GetWidth() <= 350
        setButtonText(ui.themeBtn, db.theme == "dark" and (compactTheme and "WoW" or "WoW Mode") or (compactTheme and "Dark" or "Dark Mode"))
        applyBackdrop(ui.themeBtn, c.panel2, c.border)
        ui.themeBtn.text:SetTextColor(c.value[1], c.value[2], c.value[3], 1)
    end
    if ui.setGoalBtn then applyBackdrop(ui.setGoalBtn, c.panel2, c.border); ui.setGoalBtn.text:SetTextColor(c.value[1], c.value[2], c.value[3], 1) end
    if ui.startStopBtn then applyBackdrop(ui.startStopBtn, c.panel2, c.border); ui.startStopBtn.text:SetTextColor(c.value[1], c.value[2], c.value[3], 1) end
    if ui.sessionResetBtn then applyBackdrop(ui.sessionResetBtn, c.panel2, c.border); ui.sessionResetBtn.text:SetTextColor(c.value[1], c.value[2], c.value[3], 1) end

    if ui.closeBtn and ui.closeBtn.text then ui.closeBtn.text:SetTextColor(c.value[1], c.value[2], c.value[3], 1) end

    if ui.dividers then
        for _, d in ipairs(ui.dividers) do
            d:SetTexture("Interface\\Buttons\\WHITE8X8")
            d:SetVertexColor(c.border[1], c.border[2], c.border[3], 0.75)
        end
    end
end

local function refreshUI()
    if not frame then return end
    local elapsed = sessionElapsed()
    local session = db.totals.sessionVendorCopper or 0
    local lifetime = db.totals.lifetimeVendorCopper or 0
    local gph = sessionGPH()
    local goal = db.goalCopper or 0

    ui.v1:SetText(formatMoney(session))
    ui.v2:SetText(formatMoney(lifetime))
    ui.v3:SetText(formatMoney(round(gph)))
    ui.v4:SetText(formatTime(elapsed))
    ui.v5:SetText(tostring(db.totals.sessionItems or 0))

    local pct = 0
    if goal > 0 then pct = math.min(1, session / goal) end
    ui.progress:SetMinMaxValues(0, 1)
    ui.progress:SetValue(pct)
    ui.progressText:SetText(string.format("%d%%  (%s / %s)", math.floor((pct * 100) + 0.5), formatMoney(session), formatMoney(goal)))

    if pct >= 1 and goal > 0 then
        local c = C()
        ui.progressText:SetTextColor(c.accent2[1], c.accent2[2], c.accent2[3], 1)
    else
        local c = C()
        ui.progressText:SetTextColor(c.value[1], c.value[2], c.value[3], 1)
    end

    if ui.goalEdit and not ui.goalEdit:HasFocus() then
        ui.goalEdit:SetText("")
        ui.goalEdit.fs:SetText(formatMoney(goal))
        local c = C()
        ui.goalEdit.fs:SetTextColor(c.value[1], c.value[2], c.value[3], 1)
    end
end


local function forceWindowClosed()
    if not frame then return end
    frame:Hide()
    frame:SetAlpha(0)
    frame:EnableMouse(false)
    frame._eaForceHiddenUntil = (GetTime and GetTime() or 0) + 0.6
end

local function releaseForcedWindowClose()
    if not frame then return end
    frame:SetAlpha(1)
    frame:EnableMouse(true)
    frame._eaForceHiddenUntil = nil
    if db and db.startClosed then frame:Hide() end
end

local function runAfter(delay, func)
    local timer = CreateFrame("Frame")
    local elapsed = 0
    timer:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed >= delay then
            self:SetScript("OnUpdate", nil)
            if func then func() end
        end
    end)
end

local function updateStartStopButton()
    if not ui.startStopBtn then return end
    local running = (db.totals.sessionRunning == true)
    setButtonText(ui.startStopBtn, running and "Stop" or "Start")
end

local function setSessionRunning(running, silent)
    running = not not running
    local currentlyRunning = (db.totals.sessionRunning == true)
    if running == currentlyRunning then
        updateStartStopButton()
        return
    end

    if running then
        db.totals.sessionStartTime = GetTime()
        db.totals.sessionRunning = true
        if not silent then msg("Session started.") end
    else
        if db.totals.sessionStartTime and db.totals.sessionStartTime > 0 then
            db.totals.sessionElapsedSaved = (db.totals.sessionElapsedSaved or 0) + math.max(0, GetTime() - db.totals.sessionStartTime)
        end
        db.totals.sessionStartTime = 0
        db.totals.sessionRunning = false
        if not silent then msg("Session paused.") end
    end
    updateStartStopButton()
    refreshUI()
end

local function toggleSessionRunning()
    setSessionRunning(not (db.totals.sessionRunning == true), false)
end

local function addVendorValue(copper, itemCount)
    copper = tonumber(copper) or 0
    if copper <= 0 then return end
    db.totals.sessionVendorCopper = (db.totals.sessionVendorCopper or 0) + copper
    db.totals.lifetimeVendorCopper = (db.totals.lifetimeVendorCopper or 0) + copper
    db.totals.sessionItems = (db.totals.sessionItems or 0) + (itemCount or 0)
    refreshUI()
end


local function resetSession(silent)
    db.totals.sessionVendorCopper = 0
    db.totals.sessionItems = 0
    db.totals.sessionElapsedSaved = 0
    db.totals.sessionStartTime = (db.totals.sessionRunning == false) and 0 or GetTime()
    db.totals.sessionResets = (db.totals.sessionResets or 0) + 1
    refreshUI()
    if not silent then msg("Session reset.") end
end

local function setGoalFromText(text)
    local copper = parseGoalToCopper(text)
    if copper == nil then
        msg("Invalid goal. Use examples: 250000 (copper), 25g, 12g50s")
        return false
    end
    db.goalCopper = copper
    refreshUI()
    msg("Goal set to " .. formatMoney(copper) .. ".")
    return true
end

local function buildUI()
    frame = CreateFrame("Frame", "EbonholdAppraiserFrame", UIParent)
    frame:SetWidth(db.window.width or 360)
    frame:SetHeight(db.window.height or 270)
    frame:SetMinResize(340, 250)
    frame:SetMaxResize(520, 420)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:RegisterForDrag("LeftButton")
    applyBackdrop(frame, C().bg, C().border)

    frame:SetScript("OnDragStart", function(self)
        if db.lockWindow then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint(1)
        db.window.point, db.window.x, db.window.y = p or "CENTER", x or 0, y or 0
        db.window.relativePoint = rp or "CENTER"
    end)

    frame:SetScript("OnSizeChanged", function(self, w, h)
        db.window.width, db.window.height = math.floor(w), math.floor(h)
        applyResponsiveLayout()
    end)

    if db.window and db.window.point then
        frame:SetPoint(db.window.point, UIParent, db.window.relativePoint or db.window.point, db.window.x or 0, db.window.y or 0)
    else
        frame:SetPoint("CENTER")
    end

    ui.titleBar = CreateFrame("Frame", nil, frame)
    ui.titleBar:SetPoint("TOPLEFT", 8, -8)
    ui.titleBar:SetPoint("TOPRIGHT", -8, -8)
    ui.titleBar:SetHeight(30)
    applyBackdrop(ui.titleBar, C().panel, C().border)
    ui.titleBar:EnableMouse(true)
    ui.titleBar:RegisterForDrag("LeftButton")
    ui.titleBar:SetScript("OnDragStart", frame:GetScript("OnDragStart"))
    ui.titleBar:SetScript("OnDragStop", frame:GetScript("OnDragStop"))

    ui.title = createLabel(ui.titleBar, 13, "OUTLINE")
    ui.title:SetPoint("LEFT", 10, 0)
    ui.title:SetText(APP_NAME)

    ui.subtitle = createLabel(ui.titleBar, 10, "")
    ui.subtitle:SetPoint("LEFT", ui.title, "RIGHT", 8, 0)
    ui.subtitle:SetText("V" .. APP_VERSION .. "  •  by " .. AUTHOR)

    ui.closeBtn = makeButton(ui.titleBar, 22, 22, "X")
    ui.closeBtn:SetPoint("RIGHT", -4, 0)
    ui.closeBtn:SetScript("OnClick", function() frame:Hide() end)

    ui.bodyPanel = CreateFrame("Frame", nil, frame)
    ui.bodyPanel:SetPoint("TOPLEFT", ui.titleBar, "BOTTOMLEFT", 0, -8)
    ui.bodyPanel:SetPoint("TOPRIGHT", ui.titleBar, "BOTTOMRIGHT", 0, -8)
    ui.bodyPanel:SetHeight(184)
    applyBackdrop(ui.bodyPanel, C().panel, C().border)

    ui.section1 = createLabel(ui.bodyPanel, 11, "OUTLINE")
    ui.section1:SetPoint("TOPLEFT", 10, -10)
    ui.section1:SetText("SESSION")

    ui.sessionResetBtn = makeButton(ui.bodyPanel, 44, 18, "Reset")
    ui.sessionResetBtn:SetScript("OnClick", function()
        resetSession(false)
    end)

    local function row(y, labelText)
        local l = createLabel(ui.bodyPanel, 11, "")
        l:SetPoint("TOPLEFT", 10, y)
        l:SetText(labelText)
        local v = createLabel(ui.bodyPanel, 11, "OUTLINE")
        v:SetPoint("TOPRIGHT", -10, y)
        v:SetJustifyH("RIGHT")
        v:SetText("-")
        return l, v
    end

    ui.l1, ui.v1 = row(-30, "Vendor Value (Session)")
    ui.l3, ui.v3 = row(-48, "Vendor GPH")
    ui.l4, ui.v4 = row(-66, "Session Time")
    ui.l5, ui.v5 = row(-84, "Items Counted")

    local div1 = ui.bodyPanel:CreateTexture(nil, "ARTWORK")
    div1:SetPoint("TOPLEFT", 10, -105)
    div1:SetPoint("TOPRIGHT", -10, -105)
    div1:SetHeight(1)

    ui.section2 = createLabel(ui.bodyPanel, 11, "OUTLINE")
    ui.section2:SetPoint("TOPLEFT", 10, -116)
    ui.section2:SetText("TOTALS")
    ui.l2, ui.v2 = row(-136, "Vendor Value (Lifetime)")

    ui.goalPanel = CreateFrame("Frame", nil, frame)
    ui.goalPanel:SetPoint("TOPLEFT", ui.bodyPanel, "BOTTOMLEFT", 0, -8)
    ui.goalPanel:SetPoint("TOPRIGHT", ui.bodyPanel, "BOTTOMRIGHT", 0, -8)
    ui.goalPanel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 58)
    applyBackdrop(ui.goalPanel, C().panel, C().border)

    ui.section3 = createLabel(ui.goalPanel, 11, "OUTLINE")
    ui.section3:SetPoint("TOPLEFT", 10, -10)
    ui.section3:SetText("GOAL TRACKER")

    ui.goalLabel = createLabel(ui.goalPanel, 11, "")
    ui.goalLabel:SetPoint("TOPLEFT", 10, -30)
    ui.goalLabel:SetText("Goal")

    ui.goalEdit = makeEditBox(ui.goalPanel, 98, 22)
    ui.goalEdit:SetPoint("TOPLEFT", 50, -25)
    ui.goalEdit:SetPlaceholder("e.g. 25g")
    ui.goalEdit:SetScript("OnEnterPressed", function(self)
        if setGoalFromText(self:GetText()) then self:SetText("") end
        self:ClearFocus()
    end)
    ui.goalEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText(""); refreshUI() end)

    ui.setGoalBtn = makeButton(ui.goalPanel, 54, 22, "Set")
    ui.setGoalBtn:SetPoint("LEFT", ui.goalEdit, "RIGHT", 6, 0)
    ui.setGoalBtn:SetScript("OnClick", function()
        if setGoalFromText(ui.goalEdit:GetText()) then ui.goalEdit:SetText("") end
    end)

    ui.startStopBtn = makeButton(ui.goalPanel, 58, 22, "Start")
    ui.startStopBtn:SetPoint("LEFT", ui.setGoalBtn, "RIGHT", 6, 0)
    ui.startStopBtn:SetScript("OnClick", function()
        toggleSessionRunning()
    end)

    ui.themeBtn = makeButton(ui.goalPanel, 86, 22, "WoW Mode")
    ui.themeBtn:SetPoint("LEFT", ui.startStopBtn, "RIGHT", 6, 0)
    ui.themeBtn:SetScript("OnClick", function()
        db.theme = (db.theme == "dark") and "wow" or "dark"
        applyTheme()
        refreshUI()
    end)

    ui.goalSub = createLabel(ui.goalPanel, 10, "")
    ui.goalSub:SetPoint("TOPLEFT", 10, -54)
    ui.goalSub:SetText("/ea to toggle  -  /ea reset  -  /ea goal 25g  -  /ea start|pause")

    ui.progressBackdrop = CreateFrame("Frame", nil, ui.goalPanel)
    ui.progressBackdrop:SetPoint("TOPLEFT", 10, -74)
    ui.progressBackdrop:SetPoint("TOPRIGHT", -10, -74)
    ui.progressBackdrop:SetHeight(24)
    applyBackdrop(ui.progressBackdrop, C().editbg, C().border)

    ui.progress = CreateFrame("StatusBar", nil, ui.progressBackdrop)
    ui.progress:SetPoint("TOPLEFT", 3, -3)
    ui.progress:SetPoint("BOTTOMRIGHT", -3, 3)
    ui.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    ui.progress:SetMinMaxValues(0, 1)
    ui.progress:SetValue(0)
    ui.progressFill = ui.progress:GetStatusBarTexture()

    ui.progressGlow = ui.progress:CreateTexture(nil, "BACKGROUND")
    ui.progressGlow:SetAllPoints(ui.progress)

    ui.progressText = createLabel(ui.progress, 11, "OUTLINE")
    ui.progressText:SetPoint("CENTER")
    ui.progressText:SetJustifyH("CENTER")

    ui.hint = createLabel(frame, 10, "")
    ui.hint:SetPoint("BOTTOMLEFT", 10, 8)
    ui.hint:SetText("")

    local resize = CreateFrame("Button", nil, frame)
    resize:SetWidth(14); resize:SetHeight(14)
    resize:SetPoint("BOTTOMRIGHT", -5, 5)
    resize:EnableMouse(true)
    resize:SetScript("OnMouseDown", function()
        if db.lockWindow then return end
        frame:StartSizing("BOTTOMRIGHT")
    end)
    resize:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        local p, _, rp, x, y = frame:GetPoint(1)
        db.window.point, db.window.relativePoint, db.window.x, db.window.y = p, rp, x, y
    end)
    resize.tex = resize:CreateTexture(nil, "OVERLAY")
    resize.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resize.tex:SetAllPoints(resize)
    ui.resize = resize

    ui.dividers = { div1 }

    frame:SetScript("OnShow", refreshUI)
    frame:SetScript("OnUpdate", function(self, elapsed)
        self._eaTicker = (self._eaTicker or 0) + elapsed
        if self._eaTicker >= 0.25 then
            self._eaTicker = 0
            refreshUI()
        end
    end)

    applyResponsiveLayout()
    updateStartStopButton()
    refreshUI()
    forceWindowClosed()
    frame:SetScript("OnShow", function(self)
        if self._eaForceHiddenUntil and ((GetTime and GetTime() or 0) < self._eaForceHiddenUntil) then
            self:Hide()
            return
        end
        self:SetAlpha(1)
        self:EnableMouse(true)
        refreshUI()
    end)
end

getItemVendorValue = function(itemLink)
    if not itemLink then return nil end
    local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemLink)
    return sellPrice
end

local function itemKeyFromLink(itemLink)
    if not itemLink then return nil end
    local itemString = string.match(itemLink, "|H(item:[^|]+)|h")
    return itemString or itemLink
end

local function getBagSnapshot()
    local snap = {}
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local _, itemCount = GetContainerItemInfo(bag, slot)
                itemCount = tonumber(itemCount) or 1
                local key = itemKeyFromLink(itemLink)
                if key then
                    local row = snap[key]
                    if not row then
                        row = { qty = 0, link = itemLink }
                        snap[key] = row
                    end
                    row.qty = row.qty + itemCount
                    row.link = itemLink
                end
            end
        end
    end
    return snap
end

local function initBagSnapshot()
    bagSnapshot = getBagSnapshot()
end

local function queuePendingItem(itemLink, qty)
    if not frame then return end
    frame.pendingItems = frame.pendingItems or {}
    table.insert(frame.pendingItems, {link = itemLink, qty = qty, tries = 0})
end

local function processBagDelta()
    if not db or not frame then return end
    local current = getBagSnapshot()
    if not bagSnapshot then
        bagSnapshot = current
        return
    end

    local running = (db.totals.sessionRunning == true)
    for key, row in pairs(current) do
        local oldQty = (bagSnapshot[key] and bagSnapshot[key].qty) or 0
        local delta = (row.qty or 0) - oldQty
        if delta > 0 and running then
            local sellPrice = getItemVendorValue(row.link)
            if sellPrice == nil then
                queuePendingItem(row.link, delta)
            elseif sellPrice > 0 then
                addVendorValue(sellPrice * delta, delta)
            end
        end
    end

    bagSnapshot = current
end

-- Kept for compatibility but no longer used as the primary tracker.
local function processLootMessage(text)
    return nil
end

local function processPending()
    if not frame or not frame.pendingItems or #frame.pendingItems == 0 then return end
    local keep = {}
    for i = 1, #frame.pendingItems do
        local p = frame.pendingItems[i]
        local sellPrice = getItemVendorValue(p.link)
        if sellPrice and sellPrice > 0 then
            addVendorValue(sellPrice * (p.qty or 1), p.qty or 1)
        else
            p.tries = (p.tries or 0) + 1
            if p.tries < 20 then
                table.insert(keep, p)
            end
        end
    end
    frame.pendingItems = keep
end

local function toggleWindow()
    if not frame then return end
    if frame._eaForceHiddenUntil then
        releaseForcedWindowClose()
    end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        if db and db.totals and db.totals.sessionRunning ~= true then
            setSessionRunning(true, true)
        end
        refreshUI()
    end
end

local function _eaTokenizeCommand(msgText)
    msgText = trim(tostring(msgText or ""))
    if msgText == "" then return "", "" end

    -- Support accidental punctuation like "/ea reset," and extra spaces
    local cmd, rest = msgText:match("^(%S+)%s*(.-)$")
    cmd = string.lower((cmd or ""):gsub("[^%a]", ""))
    rest = trim(rest or "")
    return cmd, rest
end

local function slashHandler(msgText)
    if not frame then
        msg("UI is not ready yet. Try again in a moment.")
        return
    end
    local cmd, rest = _eaTokenizeCommand(msgText)

    if cmd == "" then
        toggleWindow(); return
    elseif cmd == "show" then
        frame:Show()
        if db and db.totals and db.totals.sessionRunning ~= true then
            setSessionRunning(true, true)
        end
        refreshUI(); return
    elseif cmd == "hide" then
        frame:Hide(); return
    elseif cmd == "toggle" then
        toggleWindow(); return
    elseif cmd == "reset" then
        resetSession(false); return
    elseif cmd == "start" or cmd == "run" then
        setSessionRunning(true, false); return
    elseif cmd == "stop" or cmd == "pause" then
        setSessionRunning(false, false); return
    elseif cmd == "goal" or cmd == "setgoal" then
        if rest == "" then
            msg("Current goal: " .. formatMoney(db.goalCopper or 0))
            return
        end
        setGoalFromText(rest)
        return
    elseif cmd == "dark" then
        db.theme = (db.theme == "wow" or db.theme == "dark") and db.theme or "dark"
        -- Force dark mode on startup per user preference
        db.theme = "dark"; applyTheme(); refreshUI(); msg("Dark mode enabled."); return
    elseif cmd == "wow" then
        db.theme = "wow"; applyTheme(); refreshUI(); msg("WoW mode enabled."); return
    elseif cmd == "theme" then
        rest = string.lower(trim(rest or ""))
        if rest == "dark" or rest == "wow" then
            db.theme = rest; applyTheme(); refreshUI(); msg((rest == "wow" and "WoW" or "Dark") .. " mode enabled.")
        else
            msg("Usage: /ea theme dark OR /ea theme wow")
        end
        return
    elseif cmd == "lock" then
        db.lockWindow = true; msg("Window locked."); return
    elseif cmd == "unlock" then
        db.lockWindow = false; msg("Window unlocked."); return
    elseif cmd == "status" then
        msg(string.format("Session: %s | GPH: %s | Goal: %s | %s | Theme: %s", formatMoney(db.totals.sessionVendorCopper or 0), formatMoney(round(sessionGPH())), formatMoney(db.goalCopper or 0), (db.totals.sessionRunning == true) and "Running" or "Stopped", db.theme or "dark"))
        return
    elseif cmd == "help" or cmd == "commands" then
        msg("Commands: /ea, /ea start, /ea pause, /ea reset, /ea goal 25g, /ea dark, /ea wow, /ea lock, /ea unlock, /ea status")
        return
    else
        msg("Unknown command. Type /ea help")
        return
    end
end

local function registerSlashCommands()
    SLASH_EBONHOLDAPPRAISER1 = "/ea"
    SLASH_EBONHOLDAPPRAISER2 = "/ebonholdappraiser"
    SLASH_EBONHOLDAPPRAISER3 = "/eapp"
    SLASH_EBONHOLDAPPRAISER4 = "/eappraiser"
    SlashCmdList["EBONHOLDAPPRAISER"] = function(text) slashHandler(text or "") end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= addonName then return end

        EbonholdAppraiserDB = deepcopyDefaults(EbonholdAppraiserDB, defaults)
        db = EbonholdAppraiserDB

        if db.totals.sessionElapsedSaved == nil then db.totals.sessionElapsedSaved = 0 end
        if db.totals.sessionRunning == nil then db.totals.sessionRunning = false end
        db.theme = (db.theme == "wow" or db.theme == "dark") and db.theme or "dark"
        -- Force dark mode on startup per user preference
        db.theme = "dark"
        -- Start paused by default on login/reload so the Start button shows when opened
        db.totals.sessionRunning = false
        db.totals.sessionStartTime = 0

        buildUI()
        db.startClosed = true
        setSessionRunning(false, true)
        if frame then
            updateStartStopButton()
            refreshUI()
            forceWindowClosed()
            runAfter(1.0, function() if frame then releaseForcedWindowClose() end end)
        end
        initBagSnapshot()

        registerSlashCommands()

        msg("Loaded. Type /ea to open.")

    elseif event == "CHAT_MSG_LOOT" then
        local text = ...
        if type(text) == "string" and string.find(text, YOU_LOOT_MONEY or "") then
            return
        end
        -- Optional/no-op now; BAG_UPDATE is the source of truth for lootbot compatibility.
        processLootMessage(text)
    elseif event == "BAG_UPDATE" then
        processBagDelta()
    elseif event == "PLAYER_ENTERING_WORLD" then
        registerSlashCommands() -- re-register in case another addon overwrote /ea
        initBagSnapshot()
        if db then
            db.totals.sessionRunning = false
            db.totals.sessionStartTime = 0
        end
        if frame then
            updateStartStopButton()
            refreshUI()
        end
        if frame and db and db.startClosed then
            forceWindowClosed()
            runAfter(1.0, function() if frame then releaseForcedWindowClose() end end)
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        processPending()
    end
end)
