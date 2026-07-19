-- LushwaterLFG (core) — Looking For Group / Random Dungeon Finder for WoW 1.12.1
-- Pure 1.12 API: no SendAddonMessage, no client patches. Comms run over a hidden
-- custom chat channel ("LushLFG"), the same pattern as the LFT addon for Turtle WoW.
-- Grouping is same-faction only: every protocol message is tagged with the sender's
-- faction (UnitFactionGroup) and non-matching entries are filtered out. The CMaNGOS
-- server also rejects cross-faction invites (AllowTwoSide.Interaction.Group = 0).
--
-- File load order (.toc): core -> Queue -> Match -> UI.

LWLFG = LWLFG or {}   -- global namespace shared by all addon files

LWLFG.ADDON_VERSION = "1.0"
LWLFG.CHANNEL_NAME  = "LushLFG"
LWLFG.BOT_NAME      = "LushLFG"   -- server whisper/channel bot identity
LWLFG.MSG_PREFIX    = "LW"          -- every protocol message starts with "LW:"
local ENTRY_TTL     = 300           -- seconds before a stale specific-queue listing expires
local SEND_SPACING  = 2.0           -- min seconds between outgoing channel messages (throttle)

LWLFG.me       = UnitName("player")
LWLFG.myFaction = nil               -- "Alliance" / "Horde" (resolved on entering world)

-- UnitFactionGroup("player") returns nil for some characters (observed on a
-- GM character); UnitRace is a reliable fallback. Both spellings seen in
-- the wild are mapped ("NightElf"/"Night Elf", "Undead"/"Scourge").
local RACE_FACTION = {
    Human = "Alliance", Dwarf = "Alliance", Gnome = "Alliance",
    NightElf = "Alliance", ["Night Elf"] = "Alliance",
    Orc = "Horde", Troll = "Horde", Tauren = "Horde",
    Undead = "Horde", Scourge = "Horde",
}
function LWLFG.detectFaction()
    local f = UnitFactionGroup("player")
    if not f then
        local race = UnitRace("player")
        f = race and RACE_FACTION[race]
    end
    return f
end

-- ---------------------------------------------------------------------------
-- Static data
-- ---------------------------------------------------------------------------

-- Vanilla dungeon list. key = protocol code, lo/hi = suggested level range.
LWLFG.DUNGEONS = {
    { key = "RFC",  name = "Ragefire Chasm",        lo = 13, hi = 18 },
    { key = "WC",   name = "Wailing Caverns",       lo = 17, hi = 24 },
    { key = "VC",   name = "The Deadmines",         lo = 17, hi = 26 },
    { key = "SFK",  name = "Shadowfang Keep",       lo = 22, hi = 30 },
    { key = "BFD",  name = "Blackfathom Deeps",     lo = 24, hi = 32 },
    { key = "STK",  name = "Stormwind Stockades",   lo = 24, hi = 32 },
    { key = "GNO",  name = "Gnomeregan",            lo = 29, hi = 38 },
    { key = "RFK",  name = "Razorfen Kraul",        lo = 29, hi = 38 },
    { key = "SM",   name = "Scarlet Monastery",     lo = 34, hi = 45 },
    { key = "RFD",  name = "Razorfen Downs",        lo = 37, hi = 46 },
    { key = "ULD",  name = "Uldaman",               lo = 41, hi = 51 },
    { key = "ZF",   name = "Zul'Farrak",            lo = 44, hi = 54 },
    { key = "MAR",  name = "Maraudon",              lo = 46, hi = 55 },
    { key = "ST",   name = "Sunken Temple",         lo = 50, hi = 60 },
    { key = "BRD",  name = "Blackrock Depths",      lo = 52, hi = 60 },
    { key = "LBRS", name = "Lower Blackrock Spire", lo = 55, hi = 60 },
    { key = "DM",   name = "Dire Maul",             lo = 55, hi = 60 },
    { key = "SCHO", name = "Scholomance",           lo = 58, hi = 60 },
    { key = "STRAT",name = "Stratholme",            lo = 58, hi = 60 },
    { key = "UBRS", name = "Upper Blackrock Spire", lo = 58, hi = 60 },
}

