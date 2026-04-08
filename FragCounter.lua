-- FragCounter: Tracks Silithid Carapace Fragment looting for the Scarab Lord questline
-- Vanilla WoW 1.12.1 / Turtle WoW compatible (Lua 5.0)

local FRAGMENT_NAME = "Silithid Carapace Fragment"
local FRAGMENTS_PER_TURNIN = 200
local BROOD_FACTION_NAME = "Brood of Nozdormu"
local REP_PER_TURNIN_BASE = 200
local REP_PER_TURNIN_HUMAN = 220

-- Runtime goal value; persisted copy lives in FragCounterDB.goal
local FRAGMENTS_TOTAL_GOAL = 36000
local FARMING_ZONE = "Silithus"

local sessionLooted = 0
local sessionDeaths = 0
local sessionGold = 0 -- copper gained this session (from loot + vendor)
local sessionVendorGold = 0 -- copper gained from vendoring
local sessionStartTime = nil -- GetTime() of first loot this session
local addonLoaded = false
local bagUpdateDirty = false
local cachedBroodIndex = nil
local loginMoney = nil -- GetMoney() at login
local merchantOpenMoney = nil -- GetMoney() when merchant opened

-- Rolling window for rate calculation (last 15 minutes)
local RATE_WINDOW = 900
local RELOAD_THRESHOLD = 60 -- max seconds between save and load to count as /reload
local lootTimestamps = {}

local function IsInFarmingZone()
    return GetRealZoneText() == FARMING_ZONE
end

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

-- Format copper amount as gold/silver/copper string
local function FormatMoney(copper)
    if copper == 0 then return "0c" end
    local negative = copper < 0
    if negative then copper = 0 - copper end
    local g = math.floor(copper / 10000)
    local s = math.floor(mod(copper, 10000) / 100)
    local c = mod(copper, 100)
    local result = ""
    if negative then result = "-" end
    if g > 0 then
        result = result .. "|cffffd700" .. FormatNumber(g) .. "g|r "
    end
    if s > 0 or g > 0 then
        result = result .. "|cffc7c7cf" .. s .. "s|r "
    end
    result = result .. "|cffeda55f" .. c .. "c|r"
    return result
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

