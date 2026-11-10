-- ============================================================================
-- GuildScanner - World of Warcraft: Forever (Client 1.60.1 / Interface 16001)
-- ============================================================================
-- Kompatibel mit Midnight/Forever Engine-Restriktionen (Kein Combat Log,
-- UnitIsForbidden-Prüfung, SecureActionButton Combat-Lockdown-Queue).
-- Inklusive Einstellungs-GUI, Blizzard AddOn-Options & Minimap-Button.
-- ============================================================================

local ADDON_NAME = ...
local GuildScanner = CreateFrame("Frame", "GuildScannerEventFrame")

-- ============================================================================
-- Konstanten & Lokale Variablen
-- ============================================================================
local COOLDOWN_SECONDS = 60
local recentDetections = {} -- [playerName] = timestamp (GetTime)
local pendingAlert = nil    -- Speichert { exactName, displayName, guildName, guildRank, classFile, factionGroup } während Kampf

local PREFIX = "|cff00ccff[GuildScanner]|r "

local DEFAULT_DB = {
    watchlist = {}, -- [lowercaseGuildName] = OriginalGuildName
    point = "CENTER",
    relativePoint = "CENTER",
    xOfs = 0,
    yOfs = -180,
    minimapAngle = 225,
    hideMinimapButton = false,
    soundEnabled = true,
}

-- Vorwärtsdeklarationen für UI-Updates
local RefreshWatchlistUI
local ToggleConfigFrame
local UpdateMinimapButtonPosition

-- ============================================================================
-- Hilfsfunktionen
-- ============================================================================
local function PrintMsg(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

local function Trim(str)
    if not str then return "" end
    return str:match("^%s*(.-)%s*$") or ""
end

local function GetClassColorHex(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local c = RAID_CLASS_COLORS[classFile]
        return c.colorStr or string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255), c.r, c.g, c.b
    end
    return "ffffffff", 1.0, 1.0, 1.0
end

local function GetFullPlayerName(unit)
    local name, realm = UnitName(unit)
    if not name or name == UNKNOWNOBJECT then
        return nil
    end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- ============================================================================
-- Watchlist-Verwaltung (Zentrale Funktionen für Chat & GUI)
-- ============================================================================
local function AddGuildToWatchlist(guildName)
    guildName = Trim(guildName)
    if guildName == "" then
        PrintMsg("|cffff5555Bitte gib einen gültigen Gildennamen ein.|r")
        return false
    end
    local key = string.lower(guildName)
    GuildScannerDB.watchlist[key] = guildName
    PrintMsg(string.format("Gilde |cff40ff40<%s>|r wurde zur Watchlist hinzugefügt.", guildName))
    if RefreshWatchlistUI then
        RefreshWatchlistUI()
    end
    return true
end

local function RemoveGuildFromWatchlist(guildNameOrKey)
    guildNameOrKey = Trim(guildNameOrKey)
    if guildNameOrKey == "" then return false end
    local key = string.lower(guildNameOrKey)
    local existing = GuildScannerDB.watchlist[key]
    if existing then
        GuildScannerDB.watchlist[key] = nil
        PrintMsg(string.format("Gilde |cffff5555<%s>|r wurde von der Watchlist entfernt.", existing))
        if RefreshWatchlistUI then
            RefreshWatchlistUI()
        end
        return true
    else
        PrintMsg(string.format("Gilde |cffff5555<%s>|r befindet sich nicht auf der Watchlist.", guildNameOrKey))
        return false
    end
end

-- ============================================================================
-- RareScanner-Style Alert-Popup (SecureActionButtonTemplate + BackdropTemplate)
-- ============================================================================
local alertFrame = CreateFrame("Button", "GuildScannerAlertFrame", UIParent, "SecureActionButtonTemplate, BackdropTemplate")
alertFrame:SetSize(280, 78)
alertFrame:SetFrameStrata("HIGH")
alertFrame:SetClampedToScreen(true)
alertFrame:SetMovable(true)
alertFrame:RegisterForDrag("LeftButton")
alertFrame:RegisterForClicks("AnyUp", "AnyDown")
alertFrame:Hide()

alertFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
})
alertFrame:SetBackdropColor(0.08, 0.08, 0.1, 0.94)
alertFrame:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)

