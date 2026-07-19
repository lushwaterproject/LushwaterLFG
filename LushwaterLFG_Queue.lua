-- LushwaterLFG_Queue — random-queue state machine, entry pool, deserter cooldown.
-- State machine (local player): IDLE -> QUEUED -> PROPOSED -> FORMING -> GROUPED.
-- While QUEUED or PROPOSED the client heartbeats LW:RQ so every client (and the
-- elected matcher) shares the same queue view.

LWLFG = LWLFG or {}
LWLFG.Queue = {}
local Q = LWLFG.Queue

local HEARTBEAT        = 90    -- seconds between LW:RQ re-broadcasts
local ENTRY_TTL        = 200   -- seconds before a pool entry is considered stale (> HEARTBEAT)
local PROPOSED_TIMEOUT = 45    -- self-heal: PROPOSED without FORM falls back to QUEUED
local DESERTER_SECONDS = 300   -- 5-minute cooldown after declining a ready check
local NEED_HEARTBEAT   = 30    -- seconds between LW:NEED re-broadcasts (replacement)

Q.status      = "IDLE"
Q.queueStart  = 0
Q.lastBeat    = 0
Q.propId      = nil            -- proposal we are currently part of
Q.propRole    = nil            -- role assigned to us in that proposal
Q.propDungeon = nil
Q.propMembers = nil            -- { name = role } from the PROP message
Q.propSince   = 0
Q.autoAcceptFrom = nil         -- leader whose invite we auto-accept (FORMING)
Q.autoAcceptUntil = 0
Q.inDungeon   = false          -- server teleported us in (SUMMON_OK/PORT_IN_OK)
Q.completed   = false          -- final boss killed (REWARD received) — stops NEED
Q.rpropLeader = nil            -- leader name of the replacement proposal we answered
Q.rjoin       = false          -- accepted a replacement invite; JOIN on party join
Q.joinedViaFinder = false      -- accepted a finder invite while PROPOSED (pre-FORM)
Q.readyState  = nil            -- ready-check status: { [name] = { role=, state= } }
Q.need        = nil            -- leader-side replacement request: { dungeon, roles={set}, lastBeat }
Q.entries     = {}             -- pool: [name] = { level, class, roles={set}, seen, firstSeen }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function selectedRolesList()
    local out = {}
    for _, r in ipairs(LWLFG.ROLES) do
        if LWLFG.settings.rqRoles[r] and LWLFG.roleAllowed(r) then
            table.insert(out, r)
        end
    end
    return out
end
Q.selectedRolesList = selectedRolesList

function Q.deserterRemaining()
    local left = (LWLFG.settings.deserterUntil or 0) - time()
    if left > 0 then return left end
    return 0
end

local function announce()
    if not LWLFG.myFaction then return end
    local roles = selectedRolesList()
    if table.getn(roles) == 0 then return end
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":RQ:" .. LWLFG.myFaction .. ":"
        .. UnitLevel("player") .. ":" .. LWLFG.myClassToken() .. ":"
        .. LWLFG.joinKeys(roles, ","))
    -- keep our own pool entry fresh (matcher includes itself)
    Q.entries[LWLFG.me] = Q.entries[LWLFG.me] or { firstSeen = GetTime() }
    local e = Q.entries[LWLFG.me]
    e.level = UnitLevel("player")
    e.class = LWLFG.myClassToken()
    e.roles = {}
    for _, r in ipairs(roles) do e.roles[r] = true end
    e.seen = GetTime()
end
Q.announce = announce

-- ---------------------------------------------------------------------------
-- Replacement queueing (retail-style): the leader of an in-progress RDF party
-- broadcasts LW:NEED while short-handed; the elected matcher pairs the party
-- with a queued solo player (see Match).
-- ---------------------------------------------------------------------------

local function stopNeed()
    if not Q.need then return end
    Q.need = nil
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":NEEDSTOP")
end