-- Get total fragments needed to reach Neutral based on current rep, or custom goal
local function GetFragmentGoal()
    if FragCounterDB and FragCounterDB.goal then
        return FragCounterDB.goal
    end
    local _, repToNeutral = GetBroodRep()
    if repToNeutral > 0 then
        local _, fragsNeeded = CalcFragsToNeutral(repToNeutral)
        return fragsNeeded
    end
    return FRAGMENTS_TOTAL_GOAL
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
        FragCounterDB.daily[dateKey] = { looted = 0, deaths = 0, gold = 0, vendorGold = 0, activeTime = 0, lastLootTime = nil }
    end
    -- Migrate old format (plain number) to new table format
    if type(FragCounterDB.daily[dateKey]) == "number" then
        FragCounterDB.daily[dateKey] = {
            looted = FragCounterDB.daily[dateKey],
            deaths = 0,
            activeTime = 0,
            lastLootTime = nil,
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
    local elapsed = sessionStartTime and (GetTime() - sessionStartTime) or 0
    -- Convert timestamps to offsets from sessionStartTime (epoch-independent)
    local relTimestamps = {}
    if sessionStartTime then
        for i = 1, getn(lootTimestamps) do
            table.insert(relTimestamps, {
                offset = lootTimestamps[i].time - sessionStartTime,
                count = lootTimestamps[i].count,
            })
        end
    end
    FragCounterDB.session = {
        looted = sessionLooted,
        deaths = sessionDeaths,
        gold = sessionGold,
        vendorGold = sessionVendorGold,
        elapsed = elapsed,
        relTimestamps = relTimestamps,
        savedWallTime = time(),
    }
end

local function UpdateDisplay()
    if not addonLoaded then return end

    local today = GetDateKey()
    local dayData = GetDailyEntry(today)
    local charTotal = GetAllCharacterTotal()

    if IsInFarmingZone() then
        FragCounterTitle:SetText("FragCounter")
        FragCounterTitle:SetTextColor(1, 0.82, 0)
    else
        FragCounterTitle:SetText("FragCounter (paused)")
        FragCounterTitle:SetTextColor(0.5, 0.5, 0.5)
    end

    FragCounterSessionText:SetText("Session: +" .. FormatNumber(sessionLooted))
    FragCounterTodayText:SetText("Today: +" .. FormatNumber(dayData.looted))

    FragCounterTotalText:SetText("Total: " .. FormatNumber(charTotal))

    local perHour = GetRollingRate()
    if perHour > 0 then
        FragCounterRateText:SetText("Rate: ~" .. FormatNumber(perHour) .. "/hr")
    else
        FragCounterRateText:SetText("")
    end

    if sessionGold > 0 then
        FragCounterGoldText:SetText("Gold: " .. FormatMoney(sessionGold))
    else
        FragCounterGoldText:SetText("")
    end

    if sessionDeaths > 0 then
        FragCounterDeathText:SetText("Deaths: " .. sessionDeaths)
    else
        FragCounterDeathText:SetText("")
    end

    -- Dynamic height based on visible rows
    -- Rows at fixed Y offsets: Session(-22), Today(-34), Total(-46), Rate(-58), Gold(-70), Deaths(-82)
    local height = 66 -- base: title + session + today + total + padding
    if perHour > 0 then height = 66 + 12 end
    local extraRows = 0
    if sessionGold > 0 then extraRows = extraRows + 1 end
    if sessionDeaths > 0 then extraRows = extraRows + 1 end
    -- Shift gold/deaths up if rate is hidden
    if perHour <= 0 then
        local goldY = -58
        local deathY = sessionGold > 0 and -70 or -58
        FragCounterGoldText:ClearAllPoints()
        FragCounterGoldText:SetPoint("TOPLEFT", FragCounterFrame, "TOPLEFT", 10, goldY)
        FragCounterDeathText:ClearAllPoints()
        FragCounterDeathText:SetPoint("TOPLEFT", FragCounterFrame, "TOPLEFT", 10, deathY)
        height = 66 + extraRows * 12
    else
        FragCounterGoldText:ClearAllPoints()
        FragCounterGoldText:SetPoint("TOPLEFT", FragCounterFrame, "TOPLEFT", 10, -70)
        FragCounterDeathText:ClearAllPoints()
        local deathY = sessionGold > 0 and -82 or -70
        FragCounterDeathText:SetPoint("TOPLEFT", FragCounterFrame, "TOPLEFT", 10, deathY)
        height = 66 + 12 + extraRows * 12
    end
    FragCounterFrame:SetHeight(height)

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
    -- Accumulate active farming time: count gaps under 5 min, only in Silithus
    if dayData.lastLootTime and IsInFarmingZone() then
        local gap = now - dayData.lastLootTime
        if gap < 300 then
            dayData.activeTime = (dayData.activeTime or 0) + gap
        end
    end
    dayData.lastLootTime = now

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

    if FragCounterDB.showChat ~= false then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccffFragCounter:|r +" .. count ..
            "  |cffffffffSession: " .. FormatNumber(sessionLooted) ..
            "  |cff88ff88Today: " .. FormatNumber(dayData.looted) ..
            "|r" .. turnInMsg
        )
    end

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
    if sessionGold > 0 then
        local goldLine = "  Gold: " .. FormatMoney(sessionGold)
        if sessionVendorGold > 0 then
            goldLine = goldLine .. " (vendor: " .. FormatMoney(sessionVendorGold) .. ")"
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. goldLine .. "|r")
    end

    -- Today stats
    local todayLine = "Today (" .. today .. "): +" .. FormatNumber(dayData.looted) .. " fragments"
    if FragCounterDB.showTurnIn then
        todayLine = todayLine .. " (" .. turninsToday .. " turn-ins)"
    end
    if dayData.deaths > 0 then
        todayLine = todayLine .. ", " .. dayData.deaths .. " deaths"
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88" .. todayLine .. "|r")
    if (dayData.gold or 0) > 0 then
        local todayGoldLine = "  Gold: " .. FormatMoney(dayData.gold)
        if (dayData.vendorGold or 0) > 0 then
            todayGoldLine = todayGoldLine .. " (vendor: " .. FormatMoney(dayData.vendorGold) .. ")"
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88" .. todayGoldLine .. "|r")
    end

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
            if (entry.gold or 0) > 0 then
                line = line .. ", " .. FormatMoney(entry.gold)
            end
            local farmTime = entry.activeTime or 0
            -- Fallback for old data that only has firstLoot/lastLoot
            if farmTime < 60 and entry.firstLoot and entry.lastLoot and entry.lastLoot > entry.firstLoot then
                farmTime = entry.lastLoot - entry.firstLoot
            end
            if farmTime > 60 then
                local avg = math.floor(entry.looted / farmTime * 3600)
                line = line .. " | " .. FormatDuration(farmTime) .. " avg " .. FormatNumber(avg) .. "/hr"
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
        sessionGold = 0
        sessionVendorGold = 0
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
        sessionGold = 0
        sessionVendorGold = 0
        sessionStartTime = nil
        lootTimestamps = {}
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r All data reset.")
    elseif msg == "goal" then
        local charTotal = GetAllCharacterTotal()
        local goal = GetFragmentGoal()
        local pct = 0
        if goal > 0 then
            pct = math.floor(charTotal / goal * 100)
        end
        local source = FragCounterDB.goal and "custom" or "from rep"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Goal: " .. FormatNumber(goal) .. " fragments (" .. source .. "). Have: " .. FormatNumber(charTotal) .. " (" .. pct .. "%)")
    elseif strfind(msg, "^goal%s+%d+$") then
        local _, _, num = strfind(msg, "^goal%s+(%d+)$")
        FragCounterDB.goal = tonumber(num)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Custom goal set to " .. FormatNumber(FragCounterDB.goal) .. " fragments.")
    elseif msg == "goal auto" then
        FragCounterDB.goal = nil
        local goal = GetFragmentGoal()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Goal auto-calculating from rep (" .. FormatNumber(goal) .. " fragments).")
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
    elseif strfind(msg, "^scale%s+[%d%.]+$") then
        local _, _, num = strfind(msg, "^scale%s+([%d%.]+)$")
        local scale = tonumber(num)
        if scale and scale >= 0.5 and scale <= 2.0 then
            if not FragCounterCharDB then FragCounterCharDB = {} end
            FragCounterCharDB.scale = scale
            FragCounterFrame:SetScale(scale)
            -- Re-anchor to center so it doesn't go off screen
            FragCounterFrame:ClearAllPoints()
            FragCounterFrame:SetPoint("CENTER", "UIParent", "CENTER", 0, 0)
            FragCounter_SaveFramePosition()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Scale set to " .. num .. ". Frame re-centered — drag to reposition.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Scale must be between 0.5 and 2.0.")
        end
    elseif msg == "scale" then
        local scale = (FragCounterCharDB and FragCounterCharDB.scale) or 1.0
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Current scale: " .. scale .. " (use /frag scale <0.5-2.0>)")
    elseif msg == "chat" then
        if FragCounterDB.showChat == false then
            FragCounterDB.showChat = true
        else
            FragCounterDB.showChat = false
        end
        local state = FragCounterDB.showChat ~= false and "ON" or "OFF"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Loot chat messages " .. state .. ".")
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
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag scale <0.5-2.0>|r - Set display scale")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag chat|r - Toggle loot chat messages")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag lock|r - Lock frame position")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag unlock|r - Unlock frame (draggable)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag goal|r - Show progress toward goal")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag goal <number>|r - Set custom goal")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/frag goal auto|r - Auto-calculate goal from rep")
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