LWLFG.ROLES = { "TANK", "HEAL", "DPS" }

-- Which roles a class may pick (conservative, vanilla-style).
LWLFG.CLASS_ROLES = {
    WARRIOR = { TANK = true, DPS = true },
    PALADIN = { TANK = true, HEAL = true, DPS = true },
    DRUID   = { TANK = true, HEAL = true, DPS = true },
    PRIEST  = { HEAL = true, DPS = true },
    SHAMAN  = { HEAL = true, DPS = true },
    MAGE    = { DPS = true },
    HUNTER  = { DPS = true },
    WARLOCK = { DPS = true },
    ROGUE   = { DPS = true },
}

LWLFG.CLASS_COLORS = {
    WARRIOR = "|cffc79c6e", PALADIN = "|cfff58cba", HUNTER  = "|cffabd473",
    ROGUE   = "|cfffff569", PRIEST  = "|cffffffff", SHAMAN  = "|cff0070de",
    MAGE    = "|cff69ccf0", WARLOCK = "|cff9482c9", DRUID   = "|cffff7d0a",
}

-- ---------------------------------------------------------------------------
-- State (shared)
-- ---------------------------------------------------------------------------

LWLFG.settings     = nil            -- SavedVariables mirror (see ADDON_LOADED)
LWLFG.channelIndex = 0
LWLFG.sendQueue    = {}
LWLFG.lastSend     = 0
LWLFG.handlers     = {}             -- protocol kind -> function(parts, sender)

-- Specific-queue (v1) state
LWLFG.specificQueued = false
LWLFG.specificEntries = {}          -- [name] = { faction, level, class, role, dungeons, seen }
LWLFG.lastSpecificBeat = 0
local SPECIFIC_HEARTBEAT = 90

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function LWLFG.print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fd6a8[LushwaterLFG]|r " .. msg)
end

-- Lua 5.0 compatible splitter (no string.gmatch in 1.12).
function LWLFG.split(str, sep)
    local out, pos = {}, 1
    while true do
        local s, e = string.find(str, sep, pos, true)
        if not s then
            table.insert(out, string.sub(str, pos))
            return out
        end
        table.insert(out, string.sub(str, pos, s - 1))
        pos = e + 1
    end
end

-- table.concat is Lua 5.1; the 1.12 client ships 5.0 without it.
function LWLFG.joinKeys(keys, sep)
    local out = ""
    for i, k in ipairs(keys) do
        out = (i == 1) and k or (out .. sep .. k)
    end
    return out
end

function LWLFG.myClassToken()
    local _, c = UnitClass("player")   -- english token, e.g. "WARRIOR"
    return c or "WARRIOR"
end

function LWLFG.roleAllowed(role)
    local allowed = LWLFG.CLASS_ROLES[LWLFG.myClassToken()]
    return allowed and allowed[role]
end

function LWLFG.dungeonName(key)
    for _, d in ipairs(LWLFG.DUNGEONS) do
        if d.key == key then return d.name end
    end
    return key
end

-- Level range for a dungeon key: server-authoritative once the bot answers
-- RANGES, static DUNGEONS table otherwise (old/absent server fallback).
function LWLFG.dungeonRange(key)
    if LWLFG.Bot and LWLFG.Bot.ranges and LWLFG.Bot.ranges[key] then
        local r = LWLFG.Bot.ranges[key]
        return r.lo, r.hi
    end
    for _, d in ipairs(LWLFG.DUNGEONS) do
        if d.key == key then return d.lo, d.hi end
    end
    return nil
end

-- True if the given player name is in the current party (including self).
function LWLFG.isInParty(name)
    if not name or name == LWLFG.me then return true end
    local n = GetNumPartyMembers()
    if n == 0 then return false end
    for i = 1, n do
        if UnitName("party" .. i) == name then
            return true
        end
    end
    return false
end

