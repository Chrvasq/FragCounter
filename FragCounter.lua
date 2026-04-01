-- FragCounter: Tracks Silithid Carapace Fragment looting for the Scarab Lord questline
-- Vanilla WoW 1.12.1 / Turtle WoW compatible (Lua 5.0)

local FRAGMENT_NAME = "Silithid Carapace Fragment"
local FRAGMENTS_PER_TURNIN = 200
local BROOD_FACTION_NAME = "Brood of Nozdormu"
local REP_PER_TURNIN_BASE = 200
local REP_PER_TURNIN_HUMAN = 220

-- Runtime goal value; persisted copy lives in FragCounterDB.goal
local FRAGMENTS_TOTAL_GOAL = 36000

local sessionLooted = 0
local sessionDeaths = 0
local sessionStartTime = nil -- GetTime() of first loot this session
local addonLoaded = false
local bagUpdateDirty = false
local cachedBroodIndex = nil

-- Rolling window for rate calculation (last 15 minutes)
local RATE_WINDOW = 900
local lootTimestamps = {}

local function GetDateKey()
    return date("%Y-%m-%d")
end

local function FormatNumber(n)
    local s = tostring(n)
    local result = ""
    local len = strlen(s)
    for i = 1, len do
        if i > 1 and mod(len - i + 1, 3) == 0 then
            result = result .. ","
        end
        result = result .. strsub(s, i, i)
    end
    return result
end

