-- LushwaterLFG_Match — decentralized matchmaking for the random queue.
--
-- Matcher election is deterministic: the queued player with the lexicographically
-- smallest name is the matcher. Every client computes this from the same shared
-- queue view, so exactly one client emits proposals. If the matcher leaves the
-- queue (RQLEAVE / TTL), the next name takes over automatically.
--
-- Flow: matcher emits PROP -> members respond READY -> matcher emits FORM ->
-- leader invites, members auto-accept (handled in Queue).

LWLFG = LWLFG or {}
LWLFG.Match = {}
local M = LWLFG.Match
local Q = nil   -- set on load

local TICK_INTERVAL   = 5     -- matcher attempts a match every N seconds
local READY_WINDOW    = 35    -- matcher waits this long for READY responses
local INVITE_SPACING  = 1.5   -- seconds between leader's InviteByName calls
local NEED_TTL        = 120   -- seconds before an unanswered NEED is dropped

M.lastTick   = 0
M.pending    = nil   -- matcher-side proposal: { id, dungeon, members={name=role},
                     --                        responses={name=bool}, created }
M.inviteList = nil   -- leader-side: { names..., index, nextAt, leader }
M.needs      = {}    -- in-progress parties wanting a replacement:
                     --   [leader] = { dungeon, roles={set}, seen, failed={set} }
M.pendingR   = nil   -- matcher-side replacement proposal:
                     --   { id, leader, dungeon, name, role, created }
M.leaderPending = nil   -- leader-side: { id, name } candidate found for our party

function M.onLoad()
    Q = LWLFG.Queue
end

-- ---------------------------------------------------------------------------
-- Election
-- ---------------------------------------------------------------------------

local function matcherName()
    local best = nil
    for name, _ in pairs(Q.entries) do
        if not best or name < best then best = name end
    end
    return best
end

function M.amIMatcher()
    if Q.status ~= "QUEUED" and Q.status ~= "PROPOSED" then return false end
    return matcherName() == LWLFG.me
end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- Intersect two dungeon-key sets; returns a SET (possibly empty). The result
-- is fed back in as setB on the next bt slot — building it as an array
-- ({1="WC",2="VC"}) would make the next iteration test keys 1,2 (which match
-- no dungeon) and silently collapse the intersection to empty.
local function intersectDungeons(setA, setB)
    local out = {}
    for k, _ in pairs(setA) do
        if setB[k] then out[k] = true end
    end
    return out
end

local function eligibleSet(level)
    local s = {}
    for _, k in ipairs(LWLFG.eligibleDungeons(level)) do
        -- the elected matcher avoids phase-locked dungeons once the server
        -- bot has told us the global phase-open set
        if not LWLFG.Bot or not LWLFG.Bot.phaseOpen or LWLFG.Bot.phaseOpen[k] then
            s[k] = true
        end
    end
    return s
end

-- Try to assign 5 players from the pool to TANK/HEAL/DPSx3 with a non-empty
-- common dungeon intersection. Backtracking over slots; pools are small.
-- Returns members {name=role} + dungeon list, or nil.
local SLOTS = { "TANK", "HEAL", "DPS", "DPS", "DPS" }

local function tryMatch()
    -- Build candidate list sorted by firstSeen (oldest waited longest).
    -- Ourselves only while QUEUED: our own pool entry stays fresh in PROPOSED
    -- too, but a busy matcher (e.g. candidate in a replacement proposal) must
    -- not be matched into another proposal.
    local cands = {}
    for name, e in pairs(Q.entries) do
        if name ~= LWLFG.me or Q.status == "QUEUED" then
            table.insert(cands, {
                name  = name,
                roles = e.roles,
                dset  = eligibleSet(e.level),
                seen  = e.firstSeen or e.seen,
            })
        end
    end
    if table.getn(cands) < 5 then return nil end
    table.sort(cands, function(a, b) return a.seen < b.seen end)

    local assign = {}      -- slot -> candidate index
    local used   = {}      -- candidate index -> bool
    local common = nil     -- running dungeon intersection (set)

    local function bt(slot)
        if slot > 5 then return true end
        local role = SLOTS[slot]
        for i = 1, table.getn(cands) do
            local c = cands[i]
            if not used[i] and c.roles[role] then
                local inter = common and intersectDungeons(common, c.dset) or c.dset
                -- inter is a string-keyed SET on slot 1 (c.dset): table.getn
                -- counts array entries only and returns 0 for sets in Lua 5.0
                if next(inter) then
                    used[i] = true
                    assign[slot] = i
                    local saved = common
                    common = inter
                    if bt(slot + 1) then return true end
                    common = saved
                    assign[slot] = nil
                    used[i] = nil
                end
            end
        end
        return false
    end

    if not bt(1) then return nil end

    local members, names = {}, {}
    for slot = 1, 5 do
        local c = cands[assign[slot]]
        members[c.name] = SLOTS[slot]
        table.insert(names, c.name)
    end
    return members, names, common