-- Dungeon keys whose suggested level range contains the given level.
-- When the server bot has answered ELIGIBLE and the level is our own, the
-- list is intersected with the server's level+phase-open set.
function LWLFG.eligibleDungeons(level)
    local out = {}
    for _, d in ipairs(LWLFG.DUNGEONS) do
        local lo, hi = LWLFG.dungeonRange(d.key)
        if lo and level >= lo and level <= hi then
            table.insert(out, d.key)
        end
    end
    if LWLFG.Bot and LWLFG.Bot.eligible and level == UnitLevel("player") then
        local filtered = {}
        for _, k in ipairs(out) do
            if LWLFG.Bot.eligible[k] then table.insert(filtered, k) end
        end
        return filtered
    end
    return out
end

-- True if a dungeon is accessible to the player at the given level.
-- Falls back to the static DUNGEONS range when the server bot hasn't answered.
function LWLFG.isDungeonEligible(key, level)
    local lo, hi = LWLFG.dungeonRange(key)
    if not lo or level < lo or level > hi then return false end
    if LWLFG.Bot and LWLFG.Bot.eligible and level == UnitLevel("player") then
        return LWLFG.Bot.eligible[key] and true or false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Outgoing channel traffic (throttled)
-- ---------------------------------------------------------------------------

function LWLFG.enqueueSend(msg)
    table.insert(LWLFG.sendQueue, msg)
end

local function flushSendQueue()
    if table.getn(LWLFG.sendQueue) == 0 then return end
    if LWLFG.channelIndex == 0 then return end
    if GetTime() - LWLFG.lastSend < SEND_SPACING then return end
    local msg = table.remove(LWLFG.sendQueue, 1)
    SendChatMessage(msg, "CHANNEL", nil, LWLFG.channelIndex)
    LWLFG.lastSend = GetTime()
end

-- ---------------------------------------------------------------------------
-- Specific-queue (v1 protocol, kept for the "Specific" tab)
-- ---------------------------------------------------------------------------

local function selectedDungeons()
    local keys = {}
    for _, d in ipairs(LWLFG.DUNGEONS) do
        if LWLFG.settings.dungeons[d.key] then
            table.insert(keys, d.key)
        end
    end
    return keys
end

-- canonical "+"-joined role set for the specific queue (TANK+HEAL+DPS order;
-- old peers display the raw joined string, new ones prettify to "TANK/HEAL")
function LWLFG.specRoleString()
    local out = {}
    for _, r in ipairs(LWLFG.ROLES) do
        if LWLFG.settings.specRoles[r] then table.insert(out, r) end
    end
    if table.getn(out) == 0 then return "DPS" end
    return table.concat(out, "+")
end

function LWLFG.toggleSpecRole(role)
    local s = LWLFG.settings.specRoles
    if s[role] then
        s[role] = nil
        if not next(s) then   -- never allow an empty role set
            s[role] = true
            LWLFG.print("Pick at least one role.")
        end
    else
        s[role] = true
    end
    if LWLFG.specificQueued then LWLFG.broadcastSpecific() end
    if LWLFG.UI and LWLFG.UI.refreshRoleButtons then LWLFG.UI.refreshRoleButtons() end
end

function LWLFG.broadcastSpecific()
    if not LWLFG.specificQueued or not LWLFG.myFaction then return end
    local keys = selectedDungeons()
    if table.getn(keys) == 0 then return end
    local level = UnitLevel("player")
    local eligible = {}
    for _, k in ipairs(keys) do
        if LWLFG.isDungeonEligible(k, level) then table.insert(eligible, k) end
    end
    if table.getn(eligible) == 0 then return end
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":LFG:" .. LWLFG.myFaction .. ":"
        .. level .. ":" .. LWLFG.myClassToken() .. ":"
        .. LWLFG.specRoleString() .. ":" .. LWLFG.joinKeys(eligible, ","))
end