-- Maintain (or clear) the replacement request for our own in-progress party.
-- Called on party/roster-relevant events and from Q.tick; cheap and idempotent.
function Q.refreshNeed()
    local short = Q.status == "GROUPED" and Q.inDungeon and not Q.completed
        and UnitIsPartyLeader("player")
    local n = GetNumPartyMembers()
    if short and (n < 1 or n >= 4) then short = false end   -- alone or full
    if not short then stopNeed() return end
    if not Q.propDungeon then stopNeed() return end

    -- missing roles = roles of departed proposed members; unknown roster (relog
    -- or promoted replacement) falls back to accepting any role
    local present = {}
    present[LWLFG.me] = true
    for i = 1, n do
        local nm = UnitName("party" .. i)
        if nm then present[nm] = true end
    end
    local roles, any = {}, false
    if Q.propMembers then
        for name, role in pairs(Q.propMembers) do
            if not present[name] then
                roles[role] = true
                any = true
            end
        end
    end
    if not any then roles = { TANK = true, HEAL = true, DPS = true } end

    if not Q.need then
        Q.need = { lastBeat = 0 }
        LWLFG.print("Party short-handed — looking for a replacement for "
            .. LWLFG.dungeonName(Q.propDungeon) .. ".")
    end
    Q.need.dungeon = Q.propDungeon
    Q.need.roles = roles
    if GetTime() - Q.need.lastBeat > NEED_HEARTBEAT then Q.announceNeed() end
end

function Q.announceNeed()
    if not Q.need or not LWLFG.myFaction then return end
    local roles = {}
    for _, r in ipairs(LWLFG.ROLES) do
        if Q.need.roles[r] then table.insert(roles, r) end
    end
    if table.getn(roles) == 0 then return end
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":NEED:" .. LWLFG.myFaction .. ":"
        .. Q.need.dungeon .. ":" .. LWLFG.joinKeys(roles, ","))
    Q.need.lastBeat = GetTime()
end

function Q.leave(notify)
    local wasQueued = (Q.status ~= "IDLE")
    Q.status = "IDLE"
    Q.propId = nil
    Q.propRole = nil
    Q.propDungeon = nil
    Q.propMembers = nil
    Q.autoAcceptFrom = nil
    Q.rpropLeader = nil
    Q.rjoin = false
    Q.joinedViaFinder = false
    Q.readyState = nil
    if LWLFG.UI and LWLFG.UI.readyHide then LWLFG.UI.readyHide() end
    stopNeed()
    Q.entries[LWLFG.me] = nil
    if wasQueued then
        LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":RQLEAVE")
    end
    if notify then LWLFG.print("Left the random queue.") end
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

-- ---------------------------------------------------------------------------
-- Public actions (UI)
-- ---------------------------------------------------------------------------

function Q.toggle()
    -- GROUPED is terminal (party formed); clicking Find Group starts a new queue
    if Q.status ~= "IDLE" and Q.status ~= "GROUPED" then
        Q.leave(true)
        return
    end
    if Q.deserterRemaining() > 0 then
        LWLFG.print("Deserter: you declined a ready check. Wait "
            .. math.ceil(Q.deserterRemaining()) .. "s.")
        return
    end
    if GetNumPartyMembers() > 0 then
        LWLFG.print("Leave your party before queueing for a random dungeon.")
        return
    end
    local roles = selectedRolesList()
    if table.getn(roles) == 0 then
        LWLFG.print("Pick at least one role first.")
        return
    end
    if table.getn(LWLFG.eligibleDungeons(UnitLevel("player"))) == 0 then
        LWLFG.print("No dungeons available at your level yet (first: Ragefire Chasm at 13).")
        return
    end
    Q.status = "QUEUED"
    Q.queueStart = GetTime()
    Q.lastBeat = 0
    Q.joinedViaFinder = false
    announce()
    LWLFG.print("Queued for a random dungeon as " .. LWLFG.joinKeys(roles, "/") .. ".")
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

-- ---------------------------------------------------------------------------
-- Ready-check status tracking (feeds the WotLK-style strip in the UI).
-- READY responses are broadcast, so every client tracks per-member state
-- independently; the local player's own answer is marked directly.
-- ---------------------------------------------------------------------------

function Q.readyStart()
    Q.readyState = nil
    if not Q.propMembers then return end   -- replacement proposals have no roster
    local st = {}
    for name, role in pairs(Q.propMembers) do
        st[name] = { role = role, state = "waiting" }
    end
    Q.readyState = st
    if LWLFG.UI and LWLFG.UI.readyShow then LWLFG.UI.readyShow() end
end

function Q.readyMark(name, accepted)
    if not Q.readyState or not Q.readyState[name] then return end
    Q.readyState[name].state = accepted and "ready" or "declined"
    if LWLFG.UI and LWLFG.UI.readyRefresh then LWLFG.UI.readyRefresh() end
    if not accepted and LWLFG.UI and LWLFG.UI.readyHideSoon then
        LWLFG.UI.readyHideSoon(4)   -- show the red X briefly, then close
    end
