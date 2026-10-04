-- ============================================================
-- aislopmatch_bots / bot_core.lua
-- Core bot manager: spawning, team assignment, config-driven loadouts,
-- per-bot think dispatch, and damage/death hooks.
-- ============================================================

include("aislopmatch_bots/bot_util.lua")
include("aislopmatch_bots/bot_nav.lua")
include("aislopmatch_bots/bot_combat.lua")
include("aislopmatch_bots/bot_think.lua")

-- ── ConVars ──────────────────────────────────────────────────
local cv_enabled  = CreateConVar("tdm_bots_enabled",  "1",    FCVAR_NOTIFY, "Enable/disable TDM bot AI entirely")
local cv_max      = CreateConVar("tdm_bots_max",       "16",   FCVAR_NOTIFY, "Maximum bots allowed")
local cv_skill    = CreateConVar("tdm_bots_skill",     "2",    FCVAR_NOTIFY, "Bot skill level: 1=easy 2=medium 3=hard")
local cv_teammode = CreateConVar("tdm_bots_teammode",  "auto", FCVAR_NOTIFY, "auto | 1 | 2 — which team bots are assigned to")

TDMBots = TDMBots or {}
local TDMBotsPending = {}

-- ── Team balancing ────────────────────────────────────────────
local function GetBotCount()
    local n = 0
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:IsBot() then n = n + 1 end
    end
    return n
end

local function PickTeam()
    local mode = cv_teammode:GetString()
    if mode=="1" then return 1 end
    if mode=="2" then return 2 end
    local c1, c2 = 0, 0
    -- Count human (non-bot) players only by their actual team.
    -- Bots are counted separately from TDMBots/TDMBotsPending to avoid
    -- double-counting and to handle the race where Team() is still 0.
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and not ply:IsBot() then
            if ply:Team()==1 then c1=c1+1 elseif ply:Team()==2 then c2=c2+1 end
        end
    end
    -- Count already-registered bots by their assigned intendedTeam
    for _, bd in pairs(TDMBots) do
        local t = bd.intendedTeam or 0
        if t==1 then c1=c1+1 elseif t==2 then c2=c2+1 end
    end
    -- Count pending bots (spawning right now, not yet in TDMBots)
    for _, pend in pairs(TDMBotsPending) do
        if pend.team==1 then c1=c1+1 elseif pend.team==2 then c2=c2+1 end
    end
    return (c1<=c2) and 1 or 2
end

-- ── Config-aware class and loadout system ────────────────────
--
-- GetClassWeaponPool reads the active TDM_CONFIG (whatever config the server
-- has loaded — custom ARC9 packs, non-ARC9 weapons, anything) and builds a
-- list of weapons per slot for the given class.  It handles multiple common
-- config structures without hardcoding any weapon class names.
--
-- PickLoadout then selects one random weapon per slot and stores it
-- PERMANENTLY in bd.loadout — it is never cleared on respawn, so the bot
-- plays the same loadout for its entire session (matching real-player UX).

local function GetClassDef(classID)
    if not TDM_CONFIG or not TDM_CONFIG.Classes then return nil end
    for _, cls in ipairs(TDM_CONFIG.Classes) do
        if tostring(cls.id or "") == tostring(classID) then return cls end
    end
    return nil
end

-- Determines whether a weapon class string belongs to a given slot.
-- Uses TDM_GetWeaponDef when available; falls back to common naming conventions.
local function ClassifyWeaponSlot(wepClass)
    if not wepClass or wepClass=="" then return "" end
    local def = TDM_GetWeaponDef and TDM_GetWeaponDef(wepClass)
    if def and def.slot then return tostring(def.slot) end
    -- Naming convention fallback (ARC9 and common TDM weapon packs)
    local c = wepClass:lower()
    if c:find("_sn_") or c:find("_mm_") or c:find("_ar_") or c:find("_lm_") or c:find("_sm_") or c:find("_sg_") then return "primary" end
    if c:find("_pi_") then return "secondary" end
    if c:find("_me_") or c:find("knife") or c:find("melee") then return "melee" end
    if c:find("grenade") or c:find("_nade") or c:find("frag") or c:find("flash") or c:find("smoke") then return "grenade" end
    -- Anything else with launcher/rocket/rpg/gl hints → gadget
    if c:find("launcher") or c:find("rocket") or c:find("rpg") or c:find("_gl_") or c:find("_rl_")
       or c:find("ammo") or c:find("crate") or c:find("claymore") or c:find("mine") then return "gadget" end
    return ""
end

-- Extracts all weapon class strings from a class definition, regardless of
-- how the config author structured the table (many different TDM configs exist).
local function ExtractWeaponsFromClassDef(classDef)
    if not classDef then return {} end
    local found = {}
    local seen  = {}
    local function add(v)
        if type(v)=="string" and v~="" and not seen[v] then
            seen[v]=true; table.insert(found, v)
        end
    end
    local function scanTable(t)
        if type(t)~="table" then return end
        for k, v in pairs(t) do
            if type(v)=="string" then
                -- Only include values that look like weapon class names
                if v:find("arc9",1,true) or v:find("weapon_",1,true)
                   or v:find("_sn_") or v:find("_ar_") or v:find("_pi_")
                   or v:find("_sm_") or v:find("_sg_") or v:find("_lm_")
                   or v:find("_mm_") or v:find("_me_") or v:find("_gl_")
                   or ClassifyWeaponSlot(v) ~= "" then
                    add(v)
                end
            elseif type(v)=="table" then
                -- Handle sub-tables like {class="...", slot="..."} or {"arc9_...", "primary"}
                if type(v.class)=="string" then add(v.class)
                elseif type(v[1])=="string" and (v[1]:find("arc9",1,true) or v[1]:find("weapon_",1,true) or ClassifyWeaponSlot(v[1])~="") then
                    add(v[1])
                else
                    -- Shallow recurse one level for { primary={...}, secondary={...} } structures
                    local k_lower = type(k)=="string" and k:lower() or ""
                    if k_lower=="weapons" or k_lower=="loadout" or k_lower=="primary"
                       or k_lower=="secondary" or k_lower=="gadget" or k_lower=="grenade"
                       or k_lower=="melee" then
                        for _, wv in ipairs(type(v)=="table" and v or {v}) do
                            if type(wv)=="string" then add(wv)
                            elseif type(wv)=="table" then
                                if type(wv.class)=="string" then add(wv.class)
                                elseif type(wv[1])=="string" then add(wv[1]) end
                            end
                        end
                    end
                end
            end
        end
    end
    scanTable(classDef)
    return found