function LWLFG.toggleSpecificQueue()
    if LWLFG.specificQueued then
        LWLFG.specificQueued = false
        LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":LEAVE")
        LWLFG.print("Left the specific-dungeon queue.")
    else
        local keys = selectedDungeons()
        if table.getn(keys) == 0 then
            LWLFG.print("Pick at least one dungeon first.")
            return
        end
        local level = UnitLevel("player")
        local bad = {}
        for _, k in ipairs(keys) do
            if not LWLFG.isDungeonEligible(k, level) then
                table.insert(bad, LWLFG.dungeonName(k))
                LWLFG.settings.dungeons[k] = nil
            end
        end
        if table.getn(bad) > 0 then
            LWLFG.print("Cannot queue for " .. table.concat(bad, ", ")
                .. " at your level.")
            if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
            return
        end
        LWLFG.specificQueued = true
        LWLFG.lastSpecificBeat = 0
        LWLFG.broadcastSpecific()
        LWLFG.print("Queued (specific) as "
            .. string.gsub(LWLFG.specRoleString(), "%+", "/") .. ".")
    end
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

LWLFG.handlers["LFG"] = function(parts, sender)
    if parts[3] ~= LWLFG.myFaction then return end    -- same-faction filter
    LWLFG.specificEntries[sender] = {
        faction  = parts[3],
        level    = tonumber(parts[4]) or 0,
        class    = parts[5] or "WARRIOR",
        role     = parts[6] or "DPS",
        dungeons = parts[7] or "",
        seen     = GetTime(),
    }
    if LWLFG.UI and LWLFG.UI.refreshResults then LWLFG.UI.refreshResults() end
end

LWLFG.handlers["LEAVE"] = function(parts, sender)
    LWLFG.specificEntries[sender] = nil
    if LWLFG.UI and LWLFG.UI.refreshResults then LWLFG.UI.refreshResults() end
end

LWLFG.handlers["PING"] = function(parts, sender)
    if LWLFG.specificQueued then LWLFG.broadcastSpecific() end
    if LWLFG.Queue and LWLFG.Queue.onPing then LWLFG.Queue.onPing() end
end

-- Expire stale specific-queue listings.
local function sweepSpecific()
    local now = GetTime()
    for name, e in pairs(LWLFG.specificEntries) do
        if now - e.seen > ENTRY_TTL then
            LWLFG.specificEntries[name] = nil
        end
    end
end
LWLFG.sweepSpecific = sweepSpecific

-- ---------------------------------------------------------------------------
-- Channel management (join must be deferred until after PLAYER_ENTERING_WORLD)
-- ---------------------------------------------------------------------------

local joinState = { pending = false, elapsed = 0 }

