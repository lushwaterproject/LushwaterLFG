-- LushwaterLFG_UI — main window (Random | Specific tabs), ready-check popup
-- and minimap button. WotLK-Dungeon-Finder layout reproduced with stock 1.12
-- textures only: round role buttons = icon inside the minimap tracking ring,
-- coin icons from MoneyFrame, UIDropDownMenu for the Type line. (The WotLK
-- LFGFRAME art itself does not exist in the 1.12 client.)

LWLFG = LWLFG or {}
LWLFG.UI = {}
local UI = LWLFG.UI

local READY_TIMEOUT = 30     -- seconds to answer the ready check
local MAX_RESULTS   = 6      -- specific-tab result rows (fits the window)

-- Stock 1.12 stand-ins for the WotLK role icons (which do not exist in the
-- 1.12 client). Shield = tank, FlashHeal = healer, sword = damage.
local ROLE_ICONS = {
    TANK = "Interface\\Icons\\INV_Shield_06",
    HEAL = "Interface\\Icons\\Spell_Holy_FlashHeal",
    DPS  = "Interface\\Icons\\INV_Sword_04",
}
local ROLE_LABELS = { TANK = "Tank", HEAL = "Healer", DPS = "Damage" }

-- Optional LFT art hook. LFT (Looking For Turtles, Turtle WoW) textures are
-- all-rights-reserved and therefore NOT shipped with this addon — run
-- fetch-lft-art.sh to download them into images/ for personal use (gitignored).
-- We probe for the files and fall back to stock 1.12 art when they're absent.
-- NOTE: everything is kept FLAT in images/ — the 1.12 client cannot decode
-- addon-subdirectory textures at ADDON_LOADED (root files load fine), which
-- is why LFT's own background/ eye/ icon/ dungeon_complete/ folders are
-- flattened both here and in fetch-lft-art.sh.
local LFT_IMG = "Interface\\AddOns\\LushwaterLFG\\images\\"
local LFT_ROLE_ICONS = { TANK = "tank2", HEAL = "healer2", DPS = "damage2" }
local LFT_READY_ICONS = { TANK = "ready_tank", HEAL = "ready_healer", DPS = "ready_damage" }

-- dungeon key -> LFT art suffix (used for ui-lfg-background-* and lfgicon-*;
-- all art is kept FLAT in images/ — see the subdirectory note at probeArt)
local LFT_DUNGEON_ART = {
    RFC  = "ragefirechasm",    WC   = "wailingcaverns",   VC   = "deadmines",
    SFK  = "shadowfangkeep",   BFD  = "blackfathomdeeps", STK  = "stormwindstockades",
    GNO  = "gnomeregan",       RFK  = "razorfenkraul",   SM   = "scarletmonastery",
    RFD  = "razorfendowns",    ULD  = "uldaman",         ZF   = "zulfarak",
    MAR  = "maraudon",         ST   = "sunkentemple",    BRD  = "blackrockdepths",
    LBRS = "blackrockspire",   DM   = "diremaul",        SCHO = "scholomance",
    STRAT = "stratholme",      UBRS = "upperblackrockspire",
}
-- eye animation frame indices shipped by LFT (gaps in the sequence are real)
local LFT_EYE_FRAMES = { 0, 1, 2, 3, 4, 9, 10, 11, 12, 13, 14, 15,
                         17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 }

local function probeArt()
    local t = CreateFrame("Frame"):CreateTexture()
    local function has(name)
        t:SetTexture(LFT_IMG .. name)
        return t:GetTexture() ~= nil   -- missing file -> GetTexture() is nil
    end
    LWLFG.ART = {
        roles    = has("tank2") and has("healer2") and has("damage2"),
        ready    = has("ready_tank") and has("ready_healer") and has("ready_damage"),
        portrait = has("ui-lfg-portrait"),
        frame    = has("ui-lfg-frame"),
        wall     = has("ui-lfg-background-dungeonwall"),
        tabs     = has("ui-character-activetab") and has("ui-character-inactivetab"),
        complete = has("dungeon_complete_00"),
        readyArt = has("dungeon_ready_top") and has("dungeon_ready_middle"),
    }
    local A = LWLFG.ART
    -- per-dungeon art maps (only entries whose files actually exist)
    A.bg, A.icon = {}, {}
    for key, suffix in pairs(LFT_DUNGEON_ART) do
        if has("ui-lfg-background-" .. suffix) then A.bg[key] = suffix end
        if has("lfgicon-" .. suffix) then A.icon[key] = suffix end
    end
    if not A.bg.UBRS and A.bg.LBRS then A.bg.UBRS = "blackrockspire" end
    -- eye animation frames that exist on disk
    A.eyeFrames = {}
    for _, i in ipairs(LFT_EYE_FRAMES) do
        if has("battlenetworking" .. i) then table.insert(A.eyeFrames, i) end
    end
end

local ui = {}