-- Per-character frame position and size
function FragCounter_SaveFramePosition()
    if not FragCounterCharDB then FragCounterCharDB = {} end
    local point, _, relPoint, x, y = FragCounterFrame:GetPoint()
    FragCounterCharDB.point = point
    FragCounterCharDB.relPoint = relPoint
    FragCounterCharDB.x = x
    FragCounterCharDB.y = y
end

function FragCounter_RestoreFrame()
    if not FragCounterCharDB then FragCounterCharDB = {} end
    if FragCounterCharDB.scale then
        FragCounterFrame:SetScale(FragCounterCharDB.scale)
    end
    if FragCounterCharDB.point then
        FragCounterFrame:ClearAllPoints()
        FragCounterFrame:SetPoint(FragCounterCharDB.point, "UIParent", FragCounterCharDB.relPoint, FragCounterCharDB.x, FragCounterCharDB.y)
    end
end


function FragCounter_OnLoad()
    this:RegisterEvent("VARIABLES_LOADED")
    this:RegisterEvent("PLAYER_ENTERING_WORLD")
    this:RegisterEvent("PLAYER_DEAD")
    this:RegisterEvent("CHAT_MSG_LOOT")
    this:RegisterEvent("CHAT_MSG_MONEY")
    this:RegisterEvent("MERCHANT_SHOW")
    this:RegisterEvent("MERCHANT_CLOSED")
    this:RegisterEvent("BAG_UPDATE")
    this:RegisterEvent("BANKFRAME_OPENED")
    this:RegisterEvent("BANKFRAME_CLOSED")
    this:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
    this:RegisterEvent("ZONE_CHANGED_NEW_AREA")
end