end

-- Returns { primary={}, secondary={}, gadget={} } for the given classID.
local function GetClassWeaponPool(classID)
    local pool = { primary={}, secondary={}, gadget={} }
    local classDef = GetClassDef(classID)
    if not classDef then return pool end

    local seen = { primary = {}, secondary = {}, gadget = {} }
    local function addToSlot(slot, cls)
        if slot ~= "primary" and slot ~= "secondary" and slot ~= "gadget" then return end
        if type(cls) ~= "string" or cls == "" then return end
        if seen[slot][cls] then return end
        seen[slot][cls] = true
        table.insert(pool[slot], cls)
    end

    -- Prefer explicit slot keys from the class config. This supports custom
    -- weapon class names that don't match naming heuristics.
    local function addExplicitSlot(slot, v)
        if type(v) == "string" then
            addToSlot(slot, v)
            return
        end
        if type(v) ~= "table" then return end

        for k2, v2 in pairs(v) do
            if type(v2) == "string" then
                addToSlot(slot, v2)
            elseif type(v2) == "table" then
                if type(v2.class) == "string" then
                    addToSlot(slot, v2.class)
                elseif type(v2[1]) == "string" then
                    addToSlot(slot, v2[1])
                else
                    local key2 = type(k2) == "string" and k2:lower() or ""
                    if key2 == "primary" or key2 == "secondary" or key2 == "gadget" then
                        addExplicitSlot(key2, v2)
                    else
                        addExplicitSlot(slot, v2)
                    end
                end
            end
        end
    end

    local function scanExplicitSlots(t)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            local key = type(k) == "string" and k:lower() or ""
            if key == "primary" or key == "secondary" or key == "gadget" then
                addExplicitSlot(key, v)
            elseif (key == "weapons" or key == "loadout") and type(v) == "table" then
                scanExplicitSlots(v)
            end
        end
    end

    scanExplicitSlots(classDef)

    local weapons = ExtractWeaponsFromClassDef(classDef)
    for _, wepClass in ipairs(weapons) do
        local slot = ClassifyWeaponSlot(wepClass)
        if slot=="primary" then
            addToSlot("primary", wepClass)
        elseif slot=="secondary" then
            addToSlot("secondary", wepClass)
        elseif slot=="gadget" then
            addToSlot("gadget", wepClass)
        end
    end
    return pool
end

-- Detect what kind of gadget a weapon is so CombatThink knows how to use it.
local function DetectGadgetType(gadgetClass)
    if not gadgetClass or gadgetClass=="" then return "other" end
    local c = gadgetClass:lower()
    -- Launchers: RPG, GL (grenade launcher), RL (rocket launcher)
    if c:find("_gl_") or c:find("_rl_") or c:find("rpg") or c:find("launcher") or c:find("rocket") then
        return "launcher"
    end
    -- Claymores / mines → recon (no-op)
    if c:find("claymore") or c:find("_mine") or c:find("recon") then
        return "recon"
    end
    -- Ammo / munition crates → support
    if c:find("ammo") or c:find("crate") or c:find("munition") or c:find("support") then
        return "support"
    end
    -- Try TDM weapon def for anything not caught above
    local def = TDM_GetWeaponDef and TDM_GetWeaponDef(gadgetClass)
    if def and def.name then
        local n = def.name:lower()
        if n:find("launcher") or n:find("rocket") or n:find("grenade") then return "launcher" end
        if n:find("ammo") or n:find("crate") or n:find("munition") then return "support" end
        if n:find("claymore") or n:find("mine") then return "recon" end
    end
    return "other"
end

-- Treat gadgets as disabled when common config flags explicitly disable them.
-- Unknown/missing flags default to enabled for compatibility with older configs.
local function GadgetsEnabled()
    local cfg = TDM_CONFIG
    if not istable(cfg) then return true end
    if cfg.GadgetsEnabled == false then return false end
    if cfg.EnableGadgets == false then return false end
    if cfg.AllowGadgets == false then return false end
    if cfg.FieldUpgradesEnabled == false then return false end
    return true
end

-- ── ARC9 random attachment loadouts ──────────────────────────
-- Mirrors how ARC9 Gunfight / Gun Game randomise weapon builds.
-- Called once per weapon per session — the result stays for the bot's life.
--
-- ARC9 weapons store attachment slot definitions in SWEP.Attachments:
--   { PrintName="Muzzle", Slot={"att_class_1","att_class_2",...}, ... }
-- To apply attachments we try the gunfight module API first, then fall back
-- ── Bot loadout randomization using TDM_PlayerData directly ──────────────
--
-- TDM_PlayerData is a global table keyed by SteamID64.
-- TDM_GiveLoadoutWeapons (called at t=0.3s after spawn) reads:
--   data.selectedClass                          → which class to give weapons for
--   data.classWeapons[classID].primary/.secondary → which weapon per slot
--   data.weaponAttachments[weaponClass]         → { [slotIdx]=attID } slot map
--
-- By writing into these tables synchronously in PlayerSpawn, our choices are
-- already in place when TDM's 0.3s timer fires — TDM does all the giving.

-- Builds a set table {[classname]=true} from an allowed-weapons array and an
-- optional default classname string.  Used for fast pool-membership lookups.
local function buildPool(pool, default)
    local set = {}
    if pool then
        for _, cls in ipairs(pool) do
            if cls and cls ~= "" then set[cls] = true end
        end
    end
    if default and default ~= "" then set[default] = true end
    return set
end

