-- ============================================================================
-- GuildScanner - World of Warcraft: Forever (Client 1.60.1 / Interface 16001)
-- ============================================================================
-- Kompatibel mit Midnight/Forever Engine-Restriktionen (Kein Combat Log,
-- UnitIsForbidden/SecretValue-Prüfung, SecureActionButton Combat-Lockdown-Queue).
-- Inklusive Einstellungs-GUI, Minimap-Button & synchronisiertem Gilden-Leaderboard.
-- ============================================================================

local ADDON_NAME = ...
local GuildScanner = CreateFrame("Frame", "GuildScannerEventFrame")

-- ============================================================================
-- Konstanten & Lokale Variablen
-- ============================================================================
local COOLDOWN_SECONDS = 60
local KILL_DEDUP_SECONDS = 45
local COMM_PREFIX = "GScanLB"

local recentDetections = {} -- [playerName] = timestamp (GetTime)
local recentKills = {}      -- [victimName] = timestamp (GetTime)
local trackedUnits = {}     -- [unitToken] = { name, guildName, guildKey, classFile, wasAlive }
local lastDamagedTarget = nil -- { name, guildName, guildKey, time }
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
    leaderboardEnabled = true,
    broadcastKillsRealtime = true,
    leaderboard = {
        players = {}, -- [killerName] = { kills = 0, classFile = "WARRIOR", byGuild = { [guildKey] = count }, updated = 0 }
        guilds = {},  -- [guildKey] = { name = "Original Name", kills = 0 }
    },
}

-- Vorwärtsdeklarationen für UI-Updates
local RefreshWatchlistUI
local RefreshLeaderboardUI
local ToggleConfigFrame
local ToggleLeaderboardFrame
local UpdateMinimapButtonPosition
local RequestGuildLeaderboardSync
local BroadcastGuildLeaderboardState

