-- ============================================================
-- aislopmatch_bots / bot_nav.lua
-- Navigation: A* path planning + movement direction.
-- Movement is driven through StartCommand in bot_think.
-- ============================================================

local NAV_UPDATE_CHASE  = 0.25   -- path rebuild rate when actively chasing a target (was 0.55 — too slow, target out-paced path)
local NAV_UPDATE_ROAM   = 2.00   -- path rebuild rate when roaming with no target (was 1.4, lighter)
-- Re-path immediately if a tracked target moves more than this many units from
-- the position used to plan the current path. Keeps the route locked onto a
-- moving enemy instead of leading the bot to where the enemy WAS half a second ago.
local CHASE_REPATH_DIST     = 90
local CHASE_REPATH_DIST_SQR = CHASE_REPATH_DIST * CHASE_REPATH_DIST

-- 3D distance (not 2D) to count a waypoint as reached.  The old 80-unit 2D
-- check caused bots to "reach" waypoints that were one floor above them.
local WAYPOINT_REACH_3D     = 100
local WAYPOINT_REACH_3D_SQR = WAYPOINT_REACH_3D * WAYPOINT_REACH_3D

-- A* iteration cap — 320 was far too low for any non-trivial map; A* would
-- exhaust its budget halfway across the mesh, fall back to a direct line, and
-- the bot would stuck-loop. 6000 is safe (Lua tables/heaps are fast) and lets
-- A* solve any practical Source map without truncation.
local MAX_ASTAR_ITER = 6000

-- Path-cache TTL. Many bots roaming same area pairs request near-identical
-- A* paths within the same second. Sharing results across bots cuts the
-- per-frame A* cost dramatically when bot count is high.
local PATH_CACHE_TTL = 3.0

-- Roam destination policy: prefer the LEAST-RECENTLY-VISITED nav areas so a
-- single bot (and the bot population as a whole) covers the entire mesh
-- instead of pinging between a handful of "random" picks near spawns.
local ROAM_SAMPLES         = 28      -- candidates examined per roam pick
local ROAM_MIN_DIST        = 700     -- minimum unit distance from current pos
local VISIT_DECAY_PER_SEC  = 0.04    -- visit-count drops off so old data fades

local STUCK_THRESHOLD  = 0.55  -- seconds without 80-unit movement = stuck
local JUMP_COOLDOWN    = 0.80
local VAULT_CHECK_DIST = 56
local OVERWHELM_RADIUS = 900
local OVERWHELM_COUNT  = 6

-- Door entity classes bots should press IN_USE on when blocked
local DOOR_CLASSES = {
    ["func_door"]          = true,
    ["func_door_rotating"] = true,
    ["prop_door_rotating"] = true,
}
local DOOR_TRACE_DIST  = 85
local DOOR_USE_COOLDOWN = 0.8

-- Nav area attributes that indicate a ladder/climbing section.
-- Bots that enter these areas via A* need different movement handling.
local NAV_ATTR_CROUCH = bit.lshift(1, 2)   -- area requires crouching
-- GMod uses bit 0x2 for LADDER attribute on CNavLadder; nav areas adjacent
-- to ladders have the ladder in GetLadders() — we detect by height-delta instead.
local LADDER_HEIGHT_THRESH = 80   -- Z difference that implies a ladder waypoint

-- ── Nav area cache + global state ────────────────────────────
local _navAreaCache  = nil
local _navCacheBuiltAt = 0
local _visitCount    = {}     -- [areaID] = float (decays over time)
local _visitLastDecay = 0
local _pathCache     = {}     -- ["startID:endID"] = { path = {...}, expire = t }
local _pathCacheCount = 0

local function _DecayVisits(now)
    -- Cheap O(visited-area-count) decay. Called at most once a second.
    if now - _visitLastDecay < 1.0 then return end
    local dt = now - _visitLastDecay
    _visitLastDecay = now
    local drop = VISIT_DECAY_PER_SEC * dt
    for id, v in pairs(_visitCount) do
        local nv = v - drop
        if nv <= 0.05 then _visitCount[id] = nil else _visitCount[id] = nv end
    end
end

local function _PrunePathCache(now)
    if _pathCacheCount < 64 then return end
    for k, v in pairs(_pathCache) do
        if now >= (v.expire or 0) then
            _pathCache[k] = nil
            _pathCacheCount = _pathCacheCount - 1
        end
    end
end

local function _EnsureNavCache()
    local now = CurTime()
    if not _navAreaCache or #_navAreaCache == 0 or (now - _navCacheBuiltAt) > 60 then
        _navAreaCache = navmesh.GetAllNavAreas() or {}
        _navCacheBuiltAt = now
    end
    return _navAreaCache
end

-- Extra g-cost added when the A* path must pass through a dead-end area.
-- Higher value = pathfinder avoids containers/alcoves more aggressively.
local DEAD_END_PENALTY = 4500
local JUMP_EDGE_PENALTY = 12    -- cost per unit of height for connections requiring a jump

-- Returns true if this nav area is a dead end — typically a small enclosed
-- space like a shipping container, alcove, or room with a single entrance.
-- Uses both connection count AND area size to catch container-entrance slivers
-- that technically have 2 connections but are too small to navigate out of.
--
-- DECLARATION ORDER: this MUST be defined before GetRandomNavArea / GetFarNavArea
-- because Lua resolves locals at function-compile time.  The previous file order
-- placed `local function IsDeadEndArea` *after* GetRandomNavArea, which made the
-- reference inside GetRandomNavArea fall through to a nil global — every call to
-- GetRandomNavArea threw a runtime error and the silent failure manifested as
-- bots ending up at junk roam destinations.
local function IsDeadEndArea(area)
    if not area then return false end
    if area:IsBlocked() then return true end
    local adj = area:GetAdjacentAreas()
    if #adj == 0 then return true end
    if #adj == 1 then return true end
    -- Small 2-connection areas are typically container doorframe slivers.
    -- Players can walk in but the nav center is often inside the frame.
    if #adj == 2 then
        local sx = area:GetSizeX()
        local sy = area:GetSizeY()
        if sx < 100 and sy < 100 then return true end
    end
    return false