end

function Q.readyDone()
    if not Q.readyState then return end
    for _, m in pairs(Q.readyState) do m.state = "ready" end
    if LWLFG.UI and LWLFG.UI.readyRefresh then LWLFG.UI.readyRefresh() end
    if LWLFG.UI and LWLFG.UI.readyHideSoon then LWLFG.UI.readyHideSoon(4) end
end

-- ---------------------------------------------------------------------------
-- Ready-check responses (called by the popup UI)
-- ---------------------------------------------------------------------------

function Q.respondReady(accept)
    if Q.status ~= "PROPOSED" or not Q.propId then return end
    if Q.rpropLeader then
        -- replacement candidate answering the matcher's RPROP
        LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":RREADY:" .. Q.propId .. ":"
            .. (accept and "ACCEPT" or "DECLINE"))
        -- if we are the matcher, our own RREADY never comes back over the channel
        if LWLFG.Match and LWLFG.Match.onLocalRready then
            LWLFG.Match.onLocalRready(Q.propId, accept)
        end
        if accept then
            LWLFG.print("Accepted — waiting for " .. Q.rpropLeader .. "'s invite...")
            Q.status = "FORMING"
            Q.autoAcceptFrom = Q.rpropLeader
            Q.autoAcceptUntil = GetTime() + 60
            Q.rjoin = true
        else
            LWLFG.settings.deserterUntil = time() + DESERTER_SECONDS
            LWLFG.print("Declined — deserter for " .. DESERTER_SECONDS .. "s.")
            Q.leave(false)
        end
        Q.rpropLeader = nil
        if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
        return
    end
    LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":READY:" .. Q.propId .. ":"
        .. (accept and "ACCEPT" or "DECLINE"))
    -- our own READY never comes back over the channel; mark it locally
    Q.readyMark(LWLFG.me, accept)
    -- if we are the matcher, our own READY never comes back over the channel
    if LWLFG.Match and LWLFG.Match.onLocalReady then
        LWLFG.Match.onLocalReady(accept)
    end
    if accept then
        LWLFG.print("Accepted — waiting for the rest of the group...")
        -- stay PROPOSED; Match forwards the FORM instruction
    else
        LWLFG.settings.deserterUntil = time() + DESERTER_SECONDS
        LWLFG.print("Declined — deserter for " .. DESERTER_SECONDS .. "s.")
        Q.leave(false)
    end
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

-- ---------------------------------------------------------------------------
-- Incoming protocol (registered with core)
-- ---------------------------------------------------------------------------

LWLFG.handlers["RQ"] = function(parts, sender)
    if parts[3] ~= LWLFG.myFaction then return end   -- same-faction filter
    local class = parts[5] or "WARRIOR"
    -- queue data is self-reported: drop roles the announced class cannot play
    -- (a modified client can still lie about its class, but not convincingly —
    -- party frames show the real one)
    local allowed = LWLFG.CLASS_ROLES[class]
    local roles = {}
    for _, r in ipairs(LWLFG.split(parts[6] or "DPS", ",")) do
        if not allowed or allowed[r] then roles[r] = true end
    end
    local e = Q.entries[sender]
    if not e then
        e = { firstSeen = GetTime() }
        Q.entries[sender] = e
    end
    e.level = tonumber(parts[4]) or 0
    e.class = class
    e.roles = roles
    e.seen = GetTime()
end

LWLFG.handlers["RQLEAVE"] = function(parts, sender)
    Q.entries[sender] = nil
end

function Q.onPing()
    if Q.status == "QUEUED" or Q.status == "PROPOSED" then
        announce()
    end
end

function Q.onLevelUp()
    if Q.status == "QUEUED" or Q.status == "PROPOSED" then
        announce()
    end
end

-- ---------------------------------------------------------------------------
-- Group formation events (driven by Match, resolved here)
-- ---------------------------------------------------------------------------