-- Standard-Attribut für Linksklick: Auto-Target-Makro
alertFrame:SetAttribute("type", "macro")
alertFrame:SetAttribute("type1", "macro")
alertFrame:SetAttribute("macrotext", "")
alertFrame:SetAttribute("macrotext1", "")
alertFrame:SetAttribute("type2", "")

-- Glow-Overlay für optisches Aufleuchten bei Alarm
local glowBorder = CreateFrame("Frame", nil, alertFrame, "BackdropTemplate")
glowBorder:SetPoint("TOPLEFT", -4, 4)
glowBorder:SetPoint("BOTTOMRIGHT", 4, -4)
glowBorder:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
})
glowBorder:SetBackdropBorderColor(1.0, 0.2, 0.1, 0.0)

-- Aufleucht-Animation für den Rahmen
local glowAnimGroup = glowBorder:CreateAnimationGroup()
glowAnimGroup:SetLooping("BOUNCE")

local glowAlpha = glowAnimGroup:CreateAnimation("Alpha")
glowAlpha:SetFromAlpha(0.15)
glowAlpha:SetToAlpha(1.0)
glowAlpha:SetDuration(0.45)
glowAlpha:SetSmoothing("IN_OUT")

local function TriggerGlowAnimation()
    glowBorder:SetBackdropBorderColor(1.0, 0.25, 0.1, 1.0)
    glowAnimGroup:Play()
    C_Timer.After(3.6, function()
        if glowAnimGroup:IsPlaying() then
            glowAnimGroup:Stop()
        end
        glowBorder:SetBackdropBorderColor(1.0, 0.25, 0.1, 0.0)
    end)
end

-- Klassen-/Fraktionssymbol links im Popup
local iconTexture = alertFrame:CreateTexture(nil, "ARTWORK")
iconTexture:SetSize(44, 44)
iconTexture:SetPoint("LEFT", alertFrame, "LEFT", 14, 2)
iconTexture:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")

-- Kleines Fraktions-Badge am Icon
local factionBadge = alertFrame:CreateTexture(nil, "OVERLAY")
factionBadge:SetSize(20, 20)
factionBadge:SetPoint("BOTTOMRIGHT", iconTexture, "BOTTOMRIGHT", 4, -4)

-- Header ("GILDEN-ALARM")
local headerText = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
headerText:SetPoint("TOPLEFT", iconTexture, "TOPRIGHT", 10, 2)
headerText:SetPoint("RIGHT", alertFrame, "RIGHT", -28, 0)
headerText:SetJustifyH("LEFT")
headerText:SetText("|cffff4444GILDEN-ALARM|r")

-- Spielername (in Klassenfarbe)
local playerText = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
playerText:SetPoint("TOPLEFT", headerText, "BOTTOMLEFT", 0, -2)
playerText:SetPoint("RIGHT", alertFrame, "RIGHT", -28, 0)
playerText:SetJustifyH("LEFT")
playerText:SetWordWrap(false)

-- Gildenname "<Gilde>"
local guildText = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
guildText:SetPoint("TOPLEFT", playerText, "BOTTOMLEFT", 0, -2)
guildText:SetPoint("RIGHT", alertFrame, "RIGHT", -14, 0)
guildText:SetJustifyH("LEFT")
guildText:SetWordWrap(false)

-- Hinweis-Zeile unten
local hintText = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hintText:SetPoint("BOTTOM", alertFrame, "BOTTOM", 0, 7)
hintText:SetText("Linksklick: Anvisieren  |  Shift+Ziehen: Bewegen")

