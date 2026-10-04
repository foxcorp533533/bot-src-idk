-- ============================================================
-- aislopmatch_bots / bot_util.lua
-- Small shared utilities used across bot modules
-- ============================================================

function TDMBot_GetPlayerData(ply)
    if GetPlayerData then return GetPlayerData(ply) end
    return {}
end

function TDMBot_RoundActive()
    if TDM_Round then
        if TDM_Round.waiting or TDM_Round.warmup then return false end
        return TDM_Round.active == true
    end
    return true
end

-- Resolve a player's team, including bots that are still spawning with Team()==0.
local function _TDMBotResolvePlayerTeam(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return 0 end
    local t = ply:Team()
    if t ~= 0 then return t end
    if TDMBots and TDMBots[ply] then
        return TDMBots[ply].intendedTeam or 0
    end
    return 0
end

-- Invasion NPCs are tagged by the base gamemode with TDM_Team/TDM_InvasionTeam.
local function _TDMBotGetInvasionNPCTeam(ent)
    if not IsValid(ent) then return nil end
    local t = nil
    if ent.GetVar then t = ent:GetVar("TDM_Team") end
    if t == nil then t = ent.TDM_InvasionTeam end
    t = tonumber(t)
    if t == 1 or t == 2 then return t end
    return nil
end

-- Returns true if `ent` is a hostile NPC that bots should treat as an enemy.
-- Friendly NPCs (citizens, Alyx, etc.) and neutral entities return false.
-- `againstPlayer` is optional; when provided, hostility is evaluated relative
-- to that player's team (needed for Invasion's team-tagged NPCs).
function TDMBot_IsHostileNPC(ent, againstPlayer)
    if not IsValid(ent) then return false end
    local isNPC = ent:IsNPC() or ent.Type == "nextbot"
    if not isNPC then return false end
    if (ent:Health() or 0) <= 0 then return false end

    -- Invasion mode: trust explicit NPC team tags from the main gamemode.
    local invTeam = _TDMBotGetInvasionNPCTeam(ent)
    if invTeam then
        if IsValid(againstPlayer) and againstPlayer:IsPlayer() then
            local pteam = _TDMBotResolvePlayerTeam(againstPlayer)
            if pteam == 1 or pteam == 2 then
                return pteam ~= invTeam
            end
        end
        -- If we cannot resolve a player team, still treat tagged invasion NPCs
        -- as combatants so they remain in the target candidate set.
        return true
    end

    -- Use disposition toward any human/bot player as the canonical signal.
    -- Disposition codes: 1=D_HT (hate), 2=D_FR (fear), 3=D_LI (like), 4=D_NU (neutral).
    if ent.Disposition then
        if IsValid(againstPlayer) and againstPlayer:IsPlayer() then
            local d = ent:Disposition(againstPlayer)
            if d == 1 or d == 2 then return true end
            if d == 3 or d == 4 then return false end
        else
            local sawFriendly = false
            for _, ply in ipairs(player.GetAll()) do
                if IsValid(ply) then
                    local d = ent:Disposition(ply)
                    if d == 1 or d == 2 then return true end
                    if d == 3 or d == 4 then sawFriendly = true end
                end
            end
            if sawFriendly then return false end
        end
    end
    -- Fallback class-name heuristic for NPCs whose disposition isn't set yet.
    local c = ent:GetClass():lower()
    if c:find("combine") or c:find("zombie") or c:find("antlion")
       or c:find("headcrab") or c:find("hunter") or c:find("strider")
       or c:find("manhack") or c:find("metropolice") or c:find("fastzombie")
       or c:find("poison") or c:find("vortigaunt_slave") then
        return true
    end
    return false
end