function Q.onPartyInvite(inviter)
    local forming = Q.status == "FORMING" and Q.autoAcceptFrom == inviter
        and GetTime() < Q.autoAcceptUntil
    -- Invites are instant but the FORM broadcast crawls the throttled send
    -- queue, so the leader's invite can land while we are still PROPOSED. Only
    -- the proposal's chosen leader sends invites in-protocol, so an invite
    -- from any proposal member IS the finder invite — accept it immediately.
    local early = Q.status == "PROPOSED" and Q.propMembers and Q.propMembers[inviter]
    if forming or early then
        AcceptGroup()
        Q.joinedViaFinder = true
        Q.autoAcceptFrom = inviter   -- remember leader for any follow-up invites
        LWLFG.print("Auto-accepted invite from " .. inviter .. ".")
        return
    end
    -- The leader's invite can cross the member's join/teleport event on the
    -- network, arriving after we are already grouped. If the inviter is a
    -- proposal member and is actually in our party, this is a duplicate dialog
    -- that should be closed rather than left for 30-45 seconds.
    local duplicate = (Q.status == "FORMING" or Q.status == "GROUPED")
        and Q.propMembers and Q.propMembers[inviter]
        and LWLFG.isInParty(inviter)
    if duplicate then
        -- Already in the party; the popup will be suppressed by the
        -- StaticPopup_Show wrapper, so nothing else to do here.
        return
    end
    if Q.propMembers and Q.propMembers[inviter] then
        -- should never happen: a proposal member's invite slipped both gates
        LWLFG.print("Invite from " .. inviter .. " not auto-accepted (status "
            .. tostring(Q.status) .. ").")
    end
end

-- The default UI renders the PARTY_INVITE static popup in its own event handler,
-- which runs before our OnEvent handler. Intercept StaticPopup_Show itself so
-- finder invites are auto-accepted before the popup ever appears; non-finder
-- invites are passed through untouched.
local function isFinderInvite(inviter)
    if not inviter then return false end
    if Q.propMembers and Q.propMembers[inviter] then return true end
    if inviter == Q.autoAcceptFrom then return true end
    if inviter == Q.rpropLeader then return true end
    return false
end

local origStaticPopup_Show = StaticPopup_Show
function StaticPopup_Show(which, a1, a2, a3)
    if which == "PARTY_INVITE" then
        local inviter = a1
        if isFinderInvite(inviter) then
            -- Already in the party means this is a duplicate popup after teleport;
            -- just suppress it. Otherwise accept the invite before the popup renders.
            if not LWLFG.isInParty(inviter) then
                AcceptGroup()
            end
            return
        end
    end
    return origStaticPopup_Show(which, a1, a2, a3)
end

function Q.onPartyChanged()
    local inParty = GetNumPartyMembers() > 0
    -- accepted the finder's invite before FORM landed: this IS our party, not
    -- an outside one — move to FORMING instead of declining the proposal
    if Q.status == "PROPOSED" and inParty and Q.joinedViaFinder then
        Q.status = "FORMING"
        Q.autoAcceptUntil = GetTime() + 60
    end
    if (Q.status == "QUEUED" or Q.status == "PROPOSED") and inParty then
        -- joined a party outside the finder (or declined implicitly)
        if Q.status == "PROPOSED" then
            if Q.rpropLeader then
                LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":RREADY:" .. Q.propId .. ":DECLINE")
            else
                LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":READY:" .. Q.propId .. ":DECLINE")
            end
        end
        LWLFG.print("Joined a party — removed from the random queue.")
        Q.leave(false)
    elseif Q.status == "FORMING" and inParty then
        -- replacements join a partial party; fresh groups wait until full
        if not Q.rjoin and GetNumPartyMembers() < 4 then return end
        Q.status = "GROUPED"
        Q.entries[LWLFG.me] = nil
        LWLFG.enqueueSend(LWLFG.MSG_PREFIX .. ":RQLEAVE")
        Q.readyDone()   -- close the ready-check strip even if FORM was delayed/lost
        if Q.rjoin then
            Q.rjoin = false
            LWLFG.print("|cffffd100Joined "
                .. LWLFG.dungeonName(Q.propDungeon or "?") .. " in progress|r")
            -- the server records us with our current spot and teleports us in
            if LWLFG.Bot then
                LWLFG.print("Requesting server teleport...")
                LWLFG.Bot.send("JOIN")
            else
                LWLFG.print("Good Luck!")
            end
        else
            LWLFG.print("|cffffd100Group formed for "
                .. LWLFG.dungeonName(Q.propDungeon or "?") .. "|r")
            -- the leader asks the server bot to summon the whole party into the
            -- dungeon; without the server feature the group walks (v0.2 behavior)
            if UnitIsPartyLeader("player") and LWLFG.Bot then
                LWLFG.print("Requesting server summon...")
                LWLFG.Bot.send("SUMMON:" .. (Q.propDungeon or ""))
            else
                LWLFG.print("Good Luck!")
            end
        end
        if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
    end
    Q.refreshNeed()