local function ensureChannel()
    if GetChannelName(LWLFG.CHANNEL_NAME) == 0 then
        -- join WITHOUT attaching to any chat frame (nil frame id) so no
        -- "Joined Channel" notice appears; the RemoveChannel loop below is
        -- belt-and-braces for clients where the nil is ignored
        JoinChannelByName(LWLFG.CHANNEL_NAME, nil, nil)
    end
    LWLFG.channelIndex = GetChannelName(LWLFG.CHANNEL_NAME)
    if LWLFG.channelIndex > 0 then
        -- hide the protocol channel from every chat frame: CHAT_MSG_CHANNEL
        -- still fires for our handlers, but nothing shows in chat (no join
        -- notices, no LW:PING spam, no bot replies)
        for i = 1, NUM_CHAT_WINDOWS do
            local cf = getglobal("ChatFrame" .. i)
            if cf then ChatFrame_RemoveChannel(cf, LWLFG.CHANNEL_NAME) end
        end
        -- ask everyone already queued to re-broadcast so our lists fill up
        LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":PING")
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local ev = CreateFrame("Frame", "LushwaterLFGFrame")
LWLFG.frame = ev

ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_CHANNEL")
ev:RegisterEvent("PARTY_INVITE_REQUEST")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("CHAT_MSG_MONSTER_WHISPER")

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "LushwaterLFG" then
        if not LWLFG_Settings then LWLFG_Settings = {} end
        local s = LWLFG_Settings
        if not s.dungeons then s.dungeons = {} end
        if not s.rqRoles then s.rqRoles = { DPS = true } end
        if not s.deserterUntil then s.deserterUntil = 0 end
        if not s.tab then s.tab = "random" end
        -- specific-queue roles are a multi-select SET (migrated from the
        -- old single s.role); must never be empty or class-impossible
        if not s.specRoles then s.specRoles = { [s.role or "DPS"] = true } end
        s.role = nil
        LWLFG.settings = s
        local anySpec = false
        for r in pairs(s.specRoles) do
            if LWLFG.roleAllowed(r) then anySpec = true else s.specRoles[r] = nil end
        end
        if not anySpec then s.specRoles.DPS = true end

        if LWLFG.Queue and LWLFG.Queue.onLoad then LWLFG.Queue.onLoad() end
        if LWLFG.Match and LWLFG.Match.onLoad then LWLFG.Match.onLoad() end
        if LWLFG.UI and LWLFG.UI.build then LWLFG.UI.build() end

        SLASH_LWLFG1 = "/lwlfg"
        SlashCmdList["LWLFG"] = function(msg)
            if msg == "debug" then
                local B = LWLFG.Bot
                local rw = B and B.reward
                local nElig = 0
                if B and B.eligible then for _ in pairs(B.eligible) do nElig = nElig + 1 end end
                LWLFG.print("channel index: " .. tostring(GetChannelName(LWLFG.CHANNEL_NAME)))
                LWLFG.print("faction: " .. tostring(LWLFG.myFaction))
                LWLFG.print("bot available: " .. tostring(B and B.available))
                LWLFG.print("eligible dungeons: " .. nElig
                    .. "  reward: xp=" .. tostring(rw and rw.xp)
                    .. " copper=" .. tostring(rw and rw.copper))
                -- what the art probe actually found (missing LFT files read
                -- as nil -> that UI element falls back to stock art)
                local A = LWLFG.ART
                if A then
                    local nb, ni = 0, 0
                    for _ in pairs(A.bg or {}) do nb = nb + 1 end
                    for _ in pairs(A.icon or {}) do ni = ni + 1 end
                    LWLFG.print("art: frame=" .. tostring(A.frame)
                        .. " tabs=" .. tostring(A.tabs)
                        .. " roles=" .. tostring(A.roles)
                        .. " eyeFrames=" .. table.getn(A.eyeFrames or {})
                        .. " bg=" .. nb .. " icons=" .. ni
                        .. " readyArt=" .. tostring(A.readyArt)
                        .. " complete=" .. tostring(A.complete))
                else
                    LWLFG.print("art: probe did not run")
                end
                LWLFG.debugChan = not LWLFG.debugChan
                LWLFG.print("raw CHAT_MSG_CHANNEL logging: "
                    .. (LWLFG.debugChan and "ON (spammy!)" or "OFF"))
                return
            end
            if LWLFG.UI then LWLFG.UI.toggle() end
        end
        LWLFG.print("v" .. LWLFG.ADDON_VERSION .. " loaded — /lwlfg to open.")
        pcall(math.randomseed, time())

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- UnitName("player") can be nil or "Unknown Entity" at file-load time;
        -- re-capture it here. The matcher election and the self-message filter
        -- both compare against LWLFG.me — a bogus value DEADLOCKS the election
        -- (own RQ isn't filtered, own pool entry lands under the wrong name,
        -- amIMatcher is false everywhere, nobody ever proposes).
        local realName = UnitName("player")
        if realName and realName ~= LWLFG.me then
            if LWLFG.me and LWLFG.Queue and LWLFG.Queue.entries
                and LWLFG.Queue.entries[LWLFG.me] then
                -- migrate a self pool entry created under the bogus name
                LWLFG.Queue.entries[realName] = LWLFG.Queue.entries[LWLFG.me]
                LWLFG.Queue.entries[LWLFG.me] = nil
            end
            LWLFG.me = realName
        end
        -- UnitFactionGroup can return nil; detectFaction falls back to race
        LWLFG.myFaction = LWLFG.myFaction or LWLFG.detectFaction()
        if LWLFG.UI and LWLFG.UI.onEnteringWorld then LWLFG.UI.onEnteringWorld() end
        joinState.pending = true
        joinState.elapsed = 0

    elseif event == "CHAT_MSG_CHANNEL" then
        -- arg1 = message, arg2 = sender, arg8 = channel index, arg9 = channel name
        if LWLFG.debugChan then
            LWLFG.print("CHAN idx=" .. tostring(arg8) .. " name=" .. tostring(arg9)
                .. " msg=" .. tostring(arg1))
        end
        if arg9 == LWLFG.CHANNEL_NAME
            or (LWLFG.channelIndex and LWLFG.channelIndex > 0
                and arg8 == LWLFG.channelIndex) then
            local parts = LWLFG.split(arg1, ":")
            if parts[1] == LWLFG.MSG_PREFIX then
                -- peer-to-peer protocol (never from ourselves)
                if arg2 ~= LWLFG.me then
                    local h = LWLFG.handlers[parts[2] or ""]
                    if h then h(parts, arg2) end
                end
            else
                -- server bot reply: the server fakes these CHAT_MSG_CHANNEL
                -- packets with OUR OWN GUID as sender (an unresolvable GUID
                -- would make the client hold the message forever), so genuine
                -- bot traffic always arrives self-addressed (arg2 == own
                -- name). Non-LW: channel messages from anyone else can only be
                -- a forgery attempt — drop them.
                if arg2 == LWLFG.me and LWLFG.Bot then
                    LWLFG.Bot.onMessage(arg1, LWLFG.BOT_NAME)
                end
            end
        end

    elseif event == "PARTY_INVITE_REQUEST" then
        -- arg1 = inviter name
        if LWLFG.Queue and LWLFG.Queue.onPartyInvite then
            LWLFG.Queue.onPartyInvite(arg1)
        end

    elseif event == "PARTY_MEMBERS_CHANGED" then
        if LWLFG.Queue and LWLFG.Queue.onPartyChanged then
            LWLFG.Queue.onPartyChanged()
        end

    elseif event == "PLAYER_LEVEL_UP" then
        -- level change may alter dungeon eligibility; refresh announcements
        if LWLFG.specificQueued then LWLFG.broadcastSpecific() end
        if LWLFG.Queue and LWLFG.Queue.onLevelUp then LWLFG.Queue.onLevelUp() end
        if LWLFG.Bot then LWLFG.Bot.requestEligible() end

    elseif event == "CHAT_MSG_MONSTER_WHISPER" then
        -- legacy bot transport (pre-v0.5.1 servers): arg2 = embedded sender name
        if LWLFG.Bot then LWLFG.Bot.onMessage(arg1, arg2) end
    end