-- ============================================================================
-- Hilfsfunktionen & Secret-Value-Schutz (WoW 12.x / Forever)
-- ============================================================================
local function PrintMsg(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

local function Trim(str)
    if not str then return "" end
    return str:match("^%s*(.-)%s*$") or ""
end

local function IsSecret(val)
    if issecretvalue and issecretvalue(val) then
        return true
    end
    return false
end

local function SafeIsTrue(val)
    if IsSecret(val) then
        return false
    end
    return val and true or false
end

local function SafeString(val)
    if val == nil or IsSecret(val) then
        return nil
    end
    if type(val) ~= "string" or val == "" then
        return nil
    end
    return val
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
    name = SafeString(name)
    if not name or name == UNKNOWNOBJECT then
        return nil
    end
    realm = SafeString(realm)
    if realm then
        return name .. "-" .. realm
    end
    return name
end

local function GetLocalPlayerShortName()
    local fullName = GetFullPlayerName("player")
    if not fullName then return "Spieler" end
    return SafeString(Ambiguate(fullName, "none")) or fullName
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
    if RefreshLeaderboardUI then
        RefreshLeaderboardUI()
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
        if RefreshLeaderboardUI then
            RefreshLeaderboardUI()
        end
        return true
    else
        PrintMsg(string.format("Gilde |cffff5555<%s>|r befindet sich nicht auf der Watchlist.", guildNameOrKey))
        return false
    end
end

-- ============================================================================
-- Leaderboard-Datenbank & Gilden-Synchronisation (C_ChatInfo Addon-Channel)
-- ============================================================================
local function EnsureLeaderboardTables()
    if not GuildScannerDB then return end
    if type(GuildScannerDB.leaderboard) ~= "table" then
        GuildScannerDB.leaderboard = { players = {}, guilds = {} }
    end
    if type(GuildScannerDB.leaderboard.players) ~= "table" then
        GuildScannerDB.leaderboard.players = {}
    end
    if type(GuildScannerDB.leaderboard.guilds) ~= "table" then
        GuildScannerDB.leaderboard.guilds = {}
    end
end

local function RebuildGuildTotalsFromPlayers()
    EnsureLeaderboardTables()
    local lb = GuildScannerDB.leaderboard
    local computedGuilds = {}

    for _, pData in pairs(lb.players) do
        if type(pData.byGuild) == "table" then
            local sum = 0
            for gKey, count in pairs(pData.byGuild) do
                if type(count) == "number" and count > 0 then
                    sum = sum + count
                    computedGuilds[gKey] = (computedGuilds[gKey] or 0) + count
                end
            end
            if sum > (pData.kills or 0) then
                pData.kills = sum
            end
        end
    end

    for gKey, totalCount in pairs(computedGuilds) do
        local displayName = (GuildScannerDB.watchlist and GuildScannerDB.watchlist[gKey])
            or (lb.guilds[gKey] and lb.guilds[gKey].name)
            or gKey
        lb.guilds[gKey] = {
            name = displayName,
            kills = totalCount,
        }
    end
end

local function SendGuildAddonMessage(payload)
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then return end
    if not IsInGuild or not IsInGuild() then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        pcall(C_ChatInfo.SendAddonMessage, COMM_PREFIX, payload, "GUILD")
    elseif SendAddonMessage then
        pcall(SendAddonMessage, COMM_PREFIX, payload, "GUILD")
    end
end

-- Registriert einen neuen Kill (lokal oder empfangen) und synchronisiert ihn
local function RecordWatchedGuildKill(killerName, killerClass, victimName, victimGuildName, isRemote)
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then return end
    EnsureLeaderboardTables()

    killerName = SafeString(killerName)
    victimGuildName = SafeString(victimGuildName)
    if not killerName or not victimGuildName then return end

    killerName = SafeString(Ambiguate(killerName, "none")) or killerName
    local guildKey = string.lower(Trim(victimGuildName))
    if guildKey == "" then return end

    local lb = GuildScannerDB.leaderboard
    local pEntry = lb.players[killerName]
    if not pEntry then
        pEntry = {
            kills = 0,
            classFile = SafeString(killerClass) or "WARRIOR",
            byGuild = {},
            updated = GetServerTime and GetServerTime() or time(),
        }
        lb.players[killerName] = pEntry
    end

    if SafeString(killerClass) then
        pEntry.classFile = killerClass
    end
    if type(pEntry.byGuild) ~= "table" then
        pEntry.byGuild = {}
    end

    pEntry.kills = (pEntry.kills or 0) + 1
    pEntry.byGuild[guildKey] = (pEntry.byGuild[guildKey] or 0) + 1
    pEntry.updated = GetServerTime and GetServerTime() or time()

    local origGuildName = (GuildScannerDB.watchlist and GuildScannerDB.watchlist[guildKey]) or victimGuildName
    if not lb.guilds[guildKey] then
        lb.guilds[guildKey] = { name = origGuildName, kills = 0 }
    else
        lb.guilds[guildKey].name = origGuildName
    end

    RebuildGuildTotalsFromPlayers()

    if not isRemote then
        local colorHex = GetClassColorHex(pEntry.classFile)
        PrintMsg(string.format(
            "|cffffd100[Leaderboard]|r Kill gezählt! |c%s%s|r hat |cffff5555%s|r (|cff40ff40<%s>|r) besiegt! (Gesamt: %d)",
            colorHex,
            killerName,
            victimName or "Gegner",
            origGuildName,
            pEntry.kills
        ))
        -- Sofort an alle Gildenmitglieder senden (sofern Echtzeit-Broadcast aktiviert ist):
        -- KILL|killer|class|guildName|newGuildCount|victimName
        if GuildScannerDB.broadcastKillsRealtime ~= false then
            local newGuildCount = pEntry.byGuild[guildKey] or 1
            local msg = string.format(
                "KILL|%s|%s|%s|%d|%s",
                killerName,
                pEntry.classFile or "WARRIOR",
                origGuildName,
                newGuildCount,
                victimName or "Unbekannt"
            )
            SendGuildAddonMessage(msg)
        end
    end

    if RefreshLeaderboardUI then
        RefreshLeaderboardUI()
    end
end

-- Merge-Funktion für empfangene Synchronisationsdaten (nimmt jeweils das Maximum pro Spieler & Gilde)
local function MergeSyncedPlayerGuildCount(killerName, killerClass, guildNameRaw, countNum)
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then return end
    EnsureLeaderboardTables()

    killerName = SafeString(killerName)
    guildNameRaw = SafeString(guildNameRaw)
    countNum = tonumber(countNum)
    if not killerName or not guildNameRaw or not countNum or countNum <= 0 then return end

    killerName = SafeString(Ambiguate(killerName, "none")) or killerName
    local guildKey = string.lower(Trim(guildNameRaw))
    if guildKey == "" then return end

    local lb = GuildScannerDB.leaderboard
    local pEntry = lb.players[killerName]
    if not pEntry then
        pEntry = {
            kills = 0,
            classFile = SafeString(killerClass) or "WARRIOR",
            byGuild = {},
            updated = GetServerTime and GetServerTime() or time(),
        }
        lb.players[killerName] = pEntry
    end

    if SafeString(killerClass) and killerClass ~= "UNKNOWN" then
        pEntry.classFile = killerClass
    end
    if type(pEntry.byGuild) ~= "table" then
        pEntry.byGuild = {}
    end

    local currentCount = pEntry.byGuild[guildKey] or 0
    if countNum > currentCount then
        pEntry.byGuild[guildKey] = countNum
    end

    if not lb.guilds[guildKey] then
        lb.guilds[guildKey] = {
            name = (GuildScannerDB.watchlist and GuildScannerDB.watchlist[guildKey]) or guildNameRaw,
            kills = 0,
        }
    end

    -- Gesamtkills des Spielers neu summieren
    local totalPlayerKills = 0
    for _, c in pairs(pEntry.byGuild) do
        totalPlayerKills = totalPlayerKills + (tonumber(c) or 0)
    end
    if totalPlayerKills > (pEntry.kills or 0) then
        pEntry.kills = totalPlayerKills
    end

    RebuildGuildTotalsFromPlayers()
    if RefreshLeaderboardUI then
        RefreshLeaderboardUI()
    end
end

BroadcastGuildLeaderboardState = function()
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then return end
    if not IsInGuild or not IsInGuild() then return end
    EnsureLeaderboardTables()

    local lb = GuildScannerDB.leaderboard
    for killerName, pData in pairs(lb.players) do
        local classFile = pData.classFile or "WARRIOR"
        if type(pData.byGuild) == "table" then
            for gKey, count in pairs(pData.byGuild) do
                if type(count) == "number" and count > 0 then
                    local gName = (lb.guilds[gKey] and lb.guilds[gKey].name)
                        or (GuildScannerDB.watchlist and GuildScannerDB.watchlist[gKey])
                        or gKey
                    local payload = string.format("STATE|%s|%s|%s|%d", killerName, classFile, gName, count)
                    SendGuildAddonMessage(payload)
                end
            end
        end
    end
end

local lastSyncRequestTime = 0
RequestGuildLeaderboardSync = function(manual)
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then
        if manual then
            PrintMsg("|cffff5555Das Leaderboard ist aktuell in den Einstellungen deaktiviert.|r")
        end
        return
    end
    if not IsInGuild or not IsInGuild() then
        if manual then
            PrintMsg("|cffff5555Du musst in einer Gilde sein, um das Leaderboard zu synchronisieren.|r")
        end
        return
    end
    local now = GetTime()
    if not manual and (now - lastSyncRequestTime) < 15 then
        return
    end
    lastSyncRequestTime = now
    SendGuildAddonMessage("REQSYNC")
    BroadcastGuildLeaderboardState()
    if manual then
        PrintMsg("Synchronisiere Leaderboard mit allen Gildenmitgliedern...")
    end
end

local function HandleAddonMessage(prefix, message, channel, sender)
    if prefix ~= COMM_PREFIX or channel ~= "GUILD" then return end
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then return end
    if IsSecret(message) or IsSecret(sender) then return end

    local senderShort = SafeString(Ambiguate(sender or "", "none")) or sender
    local myShort = GetLocalPlayerShortName()

    if message == "REQSYNC" then
        if senderShort ~= myShort then
            -- Zufällige kleine Verzögerung (0.5 - 2.5s), um Channel-Throttle zu vermeiden
            local delay = 0.5 + (math.random() * 2.0)
            C_Timer.After(delay, function()
                BroadcastGuildLeaderboardState()
            end)
        end
        return
    end

    local cmd, a1, a2, a3, a4 = strsplit("|", message)
    if cmd == "KILL" or cmd == "STATE" then
        -- Format: CMD|killerName|classFile|guildName|guildKillCount|victimName
        if a1 and a2 and a3 and a4 then
            MergeSyncedPlayerGuildCount(a1, a2, a3, tonumber(a4))
        end
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
-- (Wird erst bei tatsächlicher Anzeige außerhalb des Kampfes gesetzt, nicht beim Dateiladen)

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

-- Drag & Drop zum Verschieben (Nur mit gehaltener Shift-Taste, damit normale Klicks nicht verschluckt werden!)
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

    -- Secure Macro Attribut aktualisieren
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
    local playerName = GetLocalPlayerShortName()
    local guildName, guildRank = GetGuildInfo("player")
    guildName = SafeString(guildName) or "Testgilde Forever"
    guildRank = SafeString(guildRank) or "Gildenmeister"
    local _, rawClass = UnitClass("player")
    local classFile = SafeString(rawClass)
    local factionGroup = SafeString(UnitFactionGroup("player"))

    PrintMsg("Starte Test-Alarm für |cffffd100" .. playerName .. "|r...")
    TriggerAlert(playerName, playerName, guildName, guildRank, classFile, factionGroup)
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
    if GuildScannerDB.leaderboardEnabled == nil then
        GuildScannerDB.leaderboardEnabled = DEFAULT_DB.leaderboardEnabled
    end
    if GuildScannerDB.broadcastKillsRealtime == nil then
        GuildScannerDB.broadcastKillsRealtime = DEFAULT_DB.broadcastKillsRealtime
    end
    EnsureLeaderboardTables()
    RebuildGuildTotalsFromPlayers()
    RestoreFramePosition()
end

-- ============================================================================
-- Einstellungsfenster (GUI)
-- ============================================================================
-- WICHTIG: Nicht in UISpecialFrames eintragen! In WoW 12.x/Forever führt das
-- Einfügen von unsicheren Addon-Frames in UISpecialFrames zu globalem Array-Taint
-- in CloseSpecialWindows(), wodurch SecureActionButtons anderer Addons
-- (wie Disenchant Buddy, Auctionator etc.) mit ADDON_ACTION_BLOCKED versagen.
local configFrame = CreateFrame("Frame", "GuildScannerConfigFrame", UIParent, "BackdropTemplate")
configFrame:SetSize(380, 520)
configFrame:SetPoint("CENTER")
configFrame:SetFrameStrata("DIALOG")
configFrame:SetClampedToScreen(true)
configFrame:SetMovable(true)
configFrame:EnableMouse(true)
configFrame:RegisterForDrag("LeftButton")
configFrame:Hide()

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
configSubtitle:SetText("Überwachte Gilden verwalten & Gilden-Leaderboard")

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
    if UnitIsForbidden and SafeIsTrue(UnitIsForbidden("target")) then
        PrintMsg("|cffff5555Ziel ist durch Client-Restriktionen geschützt.|r")
        return
    end
    if not SafeIsTrue(UnitExists("target")) or not SafeIsTrue(UnitIsPlayer("target")) then
        PrintMsg("|cffff5555Bitte visiere zuerst einen Spieler an.|r")
        return
    end
    local gName = SafeString(GetGuildInfo("target"))
    if not gName then
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
listBg:SetSize(340, 175)
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
soundCheckbox:SetPoint("TOPLEFT", listBg, "BOTTOMLEFT", 0, -8)
local soundLabel = soundCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
soundLabel:SetPoint("LEFT", soundCheckbox, "RIGHT", 4, 0)
soundLabel:SetText("Warnsound bei Gilden-Erkennung abspielen")

soundCheckbox:SetScript("OnClick", function(self)
    if GuildScannerDB then
        GuildScannerDB.soundEnabled = self:GetChecked() and true or false
    end
end)

-- Leaderboard-Checkbox (Optional an-/abwählbar)
local lbCheckbox = CreateFrame("CheckButton", "GuildScannerLeaderboardCheck", configFrame, "UICheckButtonTemplate")
lbCheckbox:SetSize(24, 24)
lbCheckbox:SetPoint("TOPLEFT", soundCheckbox, "BOTTOMLEFT", 0, -2)
local lbLabel = lbCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lbLabel:SetPoint("LEFT", lbCheckbox, "RIGHT", 4, 0)
lbLabel:SetText("Gilden-Kill-Leaderboard aktivieren & synchronisieren")

-- Echtzeit-Broadcast-Checkbox (Eigener Haken für Echtzeit-Übertragung neuer Kills)
local broadcastCheckbox = CreateFrame("CheckButton", "GuildScannerBroadcastKillsCheck", configFrame, "UICheckButtonTemplate")
broadcastCheckbox:SetSize(24, 24)
broadcastCheckbox:SetPoint("TOPLEFT", lbCheckbox, "BOTTOMLEFT", 0, -2)
local broadcastLabel = broadcastCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
broadcastLabel:SetPoint("LEFT", broadcastCheckbox, "RIGHT", 4, 0)
broadcastLabel:SetText("Neue Kills in Echtzeit an Gildenmitglieder senden")

local function UpdateBroadcastCheckboxState()
    if GuildScannerDB and GuildScannerDB.leaderboardEnabled ~= false then
        broadcastCheckbox:Enable()
        broadcastLabel:SetTextColor(1.0, 0.82, 0.0)
    else
        broadcastCheckbox:Disable()
        broadcastLabel:SetTextColor(0.5, 0.5, 0.5)
    end
end

lbCheckbox:SetScript("OnClick", function(self)
    if GuildScannerDB then
        GuildScannerDB.leaderboardEnabled = self:GetChecked() and true or false
        UpdateBroadcastCheckboxState()
        if GuildScannerDB.leaderboardEnabled then
            PrintMsg("Gilden-Leaderboard |cff40ff40aktiviert|r.")
            RequestGuildLeaderboardSync(false)
        else
            PrintMsg("Gilden-Leaderboard |cffff5555deaktiviert|r.")
        end
    end
end)

broadcastCheckbox:SetScript("OnClick", function(self)
    if GuildScannerDB then
        GuildScannerDB.broadcastKillsRealtime = self:GetChecked() and true or false
        if GuildScannerDB.broadcastKillsRealtime then
            PrintMsg("Echtzeit-Übertragung neuer Kills an die Gilde |cff40ff40aktiviert|r.")
        else
            PrintMsg("Echtzeit-Übertragung neuer Kills an die Gilde |cffff5555deaktiviert|r.")
        end
    end
end)

-- Button: Leaderboard öffnen
local openLbBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
openLbBtn:SetSize(340, 26)
openLbBtn:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, 48)
openLbBtn:SetText("|cffffd100Gilden-Kill-Leaderboard öffnen|r")
openLbBtn:SetScript("OnClick", function()
    if ToggleLeaderboardFrame then
        ToggleLeaderboardFrame()
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
        lbCheckbox:SetChecked(GuildScannerDB.leaderboardEnabled ~= false)
        broadcastCheckbox:SetChecked(GuildScannerDB.broadcastKillsRealtime ~= false)
        UpdateBroadcastCheckboxState()
        RefreshWatchlistUI()
        configFrame:Show()
    end
end

-- ============================================================================
-- Gilden-Kill-Leaderboard Fenster (Ranking Pro Spieler & Pro Markierter Gilde)
-- ============================================================================
local lbFrame = CreateFrame("Frame", "GuildScannerLeaderboardFrame", UIParent, "BackdropTemplate")
lbFrame:SetSize(420, 440)
lbFrame:SetPoint("CENTER", UIParent, "CENTER", 220, 0)
lbFrame:SetFrameStrata("DIALOG")
lbFrame:SetClampedToScreen(true)
lbFrame:SetMovable(true)
lbFrame:EnableMouse(true)
lbFrame:RegisterForDrag("LeftButton")
lbFrame:Hide()

lbFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
lbFrame:SetBackdropColor(0.05, 0.05, 0.07, 0.96)

lbFrame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
lbFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

local lbTitle = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
lbTitle:SetPoint("TOP", lbFrame, "TOP", 0, -16)
lbTitle:SetText("|cffffd100GuildScanner|r – Kill-Leaderboard")

local lbSubTitle = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
lbSubTitle:SetPoint("TOP", lbTitle, "BOTTOM", 0, -4)
lbSubTitle:SetText("Synchronisiert zwischen allen Gildenmitgliedern mit GuildScanner")

local lbCloseBtn = CreateFrame("Button", nil, lbFrame, "UIPanelCloseButton")
lbCloseBtn:SetPoint("TOPRIGHT", lbFrame, "TOPRIGHT", -5, -5)

-- Tab-Auswahl: "players" (Pro Gildenmitglied) oder "guilds" (Pro Markierter Gilde)
local activeLbTab = "players"

local tabPlayersBtn = CreateFrame("Button", nil, lbFrame, "UIPanelButtonTemplate")
tabPlayersBtn:SetSize(185, 26)
tabPlayersBtn:SetPoint("TOPLEFT", lbFrame, "TOPLEFT", 20, -54)
tabPlayersBtn:SetText("Ranking: Spieler (Gilde)")

local tabGuildsBtn = CreateFrame("Button", nil, lbFrame, "UIPanelButtonTemplate")
tabGuildsBtn:SetSize(185, 26)
tabGuildsBtn:SetPoint("TOPRIGHT", lbFrame, "TOPRIGHT", -20, -54)
tabGuildsBtn:SetText("Ranking: Markierte Gilden")

-- Spalten-Header
local colHeaderLeft = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colHeaderLeft:SetPoint("TOPLEFT", tabPlayersBtn, "BOTTOMLEFT", 6, -10)
colHeaderLeft:SetText("#   Name")

local colHeaderRight = lbFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colHeaderRight:SetPoint("TOPRIGHT", tabGuildsBtn, "BOTTOMRIGHT", -28, -10)
colHeaderRight:SetText("Kills")

-- Scroll-Container für das Ranking
local lbListBg = CreateFrame("Frame", nil, lbFrame, "BackdropTemplate")
lbListBg:SetPoint("TOPLEFT", tabPlayersBtn, "BOTTOMLEFT", 0, -26)
lbListBg:SetSize(380, 290)
lbListBg:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
lbListBg:SetBackdropColor(0.02, 0.02, 0.03, 0.88)
lbListBg:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.9)