-- Schließen-Button oben rechts (UIPanelCloseButton)
local closeButton = CreateFrame("Button", nil, alertFrame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", alertFrame, "TOPRIGHT", -2, -2)
closeButton:SetScript("OnClick", function()
    if InCombatLockdown() then
        PrintMsg("|cffff5555Das Popup kann während des Kampfes nicht geschlossen werden (Combat Lockdown).|r")
        return
    end
    alertFrame:Hide()
end)

-- Rechtsklick zum Schließen (außerhalb des Kampfes)
alertFrame:HookScript("PostClick", function(self, button)
    if button == "RightButton" and not InCombatLockdown() then
        self:Hide()
    end
end)

-- Drag & Drop zum Verschieben (Nur mit gehaltener Shift-Taste, damit normale Klicks mit Mausbewegung nicht als Drag verschluckt werden!)
alertFrame:SetScript("OnDragStart", function(self)
    if InCombatLockdown() then
        PrintMsg("|cffff5555Das Popup kann im Kampf nicht verschoben werden.|r")
        return
    end
    if IsShiftKeyDown() then
        self:StartMoving()
        self.isMoving = true
    end
end)

alertFrame:SetScript("OnDragStop", function(self)
    if self.isMoving then
        self:StopMovingOrSizing()
        self.isMoving = false
        if GuildScannerDB then
            local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
            GuildScannerDB.point = point or "CENTER"
            GuildScannerDB.relativePoint = relativePoint or "CENTER"
            GuildScannerDB.xOfs = xOfs or 0
            GuildScannerDB.yOfs = yOfs or -180
        end
    end
end)

-- Tooltip beim Überfahren mit der Maus
alertFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("GuildScanner", 0.0, 0.8, 1.0)
    if self.currentDisplayName then
        GameTooltip:AddLine("Spieler: " .. self.currentDisplayName, 1, 1, 1)
    end
    if self.currentGuildName then
        local rankInfo = self.currentGuildRank and (" (" .. self.currentGuildRank .. ")") or ""
        GameTooltip:AddLine("Gilde: <" .. self.currentGuildName .. ">" .. rankInfo, 0.2, 1.0, 0.2)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Linksklick: Spieler ins Ziel nehmen (/target)", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Rechtsklick / X: Schließen (außerhalb des Kampfes)", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Shift + Linksklick-Ziehen: Fenster verschieben", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)

alertFrame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ============================================================================
-- Popup-Anzeige & Combat-Lockdown-Handling
-- ============================================================================
local function SetUnitVisuals(classFile, factionGroup)
    if classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
        local coords = CLASS_ICON_TCOORDS[classFile]
        iconTexture:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
        iconTexture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        iconTexture:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        iconTexture:SetTexCoord(0, 1, 0, 1)
    end

    if factionGroup == "Alliance" then
        factionBadge:SetTexture("Interface\\FriendsFrame\\PlusManz-Alliance")
        factionBadge:Show()
    elseif factionGroup == "Horde" then
        factionBadge:SetTexture("Interface\\FriendsFrame\\PlusManz-Horde")
        factionBadge:Show()
    else
        factionBadge:Hide()
    end
end

local function ApplyAndShowAlert(alertData, playAudio)
    if InCombatLockdown() then
        pendingAlert = alertData
        return
    end

    local exactName = alertData.exactName
    local displayName = alertData.displayName
    local guildName = alertData.guildName
    local guildRank = alertData.guildRank
    local classFile = alertData.classFile
    local factionGroup = alertData.factionGroup

    -- Secure Macro Attribut aktualisieren (Sowohl für "type1" als auch generisch "type", damit Down- und Up-Klicks in WoW 12.x/Forever unabhängig von ActionButtonUseKeyDown sofort feuern)
    local firstName = exactName:match("^([^%s%-]+)") or exactName
    local macroCmd = "/target " .. exactName
    if firstName ~= exactName then
        macroCmd = "/target " .. exactName .. "\n/target " .. firstName
    end
    alertFrame:SetAttribute("type", "macro")
    alertFrame:SetAttribute("type1", "macro")
    alertFrame:SetAttribute("macrotext", macroCmd)
    alertFrame:SetAttribute("macrotext1", macroCmd)
    alertFrame:SetAttribute("type2", "")

    -- Text & Farben aktualisieren
    local colorHex = GetClassColorHex(classFile)
    local coloredPlayerName = "|c" .. colorHex .. displayName .. "|r"

    playerText:SetText(coloredPlayerName)
    guildText:SetText("|cff40ff40<" .. guildName .. ">|r")

    alertFrame.currentDisplayName = coloredPlayerName
    alertFrame.currentGuildName = guildName
    alertFrame.currentGuildRank = guildRank

    SetUnitVisuals(classFile, factionGroup)

    alertFrame:Show()
    TriggerGlowAnimation()

    if playAudio and (not GuildScannerDB or GuildScannerDB.soundEnabled ~= false) then
        local soundID = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
        PlaySound(soundID, "Master")
    end
end

local function TriggerAlert(exactName, displayName, guildName, guildRank, classFile, factionGroup)
    local colorHex = GetClassColorHex(classFile)
    local coloredName = "|c" .. colorHex .. displayName .. "|r"
    local soundID = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959

    local alertData = {
        exactName = exactName,
        displayName = displayName,
        guildName = guildName,
        guildRank = guildRank,
        classFile = classFile,
        factionGroup = factionGroup,
    }

    if InCombatLockdown() then
        pendingAlert = alertData
        if not GuildScannerDB or GuildScannerDB.soundEnabled ~= false then
            PlaySound(soundID, "Master")
        end
        PrintMsg(string.format(
            "|cffff3333WARNUNG (Im Kampf):|r %s von |cff40ff40<%s>|r in der Nähe! (Popup folgt sofort nach Kampfende)",
            coloredName,
            guildName
        ))
    else
        PrintMsg(string.format(
            "Spieler erkannt: %s von |cff40ff40<%s>|r! Klicke auf das Popup zum Anvisieren.",
            coloredName,
            guildName
        ))
        ApplyAndShowAlert(alertData, true)
    end
end

local function RunTestAlert()
    local playerName = UnitName("player") or "Spieler"
    local shortName = Ambiguate(playerName, "none")
    local guildName, guildRank = GetGuildInfo("player")
    if not guildName or guildName == "" then
        guildName = "Testgilde Forever"
        guildRank = "Gildenmeister"
    end
    local _, classFile = UnitClass("player")
    local factionGroup = UnitFactionGroup("player")

    PrintMsg("Starte Test-Alarm für |cffffd100" .. shortName .. "|r...")
    TriggerAlert(shortName, shortName, guildName, guildRank, classFile, factionGroup)
end

-- ============================================================================
-- Datenbank-Initialisierung & Positionierung
-- ============================================================================
local function RestoreFramePosition()
    if InCombatLockdown() then return end
    alertFrame:ClearAllPoints()
    local point = (GuildScannerDB and GuildScannerDB.point) or DEFAULT_DB.point
    local relPoint = (GuildScannerDB and GuildScannerDB.relativePoint) or DEFAULT_DB.relativePoint
    local xOfs = (GuildScannerDB and GuildScannerDB.xOfs) or DEFAULT_DB.xOfs
    local yOfs = (GuildScannerDB and GuildScannerDB.yOfs) or DEFAULT_DB.yOfs
    alertFrame:SetPoint(point, UIParent, relPoint, xOfs, yOfs)
end

local function ResetAlertFramePosition()
    if InCombatLockdown() then
        PrintMsg("|cffff5555Position kann während des Kampfes nicht zurückgesetzt werden.|r")
        return
    end
    if GuildScannerDB then
        GuildScannerDB.point = DEFAULT_DB.point
        GuildScannerDB.relativePoint = DEFAULT_DB.relativePoint
        GuildScannerDB.xOfs = DEFAULT_DB.xOfs
        GuildScannerDB.yOfs = DEFAULT_DB.yOfs
    end
    RestoreFramePosition()
    PrintMsg("Popup-Position wurde auf die Bildschirmmitte zurückgesetzt.")
end

local function InitializeDatabase()
    if type(GuildScannerDB) ~= "table" then
        GuildScannerDB = {}
    end
    if type(GuildScannerDB.watchlist) ~= "table" then
        GuildScannerDB.watchlist = {}
    end
    if not GuildScannerDB.point then
        GuildScannerDB.point = DEFAULT_DB.point
        GuildScannerDB.relativePoint = DEFAULT_DB.relativePoint
        GuildScannerDB.xOfs = DEFAULT_DB.xOfs
        GuildScannerDB.yOfs = DEFAULT_DB.yOfs
    end
    if type(GuildScannerDB.minimapAngle) ~= "number" then
        GuildScannerDB.minimapAngle = DEFAULT_DB.minimapAngle
    end
    if GuildScannerDB.hideMinimapButton == nil then
        GuildScannerDB.hideMinimapButton = DEFAULT_DB.hideMinimapButton
    end
    if GuildScannerDB.soundEnabled == nil then
        GuildScannerDB.soundEnabled = DEFAULT_DB.soundEnabled
    end
    RestoreFramePosition()
end

-- ============================================================================
-- Einstellungsfenster (GUI)
-- ============================================================================
local configFrame = CreateFrame("Frame", "GuildScannerConfigFrame", UIParent, "BackdropTemplate")
configFrame:SetSize(380, 440)
configFrame:SetPoint("CENTER")
configFrame:SetFrameStrata("DIALOG")
configFrame:SetClampedToScreen(true)
configFrame:SetMovable(true)
configFrame:EnableMouse(true)
configFrame:RegisterForDrag("LeftButton")
configFrame:Hide()

-- Mit ESC schließen erlauben
tinsert(UISpecialFrames, "GuildScannerConfigFrame")

configFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
configFrame:SetBackdropColor(0.06, 0.06, 0.08, 0.96)

configFrame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
configFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

-- Titelzeile
local configTitle = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
configTitle:SetPoint("TOP", configFrame, "TOP", 0, -16)
configTitle:SetText("|cff00ccffGuildScanner|r – Einstellungen")

local configSubtitle = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
configSubtitle:SetPoint("TOP", configTitle, "BOTTOM", 0, -4)
configSubtitle:SetText("Überwachte Gilden verwalten & Alarme anpassen")

-- Schließen-Button oben rechts
local configCloseBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
configCloseBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -5, -5)