end

-- ---------------------------------------------------------------------------
-- Replacement matching (in-progress parties)
-- ---------------------------------------------------------------------------

-- Oldest-waiting queued player whose roles cover a missing role and whose
-- level fits the dungeon (server-authoritative range once RANGES arrives);
-- candidates that already failed this need are skipped.
-- Returns leader, need, { name, role } or nil.
local function tryMatchReplacement()
    for leader, need in pairs(M.needs) do
        local lo, hi = LWLFG.dungeonRange(need.dungeon)
        if lo then
            local best = nil
            for name, e in pairs(Q.entries) do
                if (name ~= LWLFG.me or Q.status == "QUEUED")
                    and not need.failed[name]
                    and e.level >= lo and e.level <= hi then
                    for _, r in ipairs(LWLFG.ROLES) do
                        if need.roles[r] and e.roles[r] then
                            local seen = e.firstSeen or e.seen
                            if not best or seen < best.seen then
                                best = { name = name, role = r, seen = seen }
                            end
                            break
                        end
                    end
                end
            end
            if best then return leader, need, best end
        end
    end
    return nil
end

local function issueReplacement()
    local leader, need, cand = tryMatchReplacement()
    if not leader then return end

    local id = leader .. "-R" .. time()
    M.pendingR = { id = id, leader = leader, dungeon = need.dungeon,
                   name = cand.name, role = cand.role, created = GetTime() }
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":RPROP:" .. id .. ":" .. leader .. ":"
        .. need.dungeon .. ":" .. cand.name .. "=" .. cand.role)

    -- the channel drops our own messages: a matcher matched as candidate
    -- handles its proposal locally
    if cand.name == LWLFG.me then
        Q.startRprop(id, leader, need.dungeon, cand.role)
    end
end

-- The candidate's own RREADY never comes back over the channel when they are
-- the matcher (same self-message drop as onLocalReady).
function M.onLocalRready(id, accept)
    if not M.pendingR or M.pendingR.id ~= id then return end
    if not accept and M.needs[M.pendingR.leader] then
        M.needs[M.pendingR.leader].failed[LWLFG.me] = true
    end
    M.pendingR = nil
end

-- ---------------------------------------------------------------------------
-- Matcher-side proposal handling
-- ---------------------------------------------------------------------------

local function issueProposal()
    local members, names, common = tryMatch()
    if not members then return end

    local dungeonList = {}
    for k, _ in pairs(common) do table.insert(dungeonList, k) end
    local dungeon = dungeonList[math.random(table.getn(dungeonList))]

    local id = LWLFG.me .. "-" .. time()
    local memberStrs = {}
    for name, role in pairs(members) do
        table.insert(memberStrs, name .. "=" .. role)
    end

    M.pending = {
        id = id, dungeon = dungeon, members = members,
        responses = {}, created = GetTime(),
    }
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":PROP:" .. id .. ":" .. dungeon
        .. ":" .. LWLFG.joinKeys(memberStrs, ","))

    -- The matcher may be part of its own proposal: treat locally.
    if members[LWLFG.me] then
        Q.propId = id
        Q.propRole = members[LWLFG.me]
        Q.propDungeon = dungeon
        Q.propMembers = members
        Q.propSince = GetTime()
        Q.status = "PROPOSED"
        if LWLFG.UI then LWLFG.UI.showReady(dungeon, Q.propRole) end
        Q.readyStart()
    end
end