local lbScrollFrame = CreateFrame("ScrollFrame", "GuildScannerLeaderboardScrollFrame", lbListBg, "UIPanelScrollFrameTemplate")
lbScrollFrame:SetPoint("TOPLEFT", lbListBg, "TOPLEFT", 6, -6)
lbScrollFrame:SetPoint("BOTTOMRIGHT", lbListBg, "BOTTOMRIGHT", -26, 6)

local lbScrollChild = CreateFrame("Frame", nil, lbScrollFrame)
lbScrollChild:SetSize(340, 1)
lbScrollFrame:SetScrollChild(lbScrollChild)

local lbEmptyText = lbListBg:CreateFontString(nil, "OVERLAY", "GameFontDisable")
lbEmptyText:SetPoint("CENTER", lbListBg, "CENTER", -8, 0)
lbEmptyText:SetText("Noch keine Kills gegen markierte Gilden aufgezeichnet.")

local lbRows = {}

local function FormatRankBadge(rank)
    if rank == 1 then
        return "|cffffd7001.|r"
    elseif rank == 2 then
        return "|cffc0c0c02.|r"
    elseif rank == 3 then
        return "|cffcd7f323.|r"
    end
    return string.format("|cff888888%d.|r", rank)
end

RefreshLeaderboardUI = function()
    if not GuildScannerDB then return end
    EnsureLeaderboardTables()
    RebuildGuildTotalsFromPlayers()

    if activeLbTab == "players" then
        tabPlayersBtn:Disable()
        tabGuildsBtn:Enable()
        colHeaderLeft:SetText("Rang & Gildenmitglied (Hover für Details)")
        colHeaderRight:SetText("Kills gesamt")
    else
        tabPlayersBtn:Enable()
        tabGuildsBtn:Disable()
        colHeaderLeft:SetText("Rang & Überwachte Gilde")
        colHeaderRight:SetText("Besiegte Spieler")
    end

    for _, r in ipairs(lbRows) do
        r:Hide()
    end

    local entries = {}
    local lb = GuildScannerDB.leaderboard

    if activeLbTab == "players" then
        for playerName, pData in pairs(lb.players) do
            if (pData.kills or 0) > 0 then
                table.insert(entries, {
                    name = playerName,
                    kills = pData.kills or 0,
                    classFile = pData.classFile,
                    byGuild = pData.byGuild,
                })
            end
        end
    else
        -- Alle markierten Gilden sowie Gilden mit aufgezeichneten Kills anzeigen
        local seenKeys = {}
        if GuildScannerDB.watchlist then
            for gKey, origName in pairs(GuildScannerDB.watchlist) do
                seenKeys[gKey] = true
                local gEntry = lb.guilds[gKey]
                table.insert(entries, {
                    key = gKey,
                    name = origName,
                    kills = (gEntry and gEntry.kills) or 0,
                })
            end
        end
        for gKey, gData in pairs(lb.guilds) do
            if not seenKeys[gKey] and (gData.kills or 0) > 0 then
                table.insert(entries, {
                    key = gKey,
                    name = gData.name or gKey,
                    kills = gData.kills or 0,
                })
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.kills ~= b.kills then
            return a.kills > b.kills
        end
        return string.lower(a.name) < string.lower(b.name)
    end)

    if #entries == 0 then
        lbEmptyText:Show()
        lbScrollChild:SetHeight(1)
        return
    end

    lbEmptyText:Hide()
    local rowHeight = 28

    for i, item in ipairs(entries) do
        local row = lbRows[i]
        if not row then
            row = CreateFrame("Frame", nil, lbScrollChild, "BackdropTemplate")
            row:SetSize(344, rowHeight - 2)
            row:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            })
            row:EnableMouse(true)

            row.rankText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.rankText:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.rankText:SetWidth(28)
            row.rankText:SetJustifyH("LEFT")

            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.nameText:SetPoint("LEFT", row.rankText, "RIGHT", 4, 0)
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -65, 0)
            row.nameText:SetJustifyH("LEFT")
            row.nameText:SetWordWrap(false)

            row.killsText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            row.killsText:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            row.killsText:SetJustifyH("RIGHT")

            lbRows[i] = row
        end

        if i == 1 then
            row:SetBackdropColor(0.35, 0.28, 0.05, 0.55)
        elseif i % 2 == 0 then
            row:SetBackdropColor(0.14, 0.14, 0.18, 0.45)
        else
            row:SetBackdropColor(0.09, 0.09, 0.12, 0.45)
        end

        row:SetPoint("TOPLEFT", lbScrollChild, "TOPLEFT", 0, -((i - 1) * rowHeight))
        row.rankText:SetText(FormatRankBadge(i))

        if activeLbTab == "players" then
            local colorHex = GetClassColorHex(item.classFile)
            row.nameText:SetText("|c" .. colorHex .. item.name .. "|r")
            row.killsText:SetText("|cffffd100" .. tostring(item.kills) .. "|r")

            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(item.name .. " – Kill-Statistik", 0.0, 0.8, 1.0)
                GameTooltip:AddLine("Gesamte Kills: " .. tostring(item.kills), 1, 0.82, 0)
                if type(item.byGuild) == "table" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Kills pro markierter Gilde:", 0.8, 0.8, 0.8)
                    for gKey, c in pairs(item.byGuild) do
                        if c and c > 0 then
                            local gName = (lb.guilds[gKey] and lb.guilds[gKey].name)
                                or (GuildScannerDB.watchlist and GuildScannerDB.watchlist[gKey])
                                or gKey
                            GameTooltip:AddDoubleLine("<" .. gName .. ">", tostring(c), 0.25, 1.0, 0.25, 1, 1, 1)
                        end
                    end
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        else
            row.nameText:SetText("|cff40ff40<" .. item.name .. ">|r")
            row.killsText:SetText("|cffff5555" .. tostring(item.kills) .. "|r")

            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("<" .. item.name .. ">", 0.25, 1.0, 0.25)
                GameTooltip:AddLine("Besiegte Mitglieder gesamt: " .. tostring(item.kills), 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Top-Jäger deiner Gilde:", 0.8, 0.8, 0.8)
                for pName, pData in pairs(lb.players) do
                    local c = pData.byGuild and pData.byGuild[item.key]
                    if c and c > 0 then
                        local colorHex = GetClassColorHex(pData.classFile)
                        GameTooltip:AddDoubleLine("|c" .. colorHex .. pName .. "|r", tostring(c), 1, 1, 1, 1, 0.82, 0)
                    end
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        row:Show()
    end

    lbScrollChild:SetHeight(#entries * rowHeight)
end

tabPlayersBtn:SetScript("OnClick", function()
    activeLbTab = "players"
    RefreshLeaderboardUI()
end)

tabGuildsBtn:SetScript("OnClick", function()
    activeLbTab = "guilds"
    RefreshLeaderboardUI()
end)

-- Untere Buttons im Leaderboard: "Mit Gilde synchronisieren" & "Eigenen Stand senden"
local syncLbBtn = CreateFrame("Button", nil, lbFrame, "UIPanelButtonTemplate")
syncLbBtn:SetSize(240, 26)
syncLbBtn:SetPoint("BOTTOMLEFT", lbFrame, "BOTTOMLEFT", 20, 16)
syncLbBtn:SetText("Mit Gilde synchronisieren")
syncLbBtn:SetScript("OnClick", function()
    RequestGuildLeaderboardSync(true)
end)

local resetLbBtn = CreateFrame("Button", nil, lbFrame, "UIPanelButtonTemplate")
resetLbBtn:SetSize(130, 26)
resetLbBtn:SetPoint("BOTTOMRIGHT", lbFrame, "BOTTOMRIGHT", -20, 16)
resetLbBtn:SetText("Reset (Lokal)")
resetLbBtn:SetScript("OnClick", function()
    if GuildScannerDB then
        GuildScannerDB.leaderboard = { players = {}, guilds = {} }
        RefreshLeaderboardUI()
        PrintMsg("Lokales Leaderboard wurde zurückgesetzt.")
    end
end)

ToggleLeaderboardFrame = function()
    InitializeDatabase()
    if lbFrame:IsShown() then
        lbFrame:Hide()
    else
        RefreshLeaderboardUI()
        lbFrame:Show()
        RequestGuildLeaderboardSync(false)
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
        if IsShiftKeyDown() then
            ToggleLeaderboardFrame()
        else
            ToggleConfigFrame()
        end
    elseif button == "RightButton" then
        if IsShiftKeyDown() then
            RunTestAlert()
        else
            ToggleLeaderboardFrame()
        end
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("GuildScanner", 0.0, 0.8, 1.0)
    GameTooltip:AddLine("Linksklick: Einstellungen öffnen", 1, 1, 1)
    GameTooltip:AddLine("Rechtsklick: Kill-Leaderboard öffnen", 1, 0.82, 0)
    GameTooltip:AddLine("Shift + Rechtsklick: Test-Alarm auslösen", 0.8, 0.8, 0.8)
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
        -- WICHTIG: Niemals HideUIPanel(SettingsPanel) aus Addon-Code aufrufen (verursacht UIParent-Taint!)
        ToggleConfigFrame()
    end)

    local openLbOptBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openLbOptBtn:SetSize(220, 28)
    openLbOptBtn:SetPoint("TOPLEFT", openGuiBtn, "BOTTOMLEFT", 0, -10)
    openLbOptBtn:SetText("Kill-Leaderboard öffnen")
    openLbOptBtn:SetScript("OnClick", function()
        ToggleLeaderboardFrame()
    end)

    -- Taint-Vermeidung: Wir registrieren das Options-Panel erst, wenn das Blizzard-Settings-Menü
    -- tatsächlich geöffnet wird, oder über einen sicheren Callback, um Lade-Reihenfolge-Taint
    -- mit Addons wie Auctionator / Disenchant Buddy zu verhindern.
    if Settings and Settings.RegisterCanvasLayoutCategory then
        pcall(function()
            local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
            Settings.RegisterAddOnCategory(category)
        end)
    elseif InterfaceOptions_AddCategory then
        pcall(InterfaceOptions_AddCategory, panel)
    end
end

-- ============================================================================
-- Erkennungs-Engine & Kill-Detektor (Ohne Combat Log!)
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

local function IsKillOnCooldown(victimShortName)
    local now = GetTime()
    local lastKill = recentKills[victimShortName]
    if lastKill and (now - lastKill) < KILL_DEDUP_SECONDS then
        return true
    end
    recentKills[victimShortName] = now
    return false
end

-- Prüft ohne Combat-Log, ob eine überwachte feindliche Einheit gerade durch uns / im Kampf gestorben ist
local function CheckUnitKillState(unit)
    if not GuildScannerDB or not GuildScannerDB.leaderboardEnabled then return end
    if not unit or IsSecret(unit) then return end
    if UnitIsForbidden and SafeIsTrue(UnitIsForbidden(unit)) then return end
    if not SafeIsTrue(UnitExists(unit)) or not SafeIsTrue(UnitIsPlayer(unit)) then return end
    if SafeIsTrue(UnitIsUnit(unit, "player")) then return end

    -- Nur feindliche / angreifbare Spieler für PvP-Kills werten
    local canAttack = SafeIsTrue(UnitCanAttack("player", unit))
    local isEnemy = SafeIsTrue(UnitIsEnemy("player", unit))
    if not canAttack and not isEnemy then
        return
    end

    local rawGuildName = GetGuildInfo(unit)
    local guildName = SafeString(rawGuildName)
    if not guildName then return end

    local guildKey = string.lower(guildName)
    local watchedGuild = GuildScannerDB.watchlist and GuildScannerDB.watchlist[guildKey]
    if not watchedGuild then return end

    local fullName = GetFullPlayerName(unit)
    if not fullName then return end
    local shortName = SafeString(Ambiguate(fullName, "none")) or fullName

    local isDead = SafeIsTrue(UnitIsDeadOrGhost(unit))
    local prev = trackedUnits[unit]

    -- Wenn der Spieler das Ziel aktiv anvisiert hat, als letztes Ziel vormerken
    if unit == "target" and not isDead then
        lastDamagedTarget = {
            name = shortName,
            guildName = watchedGuild,
            guildKey = guildKey,
            time = GetTime(),
        }
    end

    -- Übergang von Lebend -> Tot erkannt, während wir im Kampf sind oder das Ziel anvisiert haben
    if isDead and prev and prev.name == shortName and prev.wasAlive then
        prev.wasAlive = false
        local isCurrentTarget = SafeIsTrue(UnitIsUnit(unit, "target"))
        local wasRecentTarget = lastDamagedTarget
            and lastDamagedTarget.name == shortName
            and (GetTime() - lastDamagedTarget.time) <= 15

        if (isCurrentTarget or wasRecentTarget or InCombatLockdown()) and not IsKillOnCooldown(shortName) then
            local myName = GetLocalPlayerShortName()
            local _, myClass = UnitClass("player")
            RecordWatchedGuildKill(myName, SafeString(myClass), shortName, watchedGuild, false)
        end
    else
        trackedUnits[unit] = {
            name = shortName,
            guildName = watchedGuild,
            guildKey = guildKey,
            wasAlive = not isDead,
        }
    end
end

local function CheckUnitInternal(unit, allowSelfForTest)
    if not unit or IsSecret(unit) then return end

    -- 1. Midnight-Restriktionen prüfen: Verbotene Units sofort überspringen
    if UnitIsForbidden and SafeIsTrue(UnitIsForbidden(unit)) then
        return
    end

    -- 2. Existenz- und Spieler-Prüfung (Secret-Boolean-sicher)
    local exists = UnitExists(unit)
    local isPlayer = UnitIsPlayer(unit)
    if IsSecret(exists) or IsSecret(isPlayer) or not exists or not isPlayer then
        return
    end

    -- 3. Eigenen Charakter im Normalbetrieb ausschließen (Secret-Boolean-sicher!)
    if not allowSelfForTest then
        local isSelf = UnitIsUnit(unit, "player")
        if IsSecret(isSelf) or isSelf then
            return
        end
    end

    -- 4. Gildeninformationen auslesen
    local rawGuildName, rawGuildRank = GetGuildInfo(unit)
    local guildName = SafeString(rawGuildName)
    if not guildName then
        return
    end
    local guildRankName = SafeString(rawGuildRank)

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

    local shortName = SafeString(Ambiguate(fullName, "none")) or fullName

    -- Einheit für Kill-Detektor vormerken
    local isDead = SafeIsTrue(UnitIsDeadOrGhost(unit))
    trackedUnits[unit] = {
        name = shortName,
        guildName = watchedGuild,
        guildKey = guildKey,
        wasAlive = not isDead,
    }
    if unit == "target" and not isDead then
        lastDamagedTarget = {
            name = shortName,
            guildName = watchedGuild,
            guildKey = guildKey,
            time = GetTime(),
        }
    end

    if not allowSelfForTest and IsPlayerOnCooldown(shortName) then
        return
    end

    -- 7. Klassen- & Fraktionsdaten für das Popup ermitteln
    local _, rawClassFile = UnitClass(unit)
    local classFile = SafeString(rawClassFile)
    local factionGroup = SafeString(UnitFactionGroup(unit))

    TriggerAlert(shortName, shortName, guildName, guildRankName, classFile, factionGroup)
end

local function CheckUnit(unit, allowSelfForTest)
    pcall(CheckUnitInternal, unit, allowSelfForTest)
end

-- ============================================================================
-- Event-Handler
-- ============================================================================
-- WICHTIG: UNIT_HEALTH und UNIT_FLAGS NICHT global auf allen Units registrieren!
-- Globale Unit-Events feuern tausendfach und können in WoW 12.x/Forever bei
-- gleichzeitigen Secure-Aktionen anderer Addons (Disenchant Buddy / Auctionator)
-- den Execution-Stack verlangsamen oder Secret-Value-Kontexte berühren.
GuildScanner:RegisterEvent("ADDON_LOADED")
GuildScanner:RegisterEvent("PLAYER_ENTERING_WORLD")
GuildScanner:RegisterEvent("NAME_PLATE_UNIT_ADDED")
GuildScanner:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
GuildScanner:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
GuildScanner:RegisterEvent("PLAYER_TARGET_CHANGED")
GuildScanner:RegisterEvent("UNIT_TARGET")
GuildScanner:RegisterUnitEvent("UNIT_HEALTH", "target")
GuildScanner:RegisterUnitEvent("UNIT_FLAGS", "target")
GuildScanner:RegisterEvent("PLAYER_PVP_KILLS_CHANGED")
GuildScanner:RegisterEvent("CHAT_MSG_ADDON")
GuildScanner:RegisterEvent("PLAYER_REGEN_ENABLED")

GuildScanner:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitializeDatabase()
            if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
                C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
            elseif RegisterAddonMessagePrefix then
                RegisterAddonMessagePrefix(COMM_PREFIX)
            end
            UpdateMinimapButtonPosition()
            if GuildScannerDB.hideMinimapButton then
                minimapButton:Hide()
            else
                minimapButton:Show()
            end
            RegisterBlizzardOptionsPanel()
            PrintMsg("Geladen (v1.2.1). |cffffd100Linksklick|r aufs Minimap-Icon: Einstellungen | |cffffd100Rechtsklick|r: Kill-Leaderboard.")
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Nach Login / Reload einmalig mit Gildenmitgliedern synchronisieren
        C_Timer.After(4.0, function()
            RequestGuildLeaderboardSync(false)
        end)

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        CheckUnit(arg1, false)

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if arg1 and not IsSecret(arg1) then
            trackedUnits[arg1] = nil
        end

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CheckUnit("mouseover", false)

    elseif event == "PLAYER_TARGET_CHANGED" then
        CheckUnit("target", false)
        pcall(CheckUnitKillState, "target")

    elseif event == "UNIT_TARGET" then
        if arg1 and not IsSecret(arg1) and arg1 ~= "player" and not string.find(arg1, "^nameplate") then
            CheckUnit(arg1 .. "target", false)
        end

    elseif event == "UNIT_HEALTH" or event == "UNIT_FLAGS" then
        if arg1 and not IsSecret(arg1) and (arg1 == "target" or string.find(arg1, "^nameplate")) then
            pcall(CheckUnitKillState, arg1)
        end

    elseif event == "PLAYER_PVP_KILLS_CHANGED" then
        -- Ehrenhafter Sieg erhalten: Prüfen, ob unser aktuelles/letztes Ziel aus einer überwachten Gilde stammt
        pcall(CheckUnitKillState, "target")
        if lastDamagedTarget and (GetTime() - lastDamagedTarget.time) <= 15 then
            if not IsKillOnCooldown(lastDamagedTarget.name) then
                local myName = GetLocalPlayerShortName()
                local _, myClass = UnitClass("player")
                RecordWatchedGuildKill(
                    myName,
                    SafeString(myClass),
                    lastDamagedTarget.name,
                    lastDamagedTarget.guildName,
                    false
                )
            end
        end

    elseif event == "CHAT_MSG_ADDON" then
        pcall(HandleAddonMessage, arg1, arg2, arg3, arg4)

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
    PrintMsg("  |cffffd100/gscan lb|r oder |cffffd100/gscan leaderboard|r - Öffnet das Gilden-Kill-Leaderboard")
    PrintMsg("  |cffffd100/gscan sync|r - Synchronisiert das Leaderboard mit deiner Gilde")
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

    elseif cmd == "lb" or cmd == "leaderboard" or cmd == "ranking" or cmd == "kills" then
        ToggleLeaderboardFrame()

    elseif cmd == "sync" then
        RequestGuildLeaderboardSync(true)

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
