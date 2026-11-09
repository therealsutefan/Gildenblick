-- Gildenblick – eigenstaendiger Gilden-Tooltip fuer WoW Forever (Mainline-API)
local ADDON_NAME = ...

---------------------------------------------------------------------------
-- Einstellungen
---------------------------------------------------------------------------
local DEFAULTS = {
    showButton       = true,
    locked           = false,
    point            = nil,      -- {point, relPoint, x, y}
    sortBy           = "name",   -- rank | name | level | class | zone
    showRank         = false,    -- Rang-Spalte anzeigen
    showLayer        = true,     -- Layer-Erkennung + Austausch mit der Gilde
    sortDesc         = false,    -- Sortierung umkehren
    showOffline      = false,
    showNotes        = true,
    showOfficerNotes = true,
    showSummary      = true,
    maxRows          = 40,
    scale            = 1.0,
}
local db

local SORT_LABELS = { rank = "Rang", name = "Name", level = "Stufe", class = "Klasse", zone = "Gebiet", layer = "Layer" }

local function Print(msg)
    print("|cff33ccffGildenblick|r: " .. msg)
end

---------------------------------------------------------------------------
-- API-Wrapper (mit Fallbacks)
---------------------------------------------------------------------------
local lastRequest = 0
local function RequestRoster(force)
    if not IsInGuild() then return end
    local now = GetTime()
    if not force and now - lastRequest < 10 then return end
    lastRequest = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

local function CanSeeOfficerNotes()
    if C_GuildInfo and C_GuildInfo.CanViewOfficerNote then
        return C_GuildInfo.CanViewOfficerNote()
    end
    if CanViewOfficerNote then return CanViewOfficerNote() end
    return false
end

local function OpenWhisper(name)
    if ChatFrameUtil and ChatFrameUtil.SendTell then
        ChatFrameUtil.SendTell(name)
    elseif ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    end
end