local function makeButton(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(w); b:SetHeight(h)
    b:SetText(label)
    return b
end

-- Inset section panel (the framed-box look used throughout Blizzard UI)
local function makeInset(parent, x, y, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(w); f:SetHeight(h)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    return f
end

-- Round WotLK-style role button. With LFT art present: the framed role
-- circle as-is. Fallback: square spell/item icon inside the minimap tracking
-- ring (gold ring = selected, dimmed = class cannot play the role); the ring
-- art is NOT centered inside MiniMap-TrackingBorder, so the fallback copies
-- Blizzard's own layout (1.12 Minimap.xml) scaled to a 76px ring.
local function makeRoleEntry(parent, x, y, role, onClick, size)
    local S = size or 40
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(S); b:SetHeight(S)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b.roleValue = role

    if LWLFG.ART and LWLFG.ART.roles then
        -- LFT role art (framed circle, no extra ring needed)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(S); icon:SetHeight(S)
        icon:SetPoint("CENTER", b, "CENTER", 0, 0)
        icon:SetTexture(LFT_IMG .. LFT_ROLE_ICONS[role])
        b.icon = icon
    else
        -- stock 1.12 fallback: spell/item icon inside the minimap tracking
        -- ring; the ring art is NOT centered in its 64x64 texture — copy
        -- Blizzard's layout (1.12 Minimap.xml): border TOPLEFT, icon +8,-7
        -- (scaled for a 76px ring).
        local icon = b:CreateTexture(nil, "BACKGROUND")
        icon:SetWidth(30); icon:SetHeight(30)
        icon:SetPoint("TOPLEFT", b, "TOPLEFT", 8, -7)
        icon:SetTexture(ROLE_ICONS[role])
        b.icon = icon

        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetWidth(76); border:SetHeight(76)
        border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        b.border = border
    end

    -- selected checkmark (the ring tint alone is too subtle to read)
    local check = b:CreateTexture(nil, "OVERLAY")
    check:SetWidth(20); check:SetHeight(20)
    check:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 2)
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:Hide()
    b.check = check

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    b:SetScript("OnClick", function() onClick(this) end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(ROLE_LABELS[this.roleValue])
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function paintRoleEntry(b, selected, allowed)
    if b.check then
        if selected then b.check:Show() else b.check:Hide() end
    end
    if not allowed then
        b.icon:SetVertexColor(0.3, 0.3, 0.3)
        if b.border then b.border:SetVertexColor(0.3, 0.3, 0.3) end
    elseif selected then
        b.icon:SetVertexColor(1, 1, 1)
        if b.border then b.border:SetVertexColor(1, 0.82, 0) end   -- gold ring = selected
    else
        b.icon:SetVertexColor(0.65, 0.65, 0.65)
        if b.border then b.border:SetVertexColor(0.8, 0.8, 0.8) end
    end
end

-- ---------------------------------------------------------------------------
-- Main window
-- ---------------------------------------------------------------------------

function UI.build()
    probeArt()
    local A = LWLFG.ART
    local skin = A.frame and true or false   -- full LFT chrome available?

    local f = CreateFrame("Frame", "LWLFGMainFrame", UIParent)
    if skin then
        -- LFT's window: 384x512 frame; the 512x512 chrome texture's visible
        -- window occupies x 10..350, y -8..-435 of the canvas (measured)
        f:SetWidth(384); f:SetHeight(512)
    else
        f:SetWidth(370); f:SetHeight(590)
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)
    f:Hide()
    ui.frame = f
    ui.skin = skin

    if skin then
        -- wide dungeon-wall wash behind the content area (LFT: 512x256 at
        -- TOP 85,-155, BACKGROUND layer, full strength)
        if A.wall then
            local wall = f:CreateTexture(nil, "BACKGROUND")
            wall:SetWidth(512); wall:SetHeight(256)
            wall:SetPoint("TOP", f, "TOP", 85, -155)
            wall:SetTexture(LFT_IMG .. "ui-lfg-background-dungeonwall")
        end
        -- the chrome itself
        local chrome = f:CreateTexture(nil, "ARTWORK")
        chrome:SetWidth(512); chrome:SetHeight(512)
        chrome:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        chrome:SetTexture(LFT_IMG .. "ui-lfg-frame")
    end

    -- corner portrait: LFT's eye (64px in the chrome's portrait hole) or the
    -- stock Mind Vision eye inside the tracking ring (off-center art — see
    -- makeRoleEntry)
    if skin and A.portrait then
        local eyeIcon = f:CreateTexture(nil, "OVERLAY")
        eyeIcon:SetWidth(64); eyeIcon:SetHeight(64)
        eyeIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 7, -6)
        eyeIcon:SetTexture(LFT_IMG .. "ui-lfg-portrait")
    else
        local eye = CreateFrame("Frame", nil, f)
        eye:SetWidth(31); eye:SetHeight(31)
        eye:SetPoint("CENTER", f, "TOPLEFT", 10, -10)
        local eyeIcon = eye:CreateTexture(nil, "BACKGROUND")
        eyeIcon:SetWidth(20); eyeIcon:SetHeight(20)
        eyeIcon:SetPoint("TOPLEFT", eye, "TOPLEFT", 7, -6)
        eyeIcon:SetTexture("Interface\\Icons\\Spell_Holy_MindVision")
        local eyeRing = eye:CreateTexture(nil, "OVERLAY")
        eyeRing:SetWidth(53); eyeRing:SetHeight(53)
        eyeRing:SetPoint("TOPLEFT", eye, "TOPLEFT", 0, 0)
        eyeRing:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("|cffffd100Dungeon Finder|r  |cff888888v" .. LWLFG.ADDON_VERSION .. "|r")

    local close = makeButton(f, "X", 26, 22)
    -- skin: the art's top-right corner is ~34px inside the 384px frame
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", skin and -30 or -14, skin and -12 or -14)
    close:SetScript("OnClick", function() f:Hide() end)

    -- role rows: with the LFT skin they live in the chrome's dark inset,
    -- LFT coords 64x64 at TOP -100/-5/+90,-50 (one row per tab, toggled by
    -- showTab). Fallback: rows are built inside the panels themselves.
    if skin then
        ui.rqRoleChecks = {}
        ui.roleButtons = {}
        local x = 60
        for _, role in ipairs(LWLFG.ROLES) do
            local b = makeRoleEntry(f, x, -50, role, function(self)
                if not LWLFG.roleAllowed(self.roleValue) then
                    LWLFG.print("Your class cannot queue as " .. ROLE_LABELS[self.roleValue] .. ".")
                    return
                end
                LWLFG.settings.rqRoles[self.roleValue] =
                    not LWLFG.settings.rqRoles[self.roleValue] and true or nil
                UI.refresh()
            end, 64)
            table.insert(ui.rqRoleChecks, b)
            local b2 = makeRoleEntry(f, x, -50, role, function(self)
                if not LWLFG.roleAllowed(self.roleValue) then
                    LWLFG.print("Your class cannot queue as " .. ROLE_LABELS[self.roleValue] .. ".")
                    return
                end
                LWLFG.toggleSpecRole(self.roleValue)
            end, 64)
            table.insert(ui.roleButtons, b2)
            x = x + 95
        end
    end

    -- Tab buttons. Skin mode has NONE — the frame-level Type dropdown
    -- (WotLK-style) switches between Random and Specific there. Fallback
    -- keeps plain buttons at the top.
    if not skin then
        ui.tabRandom = makeButton(f, "Random", 90, 22)
        ui.tabRandom:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -48)
        ui.tabRandom:SetScript("OnClick", function() UI.showTab("random") end)

        ui.tabSpecific = makeButton(f, "Specific", 90, 22)
        ui.tabSpecific:SetPoint("LEFT", ui.tabRandom, "RIGHT", 8, 0)
        ui.tabSpecific:SetScript("OnClick", function() UI.showTab("specific") end)
    end

    UI.buildRandomPanel(f, skin)
    UI.buildSpecificPanel(f, skin)
    UI.buildReadyPopup()
    UI.buildReadyStatus()
    UI.buildMinimapButton()
    UI.buildCompleteFrame()
    UI.showTab(LWLFG.settings.tab or "random")
end

function UI.showTab(which)
    LWLFG.settings.tab = which
    -- no SetShown() in 1.12 (added in Legion) — use Show/Hide
    if which == "random" then ui.randomPanel:Show() else ui.randomPanel:Hide() end
    if which == "specific" then ui.specificPanel:Show() else ui.specificPanel:Hide() end
    -- skin mode: swap the visible role row with the panel, and reflect the
    -- switch in the frame-level Type dropdown (there are no tabs)
    if ui.skin then
        for _, b in ipairs(ui.rqRoleChecks or {}) do
            if which == "random" then b:Show() else b:Hide() end
        end
        for _, b in ipairs(ui.roleButtons or {}) do
            if which == "specific" then b:Show() else b:Hide() end
        end
        if ui.typeDropdown then
            UIDropDownMenu_SetText(
                which == "random" and "Random Dungeon" or "Specific Dungeon",
                ui.typeDropdown)
        end
    elseif ui.tabRandom then
        ui.tabRandom:SetText(which == "random" and "|cffffd100Random|r" or "Random")
        ui.tabSpecific:SetText(which == "specific" and "|cffffd100Specific|r" or "Specific")
    end
end

-- ---------------------------------------------------------------------------
-- Random panel (WotLK layout: round roles, Type dropdown, Rewards inset)
-- ---------------------------------------------------------------------------

-- center the Money: row as a group (label + coin icon/text pairs) — the
-- amounts change per level, so this reruns whenever the texts change
local function centerMoneyRow()
    if not (ui.rwBox and ui.rwMoneyLabel) then return end
    local function seg(icon, txt)
        return icon:GetWidth() + 2 + txt:GetStringWidth()
    end
    local total = ui.rwMoneyLabel:GetStringWidth() + 4
        + seg(ui.rwGoldIcon, ui.rwGoldText)
        + 6 + seg(ui.rwSilverIcon, ui.rwSilverText)
        + 6 + seg(ui.rwCopperIcon, ui.rwCopperText)
    ui.rwMoneyLabel:ClearAllPoints()
    ui.rwMoneyLabel:SetPoint("LEFT", ui.rwBox, "CENTER", -total / 2, -20)
end