-- Eingabefeld für neue Gilde
local inputLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
inputLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 20, -56)
inputLabel:SetText("Gilde hinzufügen:")

local guildEditBox = CreateFrame("EditBox", "GuildScannerGuildEditBox", configFrame, "InputBoxTemplate")
guildEditBox:SetSize(225, 24)
guildEditBox:SetPoint("TOPLEFT", inputLabel, "BOTTOMLEFT", 5, -6)
guildEditBox:SetAutoFocus(false)
guildEditBox:SetMaxLetters(64)

local addGuildBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
addGuildBtn:SetSize(105, 24)
addGuildBtn:SetPoint("LEFT", guildEditBox, "RIGHT", 8, 0)
addGuildBtn:SetText("Hinzufügen")

local function SubmitGuildInput()
    local text = Trim(guildEditBox:GetText())
    if text ~= "" then
        AddGuildToWatchlist(text)
        guildEditBox:SetText("")
        guildEditBox:ClearFocus()
    end
end

addGuildBtn:SetScript("OnClick", SubmitGuildInput)
guildEditBox:SetScript("OnEnterPressed", SubmitGuildInput)
guildEditBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

-- Button: Gilde des aktuellen Ziels übernehmen
local addTargetGuildBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
addTargetGuildBtn:SetSize(340, 22)
addTargetGuildBtn:SetPoint("TOPLEFT", guildEditBox, "BOTTOMLEFT", -5, -6)
addTargetGuildBtn:SetText("Gilde des aktuellen Ziels (Target) hinzufügen")
addTargetGuildBtn:SetScript("OnClick", function()
    if UnitIsForbidden and UnitIsForbidden("target") then
        PrintMsg("|cffff5555Ziel ist durch Client-Restriktionen geschützt.|r")
        return
    end
    if not UnitExists("target") or not UnitIsPlayer("target") then
        PrintMsg("|cffff5555Bitte visiere zuerst einen Spieler an.|r")
        return
    end
    local gName = GetGuildInfo("target")
    if not gName or gName == "" then
        PrintMsg("|cffff5555Das aktuelle Ziel ist in keiner Gilde.|r")
        return
    end
    AddGuildToWatchlist(gName)
end)