local function InviteMember(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    elseif InviteUnit then
        InviteUnit(name)
    end
end

local function ToggleGuild()
    if not IsInGuild() then return end
    if ToggleGuildFrame then ToggleGuildFrame() end
end

local function GetMaxLevel()
    if GetMaxLevelForPlayerExpansion then
        local l = GetMaxLevelForPlayerExpansion()
        if l and l > 0 then return l end
    end
    return MAX_PLAYER_LEVEL or 60
end

---------------------------------------------------------------------------
-- Farben
---------------------------------------------------------------------------
local function Hex(r, g, b)
    return string.format("ff%02x%02x%02x",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function Col(text, code) return "|c" .. code .. tostring(text) .. "|r" end

local GRAY, WHITE, GOLD, GREEN, NOTE, ONOTE =
    "ff808080", "ffffffff", "ffffd100", "ff40ff40", "ffb0b0b0", "ff60c060"

local function ClassCode(classFile)
    local t = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local c = classFile and t and t[classFile]
    if c then return Hex(c.r, c.g, c.b) end
    return WHITE
end

local function LevelCode(level)
    if GetQuestDifficultyColor then
        local c = GetQuestDifficultyColor(level)
        if c then return Hex(c.r, c.g, c.b) end
    end
    return WHITE
end

local function StatusTag(status)
    if status == 1 or status == "<AFK>" then
        return " " .. Col(CHAT_FLAG_AFK or "<AFK>", "ffffcc00")
    elseif status == 2 or status == "<DND>" then
        return " " .. Col(CHAT_FLAG_DND or "<DND>", "ffff6060")
    end
    return ""
end

---------------------------------------------------------------------------
-- Daten
---------------------------------------------------------------------------
local roster = {}
local info = { total = 0, online = 0, classes = {}, levels = {}, levelSum = 0, maxLevel = 60 }

local function LastOnlineText(m)
    if (m.lastY or 0) > 0 then return m.lastY .. " J" end
    if (m.lastM or 0) > 0 then return m.lastM .. " Mon" end
    if (m.lastD or 0) > 0 then return m.lastD .. " T" end
    if (m.lastH or 0) > 0 then return m.lastH .. " Std" end
    return "<1 Std"
end

local function Scan()
    wipe(roster)
    info.total, info.online, info.levelSum = 0, 0, 0
    info.classes, info.levels = {}, {}
    info.maxLevel = GetMaxLevel()
    if not IsInGuild() then return end

    local total = GetNumGuildMembers() or 0
    for i = 1, total do
        local name, rankName, rankIndex, level, classLoc, zone, note, officerNote,
              online, status, classFile = GetGuildRosterInfo(i)
        if name then
            local m = {
                fullName    = name,
                name        = Ambiguate and Ambiguate(name, "guild") or name,
                rank        = rankName or "",
                rankIndex   = rankIndex or 99,
                level       = level or 0,
                classLoc    = classLoc or "?",
                classFile   = classFile,
                zone        = zone or "",
                note        = note or "",
                officerNote = officerNote or "",
                online      = online and true or false,
                status      = status,
            }
            if not m.online and GetGuildRosterLastOnline then
                m.lastY, m.lastM, m.lastD, m.lastH = GetGuildRosterLastOnline(i)
            end
            roster[#roster + 1] = m

            info.total = info.total + 1
            if m.online then info.online = info.online + 1 end
            info.levelSum = info.levelSum + m.level

            local key = classFile or classLoc or "?"
            local c = info.classes[key]
            if not c then
                c = { file = classFile, loc = m.classLoc, total = 0, online = 0 }
                info.classes[key] = c
            end
            c.total = c.total + 1
            if m.online then c.online = c.online + 1 end

            local b = (m.level >= info.maxLevel) and info.maxLevel or math.floor(m.level / 10) * 10
            local lb = info.levels[b]
            if not lb then lb = { total = 0, online = 0 }; info.levels[b] = lb end
            lb.total = lb.total + 1
            if m.online then lb.online = lb.online + 1 end
        end
    end
end

---------------------------------------------------------------------------
-- Layer-Erkennung
-- Forever liefert keine offizielle Layer-Nummer. Die Kennung stammt aus dem
-- zoneUID-Feld der GUID von NPCs (Ziel, Mouseover, Namensplaketten).
-- Eine neue Kennung gilt erst, wenn zwei verschiedene NPCs sie bestaetigen.
---------------------------------------------------------------------------
local PREFIX = "Gildenblick"
local PEER_STALE, PEER_DROP = 600, 1800   -- Sekunden
local layer = { id = nil, zone = nil, time = 0 }
local pending
local peers = {}          -- [Kurzname] = { id, zone, time }
local OnLayerChanged      -- wird weiter unten gesetzt
local myName = UnitName("player")

local function IsSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

local function LayerBlocked()
    if InCombatLockdown() then return true end
    local inInstance = IsInInstance()
    if IsSecret(inInstance) then return true end
    return inInstance and true or false
end

local function ObserveUnit(unit)
    if not db or not db.showLayer or not unit or LayerBlocked() then return end
    local guid = UnitGUID(unit)
    if not guid or IsSecret(guid) then return end
    local unitType, _, _, _, zoneUID = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
    local id = tonumber(zoneUID)
    if not id or id == 0 then return end
    local now = GetTime()
    if layer.id == id then
        layer.time = now
        pending = nil
        return
    end
    if pending and pending.id == id and pending.guid ~= guid then
        layer.id, layer.zone, layer.time = id, GetRealZoneText() or "", now
        pending = nil
        if OnLayerChanged then OnLayerChanged() end
    else
        pending = { id = id, guid = guid }
    end
end

local function ResetLayer()
    pending = nil
    if layer.id then
        layer.id, layer.zone, layer.time = nil, nil, 0
        if OnLayerChanged then OnLayerChanged() end
    end
end

-- Layer eines Mitglieds: id, zone, alter (s) oder nil
local function MemberLayer(m)
    if not m.online then return nil end
    if m.name == myName then
        if layer.id then return layer.id, layer.zone, GetTime() - layer.time end
        return nil
    end
    local p = peers[m.name]
    if not p then return nil end
    local age = GetTime() - p.time
    if age > PEER_DROP then peers[m.name] = nil; return nil end
    return p.id, p.zone, age
end

local function AgeText(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec < 60 then return sec .. " s" end
    return math.floor(sec / 60) .. " min"
end

local lastSend, sendQueued = 0, false
local function SendLayer()
    if not db or not IsInGuild() then return end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    if LayerBlocked() then return end
    local now = GetTime()
    if now - lastSend < 5 then
        if not sendQueued then
            sendQueued = true
            C_Timer.After(5.2 - (now - lastSend), function() sendQueued = false; SendLayer() end)
        end
        return
    end
    lastSend = now
    local msg
    if db.showLayer and layer.id then
        msg = "L:" .. layer.id .. ":" .. (layer.zone or "")
    else
        msg = "L::"
    end
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD")
end

local function QueryLayers()
    if not db or not db.showLayer or not IsInGuild() then return end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) or LayerBlocked() then return end
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, "Q", "GUILD")
end

local SORTERS = {
    rank  = function(a, b) if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end return a.name < b.name end,
    name  = function(a, b) return a.name < b.name end,
    level = function(a, b) if a.level ~= b.level then return a.level > b.level end return a.name < b.name end,
    class = function(a, b) if a.classLoc ~= b.classLoc then return a.classLoc < b.classLoc end return a.name < b.name end,
    zone  = function(a, b) if a.zone ~= b.zone then return a.zone < b.zone end return a.name < b.name end,
    layer = function(a, b)
        local ia, ib = MemberLayer(a), MemberLayer(b)
        local ra = not ia and 2 or (ia == layer.id and 0 or 1)
        local rb = not ib and 2 or (ib == layer.id and 0 or 1)
        if ra ~= rb then return ra < rb end
        if ra == 1 and ia ~= ib then return ia < ib end
        return a.name < b.name
    end,
}

local function GetVisibleMembers()
    local list = {}
    for _, m in ipairs(roster) do
        if m.online or db.showOffline then list[#list + 1] = m end
    end
    local inner = SORTERS[db.sortBy] or SORTERS.rank
    local desc = db.sortDesc
    table.sort(list, function(a, b)
        if a.online ~= b.online then return a.online end
        if desc then return inner(b, a) end
        return inner(a, b)
    end)
    return list
end

---------------------------------------------------------------------------
-- Tooltip-Frame (interaktiv: klickbar, scrollbar)
---------------------------------------------------------------------------
local PAD, GAP, ROW_H, NUM_COLS = 10, 12, 15, 7
local COL_MAX = { 28, 150, 160, 70, 120, 200, 200 }
local COL_HEAD = { "Lvl", "Name", "Gebiet", "Layer", "Rang", "Notiz", "Offiziersnotiz" }
local COL_SORT = { "level", "name", "zone", "layer", "rank" }
local Render -- forward

local tip = CreateFrame("Frame", "GildenblickTooltip", UIParent, "BackdropTemplate")
tip:SetFrameStrata("TOOLTIP")
tip:SetClampedToScreen(true)
tip:EnableMouse(true)
tip:EnableMouseWheel(true)
tip:Hide()
tip:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
tip:SetBackdropColor(0.05, 0.05, 0.08, 0.94)
tip:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
tip.texts, tip.rows, tip.offset = {}, {}, 0

local function Measure(fs)
    if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() end
    return fs:GetStringWidth()
end

local MAX_WIDTH = 640
tip.measure = tip:CreateFontString(nil, "ARTWORK")
tip.measure:SetWordWrap(false)
tip.measure:Hide()

local function TextWidth(text, font)
    local fs = tip.measure
    fs:SetFontObject(font)
    fs:SetText(text)
    return Measure(fs)
end

local function GetText(i)
    local fs = tip.texts[i]
    if not fs then
        fs = tip:CreateFontString(nil, "ARTWORK")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWordWrap(true)
        tip.texts[i] = fs
    end
    fs:Show()
    return fs
end

local function RowOnEnter(self)
    if self.isHeader then
        GameTooltip:SetOwner(tip, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", tip, "TOPRIGHT", 2, 0)
        GameTooltip:AddLine("Spaltenkopf anklicken: sortieren", 1, 0.82, 0)
        GameTooltip:AddLine("Erneut klicken: Reihenfolge umkehren", 1, 1, 1)
        GameTooltip:AddLine("Klasse: /gblick sort class", 0.7, 0.7, 0.7)
        GameTooltip:Show()
        return
    end
    local m = self.member
    if not m then return end
    GameTooltip:SetOwner(tip, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPLEFT", tip, "TOPRIGHT", 2, 0)
    GameTooltip:AddLine(Col(m.name, ClassCode(m.classFile)))
    GameTooltip:AddLine(string.format("Stufe %d %s", m.level, m.classLoc), 1, 1, 1)
    if db.showRank then
        GameTooltip:AddDoubleLine("Rang:", m.rank, 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if m.online then
        GameTooltip:AddDoubleLine("Gebiet:", m.zone, 0.8, 0.8, 0.8, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine("Zuletzt online:", "vor " .. LastOnlineText(m), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if db.showLayer then
        local lid, lzone, lage = MemberLayer(m)
        if lid then
            GameTooltip:AddDoubleLine("Layer:", string.format("%d (%s, vor %s)", lid, lzone or "?", AgeText(lage)),
                0.8, 0.8, 0.8, 1, 1, 1)
            if lid == layer.id then
                GameTooltip:AddLine("Auf deinem Layer", 0.25, 1, 0.25)
            elseif layer.zone and lzone ~= layer.zone then
                GameTooltip:AddLine("Anderes Gebiet – Layer nicht vergleichbar", 0.6, 0.6, 0.6)
            end
        end
    end
    if m.note ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Notiz:", 1, 0.82, 0)
        GameTooltip:AddLine(m.note, 1, 1, 1, true)
    end
    if m.officerNote ~= "" and db.showOfficerNotes and CanSeeOfficerNotes() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Offiziersnotiz:", 1, 0.82, 0)
        GameTooltip:AddLine(m.officerNote, 0.4, 0.9, 0.4, true)
    end
    GameTooltip:Show()
end

local function RowOnLeave()
    GameTooltip:Hide()
end

local function HeaderClick(self)
    local cx = GetCursorPosition() / self:GetEffectiveScale() - (self:GetLeft() or 0)
    for c, range in pairs(self.colX or {}) do
        if COL_SORT[c] and cx >= range[1] and cx <= range[2] + GAP then
            if db.sortBy == COL_SORT[c] then
                db.sortDesc = not db.sortDesc
            else
                db.sortBy, db.sortDesc = COL_SORT[c], false
            end
            tip.offset = 0
            Render()
            return
        end
    end
end

local function RowOnClick(self, button)
    if self.isHeader then
        if button == "LeftButton" then HeaderClick(self) end
        return
    end
    local m = self.member
    if not m or not m.online or button ~= "LeftButton" then return end
    if IsShiftKeyDown() then
        InviteMember(m.fullName)
    else
        OpenWhisper(m.fullName)
    end
end

local function GetRow(i)
    local row = tip.rows[i]
    if not row then
        row = CreateFrame("Button", nil, tip)
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.cols = {}
        for c = 1, NUM_COLS do
            local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            fs:SetJustifyH(c == 1 and "RIGHT" or "LEFT")
            fs:SetWordWrap(false)
            row.cols[c] = fs
        end
        row:SetScript("OnClick", RowOnClick)
        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", RowOnLeave)
        tip.rows[i] = row
    end
    row:Show()
    return row
end

local function BuildSummaryLines()
    local lines = {}
    -- Klassen
    local cls = {}
    for _, c in pairs(info.classes) do cls[#cls + 1] = c end
    table.sort(cls, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.loc < b.loc
    end)
    local parts = {}
    for _, c in ipairs(cls) do
        parts[#parts + 1] = Col(c.loc, ClassCode(c.file)) .. " " .. Col(c.online, GREEN) .. "/" .. c.total
    end
    if #parts > 0 then lines[#lines + 1] = { label = Col("Klassen: ", GOLD), parts = parts } end

    -- Stufen
    local buckets = {}
    for b in pairs(info.levels) do buckets[#buckets + 1] = b end
    table.sort(buckets, function(a, b) return a > b end)
    parts = {}
    for _, b in ipairs(buckets) do
        local lb = info.levels[b]
        local label
        if b >= info.maxLevel then
            label = tostring(info.maxLevel)
        elseif b == 0 then
            label = "1-9"
        else
            label = b .. "-" .. math.min(b + 9, info.maxLevel - 1)
        end
        parts[#parts + 1] = Col(label, WHITE) .. ": " .. Col(lb.online, GREEN) .. "/" .. lb.total
    end
    if #parts > 0 then lines[#lines + 1] = { label = Col("Stufen: ", GOLD), parts = parts } end
    return lines
end

function Render()
    for _, fs in ipairs(tip.texts) do fs:Hide() end
    for _, r in ipairs(tip.rows) do r:Hide() end

    local header, footer = {}, {}

    if not IsInGuild() then
        header[1] = { "Gildenblick", GameFontNormal, fixed = true }
        header[2] = { "Du bist in keiner Gilde.", GameFontHighlightSmall, fixed = true }
    else
        local gName, gRank = GetGuildInfo("player")
        header[#header + 1] = { Col(gName or "Gilde", GOLD) .. ((db.showRank and gRank) and Col("  (" .. gRank .. ")", GRAY) or ""), GameFontNormalLarge, fixed = true }
        local motd = GetGuildRosterMOTD and GetGuildRosterMOTD() or ""
        if motd ~= "" then
            header[#header + 1] = { Col("Nachricht des Tages: ", GREEN) .. motd, GameFontHighlightSmall }
        end
        local avg = info.total > 0 and (info.levelSum / info.total) or 0
        header[#header + 1] = {
            string.format("Online: %s / %d    Ø Stufe: %.1f    Sortierung: %s%s",
                Col(info.online, GREEN), info.total, avg, SORT_LABELS[db.sortBy] or db.sortBy,
                db.sortDesc and " (umgekehrt)" or ""),
            GameFontHighlight, fixed = true,
        }
        if db.showLayer then
            local own
            if LayerBlocked() and not layer.id then
                own = Col("nicht lesbar (Kampf/Instanz)", GRAY)
            elseif layer.id then
                own = Col(layer.id, GREEN) .. Col("  " .. (layer.zone or ""), GRAY)
            else
                own = Col("unbekannt – NPC anvisieren oder mit der Maus berühren", GRAY)
            end
            local users, same = 0, 0
            for _, m in ipairs(roster) do
                if m.name ~= myName then
                    local lid = MemberLayer(m)
                    if lid then
                        users = users + 1
                        if lid == layer.id then same = same + 1 end
                    end
                end
            end
            header[#header + 1] = { Col("Dein Layer: ", GOLD) .. own, GameFontHighlightSmall, fixed = true }
            header[#header + 1] = {
                string.format("%s%d mit Gildenblick, davon %s auf deinem Layer",
                    Col("Gilde: ", GOLD), users, Col(same, GREEN)),
                GameFontHighlightSmall, fixed = true,
            }
        end
        if db.showSummary then
            for _, l in ipairs(BuildSummaryLines()) do
                header[#header + 1] = { "", GameFontHighlightSmall, pack = l }
            end
        end
    end

    -- Tabelle
    local members = IsInGuild() and GetVisibleMembers() or {}
    local maxOffset = math.max(0, #members - db.maxRows)
    if tip.offset > maxOffset then tip.offset = maxOffset end
    if tip.offset < 0 then tip.offset = 0 end
    local first = tip.offset + 1
    local last = math.min(#members, tip.offset + db.maxRows)

    local showOfficer = db.showOfficerNotes and CanSeeOfficerNotes()
    local colOn = { true, true, true, false, db.showRank and true or false, false, false }
    for i = first, last do
        local m = members[i]
        if db.showLayer and MemberLayer(m) then colOn[4] = true end
        if db.showNotes and m.note ~= "" then colOn[6] = true end
        if showOfficer and m.officerNote ~= "" then colOn[7] = true end
    end

    local rows = {}
    if #members > 0 then
        local hr = GetRow(1)
        hr.member = nil
        hr.isHeader = true
        hr:EnableMouse(true)
        for c = 1, NUM_COLS do
            local label = COL_HEAD[c]
            if COL_SORT[c] and COL_SORT[c] == db.sortBy then
                hr.cols[c]:SetText(Col(label .. (db.sortDesc and " ^" or " v"), GREEN))
            else
                hr.cols[c]:SetText(Col(label, GOLD))
            end
        end
        rows[1] = hr

        for i = first, last do
            local m = members[i]
            local row = GetRow(#rows + 1)
            row.member = m
            row.isHeader = nil
            row:EnableMouse(true)
            local cc = m.online and ClassCode(m.classFile) or GRAY
            row.cols[1]:SetText(Col(m.level, m.online and LevelCode(m.level) or GRAY))
            row.cols[2]:SetText(Col(m.name, cc) .. (m.online and StatusTag(m.status) or ""))
            if m.online then
                row.cols[3]:SetText(m.zone)
            else
                row.cols[3]:SetText(Col("vor " .. LastOnlineText(m), GRAY))
            end
            local lid, lzone, lage = MemberLayer(m)
            if not lid then
                row.cols[4]:SetText("")
            elseif lid == layer.id then
                row.cols[4]:SetText(Col(lid, GREEN))
            elseif lage > PEER_STALE or (layer.zone and lzone ~= layer.zone) then
                row.cols[4]:SetText(Col(lid, GRAY))
            else
                row.cols[4]:SetText(Col(lid, WHITE))
            end
            row.cols[5]:SetText(Col(m.rank, m.online and WHITE or GRAY))
            row.cols[6]:SetText(Col(m.note, NOTE))
            row.cols[7]:SetText(Col(m.officerNote, ONOTE))
            rows[#rows + 1] = row
        end
    elseif IsInGuild() then
        header[#header + 1] = { Col("Niemand online.", GRAY), GameFontHighlightSmall, fixed = true }
    end

    -- Spaltenbreiten
    local w, tableWidth, visible = {}, 0, 0
    for c = 1, NUM_COLS do
        w[c] = 0
        if colOn[c] then
            for _, row in ipairs(rows) do
                w[c] = math.max(w[c], Measure(row.cols[c]))
            end
            w[c] = math.min(math.ceil(w[c]) + 1, COL_MAX[c])
            tableWidth = tableWidth + w[c]
            visible = visible + 1
        end
    end
    if visible > 1 then tableWidth = tableWidth + GAP * (visible - 1) end

    if IsInGuild() then
        if #members > db.maxRows then
            footer[#footer + 1] = { Col(string.format("%d-%d von %d  (Mausrad zum Scrollen)", first, last, #members), GRAY), GameFontHighlightSmall, fixed = true }
        end
        footer[#footer + 1] = { Col("Spaltenkopf: sortieren · Klick: flüstern · Shift+Klick: einladen", GRAY), GameFontHighlightSmall, fixed = true }
        footer[#footer + 1] = { Col("Button: Links Gildenfenster · Rechts Offline · /gblick", GRAY), GameFontHighlightSmall, fixed = true }
    end

    -- Breite: Tabelle oder laengste feste Zeile, gedeckelt
    local width = math.max(tableWidth, 320)
    for _, list in ipairs({ header, footer }) do
        for _, e in ipairs(list) do
            if e.fixed then width = math.max(width, TextWidth(e[1], e[2])) end
        end
    end
    width = math.min(math.ceil(width) + 4, MAX_WIDTH)

    -- Uebersicht nur zwischen ganzen Eintraegen umbrechen
    local expanded = {}
    for _, e in ipairs(header) do
        if e.pack then
            local line, n = e.pack.label, 0
            for _, part in ipairs(e.pack.parts) do
                local candidate = (n == 0) and (line .. part) or (line .. "   " .. part)
                if n > 0 and TextWidth(candidate, e[2]) > width - 6 then
                    expanded[#expanded + 1] = { line, e[2], fixed = true }
                    line = "      " .. part
                else
                    line = candidate
                end
                n = n + 1
            end
            expanded[#expanded + 1] = { line, e[2], fixed = true }
        else
            expanded[#expanded + 1] = e
        end
    end
    header = expanded

    local y = -PAD
    local ti = 0
    local function PlaceText(entry, spacing)
        ti = ti + 1
        local fs = GetText(ti)
        fs:SetFontObject(entry[2])
        fs:SetWordWrap(not entry.fixed)
        fs:SetWidth(width)
        fs:SetText(entry[1])
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", tip, "TOPLEFT", PAD, y)
        y = y - fs:GetStringHeight() - spacing
    end

    for _, e in ipairs(header) do PlaceText(e, 4) end
    if #rows > 0 then y = y - 4 end

    for _, row in ipairs(rows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", tip, "TOPLEFT", PAD, y)
        row:SetWidth(width)
        local x = 0
        row.colX = row.colX or {}
        wipe(row.colX)
        for c = 1, NUM_COLS do
            local fs = row.cols[c]
            fs:ClearAllPoints()
            if colOn[c] then
                row.colX[c] = { x, x + w[c] }
                fs:SetWidth(w[c])
                fs:SetPoint("LEFT", row, "LEFT", x, 0)
                fs:Show()
                x = x + w[c] + GAP
            else
                fs:Hide()
            end
        end
        y = y - ROW_H
    end

    if #footer > 0 then y = y - 6 end
    for _, e in ipairs(footer) do PlaceText(e, 2) end

    tip:SetSize(width + 2 * PAD, -y + PAD - 2)
end

local function AnchorTip(owner)
    tip:ClearAllPoints()
    local x, y = owner:GetCenter()
    if not x then
        tip:SetPoint("CENTER", UIParent, "CENTER")
        return
    end
    local s = owner:GetEffectiveScale() / UIParent:GetEffectiveScale()
    x, y = x * s, y * s
    local v = (y > UIParent:GetHeight() / 2) and "TOP" or "BOTTOM"
    local h = (x > UIParent:GetWidth() / 2) and "RIGHT" or "LEFT"
    local ov = (v == "TOP") and "BOTTOM" or "TOP"
    tip:SetPoint(v .. h, owner, ov .. h, 0, 0)
end

local function ShowTip(owner)
    if not db then return end
    tip.owner = owner
    tip.offset = 0
    tip.hideTimer = 0
    tip:SetScale(db.scale)
    RequestRoster()
    Scan()
    Render()
    AnchorTip(owner)
    tip:Show()
end

tip:SetScript("OnUpdate", function(self, elapsed)
    local owner = self.owner
    if self:IsMouseOver() or (owner and owner:IsVisible() and owner:IsMouseOver()) then
        self.hideTimer = 0
        return
    end
    self.hideTimer = (self.hideTimer or 0) + elapsed
    if self.hideTimer > 0.25 then
        self:Hide()
    end
end)

tip:SetScript("OnHide", function(self)
    self.owner = nil
    GameTooltip:Hide()
end)

tip:SetScript("OnMouseWheel", function(self, delta)
    self.offset = self.offset - delta * 5
    Render()
end)

---------------------------------------------------------------------------
-- Anzeige: eigener Button + optional LDB + Addon-Compartment
---------------------------------------------------------------------------
local btn = CreateFrame("Button", "GildenblickButton", UIParent, "BackdropTemplate")
btn:SetSize(120, 22)
btn:SetFrameStrata("MEDIUM")
btn:SetMovable(true)
btn:SetClampedToScreen(true)
btn:EnableMouse(true)
btn:RegisterForDrag("LeftButton")
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
btn:SetBackdropColor(0, 0, 0, 0.75)
btn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
btn.text:SetPoint("CENTER")
btn:Hide()

local ldbObj

local function ToggleOffline()
    db.showOffline = not db.showOffline
    if tip:IsShown() then Render() end
end

local function UpdateText()
    local text
    if IsInGuild() then
        text = string.format("Gilde: %s/%d", Col(info.online, GREEN), info.total)
    else
        text = "Gilde: -"
    end
    if db.showLayer then
        text = text .. "   Layer: " .. (layer.id and Col(layer.id, GREEN) or Col("?", GRAY))
    end
    btn.text:SetText(text)
    btn:SetWidth(math.max(80, btn.text:GetStringWidth() + 20))
    if ldbObj then ldbObj.text = text end
end

OnLayerChanged = function()
    UpdateText()
    SendLayer()
    if tip:IsShown() then Render() end
end

local function RestoreButton()
    btn:ClearAllPoints()
    local p = db.point
    if p then
        btn:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        btn:SetPoint("TOP", UIParent, "TOP", 0, -10)
    end
    btn:SetShown(db.showButton)
end

btn:SetScript("OnDragStart", function(self)
    if not db.locked then self:StartMoving() end
end)
btn:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.point = { p, rp, x, y }
end)
btn:SetScript("OnEnter", function(self) ShowTip(self) end)
btn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ToggleOffline() else ToggleGuild() end
end)

function Gildenblick_OnCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then ToggleOffline() else ToggleGuild() end
end
function Gildenblick_OnCompartmentEnter(_, frame)
    if frame then ShowTip(frame) end
end
function Gildenblick_OnCompartmentLeave() end

local function RegisterLDB()
    if ldbObj then return end
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    if not LDB then return end
    ldbObj = LDB:NewDataObject("Gildenblick", {
        type  = "data source",
        label = "Gilde",
        text  = "Gilde",
        icon  = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
        OnClick = function(_, button)
            if button == "RightButton" then ToggleOffline() else ToggleGuild() end
        end,
        OnEnter = function(frame) ShowTip(frame) end,
        OnLeave = function() end,
    })
end

---------------------------------------------------------------------------
-- Slash-Befehle
---------------------------------------------------------------------------
local function OnOff(v) return v and "|cff40ff40an|r" or "|cffff4040aus|r" end

local function Help()
    Print("Befehle (/gblick oder /gildenblick):")
    print("  lock / unlock - Button sperren/entsperren")
    print("  button - Button ein/aus (" .. OnOff(db.showButton) .. ")")
    print("  rank - Rang-Spalte (" .. OnOff(db.showRank) .. ")")
    print("  layer - Layer-Anzeige + Austausch (" .. OnOff(db.showLayer) .. ")")
    print("  sort rank|name|level|class|zone|layer - Sortierung (" .. db.sortBy .. ")")
    print("  offline - Offline-Mitglieder (" .. OnOff(db.showOffline) .. ")")
    print("  notes - Notizen (" .. OnOff(db.showNotes) .. ")")
    print("  onotes - Offiziersnotizen (" .. OnOff(db.showOfficerNotes) .. ")")
    print("  summary - Klassen-/Stufenübersicht (" .. OnOff(db.showSummary) .. ")")
    print("  rows <10-200> - Zeilen pro Seite (" .. db.maxRows .. ")")
    print("  scale <0.5-2> - Tooltip-Skalierung (" .. db.scale .. ")")
    print("  reset - Einstellungen zurücksetzen")
end

SLASH_GILDENBLICK1 = "/gblick"
SLASH_GILDENBLICK2 = "/gildenblick"
SlashCmdList.GILDENBLICK = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "lock" then
        db.locked = true; Print("Button gesperrt.")
    elseif cmd == "unlock" then
        db.locked = false; Print("Button entsperrt (Linksklick ziehen).")
    elseif cmd == "button" then
        db.showButton = not db.showButton; btn:SetShown(db.showButton)
        Print("Button " .. OnOff(db.showButton))
    elseif cmd == "sort" then
        if SORTERS[arg] then db.sortBy = arg; db.sortDesc = false; Print("Sortierung: " .. SORT_LABELS[arg])
        else Print("Unbekannt. Erlaubt: rank, name, level, class, zone, layer") end
    elseif cmd == "layer" then
        db.showLayer = not db.showLayer
        if not db.showLayer then
            SendLayer() -- meldet "unbekannt" an die Gilde
            ResetLayer()
            wipe(peers)
        else
            QueryLayers()
        end
        UpdateText()
        if tip:IsShown() then Render() end
        Print("Layer-Anzeige " .. OnOff(db.showLayer))
    elseif cmd == "rank" then
        db.showRank = not db.showRank; Print("Rang-Spalte " .. OnOff(db.showRank))
        if tip:IsShown() then Render() end
    elseif cmd == "offline" then
        ToggleOffline(); Print("Offline-Mitglieder " .. OnOff(db.showOffline))
    elseif cmd == "notes" then
        db.showNotes = not db.showNotes; Print("Notizen " .. OnOff(db.showNotes))
    elseif cmd == "onotes" then
        db.showOfficerNotes = not db.showOfficerNotes; Print("Offiziersnotizen " .. OnOff(db.showOfficerNotes))
    elseif cmd == "summary" then
        db.showSummary = not db.showSummary; Print("Übersicht " .. OnOff(db.showSummary))
    elseif cmd == "rows" then
        local n = tonumber(arg)
        if n and n >= 10 and n <= 200 then db.maxRows = math.floor(n); Print("Zeilen: " .. db.maxRows)
        else Print("Wert 10-200 angeben.") end
    elseif cmd == "scale" then
        local n = tonumber(arg)
        if n and n >= 0.5 and n <= 2 then db.scale = n; Print("Skalierung: " .. n)
        else Print("Wert 0.5-2 angeben.") end
    elseif cmd == "reset" then
        wipe(db)
        for k, v in pairs(DEFAULTS) do db[k] = v end
        RestoreButton(); Print("Zurückgesetzt.")
    else
        Help()
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_GUILD_UPDATE")
ev:RegisterEvent("GUILD_MOTD")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("CHAT_MSG_ADDON")

local function OnAddonMessage(prefix, text, channel, sender)
    if IsSecret(prefix) or prefix ~= PREFIX then return end
    if IsSecret(text) or IsSecret(sender) or IsSecret(channel) or channel ~= "GUILD" then return end
    if not db.showLayer or not sender then return end
    local short = Ambiguate(sender, "guild")
    if short == myName then return end
    if text == "Q" then
        if layer.id then C_Timer.After(math.random(1, 8), SendLayer) end
        return
    end
    local id, zone = text:match("^L:(%d*):(.*)$")
    if not id then return end
    if id == "" then
        peers[short] = nil
    else
        peers[short] = { id = tonumber(id), zone = zone, time = GetTime() }
    end
    if tip:IsShown() then Render() end
end

ev:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            GildenblickDB = GildenblickDB or {}
            db = GildenblickDB
            for k, v in pairs(DEFAULTS) do
                if db[k] == nil then db[k] = v end
            end
            RegisterLDB() -- frueh, damit ElvUI/Titan das Objekt beim Init sehen
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        RestoreButton()
        RegisterLDB()
        UpdateText()
        RequestRoster(true)
        C_Timer.NewTicker(30, function() RequestRoster() end)
        myName = UnitName("player")
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end
        C_Timer.After(10, QueryLayers)
        C_Timer.NewTicker(120, function()
            if db.showLayer and layer.id then SendLayer() end
        end)
    elseif not db then
        return
    elseif event == "GUILD_ROSTER_UPDATE" or event == "GUILD_MOTD" then
        Scan()
        UpdateText()
        if tip:IsShown() then Render() end
    elseif event == "PLAYER_TARGET_CHANGED" then
        ObserveUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ObserveUnit("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        ObserveUnit(arg1)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if layer.id then
            ResetLayer()        -- neues Gebiet: Kennung neu ermitteln
        end
        if db.showLayer then SendLayer() end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(arg1, ...)
    elseif event == "PLAYER_GUILD_UPDATE" then
        RequestRoster(true)
        Scan()
        UpdateText()
    end
end)