-- center the Find Group / Teleport buttons as a pair (skin) or individually
local function positionRandomButtons(showTele)
    if not (ui.findBtn and ui.teleportBtn) then return end
    local p = ui.findBtn:GetParent()
    ui.findBtn:ClearAllPoints()
    ui.teleportBtn:ClearAllPoints()
    if ui.skin then
        -- LFT chrome's opaque visible window is offset left of the 384px frame
        -- center; centering the button(s) in the visible window looks better.
        local visibleCenter = (p:GetWidth() / 2) - 11
        local findW = ui.findBtn:GetWidth()
        local teleW = ui.teleportBtn:GetWidth()
        local gap = 10
        if showTele then
            local pairW = findW + gap + teleW
            local left = visibleCenter - (pairW / 2)
            ui.findBtn:SetPoint("TOPLEFT", p, "TOPLEFT", left, -328)
            ui.teleportBtn:SetPoint("TOPLEFT", p, "TOPLEFT", left + findW + gap, -328)
        else
            ui.findBtn:SetPoint("TOP", p, "TOP", -11, -328)
        end
    else
        ui.findBtn:SetPoint("TOP", p, "TOP", 0, -284)
        if showTele then
            ui.teleportBtn:SetPoint("TOP", p, "TOP", 0, -368)
        end
    end
end

-- pick a random dungeon backdrop for the rewards inset (LFT art only)
local function rotateRewardsBg()
    if not ui.rwBg then return end
    local keys = {}
    for k in pairs(LWLFG.ART.bg) do table.insert(keys, k) end
    if table.getn(keys) == 0 then return end
    local key = keys[math.random(1, table.getn(keys))]
    ui.rwBg:SetTexture(LFT_IMG .. "ui-lfg-background-" .. LWLFG.ART.bg[key])
end

