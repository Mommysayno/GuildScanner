-- ============================================================================
-- GuildScanner - World of Warcraft: Forever (Client 1.60.1 / Interface 16001)
-- ============================================================================
-- Kompatibel mit Midnight/Forever Engine-Restriktionen (Kein Combat Log,
-- UnitIsForbidden-Prüfung, SecureActionButton Combat-Lockdown-Queue).
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
}

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
alertFrame:SetAttribute("type1", "macro")
alertFrame:SetAttribute("macrotext1", "")

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

-- Drag & Drop zum Verschieben (außerhalb des Kampfes)
alertFrame:SetScript("OnDragStart", function(self)
    if InCombatLockdown() then
        PrintMsg("|cffff5555Das Popup kann im Kampf nicht verschoben werden.|r")
        return
    end
    self:StartMoving()
end)

alertFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if GuildScannerDB then
        local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
        GuildScannerDB.point = point or "CENTER"
        GuildScannerDB.relativePoint = relativePoint or "CENTER"
        GuildScannerDB.xOfs = xOfs or 0
        GuildScannerDB.yOfs = yOfs or -180
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
    GameTooltip:AddLine("Linksklick: Spieler ins Ziel nehmen (/targetexact)", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Rechtsklick / X: Schließen (außerhalb des Kampfes)", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Linksklick-Ziehen: Fenster verschieben", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)

alertFrame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ============================================================================
-- Popup-Anzeige & Combat-Lockdown-Handling
-- ============================================================================
local function SetUnitVisuals(classFile, factionGroup)
    -- Klassensymbol über CLASS_ICON_TCOORDS setzen
    if classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
        local coords = CLASS_ICON_TCOORDS[classFile]
        iconTexture:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
        iconTexture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        iconTexture:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        iconTexture:SetTexCoord(0, 1, 0, 1)
    end

    -- Fraktionssymbol setzen
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

    -- Secure Macro Attribut aktualisieren
    alertFrame:SetAttribute("type1", "macro")
    alertFrame:SetAttribute("macrotext1", "/targetexact " .. exactName)

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

    if playAudio then
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
        -- Taint-Schutz: Im Kampf keine SecureFrame-Attribute ändern oder :Show() aufrufen
        pendingAlert = alertData
        PlaySound(soundID, "Master")
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
    RestoreFramePosition()
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
            PrintMsg("Geladen (WoW Forever 1.60.1). Tippe |cffffd100/gscan|r für Befehle.")
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- Haupt-Scanner: Prüft die unitToken jeder neu eingeblendeten Namensplakette
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
        -- Sobald der Kampf endet: Aufgeschobenen Alarm sofort anzeigen
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
    PrintMsg("  |cffffd100/gscan add <Gildenname>|r - Fügt eine Gilde zur Watchlist hinzu")
    PrintMsg("  |cffffd100/gscan remove <Gildenname>|r - Entfernt eine Gilde von der Watchlist")
    PrintMsg("  |cffffd100/gscan list|r - Zeigt alle überwachten Gilden an")
    PrintMsg("  |cffffd100/gscan test|r - Löst einen Test-Alarm mit deinem Charakter aus")
end

SLASH_GUILDSCANNER1 = "/gscan"
SlashCmdList["GUILDSCANNER"] = function(msg)
    InitializeDatabase()

    local input = Trim(msg)
    local cmd, rest = input:match("^(%S+)%s*(.-)$")
    cmd = cmd and string.lower(cmd) or ""
    rest = Trim(rest)

    if cmd == "add" then
        if rest == "" then
            PrintMsg("|cffff5555Bitte gib einen Gildennamen an: /gscan add <Gildenname>|r")
            return
        end
        local key = string.lower(rest)
        GuildScannerDB.watchlist[key] = rest
        PrintMsg(string.format("Gilde |cff40ff40<%s>|r wurde zur Watchlist hinzugefügt.", rest))

    elseif cmd == "remove" or cmd == "del" or cmd == "delete" then
        if rest == "" then
            PrintMsg("|cffff5555Bitte gib einen Gildennamen an: /gscan remove <Gildenname>|r")
            return
        end
        local key = string.lower(rest)
        local existing = GuildScannerDB.watchlist[key]
        if existing then
            GuildScannerDB.watchlist[key] = nil
            PrintMsg(string.format("Gilde |cffff5555<%s>|r wurde von der Watchlist entfernt.", existing))
        else
            PrintMsg(string.format("Gilde |cffff5555<%s>|r befindet sich nicht auf der Watchlist.", rest))
        end

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
            PrintMsg("Die Watchlist ist aktuell leer. Nutze |cffffd100/gscan add <Gildenname>|r.")
        end

    elseif cmd == "test" then
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

    else
        ShowHelp()
    end
end
