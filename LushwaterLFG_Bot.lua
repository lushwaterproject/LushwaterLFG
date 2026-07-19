-- LushwaterLFG_Bot — client side of the server bot "LushLFG".
-- The mangosd RDF module (src/game/Custom/Rdf.cpp) is the privileged executor:
-- it validates formed parties, teleports them into the dungeon and back out to
-- their saved locations, reports phase-open dungeons and pays completion
-- rewards. The addon talks to it over plain whispers; replies arrive as
-- CHAT_MSG_CHANNEL packets on the hidden LushLFG channel (removed from all
-- chat frames, so protocol traffic is invisible). Servers older than v0.5.1
-- answered with CHAT_MSG_MONSTER_WHISPER — that handler is kept as a fallback.
--
-- If the server feature is disabled or absent, every command simply gets no
-- useful reply and the addon degrades to v0.2 behavior ("Good Luck!").

LWLFG = LWLFG or {}
LWLFG.Bot = {}
local B = LWLFG.Bot

B.available  = false   -- any bot reply received this session
B.eligible   = nil     -- set of dungeon keys open for MY level+phase (nil = unknown)
B.phaseOpen  = nil     -- set of all phase-open dungeon keys (for the matcher)
B.reward     = nil     -- { xp=..., copper=... } completion-reward preview for me
B.ranges     = nil     -- server-authoritative level ranges: { key = { lo, hi } }

local BOT_NAME = LWLFG.BOT_NAME or "LushLFG"

function B.send(msg)
    SendChatMessage(msg, "WHISPER", nil, BOT_NAME)
end

function B.requestEligible()
    B.send("ELIGIBLE")
end

local function csvToSet(csv)
    local set = {}
    if csv and csv ~= "" then
        for _, k in ipairs(LWLFG.split(csv, ",")) do
            if k ~= "" then set[k] = true end
        end
    end
    return set
end

local FAIL_TEXT = {
    cooldown        = "Summoning is on cooldown, try again shortly.",
    unknown_dungeon = "Server does not recognize that dungeon.",
    not_leader      = "Only the party leader can summon the group.",
    need_full_party = "The party must have exactly 5 members.",
    phase           = "That dungeon is not unlocked in the current server phase.",
    no_entrance     = "Server has no entrance data for that dungeon.",
    member_offline  = "A party member is offline.",
    faction         = "Cross-faction groups cannot be summoned.",
    level           = "A party member is outside the dungeon's level range.",
    combat          = "A party member is in combat.",
    taxi            = "A party member is on a flight path.",
    busy            = "A party member is busy (already teleporting).",
    no_group        = "You have no active RDF group on the server.",
    not_inside      = "You are not inside the RDF dungeon.",
    already_inside  = "You are already inside the dungeon.",
    teleport        = "Teleport failed.",
}

function B.failText(reason)
    return FAIL_TEXT[reason] or ("Server error: " .. tostring(reason))
end

-- copper -> "1g 2s 3c" (omitting zero high denominations)
function B.formatMoney(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local rest = math.mod(copper, 100)
    if gold > 0 then
        return gold .. "g " .. silver .. "s " .. rest .. "c"
    elseif silver > 0 then
        return silver .. "s " .. rest .. "c"
    end
    return rest .. "c"
end

function B.onMessage(msg, sender)
    if sender ~= BOT_NAME then return end
    B.available = true

    local parts = LWLFG.split(msg, ":")
    local kind = parts[1]

    if kind == "ELIGIBLE" then
        B.eligible = csvToSet(parts[2])

    elseif kind == "PHASEOPEN" then
        B.phaseOpen = csvToSet(parts[2])

    elseif kind == "RANGES" then
        -- RANGES:<key>=<lo>-<hi>,... — server-authoritative dungeon level ranges
        local ranges = {}
        for _, pair in ipairs(LWLFG.split(parts[2] or "", ",")) do
            local kv = LWLFG.split(pair, "=")
            local lh = LWLFG.split(kv[2] or "", "-")
            local lo, hi = tonumber(lh[1]), tonumber(lh[2])
            if kv[1] and lo and hi then
                ranges[kv[1]] = { lo = lo, hi = hi }
            end
        end
        if next(ranges) then B.ranges = ranges end

    elseif kind == "REWARDINFO" then
        -- REWARDINFO:<xp>:<copper> — completion reward for my level/phase state
        B.reward = { xp = tonumber(parts[2]) or 0, copper = tonumber(parts[3]) or 0 }

    elseif kind == "SUMMON_OK" then
        LWLFG.print("|cffffd100Teleported to " .. (parts[3] or parts[2] or "the dungeon")
            .. "!|r Use |cff7fd6a8Teleport out|r to return to your previous location.")
        if LWLFG.Queue.onSummoned then LWLFG.Queue.onSummoned(parts[2]) end

    elseif kind == "SUMMON_FAIL" then
        LWLFG.print("Summon failed: " .. B.failText(parts[2]))
        if LWLFG.Queue.onSummonFail then LWLFG.Queue.onSummonFail(parts[2]) end

    elseif kind == "PORT_OUT_OK" then
        LWLFG.print("Teleported back to your previous location.")
        if LWLFG.Queue.onPortedOut then LWLFG.Queue.onPortedOut() end

    elseif kind == "PORT_IN_OK" then
        LWLFG.print("Teleported back into the dungeon.")
        if LWLFG.Queue.onPortedIn then LWLFG.Queue.onPortedIn(parts[2]) end

    elseif kind == "JOIN_OK" then
        -- JOIN_OK:<key>:<name> — replacement recorded + teleported into the run
        LWLFG.print("|cffffd100Teleported into " .. (parts[3] or "the dungeon")
            .. "!|r Use |cff7fd6a8Teleport out|r to return to your previous location.")
        if LWLFG.Queue.onPortedIn then LWLFG.Queue.onPortedIn(parts[2]) end

    elseif kind == "PORT_FAIL" then
        LWLFG.print("Teleport failed: " .. B.failText(parts[2]))

    elseif kind == "REWARD" then
        -- REWARD:<key>:<xp>:<copper> — completion bonus for killing the final boss
        local xp = tonumber(parts[3]) or 0
        local copper = tonumber(parts[4]) or 0
        local bits = {}
        if xp > 0 then table.insert(bits, "|cff7fd6a8" .. xp .. " bonus experience|r") end
        if copper > 0 then table.insert(bits, "|cffffd100" .. B.formatMoney(copper) .. "|r") end
        if table.getn(bits) > 0 then
            local msg = "Dungeon complete! Reward: " .. bits[1]
            if bits[2] then msg = msg .. " and " .. bits[2] end
            LWLFG.print(msg .. ".")
        end
        if LWLFG.Queue.onReward then LWLFG.Queue.onReward() end
        if LWLFG.UI and LWLFG.UI.showComplete then LWLFG.UI.showComplete(parts[2]) end

    elseif kind == "UNAVAILABLE" then
        B.available = false
        LWLFG.print("Server-side dungeon teleports are currently disabled.")
    end

    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end