function UI.buildRandomPanel(parent, skin)
    local p = CreateFrame("Frame", nil, parent)
    if skin then
        -- full-frame panel; children use LFT frame coordinates directly
        p:SetWidth(384); p:SetHeight(512)
        p:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    else
        p:SetWidth(330); p:SetHeight(440)
        p:SetPoint("TOPLEFT", parent, "TOPLEFT", 15, -78)
    end
    ui.randomPanel = p

    -- round role buttons, centered (76px rings, visual center at TOPLEFT+23,-22)
    -- (skin mode: the row lives on the main frame's inset instead)
    if not skin then
        ui.rqRoleChecks = {}
        local x = 41
        for _, role in ipairs(LWLFG.ROLES) do
            local b = makeRoleEntry(p, x, 0, role, function(self)
                if not LWLFG.roleAllowed(self.roleValue) then
                    LWLFG.print("Your class cannot queue as " .. ROLE_LABELS[self.roleValue] .. ".")
                    return
                end
                LWLFG.settings.rqRoles[self.roleValue] =
                    not LWLFG.settings.rqRoles[self.roleValue] and true or nil
                UI.refresh()
            end)
            table.insert(ui.rqRoleChecks, b)
            x = x + 100
        end
    end

    -- Type line (WotLK-style dropdown; falls back to static text if the
    -- template is unavailable). Skin: parented to the MAIN frame so it sits
    -- in the chrome's divider band above BOTH panels — it replaces the
    -- bottom tabs as the Random/Specific switcher.
    local topY = skin and -136 or -70
    local anchor = skin and parent or p
    local typeLabel = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    typeLabel:SetPoint("TOPLEFT", anchor, "TOPLEFT", skin and 28 or 16, topY)
    typeLabel:SetText("|cffffd100Type:|r")

    local ok, dd = pcall(CreateFrame, "Frame", "LWLFGTypeDropdown", anchor, "UIDropDownMenuTemplate")
    if ok and dd then
        dd:SetPoint("TOPLEFT", anchor, "TOPLEFT", skin and 68 or 56, topY + 8)
        -- 1.12 API gotcha: argument order is REVERSED vs later clients —
        -- SetWidth(width, frame), SetText(text, frame), and the initialize
        -- function is called as initFunction(level), not initFunction(self, level).
        UIDropDownMenu_SetWidth(170, dd)
        if skin then
            UIDropDownMenu_Initialize(dd, function(level)
                local function addEntry(text, which)
                    local info = {}
                    info.text = text
                    info.checked = (LWLFG.settings.tab == which)
                    info.func = function() UI.showTab(which) end
                    UIDropDownMenu_AddButton(info, level)
                end
                addEntry("Random Dungeon", "random")
                addEntry("Specific Dungeon", "specific")
            end)
            ui.typeDropdown = dd
        else
            UIDropDownMenu_Initialize(dd, function(level)
                local info = {}
                info.text = "Random Dungeon"
                info.checked = true
                info.func = function() UIDropDownMenu_SetText("Random Dungeon", dd) end
                UIDropDownMenu_AddButton(info, level)
            end)
        end
        UIDropDownMenu_SetText("Random Dungeon", dd)
    else
        local fallback = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fallback:SetPoint("LEFT", typeLabel, "RIGHT", 8, 0)
        fallback:SetText("Random Dungeon")
    end

    -- Rewards inset (filled from the server's REWARDINFO preview). Skin:
    -- borderless, the faded per-dungeon art IS the background (WotLK look),
    -- and centered like the specific tab's checklist box (x 32, w 298)
    local rwY = skin and -166 or -102
    local rwBox = makeInset(p, skin and 32 or 4, rwY, skin and 298 or 322, skin and 148 or 168)
    if skin then rwBox:SetBackdrop(nil) end
    ui.rwBox = rwBox

    -- per-dungeon faded background art — rotates each time the window opens
    if LWLFG.ART and next(LWLFG.ART.bg) then
        ui.rwBg = rwBox:CreateTexture(nil, "BACKGROUND")
        ui.rwBg:SetWidth(skin and 298 or 314)
        ui.rwBg:SetHeight(skin and 148 or 152)
        ui.rwBg:SetPoint("CENTER", rwBox, "CENTER", 0, 0)
        ui.rwBg:SetAlpha(skin and 0.55 or 0.35)
        rotateRewardsBg()
    end

    local rwTitle = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    rwTitle:SetPoint("TOP", rwBox, "TOP", 0, -10)
    rwTitle:SetText("|cffffd100Random Dungeon|r")

    local rwDesc = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rwDesc:SetPoint("TOP", rwTitle, "BOTTOM", 0, -4)
    rwDesc:SetWidth(300)
    rwDesc:SetJustifyH("CENTER")
    rwDesc:SetText("Completing a random dungeon earns you bonus rewards "
        .. "when the final boss falls.")

    local rwHead = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rwHead:SetPoint("TOP", rwBox, "TOP", 0, -64)
    rwHead:SetText("|cffffd100Rewards|r")

    -- money line: coin icons from the 1.12 MoneyFrame atlas (there are no
    -- separate UI-GoldIcon/Silver/Copper textures in vanilla — one atlas
    -- atlas slices left->right: gold 0-.25, silver .25-.5, copper .5-.75)
    local MONEY_ATLAS = "Interface\\MoneyFrame\\UI-MoneyIcons"
    ui.rwMoneyLabel = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.rwMoneyLabel:SetPoint("LEFT", rwBox, "CENTER", 0, -20)  -- x fixed by centerMoneyRow
    ui.rwMoneyLabel:SetText("Money:")

    -- number LEFT of its coin, standard WoW order: 1[gold] 1[silver] 0[copper]
    ui.rwGoldText = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.rwGoldText:SetPoint("LEFT", ui.rwMoneyLabel, "RIGHT", 4, 0)
    ui.rwGoldIcon = rwBox:CreateTexture(nil, "ARTWORK")
    ui.rwGoldIcon:SetWidth(13); ui.rwGoldIcon:SetHeight(13)
    ui.rwGoldIcon:SetPoint("LEFT", ui.rwGoldText, "RIGHT", 2, 0)
    ui.rwGoldIcon:SetTexture(MONEY_ATLAS)
    ui.rwGoldIcon:SetTexCoord(0, 0.25, 0, 1)

    ui.rwSilverText = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.rwSilverText:SetPoint("LEFT", ui.rwGoldIcon, "RIGHT", 6, 0)
    ui.rwSilverIcon = rwBox:CreateTexture(nil, "ARTWORK")
    ui.rwSilverIcon:SetWidth(13); ui.rwSilverIcon:SetHeight(13)
    ui.rwSilverIcon:SetPoint("LEFT", ui.rwSilverText, "RIGHT", 2, 0)
    ui.rwSilverIcon:SetTexture(MONEY_ATLAS)
    ui.rwSilverIcon:SetTexCoord(0.25, 0.5, 0, 1)

    ui.rwCopperText = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.rwCopperText:SetPoint("LEFT", ui.rwSilverIcon, "RIGHT", 6, 0)
    ui.rwCopperIcon = rwBox:CreateTexture(nil, "ARTWORK")
    ui.rwCopperIcon:SetWidth(13); ui.rwCopperIcon:SetHeight(13)
    ui.rwCopperIcon:SetPoint("LEFT", ui.rwCopperText, "RIGHT", 2, 0)
    ui.rwCopperIcon:SetTexture(MONEY_ATLAS)
    ui.rwCopperIcon:SetTexCoord(0.5, 0.75, 0, 1)

    ui.rwXPText = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.rwXPText:SetPoint("TOP", rwBox, "TOP", 0, -110)
    ui.rwXPText:SetJustifyH("CENTER")

    ui.rwNote = rwBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.rwNote:SetPoint("TOP", rwBox, "TOP", 0, -126)
    ui.rwNote:SetWidth(260)
    ui.rwNote:SetJustifyH("CENTER")
    ui.rwNote:SetText("|cff888888Paid to every party member, once per run.|r")
    centerMoneyRow()

    ui.findBtn = makeButton(p, "Find Group", skin and 130 or 160, 32)
    -- initial position is set by positionRandomButtons() after teleportBtn exists
    ui.findBtn:SetScript("OnClick", function() LWLFG.Queue.toggle() end)

    ui.statusText = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.statusText:SetPoint("TOPLEFT", p, "TOPLEFT", skin and 28 or 8, skin and -364 or -330)
    ui.statusText:SetWidth(315)
    ui.statusText:SetJustifyH("LEFT")

    ui.deserterText = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.deserterText:SetPoint("TOPLEFT", ui.statusText, "BOTTOMLEFT", 0, -8)

    -- server teleport toggle (visible only for RDF-formed groups when the
    -- server bot answered us)
    ui.teleportBtn = makeButton(p, "Teleport", skin and 170 or 200, skin and 32 or 26)
    ui.teleportBtn:SetScript("OnClick", function()
        if LWLFG.Queue.inDungeon then
            LWLFG.Queue.teleportOut()
        else
            LWLFG.Queue.teleportIn()
        end
    end)
    ui.teleportBtn:Hide()
    positionRandomButtons(false)

    local poolLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    poolLabel:SetPoint("TOPLEFT", p, "TOPLEFT", skin and 28 or 8, skin and -382 or -406)
    poolLabel:SetText("Players in queue (your faction):")
    ui.poolLabel = poolLabel

    ui.poolText = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.poolText:SetPoint("TOPLEFT", poolLabel, "BOTTOMLEFT", 0, -6)
    ui.poolText:SetWidth(315)
    ui.poolText:SetJustifyH("LEFT")
end

-- ---------------------------------------------------------------------------
-- Specific panel (round roles + tidy two-column checklist + results)
-- ---------------------------------------------------------------------------

function UI.buildSpecificPanel(parent, skin)
    local p = CreateFrame("Frame", nil, parent)
    if skin then
        -- full-frame panel; children use LFT frame coordinates directly
        p:SetWidth(384); p:SetHeight(512)
        p:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    else
        p:SetWidth(330); p:SetHeight(440)
        p:SetPoint("TOPLEFT", parent, "TOPLEFT", 15, -78)
    end
    ui.specificPanel = p

    -- (skin mode: the role row lives on the main frame's inset instead)
    if not skin then
        local roleBox = makeInset(p, 4, -2, 322, 76)
        ui.roleButtons = {}
        local x = 57
        for _, role in ipairs(LWLFG.ROLES) do
            local b = makeRoleEntry(roleBox, x, -2, role, function(self)
                if not LWLFG.roleAllowed(self.roleValue) then
                    LWLFG.print("Your class cannot queue as " .. ROLE_LABELS[self.roleValue] .. ".")
                    return
                end
                LWLFG.toggleSpecRole(self.roleValue)
            end)
            table.insert(ui.roleButtons, b)
            x = x + 80
        end
    end

    -- dungeon checklist: two fixed columns inside an inset; names are colored
    -- by level eligibility (green = in my range) with the range on tooltip.
    -- LFT art adds a per-dungeon icon before each checkbox.
    local listBox, rowH, colW, cbSize, topPad
    if skin then
        local availLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        availLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 37, -166)
        availLabel:SetText("Available Dungeons")
        -- fills the content band with a clean margin above the chrome lip;
        -- horizontally centered in the chrome's visible window (measured
        -- from the texture: opaque x 11..352 -> center 181.5, box 298 wide)
        listBox = makeInset(p, 32, -190, 298, 220)
        rowH, colW, cbSize, topPad = 21, 149, 16, 7
    else
        listBox = makeInset(p, 4, -84, 322, 250)
        rowH, colW, cbSize, topPad = 24, 156, 22, 4
    end
    local hasIcons = LWLFG.ART and next(LWLFG.ART.icon)
    local iconSize = 16
    ui.dungeonChecks = {}
    for i, d in ipairs(LWLFG.DUNGEONS) do
        local col = math.mod(i - 1, 2)
        local row = math.floor((i - 1) / 2)
        local xoff = 6 + col * colW
        local iconTex
        if hasIcons and LWLFG.ART.icon[d.key] then
            local ic = listBox:CreateTexture(nil, "ARTWORK")
            ic:SetWidth(iconSize); ic:SetHeight(iconSize)
            ic:SetPoint("TOPLEFT", listBox, "TOPLEFT", xoff, -topPad - row * rowH - (skin and 0 or 3))
            -- 1.12 quirk: subdirectory textures can't load at ADDON_LOADED;
            -- the file is set lazily in refreshDungeonChecks (runs at PEW)
            iconTex = ic
            xoff = xoff + (skin and 18 or 20)
        end
        local cb = CreateFrame("CheckButton", nil, listBox, "UICheckButtonTemplate")
        cb:SetWidth(cbSize); cb:SetHeight(cbSize)
        cb:SetPoint("TOPLEFT", listBox, "TOPLEFT", xoff, -topPad - row * rowH)
        cb.iconTex = iconTex
        cb.dungeonKey = d.key
        cb.dungeonDef = d
        cb:SetScript("OnClick", function()
            if not LWLFG.isDungeonEligible(this.dungeonKey, UnitLevel("player")) then
                LWLFG.print(this.dungeonDef.name .. " is not available at your level/phase.")
                this:SetChecked(false)
                return
            end
            LWLFG.settings.dungeons[this.dungeonKey] = this:GetChecked() and true or nil
        end)
        cb:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText(this.dungeonDef.name)
            local lo, hi = LWLFG.dungeonRange(this.dungeonDef.key)
            GameTooltip:AddLine("Levels " .. (lo or "?") .. "-" .. (hi or "?"), 1, 1, 1)
            if not LWLFG.isDungeonEligible(this.dungeonKey, UnitLevel("player")) then
                GameTooltip:AddLine("Not available for your level/phase", 1, 0.2, 0.2)
            end
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        local label = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
        label:SetWidth(hasIcons and 108 or 132)
        label:SetJustifyH("LEFT")
        cb.label = label
        table.insert(ui.dungeonChecks, cb)
    end

    ui.specQueueBtn = makeButton(p, "Queue", skin and 128 or 120, skin and 24 or 26)
    -- right edge aligned with the centered checklist box (x 202 + 128 = 330)
    ui.specQueueBtn:SetPoint("TOPLEFT", p, "TOPLEFT", skin and 202 or 8, skin and -162 or -346)
    ui.specQueueBtn:SetScript("OnClick", function() LWLFG.toggleSpecificQueue() end)

    -- (skin: no countText — the "N player(s) looking" line had no free row;
    -- the result rows themselves carry that info. Fallback keeps it.)
    if not skin then
        ui.countText = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ui.countText:SetPoint("LEFT", ui.specQueueBtn, "RIGHT", 10, 0)
    end

    ui.resultRows = {}
    -- skin: the checklist fills the entire content band, so the "players
    -- looking" rows only exist in fallback (skin still surfaces the pool
    -- summary on the random panel and specific entries via chat)
    local numRows = skin and 0 or MAX_RESULTS
    local resY = skin and -400 or -370
    local resStep = skin and 18 or 24
    for i = 1, numRows do
        local row = CreateFrame("Frame", nil, p)
        row:SetWidth(skin and 310 or 320); row:SetHeight(skin and 18 or 22)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", skin and 30 or 6, resY - (i - 1) * resStep)
        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        txt:SetPoint("LEFT", row, "LEFT", 0, 0)
        txt:SetWidth(240)
        txt:SetJustifyH("LEFT")
        row.text = txt
        local wb = makeButton(row, "Whisper", 60, 18)
        wb:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        wb:SetScript("OnClick", function()
            if row.playerName then
                ChatFrame_OpenChat("/w " .. row.playerName .. " ")
            end
        end)
        row:Hide()
        table.insert(ui.resultRows, row)
    end