-- Liste der überwachten Gilden (Container + ScrollFrame)
local listHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
listHeader:SetPoint("TOPLEFT", addTargetGuildBtn, "BOTTOMLEFT", 0, -12)
listHeader:SetText("Überwachte Gilden (Watchlist):")

local listBg = CreateFrame("Frame", nil, configFrame, "BackdropTemplate")
listBg:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -6)
listBg:SetSize(340, 185)
listBg:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
listBg:SetBackdropColor(0.02, 0.02, 0.03, 0.85)
listBg:SetBackdropBorderColor(0.4, 0.4, 0.45, 0.9)

local scrollFrame = CreateFrame("ScrollFrame", "GuildScannerWatchlistScrollFrame", listBg, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", listBg, "TOPLEFT", 6, -6)
scrollFrame:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -26, 6)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(300, 1)
scrollFrame:SetScrollChild(scrollChild)

local emptyListText = listBg:CreateFontString(nil, "OVERLAY", "GameFontDisable")
emptyListText:SetPoint("CENTER", listBg, "CENTER", -8, 0)
emptyListText:SetText("Keine Gilden auf der Watchlist.\nGib oben einen Gildennamen ein.")

local rowFrames = {}

RefreshWatchlistUI = function()
    if not GuildScannerDB or not GuildScannerDB.watchlist then return end

    -- Sortierte Liste der Gilden erstellen
    local sorted = {}
    for key, originalName in pairs(GuildScannerDB.watchlist) do
        table.insert(sorted, { key = key, name = originalName })
    end
    table.sort(sorted, function(a, b)
        return a.key < b.key
    end)

    for _, row in ipairs(rowFrames) do
        row:Hide()
    end

    if #sorted == 0 then
        emptyListText:Show()
        scrollChild:SetHeight(1)
        return
    end

    emptyListText:Hide()
    local rowHeight = 26

    for i, entry in ipairs(sorted) do
        local row = rowFrames[i]
        if not row then
            row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
            row:SetSize(304, rowHeight - 2)
            row:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            })
            row:SetBackdropColor(0.15, 0.15, 0.2, 0.45)

            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.nameText:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -72, 0)
            row.nameText:SetJustifyH("LEFT")
            row.nameText:SetWordWrap(false)

            row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.removeBtn:SetSize(62, 20)
            row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.removeBtn:SetText("Löschen")

            rowFrames[i] = row
        end

        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -((i - 1) * rowHeight))
        row.nameText:SetText("|cff40ff40<" .. entry.name .. ">|r")
        row.removeBtn:SetScript("OnClick", function()
            RemoveGuildFromWatchlist(entry.key)
        end)
        row:Show()
    end

    scrollChild:SetHeight(#sorted * rowHeight)
end

-- Sound-Checkbox
local soundCheckbox = CreateFrame("CheckButton", "GuildScannerSoundCheck", configFrame, "UICheckButtonTemplate")
soundCheckbox:SetSize(24, 24)
soundCheckbox:SetPoint("TOPLEFT", listBg, "BOTTOMLEFT", 0, -10)
local soundLabel = soundCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
soundLabel:SetPoint("LEFT", soundCheckbox, "RIGHT", 4, 0)
soundLabel:SetText("Warnsound bei Gilden-Erkennung abspielen")

soundCheckbox:SetScript("OnClick", function(self)
    if GuildScannerDB then
        GuildScannerDB.soundEnabled = self:GetChecked() and true or false
    end
end)

-- Aktions-Buttons unten (Test-Alarm & Position zurücksetzen)
local testBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
testBtn:SetSize(164, 26)
testBtn:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", 20, 16)
testBtn:SetText("Test-Alarm auslösen")
testBtn:SetScript("OnClick", function()
    RunTestAlert()
end)

local resetPosBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
resetPosBtn:SetSize(164, 26)
resetPosBtn:SetPoint("BOTTOMRIGHT", configFrame, "BOTTOMRIGHT", -20, 16)
resetPosBtn:SetText("Popup-Position Reset")
resetPosBtn:SetScript("OnClick", function()
    ResetAlertFramePosition()
end)

ToggleConfigFrame = function()
    InitializeDatabase()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        soundCheckbox:SetChecked(GuildScannerDB.soundEnabled ~= false)
        RefreshWatchlistUI()
        configFrame:Show()
    end
end

-- ============================================================================
-- Minimap-Button (Rundes Icon an der Minimap, frei drehbar per Drag & Drop)
-- ============================================================================
local minimapButton = CreateFrame("Button", "GuildScannerMinimapButton", Minimap)
minimapButton:SetSize(32, 32)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:RegisterForDrag("LeftButton")

local mmIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
mmIcon:SetSize(20, 20)
mmIcon:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)
mmIcon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")