local function FormatDuration(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor(mod(seconds, 3600) / 60)
    if h > 0 then
        return h .. "h " .. m .. "m"
    end
    return m .. "m"
end

local function CountFragmentsInContainer(bagID)
    local total = 0
    local slots = GetContainerNumSlots(bagID)
    for slot = 1, slots do
        local link = GetContainerItemLink(bagID, slot)
        if link and strfind(link, FRAGMENT_NAME) then
            local _, count = GetContainerItemInfo(bagID, slot)
            total = total + (count or 1)
        end
    end
    return total
end

local function CountBagFragments()
    local total = 0
    for bag = 0, 4 do
        total = total + CountFragmentsInContainer(bag)
    end
    return total
end

local function CountBankFragments()
    local total = 0
    total = total + CountFragmentsInContainer(-1)
    for bag = 5, 10 do
        total = total + CountFragmentsInContainer(bag)
    end
    return total
end

local function GetBroodRep()
    if cachedBroodIndex then
        local name, _, standingID, barMin, barMax, barValue = GetFactionInfo(cachedBroodIndex)
        if name == BROOD_FACTION_NAME then
            local standingText = GetText("FACTION_STANDING_LABEL" .. standingID, UnitSex("player"))
            local progress = barValue - barMin
            local tierMax = barMax - barMin
            local repToNeutral = barValue < 0 and (0 - barValue) or 0
            return standingText, repToNeutral, barValue, progress, tierMax
        end
        cachedBroodIndex = nil
    end

    for i = 1, GetNumFactions() do
        local name, _, standingID, barMin, barMax, barValue, _, _, isHeader = GetFactionInfo(i)
        if not isHeader and name == BROOD_FACTION_NAME then
            cachedBroodIndex = i
            local standingText = GetText("FACTION_STANDING_LABEL" .. standingID, UnitSex("player"))
            local progress = barValue - barMin
            local tierMax = barMax - barMin
            local repToNeutral = barValue < 0 and (0 - barValue) or 0
            return standingText, repToNeutral, barValue, progress, tierMax
        end
    end

    return nil, 0, 0, 0, 0
end

local function GetRepPerTurnin()
    local isHuman = false
    if FragCounterDB and FragCounterDB.turnInRace then
        isHuman = (FragCounterDB.turnInRace == "human")
    else
        local _, race = UnitRace("player")
        isHuman = (race == "Human")
    end
    return isHuman and REP_PER_TURNIN_HUMAN or REP_PER_TURNIN_BASE
end

local function GetRollingRate()
    local now = GetTime()
    local cutoff = now - RATE_WINDOW

    while getn(lootTimestamps) > 0 and lootTimestamps[1].time < cutoff do
        table.remove(lootTimestamps, 1)
    end

    if getn(lootTimestamps) == 0 then
        return 0
    end

    local total = 0
    for i = 1, getn(lootTimestamps) do
        total = total + lootTimestamps[i].count
    end

    local elapsed = now - lootTimestamps[1].time
    if elapsed < 60 then
        return 0
    end

    return math.floor(total / elapsed * 3600)
end

local function GetSessionAverage()
    if not sessionStartTime or sessionLooted == 0 then
        return 0
    end
    local elapsed = GetTime() - sessionStartTime
    if elapsed < 60 then
        return 0
    end
    return math.floor(sessionLooted / elapsed * 3600)
end

local function CalcFragsToNeutral(repToNeutral)
    local turnins = math.ceil(repToNeutral / GetRepPerTurnin())
    return turnins, turnins * FRAGMENTS_PER_TURNIN
end

local function InitDB()
    if not FragCounterDB then
        FragCounterDB = {}
    end
    if not FragCounterDB.daily then
        FragCounterDB.daily = {}
    end
    if FragCounterDB.shown == nil then
        FragCounterDB.shown = true
    end
    if FragCounterDB.locked == nil then
        FragCounterDB.locked = false
    end
    if not FragCounterDB.characters then
        FragCounterDB.characters = {}
    end
end

-- Ensure daily entry has all fields
local function GetDailyEntry(dateKey)
    if not FragCounterDB.daily[dateKey] then
        FragCounterDB.daily[dateKey] = { looted = 0, deaths = 0, firstLoot = nil, lastLoot = nil }
    end
    -- Migrate old format (plain number) to new table format
    if type(FragCounterDB.daily[dateKey]) == "number" then
        FragCounterDB.daily[dateKey] = {
            looted = FragCounterDB.daily[dateKey],
            deaths = 0,
            firstLoot = nil,
            lastLoot = nil,
        }
    end
    return FragCounterDB.daily[dateKey]
end

local function GetCharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local function SaveCharacterCount(bagCount, bankCount)
    local key = GetCharKey()
    if not FragCounterDB.characters[key] then
        FragCounterDB.characters[key] = {}
    end
    if bagCount ~= nil then
        FragCounterDB.characters[key].bags = bagCount
    end
    if bankCount ~= nil then
        FragCounterDB.characters[key].bank = bankCount
    end
end

local function GetAllCharacterTotal()
    local total = 0
    for _, data in FragCounterDB.characters do
        total = total + (data.bags or 0) + (data.bank or 0)
    end
    return total
end

local function ParseLootMessage(msg)
    if not msg then return 0 end
    if not strfind(msg, "You receive loot") then return 0 end
    if not strfind(msg, FRAGMENT_NAME) then return 0 end

    local _, _, countStr = strfind(msg, "x(%d+)%.?$")
    if countStr then
        return tonumber(countStr)
    end

    return 1
end

local function SaveSession()
    FragCounterDB.session = {
        looted = sessionLooted,
        deaths = sessionDeaths,
        startTime = sessionStartTime,
        timestamps = lootTimestamps,
        savedTime = GetTime(),
    }
end

local function UpdateDisplay()
    if not addonLoaded then return end

    local today = GetDateKey()
    local dayData = GetDailyEntry(today)
    local charTotal = GetAllCharacterTotal()

    FragCounterSessionText:SetText("Session: +" .. FormatNumber(sessionLooted))
    FragCounterTodayText:SetText("Today: +" .. FormatNumber(dayData.looted))

    local perHour = GetRollingRate()
    if perHour > 0 then
        FragCounterRateText:SetText("~" .. FormatNumber(perHour) .. "/hr")
    else
        FragCounterRateText:SetText("")
    end

    FragCounterTotalText:SetText("Total: " .. FormatNumber(charTotal))

    if FragCounterDB.shown then
        FragCounterFrame:Show()
    else
        FragCounterFrame:Hide()
    end
end

local function OnFragmentsLooted(count)
    if count <= 0 then return end

    SaveCharacterCount(CountBagFragments(), nil)
    bagUpdateDirty = false

    sessionLooted = sessionLooted + count
    if not sessionStartTime then
        sessionStartTime = GetTime()
    end
    table.insert(lootTimestamps, { time = GetTime(), count = count })

    local today = GetDateKey()
    local dayData = GetDailyEntry(today)
    dayData.looted = dayData.looted + count
    local now = GetTime()
    if not dayData.firstLoot then
        dayData.firstLoot = now
    end
    dayData.lastLoot = now

    SaveSession()

    local turnInMsg = ""
    if FragCounterDB.showTurnIn then
        local standing, repToNeutral = GetBroodRep()
        if standing and repToNeutral > 0 then
            local _, fragsNeeded = CalcFragsToNeutral(repToNeutral)
            turnInMsg = "  |cffaaaaaa(" .. FormatNumber(fragsNeeded) .. " frags to Neutral)|r"
        elseif standing then
            turnInMsg = "  |cff00ff00(Neutral+ reached!)|r"
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ccffFragCounter:|r +" .. count ..
        "  |cffffffffSession: " .. FormatNumber(sessionLooted) ..
        "  |cff88ff88Today: " .. FormatNumber(dayData.looted) ..
        "|r" .. turnInMsg
    )

    UpdateDisplay()