local function concludeProposal(success)
    if not M.pending then return end
    local p = M.pending
    M.pending = nil

    if not success then
        -- accepters never left the queue; decliner removed itself already
        LWLFG.print("A group member declined or timed out — matchmaking continues.")
        if Q.status == "PROPOSED" and Q.propId == p.id then
            Q.status = "QUEUED"
            Q.propId = nil
        end
        return
    end

    -- leader: the tank if there is one, else alphabetically first member
    local leader = nil
    for name, role in pairs(p.members) do
        if role == "TANK" then leader = name end
    end
    if not leader then
        for name, _ in pairs(p.members) do
            if not leader or name < leader then leader = name end
        end
    end

    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":FORM:" .. p.id .. ":" .. leader)
    LWLFG.print("Group ready for " .. LWLFG.dungeonName(p.dungeon)
        .. " — " .. leader .. " is forming the party!")

    if p.members[LWLFG.me] then
        Q.startForming(p.id, p.dungeon, p.members, leader)
        if leader == LWLFG.me then
            M.beginInvites(p.members, leader)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Leader-side invites
-- ---------------------------------------------------------------------------

function M.beginInvites(members, leader)
    if leader ~= LWLFG.me then return end
    if M.inviteList then
        -- already in progress; don't restart
        return
    end
    M.inviteList = { index = 1, nextAt = GetTime(), names = {} }
    for name, _ in pairs(members) do
        if name ~= LWLFG.me then
            table.insert(M.inviteList.names, name)
        end
    end
    table.sort(M.inviteList.names)
end

local function pumpInvites()
    if not M.inviteList then return end
    local il = M.inviteList
    if GetTime() < il.nextAt then return end
    -- Party full: stop pumping to avoid a late duplicate invite after teleport.
    if GetNumPartyMembers() >= 4 then
        M.inviteList = nil
        return
    end
    if il.index > table.getn(il.names) then
        M.inviteList = nil
        return
    end
    local target = il.names[il.index]
    -- Don't re-invite someone who has already joined (e.g. their acceptance
    -- outran the next pump tick). Move on and try the next slot.
    if LWLFG.isInParty(target) then
        il.index = il.index + 1
        il.nextAt = GetTime() + INVITE_SPACING
        return
    end
    InviteByName(target)
    il.index = il.index + 1
    il.nextAt = GetTime() + INVITE_SPACING
end

-- ---------------------------------------------------------------------------
-- Incoming protocol
-- ---------------------------------------------------------------------------

LWLFG.handlers["PROP"] = function(parts, sender)
    if sender ~= matcherName() then return end      -- only the elected matcher may propose
    if Q.status ~= "QUEUED" then return end          -- ignore if we are busy/idle

    local id = parts[3]
    local dungeon = parts[4]
    local members = {}
    local mine = nil
    for _, pair in ipairs(LWLFG.split(parts[5] or "", ",")) do
        local kv = LWLFG.split(pair, "=")
        if kv[1] and kv[2] then
            members[kv[1]] = kv[2]
            if kv[1] == LWLFG.me then mine = kv[2] end
        end
    end
    if not mine then return end                      -- proposal doesn't include us

    Q.propId = id
    Q.propRole = mine
    Q.propDungeon = dungeon
    Q.propMembers = members
    Q.propSince = GetTime()
    Q.status = "PROPOSED"
    if LWLFG.UI then LWLFG.UI.showReady(dungeon, mine) end
    Q.readyStart()
end

LWLFG.handlers["READY"] = function(parts, sender)
    -- every client sees READY broadcasts: feed the ready-check status strip
    if parts[3] == Q.propId then
        Q.readyMark(sender, parts[4] == "ACCEPT")
    end
    if not M.pending then return end
    if parts[3] ~= M.pending.id then return end
    if not M.pending.members[sender] then return end

    local accept = (parts[4] == "ACCEPT")
    M.pending.responses[sender] = accept
    if not accept then
        concludeProposal(false)
        return
    end
    -- all accepted?
    for name, _ in pairs(M.pending.members) do
        if M.pending.responses[name] ~= true then return end
    end
    concludeProposal(true)
end