end

local function GetRandomNavArea()
    local cache = _EnsureNavCache()
    if not cache or #cache == 0 then return nil end
    -- Try up to 10 candidates, prefer non-dead-end areas
    for i = 1, 10 do
        local cand = cache[math.random(#cache)]
        if cand and not IsDeadEndArea(cand) then return cand end
    end
    return cache[math.random(#cache)]
end


-- Pick a nav area far from `pos`, preferring LEAST-VISITED locations so the
-- bot population systematically covers the entire mesh instead of bouncing
-- between a few random hot spots near spawn.  excludeIDs (optional) suppresses
-- the bot's most recent destinations.
local function GetFarNavArea(pos, excludeIDs, minDist)
    minDist = minDist or ROAM_MIN_DIST
    local cache = _EnsureNavCache()
    if not cache or #cache == 0 then return nil end
    local now = CurTime()
    _DecayVisits(now)

    local minDistSqr = minDist * minDist
    local best, bestScore = nil, -math.huge
    local n = #cache
    local samples = math.min(ROAM_SAMPLES, n)

    for i = 1, samples do
        local cand = cache[math.random(n)]
        if cand then
            local cid = cand:GetID()
            if (not excludeIDs or not excludeIDs[cid]) and not IsDeadEndArea(cand) then
                local d2 = cand:GetCenter():DistToSqr(pos)
                if d2 >= minDistSqr then
                    -- Score: distance helps, but freshness (low visit count)
                    -- dominates so the bot pushes toward unexplored regions.
                    local visit = _visitCount[cid] or 0
                    -- distance term normalised so it doesn't drown the freshness term
                    local score = (1.0 / (1.0 + visit * 1.5)) + math.sqrt(d2) * 0.0006
                    if score > bestScore then
                        bestScore = score; best = cand
                    end
                end
            end
        end
    end
    -- Fallback: if every sampled area was excluded/dead-end, drop the minDist gate
    if not best then
        for i = 1, math.min(20, n) do
            local cand = cache[math.random(n)]
            if cand and not IsDeadEndArea(cand) then return cand end
        end
    end
    return best
end

-- Mark the area at `pos` as visited (called as the bot moves through it).
-- This is what makes GetFarNavArea spread bots across the whole mesh.
local function _MarkVisited(pos)
    if not navmesh or navmesh.GetNavAreaCount() == 0 then return end
    local area = navmesh.GetNearestNavArea(pos, true, 200, false, false)
    if not area then return end
    local id = area:GetID()
    _visitCount[id] = (_visitCount[id] or 0) + 1
end

-- ── Min-heap (priority queue for A*) ─────────────────────────
local function heapPush(h, item, priority)
    local n = #h + 1
    h[n] = { item = item, p = priority }
    local i = n
    while i > 1 do
        local parent = (i - i % 2) / 2
        if h[parent].p > h[i].p then h[i], h[parent] = h[parent], h[i]; i = parent
        else break end
    end
end

local function heapPop(h)
    if #h == 0 then return nil end
    local top = h[1].item
    h[1] = h[#h]; h[#h] = nil
    local i, n = 1, #h
    while true do
        local l, r, m = 2*i, 2*i+1, i
        if l <= n and h[l].p < h[m].p then m = l end
        if r <= n and h[r].p < h[m].p then m = r end
        if m == i then break end
        h[i], h[m] = h[m], h[i]; i = m
    end
    return top
end

-- Snap an arbitrary position to the nearest reachable nav area.
-- Tries an aggressive search radius and falls back to the global nearest
-- area scan, so we don't fail to path just because the target is on top of
-- a crate or a sloped surface that the engine's quick lookup misses.
local function SnapToNavArea(pos)
    if not navmesh or navmesh.GetNavAreaCount() == 0 then return nil end
    local a = navmesh.GetNearestNavArea(pos, true, 500, false, false)
    if a then return a end
    -- Wider checked radius (anywhereOnMap=true, no walkable filter)
    a = navmesh.GetNearestNavArea(pos, false, 2000, false, false)
    if a then return a end
    -- Last resort: scan the cached area list. O(N) but cache is reused.
    local cache = _EnsureNavCache()
    if not cache or #cache == 0 then return nil end
    local best, bestD = nil, math.huge
    for i = 1, #cache do
        local c = cache[i]
        if c then
            local d = c:GetCenter():DistToSqr(pos)
            if d < bestD then bestD = d; best = c end
        end
    end
    return best
end

-- ── A* path builder ────────────────────────────────────────────
-- Replaces the old greedy best-first builder which fell into dead ends.
-- A* guarantees the optimal path through the nav mesh connectivity graph,
-- so bots route correctly around rooms, corridors, and obstacles.
local function BuildNavPath(fromPos, toPos)
    if not navmesh or navmesh.GetNavAreaCount() == 0 then return { toPos } end

    local startArea = SnapToNavArea(fromPos)
    local endArea   = SnapToNavArea(toPos)
    if not startArea or not endArea then return { toPos } end
    if startArea == endArea then return { toPos } end

    -- Path cache: many bots request near-identical (startArea, endArea) paths
    -- within the same second.  The cached entry stores both the area sequence
    -- AND a reconstruction template; we re-anchor the first/last waypoint to
    -- the actual fromPos/toPos so each caller still gets a path that starts
    -- at their feet and ends on their target.
    local now      = CurTime()
    local cacheKey = startArea:GetID() .. ":" .. endArea:GetID()
    local cached   = _pathCache[cacheKey]
    if cached and now < cached.expire and cached.areaList then
        local path = {}
        local prevPoint = fromPos
        for _, area in ipairs(cached.areaList) do
            -- Re-resolve waypoint on shared edge from current bot's position.
            local wp = area:GetClosestPointOnArea(prevPoint)
            path[#path + 1] = wp
            prevPoint = wp
        end
        path[#path + 1] = toPos
        return path
    end

    local endID     = endArea:GetID()
    local endCenter = endArea:GetCenter()

    local openHeap = {}
    local gScore   = {}   -- cost from start to each area
    local prev     = {}   -- parent area for path reconstruction
    local closed   = {}

    gScore[startArea:GetID()] = 0
    heapPush(openHeap, startArea, startArea:GetCenter():Distance(endCenter))

    local found = nil
    local iter  = 0

    while #openHeap > 0 and iter < MAX_ASTAR_ITER do
        iter = iter + 1
        local cur = heapPop(openHeap)
        if not cur then break end
        local curID = cur:GetID()
        if curID == endID then found = cur; break end
        if closed[curID] then continue end
        closed[curID] = true

        local g = gScore[curID] or 0
        for _, nb in ipairs(cur:GetAdjacentAreas()) do
            local nbID = nb:GetID()
            if closed[nbID] then continue end
            -- Skip areas the engine has marked as blocked (e.g. by entities).
            if nb:IsBlocked() then continue end
            -- Penalise dead-end areas so A* prefers routes through open space —
            -- but never penalise the destination itself, otherwise enemies
            -- that happen to be standing inside a small alcove become unreachable.
            local penalty = (IsDeadEndArea(nb) and nbID ~= endID) and DEAD_END_PENALTY or 0
            -- Penalise connections that require a jump (height change > one step).
            -- ComputeAdjacentConnectionHeightChange returns the Z delta at the
            -- shared edge — positive = step up, negative = drop down.
            local hChange = cur:ComputeAdjacentConnectionHeightChange(nb)
            if hChange > 18 then
                penalty = penalty + hChange * JUMP_EDGE_PENALTY
            end
            local newG = g + cur:GetCenter():Distance(nb:GetCenter()) + penalty
            if newG < (gScore[nbID] or math.huge) then
                gScore[nbID] = newG
                prev[nbID]   = cur
                heapPush(openHeap, nb, newG + nb:GetCenter():Distance(endCenter))
            end
        end
    end

    if not found then
        -- A* hit the iteration cap or the mesh is disconnected.
        -- Walk back along the explored frontier and return the best partial
        -- path toward the goal so the bot still makes progress.
        local bestID, bestH = nil, math.huge
        for id, _ in pairs(gScore) do
            local area = navmesh.GetNavAreaByID(id)
            if area then
                local h = area:GetCenter():DistToSqr(endCenter)
                if h < bestH then bestH = h; bestID = id end
            end
        end
        if bestID and bestID ~= startArea:GetID() then
            found = navmesh.GetNavAreaByID(bestID)
        else
            return { toPos }
        end
    end

    -- Reconstruct path using GetClosestPointOnArea instead of GetCenter.
    -- Area centers can be inside walls or deep in large open areas far from the
    -- actual corridor the bot is walking.  GetClosestPointOnArea(prevPoint) gives
    -- a waypoint on the shared edge between consecutive areas, keeping the path
    -- physically close to the route the bot needs to walk.
    local areaList = {}
    local cur = found
    while prev[cur:GetID()] do
        table.insert(areaList, 1, cur)
        cur = prev[cur:GetID()]
    end

    -- Cache the area sequence (not the resolved waypoints, which depend on
    -- caller position) so other bots can reuse the A* result for a few seconds.
    _pathCache[cacheKey] = { areaList = areaList, expire = now + PATH_CACHE_TTL }
    _pathCacheCount = _pathCacheCount + 1
    _PrunePathCache(now)

    local path = {}
    local prevPoint = fromPos
    for _, area in ipairs(areaList) do
        local wp = area:GetClosestPointOnArea(prevPoint)
        table.insert(path, wp)
        prevPoint = wp
    end
    table.insert(path, toPos)
    return path
end

-- ── Stray destination (loneWolf flanking) ─────────────────────
local function GetStrayDest(bot)
    local myPos = bot:GetPos()
    local eSum, eCount = Vector(0,0,0), 0
    for _, ply in ipairs(TDMBot_GetAlivePlayers()) do
        if ply ~= bot and TDMBot_AreEnemies(bot, ply) then
            eSum = eSum + ply:GetPos(); eCount = eCount + 1
        end
    end
    if eCount == 0 then return nil end
    local centroid = eSum * (1/eCount)
    local toEnemy  = centroid - myPos; toEnemy.z = 0
    if toEnemy:LengthSqr() < 1 then return nil end

    local leftCount, rightCount = 0, 0
    if TDMBots then
        for otherBot, obd in pairs(TDMBots) do
            if otherBot ~= bot and IsValid(otherBot) and not TDMBot_AreEnemies(bot, otherBot) and (obd.approachAngle or 0) ~= 0 then
                if obd.approachAngle > 0 then rightCount = rightCount + 1 else leftCount = leftCount + 1 end
            end
        end
    end
    local side = (leftCount <= rightCount) and 1 or -1
    local dir  = Angle(0, toEnemy:Angle().y + side * math.Rand(80, 110), 0):Forward()
    local dest = myPos + dir * math.Rand(500, 950)
    if navmesh and navmesh.GetNavAreaCount() > 0 then
        local area = navmesh.GetNearestNavArea(dest, true, 900, false, false)
        if area then
            -- Walk up the adjacency chain if we snapped into a dead end
            if IsDeadEndArea(area) then
                local adj = area:GetAdjacentAreas()
                if adj and #adj > 0 then area = adj[1] end
            end
            return area:GetCenter()
        end
    end
    return dest
end

-- ── Enemy-cluster push destination ───────────────────────────
local function GetPushDest(bot)
    local myPos = bot:GetPos()
    local eSum, eCount = Vector(0,0,0), 0
    for _, ply in ipairs(TDMBot_GetAlivePlayers()) do
        if ply ~= bot and TDMBot_AreEnemies(bot, ply) then
            eSum = eSum + ply:GetPos(); eCount = eCount + 1
        end
    end
    -- Hostile NPCs count as "enemies to push toward" so bots advance on
    -- combine/zombies/etc. on co-op or mixed maps even when no player is alive.
    if TDMBot_GetHostileNPCs then
        for _, npc in ipairs(TDMBot_GetHostileNPCs()) do
            if IsValid(npc) and TDMBot_AreEnemies(bot, npc) then
                eSum = eSum + npc:GetPos(); eCount = eCount + 1
            end
        end
    end
    if eCount == 0 then return nil end
    local centroid = eSum * (1/eCount)
    local t        = math.Rand(0.55, 0.80)
    local target   = myPos + (centroid - myPos) * t + Vector(math.Rand(-350,350), math.Rand(-350,350), 0)
    if navmesh and navmesh.GetNavAreaCount() > 0 then
        local area = navmesh.GetNearestNavArea(target, true, 700, false, false)
        if area then
            -- Walk up the adjacency chain if we snapped into a dead end
            if IsDeadEndArea(area) then
                local adj = area:GetAdjacentAreas()
                if adj and #adj > 0 then area = adj[1] end
            end
            return area:GetCenter()
        end
    end
    return target
end

-- ── Pincer approach angle ─────────────────────────────────────
local function GetPincerApproachAngle(bot, baseFlankRange)
    if not TDMBots or baseFlankRange == 0 then return 0 end
    local usedAngles = {}
    for otherBot, obd in pairs(TDMBots) do
        if otherBot ~= bot and IsValid(otherBot) and not TDMBot_AreEnemies(bot, otherBot) and obd.approachAngle then
            table.insert(usedAngles, obd.approachAngle)
        end
    end
    if #usedAngles == 0 then return math.Rand(-baseFlankRange, baseFlankRange) end
    local best, bestD = 0, -1
    for _ = 1, 8 do
        local cand = math.Rand(-baseFlankRange, baseFlankRange)
        local minSep = math.huge
        for _, used in ipairs(usedAngles) do
            local sep = math.abs(cand - used)
            if sep < minSep then minSep = sep end
        end
        if minSep > bestD then bestD = minSep; best = cand end
    end
    return best
end

-- ── Overwhelm retreat ─────────────────────────────────────────
local function GetNearbyEnemyPressure(bot, radius)
    local myPos = bot:GetPos(); local rsq = radius*radius
    local n, sum = 0, Vector(0,0,0)
    for _, ply in ipairs(TDMBot_GetAlivePlayers()) do
        if TDMBot_AreEnemies(bot, ply) then
            local ppos = ply:GetPos()
            if (ppos-myPos):LengthSqr() <= rsq then n=n+1; sum=sum+ppos end
        end
    end
    return n, (n>0 and sum*(1/n) or nil)
end

local function PickOverwhelmRetreatPos(bot, bd, enemyCenter)
    local myPos = bot:GetPos()
    local away  = myPos - enemyCenter; away.z = 0
    if away:LengthSqr() < 1 then away = bot:GetForward(); away.z = 0 end
    away:Normalize()
    local perp = Vector(-away.y, away.x, 0)
    local cand = myPos + away * math.Rand(360,700) + perp * math.Rand(-280,280)
    if navmesh and navmesh.GetNavAreaCount() > 0 then
        local area = navmesh.GetNearestNavArea(cand, true, 800, false, false)
        if area then cand = area:GetCenter() end
    end
    bd.overwhelmRetreatPos = cand
end

-- ── Vault helper ──────────────────────────────────────────────
local function TryVaultWindow(bot, bd, goal, now)
    if not goal then return false end
    if now < (bd.nextVaultCheck or 0) then return false end
    bd.nextVaultCheck = now + 0.40   -- 0.22 -> 0.40 (cheaper, still feels reactive)
    if not bot:IsOnGround() then return false end
    if now < (bd.nextJumpAllowed or 0) then return false end
    if bd.isProne then return false end

    local toGoal = goal - bot:GetPos(); toGoal.z = 0
    if toGoal:LengthSqr() < 120*120 then return false end
    toGoal:Normalize()

    local chest  = bot:GetPos() + Vector(0,0,40)
    local trLow  = util.TraceLine({start=chest, endpos=chest+toGoal*VAULT_CHECK_DIST, filter=bot, mask=MASK_PLAYERSOLID})
    if not trLow.Hit then return false end

    local cls = IsValid(trLow.Entity) and trLow.Entity:GetClass() or ""
    local isWindowLike = cls=="func_breakable" or cls=="func_breakable_surf"
                      or cls:find("glass",1,true) or cls:find("window",1,true)

    if not isWindowLike and trLow.HitWorld then
        local h = trLow.HitPos.z - bot:GetPos().z
        if h < 16 or h > 72 then return false end
    elseif not isWindowLike and not trLow.HitWorld then
        return false
    end

    local hi   = bot:GetPos() + Vector(0,0,62)
    local trHi = util.TraceLine({start=hi, endpos=hi+toGoal*72+Vector(0,0,18), filter=bot, mask=MASK_PLAYERSOLID})
    if trHi.Hit then return false end

    -- Crouch-jump gives extra clearance over window frames/fences.
    bd.wantJump = true
    bd.wantCrouch = true
    bd.crouchJumpUntil = now + 0.22
    bd.vaultUntil = now + 0.42
    bd.nextJumpAllowed = now + JUMP_COOLDOWN
    return true
end

-- ── Door detection ────────────────────────────────────────────
-- Traces in the bot's movement direction. If a door is found, sets
-- bd.wantUseDoor so StartCommand can press IN_USE on the right tick.
local function CheckDoorAhead(bot, bd, now)
    if now < (bd.nextDoorCheck or 0) then return end
    bd.nextDoorCheck = now + 0.30   -- 0.12 -> 0.30 (doors don't appear out of nowhere)

    local goal = bd.goal
    if not goal then return end

    local toGoal = goal - bot:GetPos(); toGoal.z = 0
    if toGoal:LengthSqr() < 50*50 then return end   -- already near goal
    toGoal:Normalize()

    local eyePos = bot:EyePos()
    local tr = util.TraceLine({
        start  = eyePos,
        endpos = eyePos + toGoal * DOOR_TRACE_DIST,
        filter = bot,
        mask   = MASK_SOLID,
    })

    if tr.Hit and IsValid(tr.Entity) then
        local cls = tr.Entity:GetClass()
        if DOOR_CLASSES[cls] then
            if now >= (bd.lastDoorUseAt or 0) + DOOR_USE_COOLDOWN then
                bd.wantUseDoor  = true
                bd.lastDoorUseAt = now
            end
        end
    end
end

-- ── Main navigation think ─────────────────────────────────────
function TDMBot_NavThink(bot, bd)
    local now    = CurTime()
    local botPos = bot:GetPos()
    -- Visit tracking: mark the area we're currently in so global exploration
    -- can steer other roam-pickers away from already-covered ground. Throttled
    -- to once per second per bot to keep cost negligible.
    if now >= (bd.nextVisitMark or 0) then
        bd.nextVisitMark = now + 1.0
        _MarkVisited(botPos)
    end
    -- Check for doors in the movement path — sets bd.wantUseDoor if hit
    CheckDoorAhead(bot, bd, now)

    if bd.bipodDeployed then bd.goal=nil; return end

    if bd.isProne then
        if bd.goal and (bd.goal-botPos):Length2DSqr() < 120*120 then bd.goal=nil end
        return
    end

    if now < (bd.grenadeEscapeUntil or 0) and bd.goal then return end

    local p = bd.personality

    -- Damage reaction no longer forces crouch/stop behavior.
    bd.coverPos = nil

    -- Overwhelm retreat
    local pressureCount, pressureCenter = GetNearbyEnemyPressure(bot, OVERWHELM_RADIUS)
    if pressureCount >= OVERWHELM_COUNT and pressureCenter then
        bd.state = "retreat"
        if not bd.overwhelmRetreatPos or botPos:DistToSqr(bd.overwhelmRetreatPos)<130*130 or now>=(bd.nextOverwhelmRepath or 0) then
            bd.nextOverwhelmRepath = now + math.Rand(0.9, 1.6)
            PickOverwhelmRetreatPos(bot, bd, pressureCenter)
        end
        if bd.overwhelmRetreatPos then bd.goal=bd.overwhelmRetreatPos; bd.wantCrouch=false; bd.wantADS=false; return end
    else
        bd.overwhelmRetreatPos = nil
    end

    -- Retreat: only back away if truly too close
    if bd.state == "retreat" and IsValid(bd.target) then
        local retDist = math.sqrt(TDMBot_DistSqr(bot, bd.target))
        if retDist < 300 then
            local away = (botPos - bd.target:GetPos()); away.z=0
            if away:LengthSqr() > 1 then away:Normalize(); bd.goal = botPos + away*200 end
        else
            bd.state = "combat"
        end
        return
    end

    -- Proactive dead-end escape: if the bot is inside a dead-end nav area
    -- (shipping container, alcove, etc.) with no active combat target, force
    -- the goal to the area's single exit immediately rather than waiting for
    -- stuck detection to fire.  Rate-limited to 0.5 s to avoid overhead.
    if not (IsValid(bd.target) and TDMBot_IsAlive(bd.target))
       and now >= (bd.nextDeadEndCheck or 0)
       and navmesh and navmesh.GetNavAreaCount() > 0 then
        bd.nextDeadEndCheck = now + 1.0   -- was 0.5
        local curArea = navmesh.GetNearestNavArea(botPos, true, 120, false, false)
        if curArea and IsDeadEndArea(curArea) then
            local adj = curArea:GetAdjacentAreas()
            if adj and #adj > 0 then
                -- Use closest point on the exit area rather than its center;
                -- the center can be on the far side of the doorframe.
                local exitPos = adj[1]:GetClosestPointOnArea(botPos)
                if not bd.goal or bd.goal:DistToSqr(exitPos) > 150*150 then
                    bd.navPath  = { exitPos }
                    bd.navStep  = 1
                    bd.roamDest = nil
                    bd.goal     = exitPos
                    return
                end
            end
        end
    end

    -- ── Pick destination ──────────────────────────────────────
    local dest
    local target = bd.target
    if IsValid(target) and TDMBot_IsAlive(target) then
        -- While a stuck-escape is still active, keep routing to the escape position
        -- rather than the enemy.  Without this, NextNav=0 (or destChanged) causes the
        -- normal dest-picker to immediately rebuild the same blocked path to the target.
        if now < (bd.stuckEscapeUntil or 0) and bd.stuckEscapePos then
            dest = bd.stuckEscapePos
        else
            dest = target:GetPos()
            -- Personality-driven stand-off: when this bot has a configured
            -- holdRange (campers/stalkers/tacticians) and the enemy is already
            -- inside that comfort window with LOS, freeze in place. Rushers
            -- have holdRange=0 and never trigger this branch — they always push.
            local pHold = (p and p.holdRange) or 0
            if pHold > 0 and bd.state == "combat" and TDMBot_CanSee(bot, target) then
                local tdist = math.sqrt(TDMBot_DistSqr(bot, target))
                if tdist < pHold then dest = botPos end
            end
            -- Snipers without a personality holdRange still hold a small
            -- engagement gap when they have a clean shot at a stationary target.
            if pHold == 0 and bd.wepIsSn and bd.state == "combat" and TDMBot_CanSee(bot, target) then
                local tdist = math.sqrt(TDMBot_DistSqr(bot, target))
                local tspd  = (target.GetVelocity and target:GetVelocity():Length2D()) or 0
                if tdist > 1200 and tspd < 60 then dest = botPos end
            end
        end
    elseif bd.lastKnownTargetPos then
        dest = bd.lastKnownTargetPos
        -- Forget last-known position once the bot has reached it, so the next
        -- think falls through to roam (which will pick a fresh push dest toward
        -- live enemies via GetPushDest) instead of stalling on a stale spot.
        if botPos:DistToSqr(bd.lastKnownTargetPos) < 200*200 then
            bd.lastKnownTargetPos = nil
        end
    else
        if bd.roamDest and botPos:DistToSqr(bd.roamDest) < 150*150 then
            bd.roamDest = nil
        end
        if not bd.roamDest or now >= (bd.nextRoamRefresh or 0) then
            -- Faster refresh keeps the population moving and re-evaluating routes
            -- toward live enemies (was 3\u20135s, now 1.5\u20133s).
            bd.nextRoamRefresh = now + math.Rand(1.5, 3.0)
            -- Push-vs-stray bias is now driven by aggressionBias rather than a
            -- flat coin-flip. High-aggression personalities (Rusher/Aggressor)
            -- almost always head straight for the enemy cluster; low-aggression
            -- ones (Camper/Stalker) wander to flanking/holding positions more.
            -- Bias has been shifted DOWN so even cautious personalities push toward
            -- enemies most of the time \u2014 only true campers (agB \u2264 \u22120.4) ever stray.
            local agB     = (p and p.aggressionBias) or 0.5
            local strayCh = math.Clamp(0.30 - agB * 0.55, 0.02, 0.70)
            local useStray = (p and p.loneWolf and math.random() < (strayCh + 0.15))
                          or (math.random() < strayCh)
            local pushDest = useStray and GetStrayDest(bot) or GetPushDest(bot)
            if pushDest then
                bd.roamDest = pushDest
            elseif navmesh and navmesh.GetNavAreaCount() > 0 then
                bd.recentRoamAreas = bd.recentRoamAreas or {}
                local exclude = {}; for _, id in ipairs(bd.recentRoamAreas) do exclude[id]=true end
                local ra = GetFarNavArea(botPos, exclude, 500) or GetRandomNavArea()
                if ra then
                    bd.roamDest = ra:GetCenter()
                    table.insert(bd.recentRoamAreas, 1, ra:GetID())
                    while #bd.recentRoamAreas > 6 do table.remove(bd.recentRoamAreas) end
                else
                    bd.roamDest = TDMBot_RandomMapPos()
                end
            else
                bd.roamDest = TDMBot_RandomMapPos()
            end
        end
        dest = bd.roamDest
    end

    if TDM_Gunfight and TDM_Gunfight.zoneActive and TDM_Gunfight.zonePos then
        if not (IsValid(target) and TDMBot_IsAlive(target) and TDMBot_CanSee(bot, target)) then
            dest = TDM_Gunfight.zonePos
        end
    end

    -- Approach angle (pincer)
    -- Flank offsets are now suppressed when contact has not yet been made:
    -- the bot pushes STRAIGHT to the enemy until the first LOS, only fanning
    -- out laterally during sustained combat. This is the single biggest reason
    -- bots felt passive — the perpendicular offset was pulling them parallel
    -- to the enemy instead of toward them.
    local flankRange = p and (p.flankRange or 0) or 0
    local hasContact = (now - (bd.lastSeenAt or 0)) < 3.0
    if IsValid(target) and TDMBot_IsAlive(target) and hasContact then
        if target ~= bd.lastApproachTarget then
            bd.lastApproachTarget = target
            bd.approachAngle      = GetPincerApproachAngle(bot, flankRange)
        end
        if (bd.approachAngle or 0) ~= 0 then
            local toTgt = dest - botPos; toTgt.z=0
            local tLen  = toTgt:Length()
            if tLen > 100 then
                toTgt:Normalize()
                local perp   = Vector(-toTgt.y, toTgt.x, 0)
                -- Cap perpendicular offset to 30% of distance (was 65%) so the bot
                -- still meaningfully closes the range while flanking.
                local offset = math.min(math.abs(bd.approachAngle), tLen*0.30) * ((bd.approachAngle>=0) and 1 or -1)
                dest = dest + perp * offset
            end
        end
    elseif IsValid(target) and TDMBot_IsAlive(target) then
        -- No recent contact: forget any previous flank, push direct.
        bd.approachAngle      = 0
        bd.lastApproachTarget = nil
    end

    -- ── Rebuild A* path ───────────────────────────────────────
    -- Rebuild more aggressively when chasing a moving target.
    local chasingLive = IsValid(target) and TDMBot_IsAlive(target)
    local navInterval = chasingLive and NAV_UPDATE_CHASE or NAV_UPDATE_ROAM
    -- Tight 90u threshold while chasing so the path follows a moving enemy in
    -- near-real-time; loose 160u threshold while roaming to avoid thrashing.
    local repathDistSqr = chasingLive and CHASE_REPATH_DIST_SQR or (160*160)
    local destChanged = (not bd.lastNavDest) or bd.lastNavDest:DistToSqr(dest) > repathDistSqr
    if now >= (bd.nextNav or 0) or not bd.navPath or destChanged then
        bd.nextNav     = now + navInterval
        bd.lastNavDest = dest
        -- LOS-direct shortcut: only trust a straight-line path when the bot's
        -- FEET (not eyes) can also reach the destination without obstruction.
        -- Eye-LOS alone is not enough — a player visible through a railing or
        -- a window may not be reachable on foot, so falling back to A* is
        -- much more reliable than letting the bot walk into a wall.
        local useDirect = false
        if IsValid(target) and TDMBot_IsAlive(target) and TDMBot_CanSee(bot, target) then
            local trFeet = util.TraceHull({
                start  = botPos + Vector(0,0,18),
                endpos = dest    + Vector(0,0,18),
                filter = bot,
                mask   = MASK_PLAYERSOLID,
                mins   = Vector(-12,-12,0),
                maxs   = Vector( 12, 12,48),
            })
            useDirect = not trFeet.Hit
        end
        if useDirect then
            bd.navPath = { dest }
        else
            bd.navPath = BuildNavPath(botPos, dest)
        end
        bd.navStep = 1
    end

    -- ── Advance through waypoints (3D distance) ───────────────
    -- The old 2D-only check caused bots to "reach" waypoints that were
    -- one floor above them on ramps/stairs.  3D distance fixes this.
    local path = bd.navPath
    local step = bd.navStep or 1
    while path[step] do
        local wp = path[step]
        if (botPos - wp):LengthSqr() < WAYPOINT_REACH_3D_SQR then
            step = step + 1
        else
            break
        end
    end
    bd.navStep = step

    -- Proactive jump for height changes in the path.
    -- Suppressed while executing a stuck-escape to prevent the step-jump from
    -- looping every 0.8 s when the bot is pinned against a wall/corner.
    local stuckEscaping = now < (bd.stuckEscapeUntil or 0)
    local nextWP = path[step]
    if nextWP and bot:IsOnGround() and now >= (bd.nextJumpAllowed or 0) and not stuckEscaping then
        local toWP  = nextWP - botPos
        local hDiff = toWP.z
        toWP.z = 0
        local hDist = toWP:Length()
        if hDist < 160 and hDiff > 20 and hDiff < 95 then
            toWP:Normalize()
            local trStep = util.TraceLine({
                start=botPos+Vector(0,0,38), endpos=botPos+Vector(0,0,38)+toWP*50,
                filter=bot, mask=MASK_PLAYERSOLID,
            })
            if trStep.Hit then
                bd.wantJump = true; bd.nextJumpAllowed = now + JUMP_COOLDOWN
            end
        end
    end

    -- Ladder detection: if the next waypoint is far above (> LADDER_HEIGHT_THRESH),
    -- the path is routing through a ladder. Force a jump to get on the ladder and
    -- hold forward so the bot climbs rather than just standing at the base.
    if nextWP then
        local hDiff = nextWP.z - botPos.z
        if hDiff > LADDER_HEIGHT_THRESH then
            if not bd.onLadder then
                bd.onLadder = true
                bd.ladderGoal = nextWP
            end
            -- Jump to grab the ladder
            if bot:IsOnGround() and now >= (bd.nextJumpAllowed or 0) then
                bd.wantJump        = true
                bd.nextJumpAllowed = now + 0.5
            end
        else
            if bd.onLadder and (not nextWP or hDiff <= 20) then
                bd.onLadder   = false
                bd.ladderGoal = nil
            end
        end
    else
        bd.onLadder   = false
        bd.ladderGoal = nil
    end

    -- Lateral wander
    if now >= (bd.nextWanderFlip or 0) then
        bd.nextWanderFlip = now + math.Rand(0.5, 1.5)
        local maxW = p and (p.preferClose and 80 or 150) or 110
        bd.wanderOffset = math.Rand(-maxW, maxW)
    end

    local rawGoal = path[step] or dest
    local wander  = bd.wanderOffset or 0

    if rawGoal and math.abs(wander) > 10 then
        local toRaw = rawGoal - botPos; toRaw.z = 0
        if toRaw:LengthSqr() > 150*150 then
            toRaw:Normalize()
            local left  = Vector(-toRaw.y, toRaw.x, 0)
            local chest = botPos + Vector(0,0,42)
            local trL = util.TraceLine({start=chest, endpos=chest+left*70,  filter=bot, mask=MASK_PLAYERSOLID})
            local trR = util.TraceLine({start=chest, endpos=chest-left*70,  filter=bot, mask=MASK_PLAYERSOLID})
            local trF = util.TraceLine({start=chest, endpos=chest+toRaw*80, filter=bot, mask=MASK_PLAYERSOLID})
            if (trL.Hit and trR.Hit) or trF.Hit then
                wander = wander * 0.10  -- near walls: suppress wander
            end
            bd.goal = rawGoal + left * wander
            -- Corner safety: if the offset goal is blocked, fall back to raw
            local toOff = bd.goal - botPos; toOff.z=0
            if toOff:LengthSqr() > 1 then
                local trCorner = util.TraceLine({
                    start=bot:EyePos(), endpos=bot:EyePos()+toOff:GetNormalized()*math.min(90,toOff:Length()),
                    filter=bot, mask=MASK_PLAYERSOLID,
                })
                if trCorner.Hit then bd.goal = rawGoal end
            end
        else
            bd.goal = rawGoal
        end
    else
        bd.goal = rawGoal
    end

    TryVaultWindow(bot, bd, bd.goal, now)

    -- ── Stuck detection — 3 stages ───────────────────────────
    --
    -- Uses periodic position snapshots (sampled every STUCK_THRESHOLD seconds)
    -- rather than a sliding "any 45-unit movement resets the timer" window.
    -- The old approach let bots oscillating inside containers (0→50→0 pattern)
    -- endlessly reset stuckAt and never escalate past Stage 1.
    --
    -- Stage 1 (stuckCount == 1): jump + aggressive strafe + back-up
    -- Stage 2 (stuckCount == 2): abandon path/dest; if in dead-end aim at exit
    -- Stage 3 (stuckCount >= 3): full state reset, pick fresh destination
    if not bd.goal then
        bd.stuckSnapshotPos = botPos
        bd.stuckSnapshotAt  = now
        bd.stuckCount       = 0
        return
    end

    if not bd.stuckSnapshotPos then
        bd.stuckSnapshotPos = botPos
        bd.stuckSnapshotAt  = now
        return
    end

    if now - (bd.stuckSnapshotAt or now) < STUCK_THRESHOLD then return end

    -- Snapshot interval elapsed: measure net XY displacement.
    -- 80-unit threshold prevents small oscillations (jump up/down, strafe 50 units
    -- and back) from falsely resetting stuckCount to 0.
    local sdx = botPos.x - bd.stuckSnapshotPos.x
    local sdy = botPos.y - bd.stuckSnapshotPos.y
    local movedEnough = (sdx * sdx + sdy * sdy) >= 80 * 80

    bd.stuckSnapshotPos = botPos
    bd.stuckSnapshotAt  = now

    if movedEnough then
        bd.stuckCount = 0
        -- Clear escape lock if we've successfully moved away
        if now < (bd.stuckEscapeUntil or 0) then
            bd.stuckEscapeUntil = 0
            bd.stuckEscapePos   = nil
        end
        return
    end

    -- Stuck!
    bd.stuckCount = (bd.stuckCount or 0) + 1

    local jumpDir = bd.goal and (bd.goal - botPos) or bot:GetForward()
    jumpDir.z = 0
    if jumpDir:LengthSqr() > 1 then jumpDir:Normalize() end

    local trLow  = util.TraceLine({start=botPos+Vector(0,0,36),  endpos=botPos+Vector(0,0,36) +jumpDir*55, filter=bot, mask=MASK_PLAYERSOLID})
    local trHigh = util.TraceLine({start=botPos+Vector(0,0,72),  endpos=botPos+Vector(0,0,72) +jumpDir*55, filter=bot, mask=MASK_PLAYERSOLID})
    local impassable = trLow.Hit and trHigh.Hit

    if bd.stuckCount == 1 then
        -- Stage 1: jump over low obstacles; back up if wall is solid both low and high
        if trLow.Hit and not impassable and now >= (bd.nextJumpAllowed or 0) then
            bd.wantJump = true
            bd.wantCrouch = true
            bd.crouchJumpUntil = now + 0.18
            bd.nextJumpAllowed = now + JUMP_COOLDOWN
        end
        local mag = math.random(200, 320)
        bd.strafeDir      = (math.random(0,1)==0) and mag or -mag
        bd.nextStrafeFlip = now + math.Rand(0.4, 0.8)

        -- Force a perpendicular escape waypoint so the bot breaks out of the
        -- stuck loop rather than rebuilding the same path to the same dead-end.
        local perpDir = Vector(-jumpDir.y, jumpDir.x, 0)
        local sideSign = (bd.strafeDir > 0) and 1 or -1
        local escPos
        if impassable then
            escPos = botPos + (-jumpDir) * 180  -- solid wall ahead: go back
        else
            escPos = botPos + perpDir * (sideSign * 200) + jumpDir * 60
        end
        if navmesh and navmesh.GetNavAreaCount() > 0 then
            local ea = navmesh.GetNearestNavArea(escPos, true, 280, false, false)
            if ea and not IsDeadEndArea(ea) then escPos = ea:GetCenter() end
        end
        bd.goal    = escPos
        bd.navPath = { escPos }
        bd.navStep = 1
        -- Lock this escape destination for 1.8 s so the normal dest-picker
        -- cannot immediately overwrite it with the same blocked route.
        bd.stuckEscapePos   = escPos
        bd.stuckEscapeUntil = now + 1.8
        bd.nextNav = now + 1.8  -- prevent path rebuild during escape window

        -- Try to shoot breakables blocking the path
        local eyePos = bot:EyePos()
        local fwdDir = (bd.aimAngles or bot:EyeAngles()):Forward()
        local trB = util.TraceLine({start=eyePos, endpos=eyePos+fwdDir*120, filter=bot, mask=MASK_SHOT})
        if trB.Hit and IsValid(trB.Entity) and not trB.Entity:IsWorld() then
            local cls = trB.Entity:GetClass()
            if cls=="func_breakable" or cls=="func_breakable_surf"
               or cls:find("glass",1,true) or cls:find("window",1,true)
               or (trB.Entity:GetMoveType()==MOVETYPE_VPHYSICS and trB.Entity:Health()>0 and trB.Entity:Health()<80) then
                bd.wantAttack=true; bd.tapUntil=now+0.40; bd.wantADS=false
            end
        end

    elseif bd.stuckCount == 2 then
        -- Stage 2: abandon destination; route to dead-end exit if applicable
        bd.navPath            = nil
        bd.roamDest           = nil
        bd.lastKnownTargetPos = nil
        bd.approachAngle      = 0
        bd.wanderOffset       = 0
        bd.nextRoamRefresh    = now

        -- If stuck inside a dead-end, aim directly at its single exit
        local escArea = navmesh.GetNearestNavArea(botPos, true, 120, false, false)
        if escArea and IsDeadEndArea(escArea) then
            local adj = escArea:GetAdjacentAreas()
            if adj and #adj > 0 then
                local exitPos = adj[1]:GetClosestPointOnArea(botPos)
                bd.goal    = exitPos
                bd.navPath = { exitPos }
                bd.navStep = 1
            end
        end

        if navmesh and navmesh.GetNavAreaCount() > 0 then
            bd.recentRoamAreas = bd.recentRoamAreas or {}
            local exclude = {}; for _, id in ipairs(bd.recentRoamAreas) do exclude[id]=true end
            local ra = GetFarNavArea(botPos, exclude, 400)
            if ra then
                bd.roamDest = ra:GetCenter()
                -- Set goal directly so the bot starts moving immediately;
                -- relying on roamDest alone lets the normal dest-picking logic
                -- override it with the same stuck destination on the next tick.
                bd.goal    = bd.roamDest
                bd.navPath = { bd.goal }
                bd.navStep = 1
                bd.stuckEscapePos   = bd.goal
                bd.stuckEscapeUntil = now + 2.5
                bd.nextNav = now + 2.5
                table.insert(bd.recentRoamAreas, 1, ra:GetID())
                while #bd.recentRoamAreas > 6 do table.remove(bd.recentRoamAreas) end
            end
        end

    else
        -- Stage 3: full reset — two recovery attempts have failed
        bd.stuckCount         = 0
        bd.stuckSnapshotPos   = nil
        bd.stuckSnapshotAt    = nil
        bd.navPath            = nil
        bd.roamDest           = nil
        bd.lastKnownTargetPos = nil
        bd.approachAngle      = 0
        bd.goal               = nil
        bd.stuckEscapePos     = nil
        bd.stuckEscapeUntil   = 0
        bd.recentRoamAreas    = {}
        bd.nextRoamRefresh    = now
    end
end