-- True if `ent` is alive — works for players, bots, and NPCs.
function TDMBot_IsAlive(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() then return ent:Alive() end
    return (ent.Health and ent:Health() > 0) or false
end

-- Returns true if the two entities are enemies in the current mode.
-- Handles player-vs-player (team/FFA rules) AND player-vs-NPC (hostile NPCs).
-- GamemodeType: 0=TDM, 1=FFA, 2=Gunfight, 3=GunGame
function TDMBot_AreEnemies(a, b)
    if not IsValid(a) or not IsValid(b) then return false end
    if a == b then return false end

    -- NPC involvement: ignore team/gamemode rules, defer to disposition.
    local aIsNPC = a:IsNPC() or a.Type == "nextbot"
    local bIsNPC = b:IsNPC() or b.Type == "nextbot"
    if aIsNPC or bIsNPC then
        -- Two NPCs are not bot-vs-bot relevant.
        if aIsNPC and bIsNPC then return false end
        local npc    = aIsNPC and a or b
        local player = aIsNPC and b or a
        if not player:IsPlayer() then return false end
        local pteam = _TDMBotResolvePlayerTeam(player)
        local nteam = _TDMBotGetInvasionNPCTeam(npc)
        if (pteam == 1 or pteam == 2) and nteam then
            return pteam ~= nteam
        end
        return TDMBot_IsHostileNPC(npc, player)
    end

    local gt = TDM_CONFIG and TDM_CONFIG.GamemodeType or 0

    -- FFA (1) and GunGame (3): every player is an enemy.
    if gt == 1 or gt == 3 then return true end

    -- TDM (0) and Gunfight (2): team-based.
    local ta = _TDMBotResolvePlayerTeam(a)
    local tb = _TDMBotResolvePlayerTeam(b)
    if ta == 0 or tb == 0 then return false end
    return ta ~= tb
end

function TDMBot_RandomMapPos()
    local spawnClasses = {
        "info_player_start", "info_player_deathmatch",
        "info_player_counterterrorist", "info_player_terrorist",
        "info_player_teamspawn", "tdm_spawn",
    }
    local candidates = {}
    for _, cls in ipairs(spawnClasses) do
        for _, e in ipairs(ents.FindByClass(cls)) do
            if IsValid(e) then table.insert(candidates, e:GetPos()) end
        end
        if #candidates > 0 then break end
    end
    if #candidates > 0 then return candidates[math.random(#candidates)] end
    return Vector(math.random(-800,800), math.random(-800,800), 64)
end

local _losCache = {}
local _losPruneAt = 0
local LOS_TTL = 0.12  -- raised from 0.06 — bot think tick is 0.10, no behavioural cost

function TDMBot_CanSee(from_ply, to_ply)
    if not IsValid(from_ply) or not IsValid(to_ply) then return false end

    local now = CurTime()
    local key = from_ply:EntIndex() * 8192 + to_ply:EntIndex()
    local c = _losCache[key]
    if c and now < c.expire then return c.val end

    local tr = util.TraceLine({
        start  = from_ply:EyePos(),
        endpos = to_ply:EyePos(),
        filter = { from_ply, to_ply },
        mask   = MASK_SOLID_BRUSHONLY,
    })
    local vis = not tr.Hit
    _losCache[key] = { val = vis, expire = now + LOS_TTL }

    if now >= _losPruneAt then
        _losPruneAt = now + 2.0
        for k, v in pairs(_losCache) do
            if not v or now >= (v.expire or 0) then _losCache[k] = nil end
        end
    end

    return vis
end

-- Frame-cached alive-players list. player.GetAll() itself is cheap, but the
-- per-bot loops that filter it (target search, pressure check, grenade react,
-- spawn-lob picker) walked it dozens of times per frame across 16 bots.
-- Returning a single shared array per CurTime() instant cuts that down to one.
local _alivePlayersCache = nil
local _alivePlayersAt    = -1
function TDMBot_GetAlivePlayers()
    local now = CurTime()
    if _alivePlayersAt == now and _alivePlayersCache then
        return _alivePlayersCache
    end
    local list = {}
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() and not ply:GetNWBool("TDM_Spectator", false) then
            list[#list + 1] = ply
        end
    end
    _alivePlayersCache = list
    _alivePlayersAt    = now
    return list
end

-- Frame-cached alive hostile NPC list. Returns NPCs/NextBots that are alive
-- and hostile to players (combine, zombies, antlions, etc.). Empty when no
-- such NPCs are on the map. Cached the same way as TDMBot_GetAlivePlayers.
local _aliveNPCsCache = nil
local _aliveNPCsAt    = -1
function TDMBot_GetHostileNPCs()
    local now = CurTime()
    if _aliveNPCsAt == now and _aliveNPCsCache then
        return _aliveNPCsCache
    end
    local list = {}
    -- ents.FindByClass with "npc_*" returns nothing for nextbots, so iterate
    -- ents.GetAll() once. The result is cached per-frame so cost is amortised.
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and (ent:IsNPC() or ent.Type == "nextbot") then
            if _TDMBotGetInvasionNPCTeam(ent) then
                list[#list + 1] = ent
            elseif TDMBot_IsHostileNPC(ent) then
                list[#list + 1] = ent
            end
        end
    end
    _aliveNPCsCache = list
    _aliveNPCsAt    = now
    return list
end

function TDMBot_DistSqr(a, b)
    if not IsValid(a) or not IsValid(b) then return math.huge end
    return a:GetPos():DistToSqr(b:GetPos())
end

function TDMBot_Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end