end

local function OnPlayerDeath()
    sessionDeaths = sessionDeaths + 1

    local today = GetDateKey()
    local dayData = GetDailyEntry(today)
    dayData.deaths = dayData.deaths + 1

    SaveSession()

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Death #" .. sessionDeaths .. " this session (" .. dayData.deaths .. " today)")
end

local function PrintSummary()
    local today = GetDateKey()
    local dayData = GetDailyEntry(today)
    local turninsToday = math.floor(dayData.looted / FRAGMENTS_PER_TURNIN)
    local charTotal = GetAllCharacterTotal()

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff--- FragCounter Summary ---|r")

    -- Session stats
    local sessionLine = "Session: +" .. FormatNumber(sessionLooted) .. " fragments"
    if sessionDeaths > 0 then
        sessionLine = sessionLine .. ", " .. sessionDeaths .. " deaths"
    end
    if sessionStartTime then
        local elapsed = GetTime() - sessionStartTime
        sessionLine = sessionLine .. " (" .. FormatDuration(elapsed) .. ")"
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. sessionLine .. "|r")

    -- Today stats
    local todayLine = "Today (" .. today .. "): +" .. FormatNumber(dayData.looted) .. " fragments"
    if FragCounterDB.showTurnIn then
        todayLine = todayLine .. " (" .. turninsToday .. " turn-ins)"
    end
    if dayData.deaths > 0 then
        todayLine = todayLine .. ", " .. dayData.deaths .. " deaths"
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88" .. todayLine .. "|r")

    -- Rate comparison
    local rolling = GetRollingRate()
    local sessionAvg = GetSessionAverage()
    if rolling > 0 or sessionAvg > 0 then
        local rateLine = ""
        if rolling > 0 then
            rateLine = "Current: ~" .. FormatNumber(rolling) .. "/hr"
        end
        if sessionAvg > 0 then
            if rolling > 0 then
                rateLine = rateLine .. "  |  "
            end
            rateLine = rateLine .. "Session avg: " .. FormatNumber(sessionAvg) .. "/hr"
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa" .. rateLine .. "|r")
    end

    -- Character inventory
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff--- Character Inventory ---|r")
    for charName, data in FragCounterDB.characters do
        local bags = data.bags or 0
        local bank = data.bank or 0
        if bags > 0 or bank > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff" .. charName .. ": " .. FormatNumber(bags) .. " bags, " .. FormatNumber(bank) .. " bank|r")
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff= " .. FormatNumber(charTotal) .. " total across all characters|r")

    -- Rep estimate
    if rolling > 0 then
        local standing, repToNeutral, barValue, progress, tierMax = GetBroodRep()
        if standing then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff--- Brood of Nozdormu ---|r")
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. standing .. " (" .. FormatNumber(progress) .. "/" .. FormatNumber(tierMax) .. ")|r")
            if repToNeutral > 0 then
                local turninsNeeded, fragsNeeded = CalcFragsToNeutral(repToNeutral)
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. FormatNumber(fragsNeeded) .. " fragments to Neutral (" .. turninsNeeded .. " turn-ins)|r")
                local hoursLeft = fragsNeeded / rolling
                local daysLeft = math.floor(hoursLeft / 24)
                local hrsLeft = math.floor(mod(hoursLeft, 24))
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa~" ..
                    (daysLeft > 0 and (daysLeft .. "d ") or "") .. hrsLeft .. "h at current rate|r")
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Neutral reached!|r")
            end
        end
    end

    -- Daily history
    local days = {}
    for k, _ in FragCounterDB.daily do
        table.insert(days, k)
    end
    table.sort(days)

    local startIdx = max(1, getn(days) - 6)
    if getn(days) > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff--- Daily History ---|r")
        for i = startIdx, getn(days) do
            local d = days[i]
            local entry = GetDailyEntry(d)
            local line = "  " .. d .. ": " .. FormatNumber(entry.looted)
            if FragCounterDB.showTurnIn then
                local ti = math.floor(entry.looted / FRAGMENTS_PER_TURNIN)
                line = line .. " (" .. ti .. " turn-ins)"
            end
            if entry.deaths > 0 then
                line = line .. ", " .. entry.deaths .. " deaths"
            end
            if entry.firstLoot and entry.lastLoot and entry.lastLoot > entry.firstLoot then
                local duration = entry.lastLoot - entry.firstLoot
                local avg = math.floor(entry.looted / duration * 3600)
                line = line .. " | " .. FormatDuration(duration) .. " avg " .. FormatNumber(avg) .. "/hr"
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. line .. "|r")
        end
    end