end

-- ---------------------------------------------------------------------------
-- Minimap button (WotLK-style eye; stock 1.12 Mind Vision icon)
-- ---------------------------------------------------------------------------

local MINIMAP_RADIUS_OFFSET = 5

local function positionMinimapButton(angleDeg)
    local btn = ui.minimapBtn
    if not btn then return end
    local angle = math.rad(angleDeg)
    local r = (Minimap:GetWidth() / 2) + MINIMAP_RADIUS_OFFSET
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

function UI.buildMinimapButton()
    if ui.minimapBtn then return end
    local s = LWLFG.settings
    if not s.minimapAngle then s.minimapAngle = 220 end

    -- LFT parents its minimap button to UIParent (anchored relative to the
    -- Minimap), NOT to the Minimap itself: BACKGROUND-layer textures of
    -- Minimap children render UNDER the map art. Match that recipe.
    local btn = CreateFrame("Button", "LWLFGMinimapButton", UIParent)
    btn:SetFrameStrata("MEDIUM")
    btn:RegisterForDrag("LeftButton")

    -- Minimap icon: LFT's static eyeball portrait when available (the same
    -- artwork used in the frame's corner portrait). The LFT battlenetworking
    -- frames are animated but render with broken alpha, so we avoid them here.
    -- Fallback: stock Mind Vision icon.
    btn:SetWidth(31); btn:SetHeight(31)

    -- Base portrait: the static LFT eyeball. Kept solid so the button is
    -- never transparent/ghostly.
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(31); icon:SetHeight(31)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    if LWLFG.ART and LWLFG.ART.portrait then
        icon:SetTexture(LFT_IMG .. "ui-lfg-portrait")
    else
        icon:SetTexture("Interface\\Icons\\Spell_Holy_MindVision")
        icon:SetWidth(20); icon:SetHeight(20)
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -6)
    end
    icon:SetAlpha(1.0)
    btn.icon = icon

    -- Animated glow overlay: LFT's battlenetworking frames are additive
    -- so they look correct on top of the opaque portrait instead of replacing it.
    local hasEye = LWLFG.ART and LWLFG.ART.eyeFrames and table.getn(LWLFG.ART.eyeFrames) > 0
    local iconAnim = btn:CreateTexture(nil, "OVERLAY")
    iconAnim:SetWidth(31); iconAnim:SetHeight(31)
    iconAnim:SetPoint("CENTER", btn, "CENTER", 0, 0)
    iconAnim:SetBlendMode("ADD")
    iconAnim:SetAlpha(0)
    if hasEye then
        iconAnim:SetTexture(LFT_IMG .. "battlenetworking" .. LWLFG.ART.eyeFrames[1])
        btn.eyeNeedInit = (iconAnim:GetTexture() == nil)
    end
    btn.iconAnim = iconAnim

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53); border:SetHeight(53)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- The eyeball is opaque; the animated frames are an additive glow overlay.
    btn.eyeAnim = hasEye and not btn.eyeNeedInit

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    btn.dragging = false
    btn.dragStartAngle = s.minimapAngle

    btn:SetScript("OnDragStart", function()
        this.dragging = true
        this.dragStartAngle = LWLFG.settings.minimapAngle
    end)
    btn:SetScript("OnDragStop", function()
        this.dragging = false
    end)
    btn:SetScript("OnUpdate", function()
        -- LFT recipe: cycle the eye frames every 0.15s while queued,
        -- hold the first frame when idle
        if this.eyeAnim then
            if this.eyeNeedInit then
                -- retry until the client can decode it (subdir files are
                -- unloadable during the first frames after login)
                this.iconAnim:SetTexture(LFT_IMG .. "battlenetworking" .. LWLFG.ART.eyeFrames[1])
                if this.iconAnim:GetTexture() then
                    this.eyeNeedInit = nil
                    this.eyeAnim = true
                end
            end
            local queued = LWLFG.Queue and LWLFG.Queue.status == "QUEUED"
            if queued then
                this.iconAnim:SetAlpha(1)
                this.eyeElapsed = (this.eyeElapsed or 0) + (arg1 or 0.05)
                if this.eyeElapsed >= 0.15 then
                    this.eyeElapsed = 0
                    local frames = LWLFG.ART.eyeFrames
                    this.eyeIdx = math.mod((this.eyeIdx or 0) + 1, table.getn(frames))
                    this.iconAnim:SetTexture(LFT_IMG .. "battlenetworking" .. frames[this.eyeIdx + 1])
                end
            else
                this.iconAnim:SetAlpha(0)
                if this.eyeIdx and this.eyeIdx ~= 0 then
                    this.eyeIdx = 0
                    this.iconAnim:SetTexture(LFT_IMG .. "battlenetworking" .. LWLFG.ART.eyeFrames[1])
                end
            end
        end
        if not this.dragging then return end
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        local dx = (cx / scale) - mx
        local dy = (cy / scale) - my
        local angle
        if dx == 0 then
            angle = (dy >= 0) and 90 or 270
        else
            angle = math.deg(math.atan(dy / dx))
            if dx < 0 then angle = angle + 180 end
        end
        LWLFG.settings.minimapAngle = angle
        positionMinimapButton(angle)
    end)
    btn:SetScript("OnClick", function()
        -- suppress the click that ends a drag
        local moved = math.abs(LWLFG.settings.minimapAngle - this.dragStartAngle)
        if moved > 3 then return end
        UI.toggle()
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Lushwater LFG")
        GameTooltip:AddLine("Click to open  ·  Drag to move", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ui.minimapBtn = btn
    positionMinimapButton(s.minimapAngle)
end

-- ---------------------------------------------------------------------------
-- Ready-check popup
-- ---------------------------------------------------------------------------

function UI.buildReadyPopup()
    local p = CreateFrame("Frame", "LWLFGReadyPopup", UIParent)
    local skin = LWLFG.ART and LWLFG.ART.readyArt and LWLFG.ART.roles
    if skin then
        -- LFT's LFTGroupReady: 308x200 at TOP 0,-150, dungeon art behind
        -- the ready_top/ready_middle chrome, 64px role medallion
        p:SetWidth(308); p:SetHeight(200)
    else
        p:SetWidth(280); p:SetHeight(190)
    end
    p:SetPoint("TOP", UIParent, "TOP", 0, -150)
    p:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:Hide()
    p.answered = false
    p.skin = skin
    ui.readyPopup = p

    if skin then
        -- per-dungeon backdrop (chosen in showReady)
        p.dungeonBg = p:CreateTexture(nil, "BORDER")
        p.dungeonBg:SetWidth(288); p.dungeonBg:SetHeight(128)
        p.dungeonBg:SetPoint("TOP", p, "TOP", 0, -8)

        local mid = p:CreateTexture(nil, "ARTWORK")
        mid:SetWidth(512); mid:SetHeight(128)
        mid:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -72)
        mid:SetTexture(LFT_IMG .. "dungeon_ready_middle")

        local top = p:CreateTexture(nil, "OVERLAY")
        top:SetWidth(512); top:SetHeight(128)
        top:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -8)
        top:SetTexture(LFT_IMG .. "dungeon_ready_top")

        local title = p:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        title:SetPoint("TOP", p, "TOP", 0, -3)
        title:SetText("A group has been formed for:")

        p.dungeonText = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        p.dungeonText:SetPoint("TOP", p, "TOP", 0, -37)

        p.roleText = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        p.roleText:SetPoint("TOP", p, "TOP", -70, -84)
        p.roleText:SetText("Your Role")

        p.myRoleText = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        p.myRoleText:SetPoint("TOP", p, "TOP", -70, -100)

        p.roleIcon = p:CreateTexture(nil, "OVERLAY")
        p.roleIcon:SetWidth(64); p.roleIcon:SetHeight(64)
        p.roleIcon:SetPoint("TOP", p, "TOP", -2, -77)
    else
        local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", p, "TOP", 0, -18)
        title:SetText("|cffffd100Dungeon Ready!|r")

        p.dungeonText = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        p.dungeonText:SetPoint("TOP", title, "BOTTOM", 0, -8)

        p.roleText = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        p.roleText:SetPoint("TOP", p.dungeonText, "BOTTOM", 0, -6)

        p.roleIcon = p:CreateTexture(nil, "ARTWORK")
        p.roleIcon:SetWidth(24); p.roleIcon:SetHeight(24)
        p.roleIcon:SetPoint("TOP", p.roleText, "BOTTOM", 0, -6)
    end

    -- timer bar (plain texture; 1.12 has no StatusBar template)
    local barBg = p:CreateTexture(nil, "ARTWORK")
    barBg:SetTexture(0.15, 0.15, 0.15, 1)
    barBg:SetWidth(220); barBg:SetHeight(10)
    barBg:SetPoint("BOTTOM", p, "BOTTOM", 0, 52)
    p.bar = p:CreateTexture(nil, "OVERLAY")
    p.bar:SetTexture(0.3, 0.8, 0.45, 1)
    p.bar:SetHeight(10)
    p.bar:SetPoint("LEFT", barBg, "LEFT", 0, 0)

    local accept = makeButton(p, skin and "Let's do this!" or "Accept", skin and 120 or 90, 26)
    accept:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", skin and 25 or 30, 18)
    accept:SetScript("OnClick", function() UI.answerReady(true) end)

    local decline = makeButton(p, skin and "Leave Queue" or "Decline", skin and 120 or 90, 26)
    decline:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", skin and -25 or -30, 18)
    decline:SetScript("OnClick", function() UI.answerReady(false) end)

    p:SetScript("OnUpdate", function()
        if p.answered then return end
        local left = READY_TIMEOUT - (GetTime() - p.shownAt)
        if left <= 0 then
            UI.answerReady(false)          -- timeout counts as decline
            return
        end
        p.bar:SetWidth(220 * (left / READY_TIMEOUT))
    end)