local mmBorder = minimapButton:CreateTexture(nil, "OVERLAY")
mmBorder:SetSize(54, 54)
mmBorder:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

UpdateMinimapButtonPosition = function()
    local angle = math.rad((GuildScannerDB and GuildScannerDB.minimapAngle) or 225)
    local radius = (Minimap:GetWidth() / 2) + 5
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        if angle < 0 then
            angle = angle + 360
        end
        if GuildScannerDB then
            GuildScannerDB.minimapAngle = angle
        end
        UpdateMinimapButtonPosition()
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

minimapButton:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        ToggleConfigFrame()
    elseif button == "RightButton" then
        RunTestAlert()
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("GuildScanner", 0.0, 0.8, 1.0)
    GameTooltip:AddLine("Linksklick: Einstellungen öffnen", 1, 1, 1)
    GameTooltip:AddLine("Rechtsklick: Test-Alarm auslösen", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Ziehen: Icon um die Minimap bewegen", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ============================================================================
-- Integration in Blizzards ESC -> Optionen -> AddOns Menü
-- ============================================================================
local function RegisterBlizzardOptionsPanel()
    local panel = CreateFrame("Frame", "GuildScannerOptionsPanel", UIParent)
    panel.name = "GuildScanner"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cff00ccffGuildScanner|r (WoW Forever)")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("Warnt mit einem anklickbaren Auto-Target-Popup, sobald Spieler überwachter Gilden in der Nähe sind.")

    local openGuiBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openGuiBtn:SetSize(220, 28)
    openGuiBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -18)
    openGuiBtn:SetText("Einstellungsfenster öffnen")
    openGuiBtn:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then
            HideUIPanel(SettingsPanel)
        elseif InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
            InterfaceOptionsFrame:Hide()
        end
        ToggleConfigFrame()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