end

local function SlashHandler(msg)
    msg = string.lower(msg or "")

    if msg == "show" then
        FragCounterDB.shown = true
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Display shown.")
    elseif msg == "hide" then
        FragCounterDB.shown = false
        FragCounterFrame:Hide()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Display hidden.")
    elseif msg == "reset session" then
        sessionLooted = 0
        sessionDeaths = 0
        sessionStartTime = nil
        lootTimestamps = {}
        FragCounterDB.session = nil
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Session reset.")
    elseif msg == "reset today" then
        FragCounterDB.daily[GetDateKey()] = nil
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Today's count reset.")
    elseif msg == "reset all" then
        FragCounterDB.daily = {}
        FragCounterDB.characters = {}
        FragCounterDB.session = nil
        sessionLooted = 0
        sessionDeaths = 0
        sessionStartTime = nil
        lootTimestamps = {}
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r All data reset.")
    elseif msg == "goal" then
        local charTotal = GetAllCharacterTotal()
        local pct = 0
        if FRAGMENTS_TOTAL_GOAL > 0 then
            pct = math.floor(charTotal / FRAGMENTS_TOTAL_GOAL * 100)
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Goal is " .. FormatNumber(FRAGMENTS_TOTAL_GOAL) .. " fragments. Have: " .. FormatNumber(charTotal) .. " (" .. pct .. "%)")
    elseif strfind(msg, "^goal%s+%d+$") then
        local _, _, num = strfind(msg, "^goal%s+(%d+)$")
        FRAGMENTS_TOTAL_GOAL = tonumber(num)
        FragCounterDB.goal = FRAGMENTS_TOTAL_GOAL
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Goal set to " .. FormatNumber(FRAGMENTS_TOTAL_GOAL) .. " fragments.")
    elseif msg == "turnin" then
        FragCounterDB.showTurnIn = not FragCounterDB.showTurnIn
        local state = FragCounterDB.showTurnIn and "ON" or "OFF"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Turn-in countdown " .. state .. ".")
        if FragCounterDB.showTurnIn then
            local standing, repToNeutral, barValue, progress, tierMax = GetBroodRep()
            if standing then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r " .. BROOD_FACTION_NAME .. ": " .. standing .. " (" .. FormatNumber(progress) .. "/" .. FormatNumber(tierMax) .. ")")
                if repToNeutral > 0 then
                    local turninsNeeded, fragsNeeded = CalcFragsToNeutral(repToNeutral)
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r " .. FormatNumber(fragsNeeded) .. " fragments needed (" .. turninsNeeded .. " turn-ins) to reach Neutral")
                end
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r " .. BROOD_FACTION_NAME .. " not found in your reputation panel.")
            end
        end
    elseif msg == "race human" then
        FragCounterDB.turnInRace = "human"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Turn-in character set to Human (220 rep per turn-in).")
    elseif msg == "race other" then
        FragCounterDB.turnInRace = "other"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Turn-in character set to non-Human (200 rep per turn-in).")
    elseif msg == "race auto" then
        FragCounterDB.turnInRace = nil
        local _, race = UnitRace("player")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Turn-in race auto-detecting from current character (" .. race .. ", " .. GetRepPerTurnin() .. " rep per turn-in).")
    elseif msg == "race" then
        local repPer = GetRepPerTurnin()
        local setting = FragCounterDB.turnInRace or "auto"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Turn-in race: " .. setting .. " (" .. repPer .. " rep per turn-in)")
    elseif msg == "lock" then
        FragCounterDB.locked = true
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Display locked.")
    elseif msg == "unlock" then
        FragCounterDB.locked = false
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Display unlocked (drag to move).")
    elseif msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff--- FragCounter Commands ---|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag|r - Show summary")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag show|r - Show display frame")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag hide|r - Hide display frame")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag lock|r - Lock frame position")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag unlock|r - Unlock frame (draggable)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag goal|r - Show progress toward goal")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag goal <number>|r - Set custom goal")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag turnin|r - Toggle turn-in countdown")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag race|r - Show turn-in character race")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag race human|other|auto|r - Set turn-in race")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag reset session|r - Reset session counter")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag reset today|r - Reset today's counter")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag reset all|r - Reset ALL data")
    else
        PrintSummary()
    end