end

function UI.showReady(dungeonKey, role)
    local p = ui.readyPopup
    if not p then return end
    p.answered = false
    p.shownAt = GetTime()
    p.dungeonText:SetText(LWLFG.dungeonName(dungeonKey))
    if p.skin then
        -- per-dungeon backdrop + role medallion (LFT layout)
        if LWLFG.ART.bg[dungeonKey] then
            p.dungeonBg:SetTexture(LFT_IMG .. "ui-lfg-background-" .. LWLFG.ART.bg[dungeonKey])
            p.dungeonBg:Show()
        else
            p.dungeonBg:Hide()
        end
        p.myRoleText:SetText(ROLE_LABELS[role] or "")
        p.roleIcon:SetTexture(LFT_IMG .. LFT_ROLE_ICONS[role])
        p.roleIcon:Show()
    else
        p.roleText:SetText("Your role:")
        if LWLFG.ART and LWLFG.ART.ready and LFT_READY_ICONS[role] then
            p.roleIcon:SetTexture(LFT_IMG .. LFT_READY_ICONS[role])
            p.roleIcon:Show()
        elseif ROLE_ICONS[role] then
            p.roleIcon:SetTexture(ROLE_ICONS[role])
            p.roleIcon:Show()
        else
            p.roleIcon:Hide()
        end
    end
    p.bar:SetWidth(220)
    p:Show()
    PlaySound("igMainMenuOpen")
end

function UI.answerReady(accept)
    local p = ui.readyPopup
    if not p or p.answered then return end
    p.answered = true
    p:Hide()
    LWLFG.Queue.respondReady(accept)
end

-- ---------------------------------------------------------------------------
-- Ready-check status strip (WotLK-style): 5 role icons with per-member
-- ready/waiting/declined overlays, driven by Queue.readyState (tracked from
-- the READY broadcasts every client sees).
-- ---------------------------------------------------------------------------

local READY_STATE_ICONS = {
    ready    = "Interface\\Buttons\\UI-CheckBox-Check",
    declined = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7",
    waiting  = nil,
}

local READY_ROLE_ORDER = { TANK = 1, HEAL = 2, DPS = 3 }

function UI.buildReadyStatus()
    local f = CreateFrame("Frame", "LWLFGReadyStatus", UIParent)
    f:SetWidth(324); f:SetHeight(68)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("Ready Check")

    -- one slot per member: role icon + big state overlay
    f.slots = {}
    for i = 1, 5 do
        local role = f:CreateTexture(nil, "ARTWORK")
        role:SetWidth(28); role:SetHeight(28)
        role:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + (i - 1) * 66, -26)
        local state = f:CreateTexture(nil, "OVERLAY")
        state:SetWidth(24); state:SetHeight(24)
        state:SetPoint("BOTTOMRIGHT", role, "BOTTOMRIGHT", 6, -6)
        f.slots[i] = { role = role, state = state }
    end

    f:SetScript("OnUpdate", function()
        if f.hideAt and GetTime() > f.hideAt then
            f.hideAt = nil
            f:Hide()
        end
    end)
    ui.readyStatus = f
end

function UI.readyRefresh()
    local f = ui.readyStatus
    if not f then return end
    local members = LWLFG.Queue and LWLFG.Queue.readyState
    if not members then f:Hide() return end
    -- deterministic layout: TANK, HEAL, then DPS (alphabetical within a role)
    local ordered = {}
    for name, m in pairs(members) do
        table.insert(ordered, { name = name, role = m.role, state = m.state })
    end
    table.sort(ordered, function(a, b)
        if READY_ROLE_ORDER[a.role] ~= READY_ROLE_ORDER[b.role] then
            return READY_ROLE_ORDER[a.role] < READY_ROLE_ORDER[b.role]
        end
        return a.name < b.name
    end)
    for i = 1, 5 do
        local slot, m = f.slots[i], ordered[i]
        if m then
            slot.role:SetTexture(ROLE_ICONS[m.role] or "")
            slot.role:Show()
            slot.state:SetTexture(READY_STATE_ICONS[m.state] or READY_STATE_ICONS.waiting)
            local hasArt = slot.state:GetTexture() and true or false
            if hasArt then slot.state:Show() else slot.state:Hide() end
            -- art + icon tint make the status unmistakable
            if m.state == "ready" then
                slot.role:SetVertexColor(hasArt and 1 or 0.3, 1, hasArt and 1 or 0.3)
            elseif m.state == "declined" then
                slot.role:SetVertexColor(1, 0.35, 0.35)
            else
                slot.role:SetVertexColor(0.45, 0.45, 0.45)
            end
        else
            slot.role:Hide()
            slot.state:Hide()
        end
    end