-- ============================================================================
-- Erkennungs-Engine (Ohne Combat Log!)
-- ============================================================================
local function IsPlayerOnCooldown(shortName)
    local now = GetTime()
    local lastSeen = recentDetections[shortName]
    if lastSeen and (now - lastSeen) < COOLDOWN_SECONDS then
        return true
    end
    recentDetections[shortName] = now
    return false
end

local function CheckUnit(unit, allowSelfForTest)
    if not unit then return end

    -- 1. Midnight-Restriktionen prüfen: Verbotene Units sofort überspringen
    if UnitIsForbidden and UnitIsForbidden(unit) then
        return
    end

    -- 2. Existenz- und Spieler-Prüfung
    if not UnitExists(unit) or not UnitIsPlayer(unit) then
        return
    end

    -- 3. Eigenen Charakter im Normalbetrieb ausschließen
    if not allowSelfForTest and UnitIsUnit(unit, "player") then
        return
    end

    -- 4. Gildeninformationen auslesen
    local guildName, guildRankName = GetGuildInfo(unit)
    if not guildName or guildName == "" then
        return
    end

    -- 5. Case-Insensitive Abgleich mit der Watchlist
    local guildKey = string.lower(guildName)
    local watchedGuild = GuildScannerDB and GuildScannerDB.watchlist and GuildScannerDB.watchlist[guildKey]
    if not watchedGuild then
        return
    end

    -- 6. Namen & Anti-Spam Cooldown prüfen (Ambiguate)
    local fullName = GetFullPlayerName(unit)
    if not fullName then
        return
    end

    local shortName = Ambiguate(fullName, "none")
    if not allowSelfForTest and IsPlayerOnCooldown(shortName) then
        return
    end

    -- 7. Klassen- & Fraktionsdaten für das Popup ermitteln
    local _, classFile = UnitClass(unit)
    local factionGroup = UnitFactionGroup(unit)

    TriggerAlert(shortName, shortName, guildName, guildRankName, classFile, factionGroup)
end

-- ============================================================================
-- Event-Handler
-- ============================================================================
GuildScanner:RegisterEvent("ADDON_LOADED")
GuildScanner:RegisterEvent("NAME_PLATE_UNIT_ADDED")
GuildScanner:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
GuildScanner:RegisterEvent("PLAYER_TARGET_CHANGED")
GuildScanner:RegisterEvent("UNIT_TARGET")
GuildScanner:RegisterEvent("PLAYER_REGEN_ENABLED")