end)

-- Deferred channel join + heartbeats + send-queue pump + module ticks
ev:SetScript("OnUpdate", function()
    local elapsed = arg1 or 0.05

    if joinState.pending then
        joinState.elapsed = joinState.elapsed + elapsed
        if joinState.elapsed > 5 then       -- give the default channels time to settle
            joinState.pending = false
            ensureChannel()
            if LWLFG.Bot then LWLFG.Bot.requestEligible() end
        end
    end

    flushSendQueue()

    -- keep the server's eligibility/phase/range view fresh (phase rollover,
    -- reward preview): one whisper every 5 minutes is negligible
    if LWLFG.Bot and GetTime() - (LWLFG.lastEligPoll or 0) > 300 then
        LWLFG.lastEligPoll = GetTime()
        LWLFG.Bot.requestEligible()
    end

    -- specific-queue heartbeat
    if LWLFG.specificQueued then
        if GetTime() - LWLFG.lastSpecificBeat > SPECIFIC_HEARTBEAT then
            LWLFG.lastSpecificBeat = GetTime()
            LWLFG.broadcastSpecific()
        end
    end

    if LWLFG.Queue and LWLFG.Queue.tick then LWLFG.Queue.tick(elapsed) end
    if LWLFG.Match and LWLFG.Match.tick then LWLFG.Match.tick(elapsed) end
    if LWLFG.UI and LWLFG.UI.tick then LWLFG.UI.tick(elapsed) end
end)