end

function UI.readyShow()
    local f = ui.readyStatus
    if not f then return end
    f.hideAt = nil
    UI.readyRefresh()
    f:ClearAllPoints()
    if ui.readyPopup then
        f:SetPoint("TOP", ui.readyPopup, "BOTTOM", 0, -4)
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -345)
    end
    f:Show()
end

function UI.readyHide()
    local f = ui.readyStatus
    if not f then return end
    f.hideAt = nil
    f:Hide()
end

function UI.readyHideSoon(sec)
    local f = ui.readyStatus
    if not f then return end
    f.hideAt = GetTime() + (sec or 4)
end

-- ---------------------------------------------------------------------------
-- "Dungeon complete!" animation (LFT recipe: frames 00..30 at ~33fps, hold
-- the last frame, fade out after tick 119, hide at 150 = ~4.5s total)
-- ---------------------------------------------------------------------------

local COMPLETE_LAST_FRAME = 30

function UI.buildCompleteFrame()
    local f = CreateFrame("Frame", "LWLFGDungeonComplete", UIParent)
    f:SetWidth(512); f:SetHeight(128)
    -- above the player character (LFT used CENTER 0,-100, which read as
    -- "orphaned text box" below the toon)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:Hide()
    f.frameIndex = 0
    ui.completeFrame = f

    f.icon = f:CreateTexture(nil, "BACKGROUND")
    f.icon:SetWidth(42); f.icon:SetHeight(42)
    f.icon:SetPoint("LEFT", f, "LEFT", 100, 0)

    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetWidth(512); f.tex:SetHeight(128)
    f.tex:SetPoint("CENTER", f, "CENTER", 0, 0)
    -- LFT DXT5 frames can have junk alpha (invisible in BLEND — see the
    -- minimap-eye fix); ADD ignores alpha, and the glow look suits a
    -- completion swoosh anyway
    f.tex:SetBlendMode("ADD")

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER", f, "CENTER", 25, 10)
    label:SetText("Dungeon complete!")

    f.dungeonText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.dungeonText:SetPoint("CENTER", f, "CENTER", 25, -6)

    f:SetScript("OnShow", function()
        this.startTime = GetTime()
        this.frameIndex = 0
        this.loadTries = 0
        this:SetAlpha(1)
    end)
    f:SetScript("OnUpdate", function()
        if GetTime() < this.startTime + 0.03 then return end
        this.startTime = GetTime()
        -- clamp at the last shipped frame (LFT increments past it, which
        -- would blank the texture for ticks 31-149)
        local idx = this.frameIndex
        if idx > COMPLETE_LAST_FRAME then idx = COMPLETE_LAST_FRAME end
        local name = (idx < 10) and ("0" .. idx) or ("" .. idx)
        this.tex:SetTexture(LFT_IMG .. "dungeon_complete_" .. name)
        -- subdirectory files may not be decodable yet right after login:
        -- hold at frame 0 until the texture sticks (give up after ~6s)
        if this.frameIndex == 0 and not this.tex:GetTexture() then
            this.loadTries = this.loadTries + 1
            if this.loadTries < 200 then return end
        end
        if this.frameIndex > 119 then
            this:SetAlpha(this:GetAlpha() - 0.03)
        end
        if this.frameIndex >= 150 then
            this:Hide()
            return
        end
        this.frameIndex = this.frameIndex + 1
    end)
end

function UI.showComplete(dungeonKey)
    local f = ui.completeFrame
    if not f then return end
    if not (LWLFG.ART and LWLFG.ART.complete) then return end
    -- Debug/test entry point: accept the protocol key ("VC"), any case, or
    -- the full name ("The Deadmines") — and say so when nothing matches,
    -- instead of silently showing a badgeless banner.
    local resolved
    for _, d in ipairs(LWLFG.DUNGEONS) do
        if d.key == dungeonKey then resolved = d.key; break end
    end
    if not resolved then
        local want = strlower(tostring(dungeonKey))
        for _, d in ipairs(LWLFG.DUNGEONS) do
            if strlower(d.key) == want or strlower(d.name) == want then
                resolved = d.key; break
            end
        end
    end
    if not resolved then
        LWLFG.print("showComplete: unknown dungeon '" .. tostring(dungeonKey) ..
            "' (use a key like RFC, VC, DM, ...)")
        return
    end
    dungeonKey = resolved
    if LWLFG.ART.icon[dungeonKey] then
        f.icon:SetTexture(LFT_IMG .. "lfgicon-" .. LWLFG.ART.icon[dungeonKey])
        f.icon:SetTexCoord(0, 1, 0, 1)
        f.icon:Show()
    elseif LWLFG.ART.bg[dungeonKey] then
        -- LFT never shipped an RFC icon; crop its own background art (256x128)
        -- to a center square as the badge.
        f.icon:SetTexture(LFT_IMG .. "ui-lfg-background-" .. LWLFG.ART.bg[dungeonKey])
        f.icon:SetTexCoord(0.25, 0.75, 0, 1)
        f.icon:Show()
    else
        f.icon:Hide()
    end
    f.dungeonText:SetText(LWLFG.dungeonName(dungeonKey))
    f.tex:SetTexture(LFT_IMG .. "dungeon_complete_00")
    f:Show()
end

-- ---------------------------------------------------------------------------
-- Refreshers
-- ---------------------------------------------------------------------------

function UI.refreshRoleButtons()
    for _, b in ipairs(ui.roleButtons or {}) do
        paintRoleEntry(b, LWLFG.settings.specRoles[b.roleValue] and true or false,
                       LWLFG.roleAllowed(b.roleValue))
    end
end

local function refreshRqRoleChecks()
    for _, b in ipairs(ui.rqRoleChecks or {}) do
        paintRoleEntry(b, LWLFG.settings.rqRoles[b.roleValue] and true or false,
                       LWLFG.roleAllowed(b.roleValue))
    end
end

-- short display names for the skin's narrow checklist columns (full name
-- stays on the tooltip); only the ones that would wrap
local SKIN_SHORT_NAMES = { STK = "Stockades", LBRS = "LBRS", UBRS = "UBRS" }

-- dungeon checklist: restore saved checks; disable/grey any the player is no
-- longer eligible for (level range or server phase-open set).
local function refreshDungeonChecks()
    local lvl = UnitLevel("player")
    local eligibleKeys = {}
    for _, k in ipairs(LWLFG.eligibleDungeons(lvl)) do
        eligibleKeys[k] = true
    end
    for _, cb in ipairs(ui.dungeonChecks or {}) do
        local key = cb.dungeonKey
        local isEligible = eligibleKeys[key] and true or false

        -- if the player is no longer eligible, forcibly uncheck and clear it
        if not isEligible and LWLFG.settings.dungeons[key] then
            LWLFG.settings.dungeons[key] = nil
        end

        cb:SetChecked(LWLFG.settings.dungeons[key] and true or false)
        if cb.iconTex and not cb.iconTex:GetTexture() then
            cb.iconTex:SetTexture(LFT_IMG .. "lfgicon-" .. LWLFG.ART.icon[key])
        end

        local d = cb.dungeonDef
        local name = (ui.skin and SKIN_SHORT_NAMES[key]) or d.name
        if isEligible then
            cb:Enable()
            cb.label:SetText("|cff7fd6a8" .. name .. "|r")
        else
            -- keep enabled so OnEnter/OnClick fire; OnClick blocks the check
            cb:Enable()
            cb.label:SetText("|cff888888" .. name .. "|r")
        end
    end