-- Picks a random ARC9 attachment slot-map for the given weapon class.
-- Replicates the logic of TDM_SV_PickRandomAttachments (sv_init.lua), which is
-- declared as a file-scope local there and is therefore NOT accessible globally.
-- We read the ARC9 attachment table directly via the public ARC9 global.
local function BotPickRandomAttachments(weaponClass)
    if not weaponClass or weaponClass == "" then return {} end
    -- ARC9 stores its registry in ARC9.AttachmentTable or ARC9.Attachments.
    local reg = ARC9 and (ARC9.AttachmentTable or ARC9.Attachments) or nil
    if not reg or not next(reg) then return {} end

    local swep = weapons.Get(weaponClass)
    if not swep or not swep.Attachments then return {} end
    local slots = swep.Attachments
    local slotCount = #slots
    if slotCount <= 0 then return {} end

    local cap = 5
    if TDM_GetMaxEquippedAttachments then cap = TDM_GetMaxEquippedAttachments() end
    if cap <= 0 or cap > slotCount then cap = slotCount end
    local count = math.max(1, math.random(1, cap))   -- always pick at least 1

    -- Shuffle slot indices
    local indices = {}
    for i = 1, slotCount do indices[i] = i end
    for i = slotCount, 2, -1 do
        local j = math.random(i); indices[i], indices[j] = indices[j], indices[i]
    end

    -- Category helpers (mirrors the private helpers in sv_init.lua)
    local function catList(v)
        return type(v) == "table" and v or (v and {v} or {})
    end
    local function attFitsSlot(entry, slotCats)
        if not entry or not slotCats then return false end
        local sl = catList(slotCats)
        local al = catList(entry.Category)
        for _, sc in ipairs(sl) do
            if type(sc) == "string" and sc ~= "" then
                local lsc = sc:lower()
                for _, ac in ipairs(al) do
                    if type(ac) == "string" and ac:lower() == lsc then return true end
                end
            end
        end
        return false
    end
    local function isCamo(entry)
        local function m(v)
            if type(v) ~= "string" then return false end
            local lv = v:lower()
            return lv:find("camo",1,true) or lv:find("skin",1,true) or lv:find("paint",1,true)
        end
        if m(entry.Category) then return true end
        if type(entry.Category) == "table" then
            for _, c in ipairs(entry.Category) do if m(c) then return true end end
        end
        return entry.IsSkin == true or entry.Skin == true
    end
    local function isSticker(entry)
        local function m(v)
            if type(v) ~= "string" then return false end
            local lv = v:lower()
            return lv:find("sticker",1,true) or lv:find("charm",1,true)
                or lv:find("decal",1,true)   or lv:find("tracer",1,true)
                or lv:find("cosmetic",1,true) or lv:find("reticle",1,true)
                or lv:find("kill_effect",1,true) or lv:find("killeffect",1,true)
                or lv:find("emblem",1,true)
        end
        if m(entry.Category) then return true end
        if type(entry.Category) == "table" then
            for _, c in ipairs(entry.Category) do if m(c) then return true end end
        end
        return false
    end
    local function isLauncher(entry)
        local function m(v)
            if type(v) ~= "string" then return false end
            local lv = v:lower()
            return lv:find("launcher",1,true) or lv:find("grenadelaunch",1,true)
                or lv:find("grenade_launch",1,true) or lv:find("m203",1,true)
                or lv:find("masterkey",1,true) or lv:find("ub_shotgun",1,true)
        end
        if m(entry.Category) then return true end
        if type(entry.Category) == "table" then
            for _, c in ipairs(entry.Category) do if m(c) then return true end end
        end
        return false
    end

    local function pickForSlot(slotIdx)
        local slot = slots[slotIdx]
        if not slot or not slot.Category then return nil end
        local candidates = {}
        for id, entry in pairs(reg) do
            if type(entry) == "table"
               and attFitsSlot(entry, slot.Category)
               and not isSticker(entry)
               and not isLauncher(entry)
               and not isCamo(entry) then
                candidates[#candidates + 1] = id
            end
        end
        if #candidates == 0 then return nil end
        return candidates[math.random(#candidates)]
    end

    local result = {}
    local picked = 0
    for _, slotIdx in ipairs(indices) do
        if picked >= count then break end
        local att = pickForSlot(slotIdx)
        if att then result[slotIdx] = att; picked = picked + 1 end
    end
    -- 25% chance to also add a camo to a free slot
    if math.random() < 0.25 then
        for _, slotIdx in ipairs(indices) do
            if not result[slotIdx] then
                local slot = slots[slotIdx]
                if slot and slot.Category then
                    local camos = {}
                    for id, entry in pairs(reg) do
                        if type(entry) == "table"
                           and attFitsSlot(entry, slot.Category)
                           and isCamo(entry) then
                            camos[#camos + 1] = id
                        end
                    end
                    if #camos > 0 then result[slotIdx] = camos[math.random(#camos)] end
                end
                break
            end
        end
    end
    return result
end

-- Applies an ARC9 attachment slot-map to a live weapon entity.
-- Mirrors TDM_SV_ApplyAttachments, which is local to sv_init.lua and
-- therefore inaccessible from this addon.
local function ApplyBotAttachments(wep, slotMap)
    if not IsValid(wep) or not wep.ARC9 or not wep.Attachments then return end
    if not slotMap or not next(slotMap) then return end
    local applied = false
    for slotIdx, attID in pairs(slotMap) do
        local idx  = tonumber(slotIdx)
        local slot = idx and wep.Attachments[idx]
        if slot and attID and attID ~= "" then
            slot.Installed = attID
            applied = true
        end
    end
    if applied then
        if wep.PostModify then
            pcall(function() wep:PostModify() end)
        elseif wep.InvalidateCache then
            pcall(function() wep:InvalidateCache() end)
        end
    end
end

local function ResolveBotMaxLevel()
    local lvl = (TDM_CONFIG and tonumber(TDM_CONFIG.MaxLevel))
             or (TDM_CONFIG and tonumber(TDM_CONFIG.MaxPlayerLevel))
             or 55
    lvl = math.floor(tonumber(lvl) or 55)
    if lvl < 1 then lvl = 1 end
    return lvl
end

-- Keep bot profile at config max every spawn so unlock-gated weapons are usable.
local function EnsureBotMaxLevel(bot, bd)
    if not TDM_PlayerData or not IsValid(bot) then return nil end
    local sid = bot:SteamID64()
    if not sid then return nil end

    local maxLevel = ResolveBotMaxLevel()
    if not TDM_PlayerData[sid] then
        TDM_PlayerData[sid] = {
            xp=0, level=maxLevel, prestige=0, kills=0, deaths=0,
            selectedClass     = tostring((bd and bd.classID) or "1"),
            classWeapons      = {},
            weaponProgress    = {},
            weaponAttachments = {},
            weaponLocked      = false,
            awaitingLoadout   = false,
            isSpectator       = false,
            hasTeam           = false,
            killStreak        = 0,
            nextHealthRegenAt = 0,
        }
    end

    local data = TDM_PlayerData[sid]
    data.level = maxLevel
    data.weaponLocked = false
    return data, maxLevel
end

local function _SortedWeaponList(list)
    local out = {}
    if istable(list) then
        for _, cls in ipairs(list) do
            if type(cls) == "string" and cls ~= "" then
                out[#out + 1] = cls
            end
        end
    end
    table.sort(out)
    return out
end

-- Stamp current class/config weapon sources so bots can refresh when config changes.
local function BuildBotLoadoutStamp(classID)
    local cls = GetClassDef(classID)
    if not cls then return "noclass:" .. tostring(classID) end

    local cp = GetClassWeaponPool(classID)
    local aw = cls.allowedWeapons or {}

    local pri = table.concat(_SortedWeaponList(cp.primary), ",")
    local sec = table.concat(_SortedWeaponList(cp.secondary), ",")
    local gad = table.concat(_SortedWeaponList(cp.gadget), ",")
    local apri = table.concat(_SortedWeaponList(aw.primary), ",")
    local asec = table.concat(_SortedWeaponList(aw.secondary), ",")
    local agad = table.concat(_SortedWeaponList(aw.gadget), ",")

    return table.concat({
        tostring(TDM_CONFIG),
        tostring(classID),
        tostring(GadgetsEnabled()),
        pri, sec, gad,
        apri, asec, agad,
    }, "|")
end

local function SetBotRandomLoadout(bot, bd)
    local data, maxLevel = EnsureBotMaxLevel(bot, bd)
    if not data then return end
    local classID = tostring(bd.classID or "1")
    data.selectedClass = classID
    -- Keep the level at max so any per-spawn level check also passes.
    data.level = maxLevel

    local cls = nil
    for _, c in ipairs(TDM_CONFIG and TDM_CONFIG.Classes or {}) do
        if tostring(c.id) == classID then cls = c; break end
    end
    if not cls then return end

    local aw = cls.allowedWeapons or {}
    local cp = GetClassWeaponPool(classID)

    local function pick(pool)
        if pool and #pool > 0 then return pool[math.random(#pool)] end
        return ""
    end

    -- Prefer weapons discovered from the active class config itself.
    -- Only use allowedWeapons as a secondary source; never fall back to
    -- defaultWeapons for primary/secondary (prevents stale MW19 defaults).
    local primary   = pick(cp.primary)
    if primary == "" then primary = pick(aw.primary) end

    local secondary = pick(cp.secondary)
    if secondary == "" then secondary = pick(aw.secondary) end

    -- Avoid duplicate primary/secondary when a class has a tiny pool.
    if primary ~= "" and secondary ~= "" and primary == secondary then
        for _, clsName in ipairs(cp.secondary or {}) do
            if clsName ~= primary then
                secondary = clsName
                break
            end
        end
    end

    local gadget = ""
    if GadgetsEnabled() then
        gadget = pick(cp.gadget)
        if gadget == "" and istable(aw.gadget) then gadget = pick(aw.gadget) end
    end

    if not data.classWeapons then data.classWeapons = {} end
    data.classWeapons[classID] = {
        primary   = primary,
        secondary = secondary,
        melee     = "",
        grenade   = "",
        gadget    = gadget,
    }

    -- Mark chosen weapons as unlocked in weaponProgress so TDM's level/unlock
    -- check (if any) won't block giving them.  We write both common patterns
    -- (xp+level fields and unlocked=true) for compatibility across TDM versions.
    data.weaponProgress = data.weaponProgress or {}
    local function markUnlocked(cls)
        if not cls or cls == "" then return end
        if not data.weaponProgress[cls] then data.weaponProgress[cls] = {} end
        local wp = data.weaponProgress[cls]
        wp.unlocked = true
        wp.xp       = wp.xp   or 99999
        wp.level    = wp.level or 99
    end
    markUnlocked(primary)
    markUnlocked(secondary)
    markUnlocked(gadget)

    -- Build random attachment slot maps via BotPickRandomAttachments.
    -- Results are stored in bd.pendingAttachments and applied at t=0.8s after
    -- TDM has given the weapons (TDM gives at t=0.3s).
    local pendingAtts = {}
    local function makeSlotMap(weaponClass)
        if not weaponClass or weaponClass == "" then return nil end
        local m = BotPickRandomAttachments(weaponClass)
        return (m and next(m) ~= nil) and m or nil
    end

    local priMap = makeSlotMap(primary);   if priMap then pendingAtts[primary]   = priMap end
    local secMap = makeSlotMap(secondary); if secMap then pendingAtts[secondary] = secMap end
    -- Store on bd only — never TDM_PlayerData (all bots share SteamID64=="0").
    bd.loadout = bd.loadout or {}
    bd.loadout.primary     = primary
    bd.loadout.secondary   = secondary
    bd.loadout.gadget      = gadget
    bd.loadout.gadgetType  = (gadget ~= "") and DetectGadgetType(gadget) or nil
    -- Weapon pool sets: membership tells SelectLoadout which slot a weapon belongs to
    -- WITHOUT needing TDM_GetWeaponDef (works for any weapon base).
    -- Use the full config pool so pruning catches any weapon TDM may have given
    -- (including level-gated defaults not present in allowedWeapons).
    bd.loadout.primaryPool   = buildPool(cp.primary,   primary)
    bd.loadout.secondaryPool = buildPool(cp.secondary, secondary)
    bd.savedAttachments      = pendingAtts
    bd.pendingAttachments    = pendingAtts
    bd.attachmentsRandomized = true
    bd.loadoutStamp          = BuildBotLoadoutStamp(classID)

    print(string.format("[TDMBots] %s — class %s | pri=%s sec=%s gadget=%s",
        bot:Nick(), classID, tostring(primary), tostring(secondary), tostring(gadget)))
end

-- ── Personalities ─────────────────────────────────────────────
-- Every field below has a real, observable effect somewhere in the codebase.
-- Cross-reference (file:function):
--   aggressionBias  bot_combat.lua:state-machine LOS-abandon timeout
--                   bot_nav.lua:  push-vs-stray roam bias
--   crouchFreq      bot_think.lua: passive crouch probability
--   reactionMult    bot_combat.lua: reaction delay (lower = faster reflexes)
--   roamSpeedMult   bot_core.lua:  applied to SetWalkSpeed/SetRunSpeed on spawn
--                                  (Rusher = literally faster, Camper = slower)
--   preferClose     bot_combat.lua: bipod / ADS band
--                   bot_nav.lua:    waypoint width
--   holdRange       bot_nav.lua:   stand-off distance — when in combat with
--                                  LOS at < holdRange, the bot stops moving.
--                                  Campers/Stalkers hold; rushers always push.
--   flankRange      bot_nav.lua:   pincer offset magnitude
--   loneWolf        bot_combat.lua: avoid sharing targets
--                   bot_nav.lua:    take stray paths instead of converging
--   minEngageDist   bot_combat.lua: floors wepTooClose so campers retreat early
--   proneBias       bot_combat.lua: per-personality sniper-prone roll
local PERSONALITIES = {
    -- name        aggB   crouch  react  speed  close  hold  flank  lone   minEng  prone
    { name="Rusher",    aggressionBias= 0.9, crouchFreq=0.05, reactionMult=0.78, roamSpeedMult=1.30, preferClose=true,  holdRange=0,   flankRange=50,  loneWolf=false, minEngageDist=60,  proneBias=0.00 },
    { name="Flanker",   aggressionBias= 0.6, crouchFreq=0.20, reactionMult=0.85, roamSpeedMult=1.10, preferClose=true,  holdRange=0,   flankRange=400, loneWolf=true,  minEngageDist=120, proneBias=0.05 },
    { name="Brawler",   aggressionBias= 0.7, crouchFreq=0.05, reactionMult=0.82, roamSpeedMult=1.20, preferClose=true,  holdRange=0,   flankRange=60,  loneWolf=false, minEngageDist=60,  proneBias=0.00 },
    { name="Stalker",   aggressionBias= 0.0, crouchFreq=0.55, reactionMult=0.95, roamSpeedMult=0.85, preferClose=false, holdRange=700, flankRange=150, loneWolf=true,  minEngageDist=500, proneBias=0.30 },
    { name="Camper",    aggressionBias=-0.4, crouchFreq=0.85, reactionMult=1.05, roamSpeedMult=0.65, preferClose=false, holdRange=950, flankRange=60,  loneWolf=false, minEngageDist=750, proneBias=0.55 },
    { name="Support",   aggressionBias= 0.2, crouchFreq=0.40, reactionMult=1.00, roamSpeedMult=0.95, preferClose=false, holdRange=0,   flankRange=100, loneWolf=false, minEngageDist=250, proneBias=0.10 },
    { name="Aggressor", aggressionBias= 1.0, crouchFreq=0.02, reactionMult=0.72, roamSpeedMult=1.40, preferClose=true,  holdRange=0,   flankRange=40,  loneWolf=false, minEngageDist=50,  proneBias=0.00 },
    { name="Tactician", aggressionBias= 0.3, crouchFreq=0.45, reactionMult=0.95, roamSpeedMult=1.00, preferClose=false, holdRange=400, flankRange=300, loneWolf=true,  minEngageDist=300, proneBias=0.25 },
}

local function PickPersonality(teamNum)
    local counts = {}
    for _, p in ipairs(PERSONALITIES) do counts[p.name]=0 end
    if teamNum and TDMBots then
        for _, bd in pairs(TDMBots) do
            if bd.intendedTeam==teamNum and bd.personality then
                counts[bd.personality.name] = (counts[bd.personality.name] or 0)+1
            end
        end
    end
    local pool = {}
    for i, p in ipairs(PERSONALITIES) do pool[i]=p end
    for i=#pool, 2, -1 do local j=math.random(i); pool[i],pool[j]=pool[j],pool[i] end
    local best, bestCount = pool[1], math.huge
    for _, p in ipairs(pool) do
        local c = counts[p.name] or 0
        if c < bestCount then bestCount=c; best=p end
    end
    return best
end

local BOT_NAMES = {
    "BRAVO","DELTA","FOXTROT","GHOST","NOMAD","SOAP","PRICE",
    "CAPTAIN141","GRINCH","KRUGER","THORNE","MACE","VARGAS","YEGOR",
    "RUIN","OTTER","TEMPLAR","VELIKAN","SAPPER","WATCHER","CODEC",
    "STRELOK","MONOLITH","SKIF","DEMPSEY","NIKOLAI","RICHTOFEN",
}
local function BotName()
    return BOT_NAMES[math.random(#BOT_NAMES)] .. "_" .. math.random(1000, 9999)
end

-- ── Spawn ────────────────────────────────────────────────────
local function PickRandomClassID()
    if TDM_CONFIG and TDM_CONFIG.Classes and #TDM_CONFIG.Classes > 0 then
        local cls = TDM_CONFIG.Classes[math.random(#TDM_CONFIG.Classes)]
        return tostring(cls.id or "1")
    end
    return "1"
end

local function SpawnBot()
    if not cv_enabled:GetBool() then print("[TDMBots] Bots are disabled (tdm_bots_enabled 0)"); return end
    if GetBotCount() >= cv_max:GetInt() then print("[TDMBots] Bot limit reached (" .. cv_max:GetInt() .. ")"); return end

    local team    = PickTeam()
    local classID = PickRandomClassID()
    local skill   = cv_skill:GetInt()
    local name    = BotName()
    -- Loadout (weapon + attachment randomization) is applied in TDMBots_OnSpawn
    -- synchronously before TDM_GiveLoadoutWeapons fires at t=0.3s.
    TDMBotsPending[name] = { team=team, classID=classID, skill=skill }

    local bot = player.CreateNextBot(name)
    if not IsValid(bot) then
        TDMBotsPending[name] = nil
        print("[TDMBots] player.CreateNextBot failed — is the server full?")
        return
    end
    print(string.format("[TDMBots] Creating bot '%s' — Team %d, Class %s, Skill %d", name, team, classID, skill))
end

-- ── Register bot on connect ───────────────────────────────────
hook.Add("PlayerInitialSpawn", "TDMBots_InitialSpawn", function(ply)
    if not IsValid(ply) or not ply:IsBot() then return end
    local name    = ply:Nick()
    local pending = TDMBotsPending[name]
    if not pending then return end
    TDMBotsPending[name] = nil

    local team        = pending.team
    local classID     = pending.classID
    local personality = PickPersonality(team)

    TDMBots[ply] = {
        bot           = ply,
        classID       = classID,
        loadout       = nil,         -- set by SetBotRandomLoadout in TDMBots_OnSpawn
        skill         = pending.skill,
        personality   = personality,
        intendedTeam  = team,
        target        = nil,
        nextShot      = 0,
        nextNav       = 0,
        stuckAt       = CurTime(),
        lastPos       = Vector(0,0,0),
        state         = "idle",
        wantAttack    = false,
        wantCrouch    = false,
        aimAngles     = Angle(0,0,0),
        goal          = nil,
    }

    print(string.format("[TDMBots] Personality: %s | Class: %s", personality.name, classID))

    ply:SetNWBool("TDM_OurBot", true)
    print(string.format("[TDMBots] Bot '%s' registered (Class %s)", ply:Nick(), classID))
end)

-- ── Loadout selection on respawn ─────────────────────────────
--
-- WHY THIS APPROACH:
-- The previous hook (TDMBots_ApplyLoadout) had three problems:
--   1. weapons.Get() returns nil for ARC9 and other non-standard weapon bases,
--      so every ply:Give() was silently skipped.
--   2. The 0.1s timer fired before TDM finished giving its default weapons,
--      meaning our select/strip ran on an incomplete inventory.
--   3. GetClassWeaponPool might return empty pools on configs that don't use
--      predictable field names, so bd.loadout.primary was nil.
--
-- NEW APPROACH — "post-TDM slot pruning":
--   Wait 0.8s for TDM to fully equip the bot.  Then look at what the bot
--   ACTUALLY has, categorised by slot.  If a slot has multiple weapons
--   (TDM gave the whole class weapon pool), pick/confirm one at random and
--   strip the rest.  This creates per-session variety without needing to
--   parse the config at all.  If TDM gave only one per slot, the bot keeps
--   what it has — a consistent loadout per class.  On second+ respawn the
--   persistent choice (bd.loadout.primary etc.) is honoured.
hook.Add("PlayerSpawn", "TDMBots_SelectLoadout", function(ply)
    if not IsValid(ply) or not ply:IsBot() then return end
    local bd = TDMBots[ply]; if not bd then return end

    -- Wait 0.8s: TDM gives weapons at t=0.3s, then some weapon bases run
    -- post-give setup callbacks. We need all of that to finish first.
    timer.Simple(0.8, function()
        if not IsValid(ply) or not ply:Alive() then return end
        local lo = bd.loadout
        if not lo then return end

        -- Gunfight (GamemodeType==2) and GunGame (GamemodeType==3) manage weapon
        -- assignment entirely via their own per-round loadout tables, bypassing
        -- data.classWeapons.  Forcing class-based weapons here would give the bot
        -- an extra primary it shouldn't have, and EnsureActiveWeapon's early-return
        -- guard ("slot==primary and hasAmmo") would then lock it onto that weapon
        -- forever, preventing it from ever using the intended gunfight/gungame weapon.
        local gtype       = TDM_CONFIG and TDM_CONFIG.GamemodeType or 0
        local isManagedMode = (gtype == 2 or gtype == 3)

        if isManagedMode then
            -- Scan the bot's actual post-give inventory and rebuild bd.loadout to
            -- reflect what TDM assigned this round.
            local newPri, newSec = "", ""
            local newPriPool, newSecPool = {}, {}
            for _, w in ipairs(ply:GetWeapons()) do
                if IsValid(w) then
                    local wc = w:GetClass()
                    local ws = ClassifyWeaponSlot(wc)
                    if ws == "primary" then
                        if newPri == "" then newPri = wc end
                        newPriPool[wc] = true
                    elseif ws == "secondary" then
                        if newSec == "" then newSec = wc end
                        newSecPool[wc] = true
                    elseif ws ~= "melee" and ws ~= "grenade" and ws ~= "gadget" and ws ~= "" then
                        if newSec == "" then newSec = wc end
                        newSecPool[wc] = true
                    end
                end
            end
            -- Pistol-only round: bot has only a secondary.  Promote it to the
            -- primary loadout slot so EnsureActiveWeapon finds it at priority 1
            -- instead of having to fall all the way through to priority 4.
            if newPri == "" and newSec ~= "" then
                newPri = newSec; newPriPool = newSecPool; newSec = ""; newSecPool = {}
            end
            lo.primary       = newPri
            lo.secondary     = newSec
            lo.primaryPool   = newPriPool
            lo.secondaryPool = newSecPool
        else
            -- Normal TDM / FFA: enforce the chosen weapon regardless of what TDM gave.
            -- Strip by slot rather than by pool membership so level-gated defaults
            -- (which may not be in our pool tables) are also removed, then Give().
            local priWant = lo.primary   or ""
            local secWant = lo.secondary or ""

            local function enforceSlot(wantClass, slot)
                if wantClass == "" then return end
                -- Strip any same-slot weapon that isn't the desired one.
                for _, w in ipairs(ply:GetWeapons()) do
                    if IsValid(w) then
                        local wc = w:GetClass()
                        if wc ~= wantClass and ClassifyWeaponSlot(wc) == slot then
                            ply:StripWeapon(wc)
                        end
                    end
                end
                -- Give the desired weapon directly, bypassing any TDM level check.
                if not ply:HasWeapon(wantClass) then
                    local wep = ply:Give(wantClass)
                    if IsValid(wep) and wep.ARC9 then wep.ForceDefaultAmmo = 0 end
                end
            end

            enforceSlot(priWant, "primary")
            enforceSlot(secWant, "secondary")
        end

        -- Select best available weapon.
        local pickPri = lo.primary or ""
        if pickPri ~= "" and ply:HasWeapon(pickPri) then
            ply:SelectWeapon(pickPri)
        elseif lo.secondary and lo.secondary ~= "" and ply:HasWeapon(lo.secondary) then
            ply:SelectWeapon(lo.secondary)
        end

        -- Apply pre-computed ARC9 attachments (class-based loadout).
        -- Apply ARC9 attachments via our own ApplyBotAttachments helper.
        -- (TDM_SV_ApplyAttachments is a local in sv_init.lua; not accessible here.)
        local pending = bd.pendingAttachments
        if pending then
            for weaponClass, slotMap in pairs(pending) do
                local wep = ply:GetWeapon(weaponClass)
                if IsValid(wep) then ApplyBotAttachments(wep, slotMap) end
            end
            bd.pendingAttachments = nil
        end

        -- In managed modes: generate and apply fresh ARC9 attachments for whatever
        -- weapon(s) TDM gave this round (these weren't pre-computed in SetBotRandomLoadout).
        if isManagedMode then
            for _, w in ipairs(ply:GetWeapons()) do
                if IsValid(w) and w.ARC9 then
                    local wc = w:GetClass()
                    -- Reuse saved slot-map for this weapon if we already rolled one;
                    -- otherwise pick a fresh random set and save it for future respawns.
                    if bd.savedAttachments and bd.savedAttachments[wc] then
                        ApplyBotAttachments(w, bd.savedAttachments[wc])
                    else
                        local slotMap = BotPickRandomAttachments(wc)
                        if slotMap and next(slotMap) then
                            ApplyBotAttachments(w, slotMap)
                            bd.savedAttachments = bd.savedAttachments or {}
                            bd.savedAttachments[wc] = slotMap
                        end
                    end
                end
            end
        end
    end)
end)

-- ── Console commands ──────────────────────────────────────────
concommand.Add("tdmbot", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then ply:ChatPrint("[TDMBots] Admins only."); return end
    local count = math.Clamp(tonumber(args[1]) or 1, 1, 10)
    for i=1, count do SpawnBot() end
end, nil, "Spawn TDM AI bot(s). Usage: tdmbot [count]")

concommand.Add("bot_kick", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local kicked=0
    for _, p in ipairs(player.GetAll()) do
        if IsValid(p) and p:IsBot() then TDMBots[p]=nil; p:Kick("Bot removed"); kicked=kicked+1 end
    end
    print("[TDMBots] Kicked " .. kicked .. " bot(s)")
end, nil, "Kick all TDM bots from the server")

concommand.Add("bot_kick_one", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    for _, p in ipairs(player.GetAll()) do
        if IsValid(p) and p:IsBot() then TDMBots[p]=nil; p:Kick("Bot removed"); return end
    end
end, nil, "Kick one TDM bot")

-- ── Round-start spawn mortar lobs ─────────────────────────────
local SPAWN_CLASSES = {
    "info_player_start","info_player_deathmatch","info_player_teamspawn",
    "info_player_counterterrorist","info_player_terrorist","tdm_spawn",
}
local function FindEnemySpawnPositions(bot)
    local myPos=bot:GetPos(); local spawns={}
    for _, cls in ipairs(SPAWN_CLASSES) do
        for _, ent in ipairs(ents.FindByClass(cls)) do
            if IsValid(ent) then table.insert(spawns,{pos=ent:GetPos(),dsq=myPos:DistToSqr(ent:GetPos())}) end
        end
    end
    if #spawns==0 then return {} end
    table.sort(spawns, function(a,b) return a.dsq>b.dsq end)
    local result={}
    for i=1, math.min(4,#spawns) do table.insert(result,spawns[i].pos) end
    return result
end

local function TriggerSpawnLobs()
    for bot, bd in pairs(TDMBots or {}) do
        if not IsValid(bot) or not bot:Alive() then continue end
        if math.random()<0.35 then
            local candidates=FindEnemySpawnPositions(bot)
            if #candidates>0 then bd.pendingSpawnLob=candidates[math.random(#candidates)] end
        end
    end
end

local _wasRoundActive = false
-- Round-start detection runs on a slow timer instead of every Think for perf.
timer.Create("TDMBots_RoundStartDetect", 0.5, 0, function()
    local active = TDMBot_RoundActive()
    if active and not _wasRoundActive then
        _wasRoundActive=true
        timer.Simple(3.0, function() if TDMBot_RoundActive() then TriggerSpawnLobs() end end)
    elseif not active then _wasRoundActive=false end
end)

-- ── Per-frame think dispatcher ────────────────────────────────
hook.Add("Think", "TDMBots_Think", function()
    if not cv_enabled:GetBool() then return end
    for bot, bd in pairs(TDMBots) do
        if not IsValid(bot) or not bot:IsBot() then TDMBots[bot]=nil
        elseif bot:Alive() then TDMBot_Think(bot, bd) end
    end
end)

-- ── Grenade detection ─────────────────────────────────────────
local GRENADE_DETECT_CLASSES = { grenade=true, _nade=true, frag=true, flashbang=true, smoke=true }
local function IsGrenadeEntity(ent)
    if not IsValid(ent) then return false end
    local cls=ent:GetClass():lower()
    for pat in pairs(GRENADE_DETECT_CLASSES) do if cls:find(pat,1,true) then return true end end
    return false
end
hook.Add("EntityCreated", "TDMBots_GrenadeDetect", function(ent)
    timer.Simple(0.05, function()
        if not IsValid(ent) or not IsGrenadeEntity(ent) then return end
        local grenPos=ent:GetPos(); local now=CurTime()
        for bot, bd in pairs(TDMBots or {}) do
            if IsValid(bot) and bot:Alive() then
                local dsq=bot:GetPos():DistToSqr(grenPos)
                if dsq<600*600 then
                    if not bd.nearbyGrenadePos or bot:GetPos():DistToSqr(bd.nearbyGrenadePos)>dsq then
                        bd.nearbyGrenadePos=grenPos; bd.nearbyGrenadeAt=now
                    end
                end
            end
        end
    end)
end)

-- ── Cleanup on disconnect ─────────────────────────────────────
hook.Add("PlayerDisconnected", "TDMBots_Cleanup", function(ply)
    if IsValid(ply) and ply:IsBot() then TDMBots[ply]=nil end
end)

-- ── Reset per-life state on respawn ──────────────────────────
-- NOTE: bd.loadout is intentionally NOT reset here.
-- The loadout is picked once on connect and persists for the session,
-- matching the real-player experience of choosing a class at the start.
hook.Add("PlayerSpawn", "TDMBots_OnSpawn", function(ply)
    if not IsValid(ply) or not ply:IsBot() then return end
    local bd = TDMBots[ply]; if not bd then return end

    EnsureBotMaxLevel(ply, bd)

    local classID = tostring(bd.classID or "1")
    local currentStamp = BuildBotLoadoutStamp(classID)
    local needsLoadoutRefresh = (not bd.loadout)
        or (not bd.loadout.primary)
        or (bd.loadout.primary == "")
        or (bd.loadoutStamp ~= currentStamp)

    -- On the FIRST spawn: pick a random loadout (stored only in bd.loadout).
    -- On ALL subsequent spawns: re-queue the saved attachments so SelectLoadout
    -- can apply them again after TDM gives weapons.
    -- We intentionally do NOT write to TDM_PlayerData here — all GMod bots share
    -- SteamID64()=="0" so that table is a single entry for every bot on the server.
    -- The actual weapon correction happens in TDMBots_SelectLoadout at t=0.6s.
    if needsLoadoutRefresh then
        SetBotRandomLoadout(ply, bd)
    else
        bd.pendingAttachments = bd.savedAttachments
    end

    bd.state              = "idle"
    bd.target             = nil
    bd.cachedAimPoint     = nil    -- clear stale aim from previous life
    bd.aimFrozen          = false
    bd.aimUnfreezeAt      = 0
    bd.nextNoiseAt        = 0
    bd.nextNav            = 0
    bd.nextShot           = 0
    bd.stuckAt            = CurTime()
    bd.stuckSnapshotPos   = nil
    bd.stuckSnapshotAt    = nil
    bd.nextDeadEndCheck   = 0
    bd.wantAttack         = false
    bd.wantCrouch         = false
    bd.tapUntil           = nil
    bd.wantReload         = false
    bd.isReloading        = false
    bd.reloadDoneAt       = nil
    bd.reloadStartAt      = nil
    bd.nextReloadAllowed  = 0
    bd.navPath            = nil
    bd.goal               = nil
    bd.ubglPhase          = nil
    bd.wantUBGLToggle     = false
    bd.ubglCooldown       = 0
    bd.wanderOffset       = 0
    bd.wantADS            = false
    bd.grenPhase          = nil
    bd.grenPhaseAt        = nil
    bd.grenClass          = nil
    bd.grenSwitchBackTo   = nil
    bd.grenCooldown       = 0
    bd.grenIsLob          = false
    bd.grenTargetPos      = nil
    bd.grenIsSpawnLob     = false
    bd.forceMelee         = false
    bd.approachAngle      = nil
    bd.lastApproachTarget = nil
    bd.nextFidget         = 0
    bd.wantUse            = false
    bd.nextTactReload     = 0
    bd.damageFlinchUntil  = 0
    bd.noscopeActive      = false
    bd.noscopeCooldown    = 0
    bd.noscopeStartYaw    = nil
    bd.noscopeStartTime   = nil
    bd.lastSeenAt         = 0
    bd.stuckCount         = 0
    bd.scanYawOffset      = 0
    bd.scanPitchOffset    = 0
    bd.nextScanUpdate     = 0
    bd.nextRoamRefresh    = 0
    bd.nextJumpAllowed    = 0
    bd.vaultUntil         = 0
    bd.crouchJumpUntil    = 0
    bd.coverPos           = nil
    bd.coverHoldUntil     = 0
    bd.coverPeekAt        = 0
    bd.nextCoverSearch    = 0
    bd.tbagStart          = 0
    bd.tbagUntil          = 0
    bd.tbagPos            = nil
    bd.nextIntroLook      = 0
    bd.introLookTarget    = nil
    bd.wantInspect        = false
    bd.bashUntil          = 0
    bd.nextBashAt         = 0
    bd.overwhelmRetreatPos  = nil
    bd.nextOverwhelmRepath  = 0
    bd.suppressUntil      = 0
    bd.nextSuppressAt     = 0
    bd.suppressRefresh    = 0
    bd.suppressPos        = nil
    bd.recoilPitch        = 0
    bd.recoilYaw          = 0
    bd.recoilLastAt       = 0
    bd.semiSettleUntil    = 0
    bd.moveForward        = 0
    bd.moveSide           = 0
    bd.pendingSemiFire    = false
    bd.isProne            = false
    bd.pronePhase         = nil
    bd.pronePhaseAt       = 0
    bd.wantProne          = false
    bd.wantGetUp          = false
    bd.nextProneCheck     = 0
    bd.bipodDeployed      = false
    bd.bipodHoldUntil     = 0
    bd.bipodPos           = nil
    bd.nextBipodCheck     = 0
    bd.wantSlide          = false
    bd.slideUntil         = 0
    bd.sprintStartAt      = nil
    bd.nextSlideRoll      = 0
    bd.wantPeek           = false
    bd.peekUntil          = 0
    bd.nextPeekRoll       = 0
    bd.nearbyGrenadePos   = nil
    bd.nearbyGrenadeAt    = 0
    bd.grenadeEscapeUntil = 0
    bd.breakingGlass      = false
    bd.aimGlassTarget     = nil
    bd.pendingSpawnLob    = nil
    bd.targetDist         = nil

    -- Gadget system: reset phase but preserve cooldown so bots can't
    -- spam gadgets every life.  gadgetCooldown is intentionally NOT reset.
    bd.gadgetPhase        = nil
    bd.gadgetPhaseAt      = 0
    bd.gadgetSwitchBackTo = nil
    -- bd.gadgetCooldown: preserved across lives
    -- bd.attachmentsRandomized: preserved — only re-randomize when loadout changes

    local walkCV   = GetConVar("tdm_player_speed")
    local sprintCV = GetConVar("tdm_sprint_speed")
    local baseWalk   = walkCV   and walkCV:GetInt()   or 180
    local baseSprint = sprintCV and sprintCV:GetInt() or 240
    -- Personality-driven movement speed: rushers literally move faster than
    -- campers. This is the single biggest at-a-glance personality cue.
    local spdMult = (bd.personality and bd.personality.roamSpeedMult) or 1.0
    ply:SetWalkSpeed(math.floor(baseWalk   * spdMult))
    ply:SetRunSpeed (math.floor(baseSprint * spdMult))
end)

-- ── Kill taunt ────────────────────────────────────────────────
-- Server-wide tbag cooldown: only one bot can tbag at a time.
-- Without this, PlayerDeath fires for all bots simultaneously and multiple
-- bots pass the random check at the same frame, causing synchronized tbagging.
local _lastAnyTbagAt = 0
local TBAG_GLOBAL_COOLDOWN = 12   -- minimum seconds between any bot tbagging

hook.Add("PlayerDeath", "TDMBots_TBagOnKill", function(victim, inflictor, attacker)
    if not IsValid(attacker) or not attacker:IsPlayer() or not attacker:IsBot() then return end
    if not IsValid(victim)   or not victim:IsPlayer() then return end
    if attacker==victim or not TDMBot_AreEnemies(attacker, victim) then return end
    local bd = TDMBots and TDMBots[attacker]; if not bd then return end
    if CurTime() < (bd.tbagUntil or 0) then return end
    if CurTime() < _lastAnyTbagAt + TBAG_GLOBAL_COOLDOWN then return end  -- global rate-limit
    if math.random() < 0.01 then   -- 1% chance, down from 4%
        bd.tbagStart = CurTime(); bd.tbagUntil = CurTime()+math.Rand(0.8,1.6); bd.tbagPos = victim:GetPos()
        _lastAnyTbagAt = CurTime()
    end
end)

-- ── Damage flinch ─────────────────────────────────────────────
hook.Add("EntityTakeDamage", "TDMBots_DamageFlinch", function(target, dmginfo)
    if not IsValid(target) or not target:IsPlayer() or not target:IsBot() then return end
    local bd = TDMBots and TDMBots[target]; if not bd then return end
    -- Disable damage flinch/cover-react behavior: bots should keep fighting
    -- when hit instead of crouching and looking away.
    bd.damageFlinchUntil = 0
    bd.coverHoldUntil    = 0
    bd.coverPeekAt       = 0
    bd.wantCrouch        = false
    bd.tbagUntil=0; bd.tbagPos=nil
    if bd.isProne then
        if dmginfo:GetDamage()>20 or math.random()<0.4 then bd.wantGetUp=true end
    end
    local atk=dmginfo:GetAttacker()
    if IsValid(atk) and atk~=target and TDMBot_AreEnemies(target, atk) then
        bd.lastKnownTargetPos = atk:GetPos()
    end
end)