end

-- ---------------------------------------------------------------------------
-- Server-teleport integration (whisper bot)
-- ---------------------------------------------------------------------------

function Q.onSummoned(dungeonKey)
    Q.inDungeon = true
    Q.completed = false          -- new run: replacement requests allowed again
    Q.propDungeon = dungeonKey or Q.propDungeon
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

function Q.onSummonFail(reason)
    -- party stays formed; members can walk to the entrance
    if reason ~= "cooldown" then
        LWLFG.print("Group stays formed — you can still walk to the entrance.")
    end
end

function Q.onReward()
    Q.completed = true
    Q.refreshNeed()   -- dungeon done: close any open replacement request
end

function Q.onPortedOut()
    Q.inDungeon = false
    Q.refreshNeed()   -- leader outside: pause the replacement request
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

function Q.onPortedIn(dungeonKey)
    Q.inDungeon = true
    -- a promoted replacement learns the dungeon key this way
    if dungeonKey then Q.propDungeon = dungeonKey end
    Q.refreshNeed()
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

function Q.teleportOut()
    if LWLFG.Bot then LWLFG.Bot.send("TELEPORT_OUT") end
end

function Q.teleportIn()
    if LWLFG.Bot then LWLFG.Bot.send("TELEPORT_IN") end
end

-- Called by Match when a FORM message names us (either as leader or member).
-- Members who accepted the leader's invite early (before FORM landed) are
-- already FORMING via the joinedViaFinder transition — tolerate both.
function Q.startForming(propId, dungeon, members, leader)
    if Q.propId ~= propId then return end
    if Q.status == "GROUPED" then
        -- already grouped (e.g. from an early join/teleport); just make sure
        -- the strip is closed and the leader is recorded.
        Q.autoAcceptFrom = leader
        Q.readyDone()
        if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
        return
    end
    if Q.status ~= "PROPOSED" and Q.status ~= "FORMING" then return end
    if Q.status == "PROPOSED" then
        Q.status = "FORMING"
        Q.autoAcceptUntil = GetTime() + 60
    end
    Q.autoAcceptFrom = leader
    Q.readyDone()   -- all five accepted: green across the strip, then close
    if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
end

-- Candidate side of a replacement proposal (called by Match when the elected
-- matcher pairs us with an in-progress party).
function Q.startRprop(id, leader, dungeon, role)
    if Q.status ~= "QUEUED" then return end
    Q.propId = id
    Q.propDungeon = dungeon
    Q.propRole = role
    Q.propMembers = nil
    Q.rpropLeader = leader
    Q.propSince = GetTime()
    Q.status = "PROPOSED"
    if LWLFG.UI then LWLFG.UI.showReady(dungeon, role) end
end

-- ---------------------------------------------------------------------------
-- Tick: heartbeats, pool sweep, PROPOSED self-heal
-- ---------------------------------------------------------------------------

function Q.tick(elapsed)
    if Q.status == "QUEUED" or Q.status == "PROPOSED" then
        if GetTime() - Q.lastBeat > HEARTBEAT then
            Q.lastBeat = GetTime()
            announce()
        end
    end

    -- expire stale pool entries (except our own while queued)
    local now = GetTime()
    for name, e in pairs(Q.entries) do
        if name ~= LWLFG.me and now - e.seen > ENTRY_TTL then
            Q.entries[name] = nil
        end
    end

    -- proposal died silently (matcher went offline etc.) -> back to QUEUED
    if Q.status == "PROPOSED" and now - Q.propSince > PROPOSED_TIMEOUT then
        LWLFG.print("Matchmaking timed out — back in the queue.")
        Q.status = "QUEUED"
        Q.propId = nil
        Q.propRole = nil
        Q.propDungeon = nil
        Q.propMembers = nil
        Q.rpropLeader = nil
        Q.joinedViaFinder = false
        Q.readyState = nil
        if LWLFG.UI and LWLFG.UI.readyHide then LWLFG.UI.readyHide() end
        if LWLFG.UI and LWLFG.UI.refresh then LWLFG.UI.refresh() end
    end

    -- FORMING that never materialized into a full party -> drop out cleanly
    if Q.status == "FORMING" and now - Q.autoAcceptUntil > 0 and GetNumPartyMembers() < 4 then
        LWLFG.print("Group assembly incomplete — queue ended. Re-queue when ready.")
        Q.leave(false)
    end

    -- leader of an in-progress party: keep the replacement request current
    Q.refreshNeed()
end