end

-- Rewards inset: server-computed preview (money + XP with coin icons)
local function refreshRewards()
    if not ui.rwGoldText then return end
    local rw = LWLFG.Bot and LWLFG.Bot.reward
    local copper = rw and rw.copper or 0
    local xp = rw and rw.xp or 0

    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local rest = math.mod(copper, 100)

    ui.rwGoldText:SetText(gold > 0 and gold or "")
    ui.rwSilverText:SetText((gold > 0 or silver > 0) and silver or "")
    ui.rwCopperText:SetText(copper > 0 and rest or "?")
    if xp > 0 then
        ui.rwXPText:SetText("Experience: |cff7fd6a8" .. xp .. "|r")
    else
        ui.rwXPText:SetText("Experience: |cff888888none (level capped)|r")
    end
    centerMoneyRow()
end

function UI.refreshResults()
    if LWLFG.sweepSpecific then LWLFG.sweepSpecific() end
    local list = {}
    for name, e in pairs(LWLFG.specificEntries) do
        table.insert(list, { name = name, e = e })
    end
    table.sort(list, function(a, b) return a.e.level < b.e.level end)

    for i, row in ipairs(ui.resultRows or {}) do
        local item = list[i]
        if item then
            local e = item.e
            local nd = table.getn(LWLFG.split(e.dungeons, ","))
            row.playerName = item.name
            row.text:SetText("|cffffd100" .. item.name .. "|r " .. e.level .. " "
                .. (e.class or "?") .. " — "
                .. string.gsub(ROLE_LABELS[e.role] or e.role, "%+", "/")
                .. " |cff888888(" .. nd .. " dungeon(s))|r")
            row:Show()
        else
            row.playerName = nil
            row:Hide()
        end
    end
    if ui.countText then
        ui.countText:SetText(table.getn(list) .. " player(s) looking")
    end
end

-- "42s" / "12m 05s" / "1h 03m 42s" for the queue timer
local function fmtDuration(sec)
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor(math.mod(sec, 3600) / 60)
    local s = math.mod(sec, 60)
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, s) end
    if m > 0 then return string.format("%dm %02ds", m, s) end
    return s .. "s"
end

local function refreshRandomStatus()
    if not ui.statusText then return end
    local Q = LWLFG.Queue
    local s = Q.status
    if s == "IDLE" then
        ui.findBtn:SetText("Find Group")
        ui.statusText:SetText("|cff888888Not queued.|r")
    elseif s == "QUEUED" then
        ui.findBtn:SetText("|cffff6060Leave Queue|r")
        ui.statusText:SetText("|cff7fd6a8In queue|r — waiting "
            .. fmtDuration(GetTime() - Q.queueStart))
    elseif s == "PROPOSED" then
        ui.findBtn:SetText("|cffff6060Leave Queue|r")
        ui.statusText:SetText("|cffffd100Group found!|r Answer the ready check.")
    elseif s == "FORMING" then
        ui.findBtn:SetText("|cffff6060Leave Queue|r")
        ui.statusText:SetText("|cffffd100Forming party|r — invites are on the way.")
    elseif s == "GROUPED" then
        ui.findBtn:SetText("Find Group")
        ui.statusText:SetText("|cffffd100Group formed for "
            .. LWLFG.dungeonName(Q.propDungeon or "?") .. "|r — Good Luck!")
    end

    local left = Q.deserterRemaining and Q.deserterRemaining() or 0
    if left > 0 then
        ui.deserterText:SetText("|cffff6060Deserter:|r " .. math.ceil(left) .. "s remaining")
    else
        ui.deserterText:SetText("")
    end

    -- server teleport toggle
    if ui.teleportBtn then
        local showTele = Q.status == "GROUPED" and LWLFG.Bot and LWLFG.Bot.available
        if showTele then
            if Q.inDungeon then
                ui.teleportBtn:SetText("Teleport out of dungeon")
            else
                ui.teleportBtn:SetText("Teleport to dungeon")
            end
            ui.teleportBtn:Show()
        else
            ui.teleportBtn:Hide()
        end
        positionRandomButtons(showTele)
    end

    -- pool summary (queue info is irrelevant once a group has formed)
    local inGroup = (s == "FORMING" or s == "GROUPED")
    if ui.poolLabel then
        if inGroup then ui.poolLabel:Hide() else ui.poolLabel:Show() end
    end
    if ui.poolText then
        if inGroup then ui.poolText:Hide() else ui.poolText:Show() end
    end
    local counts, total = { TANK = 0, HEAL = 0, DPS = 0 }, 0
    for _, e in pairs(Q.entries) do
        total = total + 1
        for r, _ in pairs(counts) do
            if e.roles[r] then counts[r] = counts[r] + 1 end
        end
    end
    if ui.poolText and not inGroup then
        ui.poolText:SetText(total .. " queued — |cffc79c6eTANK " .. counts.TANK
            .. "|r  |cff69ccf0HEAL " .. counts.HEAL .. "|r  |cffff7d0aDPS "
            .. counts.DPS .. "|r")
    end
end

function UI.refresh()
    UI.refreshRoleButtons()
    refreshRqRoleChecks()
    refreshDungeonChecks()
    refreshRewards()
    UI.refreshResults()
    refreshRandomStatus()   -- keep Find Group / Teleport buttons centered immediately

    if ui.specQueueBtn then
        if LWLFG.specificQueued then
            ui.specQueueBtn:SetText("|cffff6060Leave Queue|r")
        else
            ui.specQueueBtn:SetText("Queue")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function UI.onEnteringWorld()
    -- subdirectory textures only become decodable around PEW (see the
    -- buildMinimapButton quirk note); belt-and-suspenders init in case the
    -- OnUpdate retry hasn't stuck yet
    local btn = ui.minimapBtn
    if btn and btn.eyeNeedInit and btn.iconAnim then
        btn.iconAnim:SetTexture(LFT_IMG .. "battlenetworking" .. LWLFG.ART.eyeFrames[1])
        if btn.iconAnim:GetTexture() then
            btn.eyeNeedInit = nil
            btn.eyeAnim = true
        end
    end
    LWLFG.myFaction = LWLFG.myFaction or LWLFG.detectFaction()
    UI.refresh()
end

function UI.toggle()
    if not ui.frame then return end
    if ui.frame:IsVisible() then
        ui.frame:Hide()
    else
        -- ask the server bot again if we never got its replies (the
        -- reward preview/eligibility arrive over the hidden channel)
        if LWLFG.Bot and not LWLFG.Bot.reward then LWLFG.Bot.requestEligible() end
        rotateRewardsBg()
        UI.refresh()
        ui.frame:Show()
    end
end

UI._statusElapsed = 0
function UI.tick(elapsed)
    -- subdirectory textures only become decodable some time AFTER login;
    -- retry the minimap-eye init here — this loop provably fires every
    -- frame (core drives it), the button's own OnUpdate apparently does not
    local btn = ui.minimapBtn
    if btn and btn.eyeNeedInit and btn.iconAnim then
        btn.iconAnim:SetTexture(LFT_IMG .. "battlenetworking" .. LWLFG.ART.eyeFrames[1])
        if btn.iconAnim:GetTexture() then
            btn.eyeNeedInit = nil
            btn.eyeAnim = true
        end
    end
    UI._statusElapsed = UI._statusElapsed + elapsed
    if UI._statusElapsed < 0.5 then return end
    UI._statusElapsed = 0
    refreshRandomStatus()
end