GuildScanner:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitializeDatabase()
            UpdateMinimapButtonPosition()
            if GuildScannerDB.hideMinimapButton then
                minimapButton:Hide()
            else
                minimapButton:Show()
            end
            RegisterBlizzardOptionsPanel()
            PrintMsg("Geladen (v1.1.2). Klicke auf das |cffffd100Minimap-Icon|r oder tippe |cffffd100/gscan|r.")
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        CheckUnit(arg1, false)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CheckUnit("mouseover", false)
    elseif event == "PLAYER_TARGET_CHANGED" then
        CheckUnit("target", false)
    elseif event == "UNIT_TARGET" then
        if arg1 and arg1 ~= "player" then
            CheckUnit(arg1 .. "target", false)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingAlert then
            local alertData = pendingAlert
            pendingAlert = nil
            ApplyAndShowAlert(alertData, false)
            PrintMsg(string.format(
                "Kampf beendet – zeige aufgeschobenes Popup für %s (<%s>).",
                alertData.displayName,
                alertData.guildName
            ))
        end
    end
end)

-- ============================================================================
-- Slash-Commands (/gscan)
-- ============================================================================
local function ShowHelp()
    PrintMsg("Befehlsübersicht:")
    PrintMsg("  |cffffd100/gscan|r oder |cffffd100/gscan config|r - Öffnet das Einstellungsfenster")
    PrintMsg("  |cffffd100/gscan add <Gildenname>|r - Fügt eine Gilde zur Watchlist hinzu")
    PrintMsg("  |cffffd100/gscan remove <Gildenname>|r - Entfernt eine Gilde von der Watchlist")
    PrintMsg("  |cffffd100/gscan list|r - Zeigt alle überwachten Gilden im Chat an")
    PrintMsg("  |cffffd100/gscan test|r - Löst einen Test-Alarm mit deinem Charakter aus")
    PrintMsg("  |cffffd100/gscan minimap|r - Blendet das Minimap-Icon ein/aus")
end

SLASH_GUILDSCANNER1 = "/gscan"
SLASH_GUILDSCANNER2 = "/guildscanner"
SlashCmdList["GUILDSCANNER"] = function(msg)
    InitializeDatabase()

    local input = Trim(msg)
    local cmd, rest = input:match("^(%S+)%s*(.-)$")
    cmd = cmd and string.lower(cmd) or ""
    rest = Trim(rest)

    if cmd == "" or cmd == "config" or cmd == "options" or cmd == "gui" then
        ToggleConfigFrame()

    elseif cmd == "add" then
        if rest == "" then
            PrintMsg("|cffff5555Bitte gib einen Gildennamen an: /gscan add <Gildenname>|r")
            return
        end
        AddGuildToWatchlist(rest)

    elseif cmd == "remove" or cmd == "del" or cmd == "delete" then
        if rest == "" then
            PrintMsg("|cffff5555Bitte gib einen Gildennamen an: /gscan remove <Gildenname>|r")
            return
        end
        RemoveGuildFromWatchlist(rest)

    elseif cmd == "list" then
        local count = 0
        for _, originalName in pairs(GuildScannerDB.watchlist) do
            if count == 0 then
                PrintMsg("Überwachte Gilden auf der Watchlist:")
            end
            count = count + 1
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  |cffffd100%d.|r |cff40ff40<%s>|r", count, originalName))
        end
        if count == 0 then
            PrintMsg("Die Watchlist ist aktuell leer. Nutze |cffffd100/gscan|r zum Öffnen der Einstellungen.")
        end

    elseif cmd == "test" then
        RunTestAlert()

    elseif cmd == "minimap" then
        GuildScannerDB.hideMinimapButton = not GuildScannerDB.hideMinimapButton
        if GuildScannerDB.hideMinimapButton then
            minimapButton:Hide()
            PrintMsg("Minimap-Icon ausgeblendet.")
        else
            minimapButton:Show()
            PrintMsg("Minimap-Icon eingeblendet.")
        end

    elseif cmd == "help" or cmd == "?" then
        ShowHelp()

    else
        ShowHelp()
    end
end