-- Core ignores our own channel messages, so when the matcher is part of its
-- own proposal its READY must be recorded locally instead of via the handler.
function M.onLocalReady(accept)
    if not M.pending then return end
    if not M.pending.members[LWLFG.me] then return end
    M.pending.responses[LWLFG.me] = accept
    if not accept then
        concludeProposal(false)
        return
    end
    for name, _ in pairs(M.pending.members) do
        if M.pending.responses[name] ~= true then return end
    end
    concludeProposal(true)
end

LWLFG.handlers["FORM"] = function(parts, sender)
    if sender ~= matcherName() then return end
    local id = parts[3]
    local leader = parts[4]
    if Q.status == "PROPOSED" and Q.propId == id then
        Q.startForming(id, Q.propDungeon, Q.propMembers, leader)
        if leader == LWLFG.me then
            M.beginInvites(Q.propMembers, leader)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Replacement protocol
-- NEED:<faction>:<dungeon>:<roles>   leader of an in-progress party (heartbeat)
-- NEEDSTOP                           request closed (full / done / disbanded)
-- RPROP:<id>:<leader>:<dungeon>:<name=role>   matcher -> candidate + leader
-- RREADY:<id>:<verdict>              candidate -> all (leader invites; matcher concludes)
-- ---------------------------------------------------------------------------

LWLFG.handlers["NEED"] = function(parts, sender)
    if parts[3] ~= LWLFG.myFaction then return end   -- same-faction filter
    local e = M.needs[sender]
    if not e then
        e = { failed = {} }
        M.needs[sender] = e
    end
    e.dungeon = parts[4]
    e.roles = {}
    for _, r in ipairs(LWLFG.split(parts[5] or "", ",")) do
        if r ~= "" then e.roles[r] = true end
    end
    e.seen = GetTime()
end

LWLFG.handlers["NEEDSTOP"] = function(parts, sender)
    M.needs[sender] = nil
end

LWLFG.handlers["RPROP"] = function(parts, sender)
    if sender ~= matcherName() then return end      -- only the elected matcher may propose
    local id, leader, dungeon = parts[3], parts[4], parts[5]
    local kv = LWLFG.split(parts[6] or "", "=")
    if leader == LWLFG.me then
        -- a candidate was found for our short-handed party
        M.leaderPending = { id = id, name = kv[1] }
        return
    end
    if kv[1] == LWLFG.me and kv[2] then
        Q.startRprop(id, leader, dungeon, kv[2])
    end
end

LWLFG.handlers["RREADY"] = function(parts, sender)
    local id, verdict = parts[3], parts[4]
    -- leader side: our candidate answered — invite them
    if M.leaderPending and M.leaderPending.id == id and M.leaderPending.name == sender then
        if verdict == "ACCEPT" then
            LWLFG.print("Inviting replacement |cffffd100" .. sender .. "|r...")
            InviteByName(sender)
        end
        M.leaderPending = nil
    end
    -- matcher side: conclude the proposal
    if M.pendingR and M.pendingR.id == id and M.pendingR.name == sender then
        if verdict ~= "ACCEPT" and M.needs[M.pendingR.leader] then
            M.needs[M.pendingR.leader].failed[sender] = true
        end
        M.pendingR = nil
    end
end

-- ---------------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------------

function M.tick(elapsed)
    if not Q then return end   -- before ADDON_LOADED / onLoad
    pumpInvites()

    -- matcher-side proposal timeout
    if M.pending and GetTime() - M.pending.created > READY_WINDOW then
        concludeProposal(false)
    end

    -- replacement proposal timeout: candidate gone -> skip them next time
    if M.pendingR and GetTime() - M.pendingR.created > READY_WINDOW then
        local p = M.pendingR
        if M.needs[p.leader] then M.needs[p.leader].failed[p.name] = true end
        M.pendingR = nil
    end

    -- expire stale replacement requests (leader stopped heartbeating)
    local now = GetTime()
    for leader, need in pairs(M.needs) do
        if now - need.seen > NEED_TTL then M.needs[leader] = nil end
    end

    if not M.amIMatcher() then return end
    if GetTime() - M.lastTick < TICK_INTERVAL then return end
    M.lastTick = GetTime()

    -- in-progress parties get priority over fresh 5-man groups (one proposal
    -- of each kind at a time)
    if not M.pending and not M.pendingR then issueReplacement() end
    if M.pending then return end                     -- one proposal at a time
    issueProposal()
end