function FragCounter_OnEvent(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
    if event == "VARIABLES_LOADED" then
        InitDB()
        addonLoaded = true

        -- Restore session if this is a /reload (saved within last 60 seconds)
        -- A fresh login after fully closing the client will have a larger gap
        if FragCounterDB.session and FragCounterDB.session.savedWallTime and (time() - FragCounterDB.session.savedWallTime) < RELOAD_THRESHOLD then
            sessionLooted = FragCounterDB.session.looted or 0
            sessionDeaths = FragCounterDB.session.deaths or 0
            sessionGold = FragCounterDB.session.gold or 0
            sessionVendorGold = FragCounterDB.session.vendorGold or 0
            local savedElapsed = FragCounterDB.session.elapsed or 0
            sessionStartTime = savedElapsed > 0 and (GetTime() - savedElapsed) or nil
            -- Convert relative offsets back to absolute GetTime() values
            lootTimestamps = {}
            if sessionStartTime then
                local relTs = FragCounterDB.session.relTimestamps or {}
                for i = 1, getn(relTs) do
                    table.insert(lootTimestamps, {
                        time = sessionStartTime + relTs[i].offset,
                        count = relTs[i].count,
                    })
                end
            end
        end
        FragCounterDB.session = nil

        SLASH_FRAGCOUNTER1 = "/frag"
        SLASH_FRAGCOUNTER2 = "/fragcount"
        SLASH_FRAGCOUNTER3 = "/fc"
        SlashCmdList["FRAGCOUNTER"] = SlashHandler

        FragCounterFrame:SetBackdropColor(0, 0, 0, 0.8)
        FragCounterFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        FragCounterFrame:SetClampedToScreen(true)
        FragCounter_RestoreFrame()

        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter|r loaded. Type |cffffffff/frag|r for summary, |cffffffff/frag help|r for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        loginMoney = GetMoney()
        local bagCount = CountBagFragments()
        SaveCharacterCount(bagCount, nil)
        UpdateDisplay()

    elseif event == "PLAYER_DEAD" then
        if IsInFarmingZone() then
            OnPlayerDeath()
        end

    elseif event == "CHAT_MSG_LOOT" then
        local count = ParseLootMessage(arg1)
        if count > 0 then
            OnFragmentsLooted(count)
        end

    elseif event == "CHAT_MSG_MONEY" then
        -- Only track gold looted in the farming zone
        if arg1 and strfind(arg1, "You loot") and IsInFarmingZone() then
            local copper = 0
            local _, _, g = strfind(arg1, "(%d+) Gold")
            local _, _, s = strfind(arg1, "(%d+) Silver")
            local _, _, c = strfind(arg1, "(%d+) Copper")
            if g then copper = copper + tonumber(g) * 10000 end
            if s then copper = copper + tonumber(s) * 100 end
            if c then copper = copper + tonumber(c) end
            if copper > 0 then
                sessionGold = sessionGold + copper
                local today = GetDateKey()
                local dayData = GetDailyEntry(today)
                dayData.gold = (dayData.gold or 0) + copper
                SaveSession()
                UpdateDisplay()
            end
        end

    elseif event == "MERCHANT_SHOW" then
        if IsInFarmingZone() then
            merchantOpenMoney = GetMoney()
        else
            merchantOpenMoney = nil
        end

    elseif event == "MERCHANT_CLOSED" then
        if merchantOpenMoney then
            local income = GetMoney() - merchantOpenMoney
            merchantOpenMoney = nil
            if income > 0 then
                sessionGold = sessionGold + income
                sessionVendorGold = sessionVendorGold + income
                local today = GetDateKey()
                local dayData = GetDailyEntry(today)
                dayData.gold = (dayData.gold or 0) + income
                dayData.vendorGold = (dayData.vendorGold or 0) + income
                SaveSession()
                UpdateDisplay()
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Vendor income: " .. FormatMoney(income))
            end
            -- Re-sync loginMoney baseline after vendor
            loginMoney = GetMoney() - sessionGold
        end

    elseif event == "BAG_UPDATE" then
        bagUpdateDirty = true

    elseif event == "BANKFRAME_OPENED" then
        bankIsOpen = true
        local bankCount = CountBankFragments()
        SaveCharacterCount(nil, bankCount)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffFragCounter:|r Bank scanned: " .. FormatNumber(bankCount) .. " fragments in bank.")
        UpdateDisplay()

    elseif event == "BANKFRAME_CLOSED" then
        bankIsOpen = false
        UpdateDisplay()

    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        if bankIsOpen then
            local bankCount = CountBankFragments()
            SaveCharacterCount(nil, bankCount)
            UpdateDisplay()
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        UpdateDisplay()
    end
end

local bankIsOpen = false

function FragCounter_OnUpdate()
    if bagUpdateDirty and addonLoaded then
        bagUpdateDirty = false
        local bagCount = CountBagFragments()
        SaveCharacterCount(bagCount, nil)
        -- Also re-scan bank if it's open (moving items between bags and bank)
        if bankIsOpen then
            local bankCount = CountBankFragments()
            SaveCharacterCount(nil, bankCount)
        end
        UpdateDisplay()
    end
end