end

function FragCounter_OnLoad()
    this:RegisterEvent("VARIABLES_LOADED")
    this:RegisterEvent("PLAYER_ENTERING_WORLD")
    this:RegisterEvent("PLAYER_DEAD")
    this:RegisterEvent("CHAT_MSG_LOOT")
    this:RegisterEvent("BAG_UPDATE")
    this:RegisterEvent("BANKFRAME_OPENED")
    this:RegisterEvent("BANKFRAME_CLOSED")
end

function FragCounter_OnEvent(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
    if event == "VARIABLES_LOADED" then
        InitDB()
        if FragCounterDB.goal then
            FRAGMENTS_TOTAL_GOAL = FragCounterDB.goal
        end
        addonLoaded = true

        -- Restore session if this is a /reload (GetTime continues counting)
        if FragCounterDB.session and FragCounterDB.session.savedTime and GetTime() >= FragCounterDB.session.savedTime then
            sessionLooted = FragCounterDB.session.looted or 0
            sessionDeaths = FragCounterDB.session.deaths or 0
            sessionStartTime = FragCounterDB.session.startTime
            lootTimestamps = FragCounterDB.session.timestamps or {}
        end
        FragCounterDB.session = nil

        SLASH_FRAGCOUNTER1 = "/frag"
        SLASH_FRAGCOUNTER2 = "/fragcount"
        SLASH_FRAGCOUNTER3 = "/fc"
        SlashCmdList["FRAGCOUNTER"] = SlashHandler

        FragCounterFrame:SetBackdropColor(0, 0, 0, 0.8)
        FragCounterFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter|r loaded. Type |cffffffff/frag|r for summary, |cffffffff/frag help|r for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        local bagCount = CountBagFragments()
        SaveCharacterCount(bagCount, nil)
        UpdateDisplay()

    elseif event == "PLAYER_DEAD" then
        OnPlayerDeath()

    elseif event == "CHAT_MSG_LOOT" then
        local count = ParseLootMessage(arg1)
        if count > 0 then
            OnFragmentsLooted(count)
        end

    elseif event == "BAG_UPDATE" then
        if addonLoaded then
            bagUpdateDirty = true
        end

    elseif event == "BANKFRAME_OPENED" then
        local bankCount = CountBankFragments()
        SaveCharacterCount(nil, bankCount)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Bank scanned: " .. FormatNumber(bankCount) .. " fragments in bank.")
        UpdateDisplay()

    elseif event == "BANKFRAME_CLOSED" then
        local bankCount = CountBankFragments()
        SaveCharacterCount(nil, bankCount)
        UpdateDisplay()
    end
end

function FragCounter_OnUpdate()
    if bagUpdateDirty then
        bagUpdateDirty = false
        local bagCount = CountBagFragments()
        SaveCharacterCount(bagCount, nil)
        UpdateDisplay()
    end
end
