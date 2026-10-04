-- ============================================================
-- aislopmatch_bots / bot_combat.lua
-- Combat: target acquisition, aiming, firing, gadget use.
--
-- bd flags written here, consumed by StartCommand in bot_think:
--   bd.aimAngles          — current view angle (lerped each tick)
--   bd.wantAttack         — hold IN_ATTACK (full-auto)
--   bd.tapUntil           — hold IN_ATTACK until this time (semi/bolt)
--   bd.wantReload         — press IN_RELOAD
--   bd.isReloading        — reload in progress
--   bd.target / bd.lastKnownTargetPos
--   bd.grenPhase / grenade FSM fields
--   bd.forceMelee         — out of ammo, charge with melee
--   bd.wantPeek           — press IN_WALK for ARC9 lean
--   bd.bipodDeployed      — LMG bipod deployed
--   bd.gadgetPhase        — gadget FSM
--   bd.aimNoise           — current Vector noise offset (recomputed at intervals)
--   bd.bashTarget         — bash aim angle set in CombatThink; consumed in StartCommand
-- ============================================================

local SCAN_RADIUS     = 16384  -- effectively map-wide; bots always know where every enemy is
local LOS_ABANDON_MIN = 3.5
local LOS_ABANDON_MAX = 7.5
local DEFAULT_RELOAD_TIME = 2.5

local TAP_HOLD_BOLT  = 0.15
local TAP_HOLD_SEMI  = 0.07   -- short press; weapon fires on key-down, release just resets for next shot
local BASH_DIST      = 75    -- units; true knife-fight range only

-- Skill-based aim error in degrees
local AIM_ERROR   = { [1]=8.0, [2]=4.0, [3]=1.5 }
-- Aim-noise refresh interval (seconds between new random offsets)
local NOISE_INTER = { [1]=0.25, [2]=0.40, [3]=0.60 }
-- Reaction delay before first shot on a new target
local REACT_DELAY = { [1]=0.70, [2]=0.38, [3]=0.15 }
-- Dot-product fire threshold (how aligned aim must be before firing)
local AIM_THRESH  = { [1]=0.90, [2]=0.93, [3]=0.96 }
-- Minimum inter-shot pause for semi (seconds) — just long enough for recoil
-- to partially decay.  Kept tight: the weapon's own GetNextPrimaryFire is the
-- primary rate limiter; this only prevents compounding-recoil spam.
local SEMI_SETTLE = { [1]=0.10, [2]=0.05, [3]=0.02 }

local SUPPRESS_MIN  = 260
local SUPPRESS_MAX  = 1200

-- ── Weapon type helpers ────────────────────────────────────────────────────
local _fireModeCache = {}

local function GetFireMode(wep)
    if not IsValid(wep) then return "auto" end
    if wep.BoltAction or wep.ManualAction then return "bolt" end
    if wep.Semiauto then return "semi" end

    -- For ARC9 weapons, always read the LIVE current firemode rather than the
    -- weapon class default.  This correctly handles:
    --   • Full-auto ARs (e.g. AS-VAL) placed in semi mode by a loadout → "semi"
    --   • Weapons whose firemode was randomised to burst              → "burst"
    --   • Auto weapons currently set to auto                          → fall through
    -- ARC9 Mode values: < 0 = auto, 0 = safe, 1 = semi, > 1 = burst count.
    -- Do NOT cache ARC9 results — the mode can change mid-round.
    if wep.ARC9 and wep.GetCurrentFiremode then
        local arc9Mode = wep:GetCurrentFiremode()
        if arc9Mode == 1 then return "semi"  end   -- single-fire: must tap
        if arc9Mode > 1  then return "burst" end   -- fixed burst: hold until volley done
        -- arc9Mode < 0 or 0 (auto/safe): fall through to class-name defaults below
    end

    local cls = wep:GetClass()
    if _fireModeCache[cls] then return _fireModeCache[cls] end
    local def  = weapons.Get(cls)
    local mode
    if def and (def.BoltAction or def.ManualAction) then
        mode = "bolt"
    elseif def and def.Semiauto then
        mode = "semi"
    elseif cls:find("_sn_",1,true) or cls:find("_mm_",1,true) then
        mode = "bolt"
    elseif cls:find("_pi_",1,true) or cls:find("_sh_",1,true) then
        mode = "semi"
    else
        mode = "auto"
    end
    _fireModeCache[cls] = mode
    return mode
end

local function IsLMGWeapon(wep)  return IsValid(wep) and wep:GetClass():find("_lm_",1,true)~=nil end
-- Marksman rifles (_mm_) share the same high-accuracy / long-range treatment as
-- true snipers.  IsSniperWeapon returning true for both lets RefreshNoise,
-- IsAimedAt, prone logic, and NavThink hold-distance all work correctly for them.
local function IsSniperWeapon(wep)
    if not IsValid(wep) then return false end
    local c = wep:GetClass()
    return c:find("_sn_",1,true)~=nil or c:find("_mm_",1,true)~=nil
end
local function IsCloseWep(wep)
    if not IsValid(wep) then return false end
    local c=wep:GetClass(); return c:find("_sg_",1,true)~=nil or c:find("_sm_",1,true)~=nil
end

local WEP_RANGE = {
    -- Bolts: hold long-range standoff and reach across the entire map.
    _sn_={ideal=2400,tooClose=220,tooFar=8000},
    -- Marksman rifles sit between bolts and ARs but engage farther than before.
    _mm_={ideal=1800,tooClose=180,tooFar=6000},
    _lm_={ideal=400,tooClose=150,tooFar=900 },
    _ar_={ideal=350,tooClose=120,tooFar=800 },
    _sm_={ideal=160,tooClose=50, tooFar=400 },
    _sg_={ideal=80, tooClose=20, tooFar=160 },
    _pi_={ideal=200,tooClose=80, tooFar=500 },
}
local function GetWepRange(bot)
    local wep=bot:GetActiveWeapon()
    if not IsValid(wep) then return {ideal=300,tooClose=80,tooFar=1000} end
    for sfx,r in pairs(WEP_RANGE) do
        if wep:GetClass():find(sfx,1,true) then return r end
    end
    return {ideal=300,tooClose=80,tooFar=1000}
end

-- ── Target finding ─────────────────────────────────────────────────────────
-- Bots are intentionally omniscient: they always know which enemy is nearest
-- regardless of LOS or distance. This keeps them aggressive and ensures fights
-- start often. The illusion of fairness is preserved elsewhere — they never
-- shoot or pre-aim through walls because:
--   • bd.lastKnownTargetPos is only refreshed when LOS is real (CombatThink)
--   • TDMBot_ComputeLiveAim returns nil after 0.9 s without LOS
--   • IsAimedAt / fire gates require the bot to be facing a visible target
-- The net effect is bots converge on enemies behind walls and START fighting
-- the instant they round the corner, instead of wandering blindly.
function TDMBot_FindTarget(bot, bd)
    local now = CurTime()
    if now < (bd.nextTargetScanAt or 0) then
        local cached = bd.cachedTarget
        if IsValid(cached) and TDMBot_IsAlive(cached) and TDMBot_AreEnemies(bot, cached) then
            return cached
        end
        if cached == false then return nil end
    end

    local best, bestD = nil, SCAN_RADIUS*SCAN_RADIUS
    local loneWolf = bd.personality and bd.personality.loneWolf
    local taken = {}
    if loneWolf and TDMBots then
        for ob,obd in pairs(TDMBots) do
            if ob~=bot and IsValid(obd.target) and not TDMBot_AreEnemies(bot,ob) then
                taken[obd.target]=true
            end
        end
    end
    local function scan(skipTaken)
        for _,ply in ipairs(TDMBot_GetAlivePlayers()) do
            if ply==bot then continue end
            if not TDMBot_AreEnemies(bot,ply) then continue end
            if skipTaken and taken[ply] then continue end
            local dsq = TDMBot_DistSqr(bot,ply)
            -- Omniscient: no LOS or hearing gate. Always pick nearest enemy.
            if dsq < bestD then bestD=dsq; best=ply end
        end
        -- Hostile NPCs are valid targets too. Scanned via the same nearest-enemy
        -- rule so a closer NPC will outrank a distant player and vice versa.
        for _,npc in ipairs(TDMBot_GetHostileNPCs()) do
            if not TDMBot_AreEnemies(bot, npc) then continue end
            if skipTaken and taken[npc] then continue end
            local dsq = TDMBot_DistSqr(bot,npc)
            if dsq < bestD then bestD=dsq; best=npc end
        end
    end
    scan(loneWolf)
    if not best and loneWolf then scan(false) end
    bd.cachedTarget   = best or false
    bd.nextTargetScanAt = now + (best and 0.10 or 0.18)
    return best
end

-- ── Aim noise ─────────────────────────────────────────────────────────────
-- Simplified: just a stable offset refreshed on an interval.
-- No freeze/unfreeze system — that was the root cause of "never fires".
local function RefreshNoise(bd, dist, now, target)
    if now < (bd.nextNoiseAt or 0) then return end
    local skill  = bd.skill or 2
    local wep    = nil  -- looked up below
    local angErr = AIM_ERROR[skill] or 4.0
    local itvl   = NOISE_INTER[skill] or 0.40
    local tgtSpd = (IsValid(target) and target.GetVelocity and target:GetVelocity():Length2D()) or math.huge

    -- Tighten for weapon type. Snipers/marksman are now near-perfect.
    if bd.wepIsSn            then angErr=angErr*0.10; itvl=itvl*6.0 end  -- sn+mm: lethal accuracy
    if bd.wepMode == "bolt"  then angErr=angErr*0.18; itvl=itvl*4.0 end  -- lever/bolt non-sniper
    if bd.wepMode == "semi"  then angErr=angErr*0.55; itvl=itvl*1.8 end

    local precise = (bd.wepMode == "semi" or bd.wepMode == "bolt" or bd.wepIsSn)

    -- Standing targets should be easy hits.
    if tgtSpd < 25 then angErr = angErr * 0.35; itvl = itvl * 0.75 end

    -- Tighten at close range
    local d = math.max(40, dist or 300)
    if d < 200 then angErr = angErr * math.Clamp(d/200, 0.20, 1.0) end
    if d < 180 and tgtSpd < 25 then angErr = angErr * 0.22 end
    if d < 260 and precise then
        -- CQB precision pass for semi/snipers/marksman: minimal random spray.
        angErr = angErr * 0.08
        itvl = itvl * 0.70
    end

    -- If target is almost stationary in close quarters, remove random offset
    -- entirely for precise weapons so shots land where aim is placed.
    if precise and d < 240 and tgtSpd < 20 then
        bd.aimNoise = Vector(0, 0, 0)
        bd.nextNoiseAt = now + itvl
        return
    end

    local wErr = math.tan(math.rad(math.max(angErr, 0.05))) * d
    bd.aimNoise   = Vector(math.Rand(-wErr,wErr), math.Rand(-wErr,wErr), math.Rand(-wErr*0.15,wErr*0.15))
    bd.nextNoiseAt = now + itvl
end

-- Aim target: upper chest (occasional head at close range)
local function GetAimPos(target, dist, bd)
    local eye = target:EyePos()
    local tSpd = (bd and bd.targetSpeed) or math.huge
    local headC = (dist < 220) and 0.12 or (dist > 900 and 0.04 or 0.08)
    if dist < 260 and tSpd < 25 then headC = 0.02 end
    if math.random() < headC then return eye end
    return eye - Vector(0,0, math.Clamp(12+(dist/1100)*4, 10, 16))
end

function TDMBot_ComputeLiveAim(bot, bd)
    local now = CurTime()
    -- Suppression aim
    if now<(bd.suppressUntil or 0) and bd.suppressPos then
        local ang = (bd.suppressPos+Vector(math.Rand(-26,26),math.Rand(-26,26),math.Rand(26,54))-bot:EyePos()):Angle()
        ang.p = ang.p - (bd.recoilPitch or 0)
        ang.y = ang.y + (bd.recoilYaw   or 0)
        return ang
    end
    local target = bd.target
    if not IsValid(target) or not TDMBot_IsAlive(target) then
        if bd.lastKnownTargetPos then return (bd.lastKnownTargetPos-bot:EyePos()):Angle() end
        return nil
    end
    if now<(bd.coverPeekAt or 0) then return nil end
    if bd.reacting and now<bd.reacting then return nil end
    if now-(bd.lastSeenAt or 0) > 0.9 then
        if bd.lastKnownTargetPos then return (bd.lastKnownTargetPos-bot:EyePos()):Angle() end
        return nil
    end
    local dist   = math.sqrt(TDMBot_DistSqr(bot,target))
    local aimPos = GetAimPos(target,dist,bd) + (bd.aimNoise or Vector(0,0,0))
    local ang    = (aimPos-bot:EyePos()):Angle()
    ang.p = ang.p - (bd.recoilPitch or 0)
    ang.y = ang.y + (bd.recoilYaw   or 0)
    return ang
end

-- ── Fire alignment check ──────────────────────────────────────────────────
local function IsAimedAt(bot, bd, target, dist)
    if not bd.aimAngles then return false end
    -- Fallback aim point when aimNoise not yet computed
    local aimPos = target:EyePos() - Vector(0,0,13) + (bd.aimNoise or Vector(0,0,0))
    local aimFwd = bd.aimAngles:Forward()
    local toTgt  = (aimPos - bot:EyePos()):GetNormalized()
    local thresh = AIM_THRESH[bd.skill or 2] or 0.93
    local precise = (bd.wepMode == "semi" or bd.wepMode == "bolt" or bd.wepIsSn)
    if dist then
        if precise then
            -- Precise weapons should not spam speculative shots in CQB.
            thresh = thresh - 0.08*math.Clamp((220-dist)/220, 0, 1)
            if dist < 260 then thresh = math.max(thresh, 0.86) end
            if dist < 180 then thresh = math.max(thresh, 0.90) end
        else
            -- Autos/SMGs can keep a looser CQB gate.
            thresh = thresh - 0.22*math.Clamp((260-dist)/260, 0, 1)
        end
    end
    -- Shotguns: loose threshold
    local wep = bot:GetActiveWeapon()
    if IsValid(wep) and wep:GetClass():find("_sh_",1,true) then
        if dist and dist < 80 then return true end
        thresh = math.min(thresh, 0.65)
    end
    return aimFwd:Dot(toTgt) > thresh
end

local function FriendlyInLane(bot, tgt)
    if not IsValid(tgt) then return false end
    local tr = util.TraceHull({
        start=bot:EyePos(), endpos=tgt:EyePos(), filter=bot, mask=MASK_SHOT,
        mins=Vector(-8,-8,-8), maxs=Vector(8,8,8),
    })
    if not tr.Hit or not IsValid(tr.Entity) then return false end
    if tr.Entity == tgt then return false end
    return tr.Entity:IsPlayer() and not TDMBot_AreEnemies(bot, tr.Entity)
end

local function GlassInLane(bot, tgt)
    if not IsValid(tgt) then return false, nil end
    local tr = util.TraceLine({start=bot:EyePos(),endpos=tgt:EyePos(),filter=bot,mask=MASK_SHOT})
    if not tr.Hit then return false, nil end
    local ent=tr.Entity; if not IsValid(ent) then return false, nil end
    local cls=ent:GetClass()
    return (cls=="func_breakable" or cls=="func_breakable_surf"
        or cls:find("glass",1,true) or cls:find("window",1,true)), ent
end

-- ── Recoil ────────────────────────────────────────────────────────────────
local RD=3.0; local RP_MAX=7.0; local RY_MAX=4.8

local function DecayRecoil(bd,now)
    local dt=math.max(0,now-(bd.recoilLastAt or now)); bd.recoilLastAt=now
    if dt<=0 then return end
    local s=RD*dt
    if (bd.wepMode == "semi" or bd.wepMode == "bolt" or bd.wepIsSn) and (bd.targetDist or math.huge) < 260 then
        s = s * 1.9
    end
    local rp=bd.recoilPitch or 0
    bd.recoilPitch = rp>0 and math.max(0,rp-s) or math.min(0,rp+s)
    local ry=bd.recoilYaw or 0
    bd.recoilYaw   = ry>0 and math.max(0,ry-s*0.85) or math.min(0,ry+s*0.85)
end

local function AddRecoil(bd,wep,dist)
    local mode=GetFireMode(wep)
    -- For burst weapons, scale recoil by burst count so the bot's aim settle
    -- accounts for all rounds fired per trigger pull (e.g. 3-round burst → 3x).
    local burstCount = (mode=="semi" and IsValid(wep)) and (tonumber(wep.BurstCount) or 1) or 1
    local burstScale = (burstCount > 1) and (math.min(burstCount, 4) * 0.65) or 1.0
    local pb=(mode=="bolt" and 1.05) or (mode=="semi" and 0.75*burstScale) or 0.42
    local sm=({[1]=1.18,[2]=1.0,[3]=0.84})[bd.skill or 2] or 1.0
    local rm=1.0+math.Clamp(((dist or 300)-280)/920,0,1)*0.95
    local pK=pb*sm*rm*math.Rand(0.85,1.20)
    local yK=pK*math.Rand(0.30,0.65)*((math.random(0,1)==0) and -1 or 1)
    if (mode=="semi" or mode=="bolt") and (dist or 300) < 260 then
        pK = pK * 0.40
        yK = yK * 0.30
    end
    bd.recoilPitch=math.Clamp((bd.recoilPitch or 0)+pK,0,RP_MAX)
    bd.recoilYaw  =math.Clamp((bd.recoilYaw   or 0)+yK,-RY_MAX,RY_MAX)
end

-- ── Suppression ────────────────────────────────────────────────────────────
local function TrySuppress(bot,bd,wep,tgt,dist,canSee)
    local now=CurTime()
    if not IsLMGWeapon(wep) or GetFireMode(wep)~="auto" then return end
    if now<(bd.suppressUntil or 0) or now<(bd.nextSuppressAt or 0) then return end
    if not IsValid(tgt) or dist<SUPPRESS_MIN or dist>SUPPRESS_MAX then return end
    if (wep:Clip1() or 0)<12 then return end
    if not canSee and now-(bd.lastSeenAt or 0)>1.2 then return end
    if math.random()>=(canSee and 0.030 or 0.018) then return end
    bd.suppressUntil=now+math.Rand(1.5,3.0); bd.nextSuppressAt=now+math.Rand(4.5,8.5)
    bd.suppressRefresh=0
    bd.suppressPos=tgt:GetPos()+Vector(math.Rand(-34,34),math.Rand(-34,34),0)
end

-- ── Slot helpers ────────────────────────────────────────────────────────────
local function GetSlot(cls)
    if not cls or cls=="" then return "" end
    local def=TDM_GetWeaponDef and TDM_GetWeaponDef(cls)
    return def and tostring(def.slot or "") or ""
end

local function FindGrenWep(bot)
    for _,w in ipairs(bot:GetWeapons()) do
        if IsValid(w) and GetSlot(w:GetClass())=="grenade" then
            local ha=w:Clip1()>0
            if not ha and w.GetPrimaryAmmoType then
                local aid=w:GetPrimaryAmmoType()
                if aid and aid>=0 then ha=bot:GetAmmoCount(aid)>0 end
            end
            if ha then return w,w:GetClass() end
        end
    end
    return nil,nil
end

local function GrenSafe(bot, isLob)
    local ep=bot:EyePos(); local fd=bot:GetAngles():Forward(); fd.z=0; fd:Normalize()
    if util.TraceLine({start=ep,endpos=ep+fd*160,filter=bot,mask=MASK_SOLID_BRUSHONLY}).Hit then return false end
    if isLob then
        local ad=Vector(fd.x,fd.y,1); ad:Normalize()
        if util.TraceLine({start=ep,endpos=ep+ad*200,filter=bot,mask=MASK_SOLID_BRUSHONLY}).Hit then return false end
    end
    return true
end

local function FindCombatWep(bot)
    for _,w in ipairs(bot:GetWeapons()) do
        if IsValid(w) then
            local s=GetSlot(w:GetClass()); if s=="primary" or s=="secondary" then return w:GetClass() end
        end
    end
    return nil
end

local function GadgetsEnabled()
    local cfg = TDM_CONFIG
    if not istable(cfg) then return true end
    if cfg.GadgetsEnabled == false then return false end
    if cfg.EnableGadgets == false then return false end
    if cfg.AllowGadgets == false then return false end
    if cfg.FieldUpgradesEnabled == false then return false end
    return true
end

local function IsOutOfAmmo(bot)
    local found=false
    for _,w in ipairs(bot:GetWeapons()) do
        if IsValid(w) then
            local s=GetSlot(w:GetClass())
            if s=="primary" or s=="secondary" then
                found=true
                if w:Clip1()>0 then return false end
                if w.GetPrimaryAmmoType then
                    local aid=w:GetPrimaryAmmoType()
                    if aid and aid>=0 and bot:GetAmmoCount(aid)>0 then return false end
                end
            end
        end
    end
    return found
end

local function FindMeleeWep(bot)
    for _,w in ipairs(bot:GetWeapons()) do
        if IsValid(w) then
            local cls=w:GetClass()
            if GetSlot(cls)=="melee" or cls:find("_me_",1,true) then return cls end
        end
    end
    return nil
end

local function HasUBGL(wep)
    if not IsValid(wep) or not wep.ARC9 then return false end
    local ok=false
    if wep.GetProcessedValue then ok=wep:GetProcessedValue("UBGL")==true end
    if not ok and wep.GetValue then ok=wep:GetValue("UBGL")==true end
    return ok and (wep:Clip2() or 0)>0
end

-- ── Reload helpers ────────────────────────────────────────────────────────
local function StartReload(bot,bd,wep)
    local now=CurTime()
    if bd.isReloading then return end
    if now<(bd.nextReloadAllowed or 0) then return end
    bd.wantAttack=false; bd.tapUntil=nil; bd.wantReload=true; bd.isReloading=true
    bd.reloadExtensions=0
    local rt=(IsValid(wep) and wep.ReloadTime) or DEFAULT_RELOAD_TIME
    bd.reloadDoneAt=now+math.max(1.0,rt+0.2); bd.nextReloadAllowed=now+0.9
end

local function CheckReloadDone(bot,bd)
    if not bd.isReloading then return end
    if CurTime()<(bd.reloadDoneAt or 0) then return end
    local wep=bot:GetActiveWeapon()
    if IsValid(wep) and (wep:Clip1() or 0)<=0 then
        bd.reloadExtensions=(bd.reloadExtensions or 0)+1
        if bd.reloadExtensions<=4 then bd.reloadDoneAt=CurTime()+0.5; return end
    end
    bd.isReloading=false; bd.wantReload=false; bd.reloadExtensions=0
end

-- ── LMG bipod ─────────────────────────────────────────────────────────────
local function HasBipodSurface(bot)
    local pos=bot:GetPos(); local fwd=bot:GetForward(); fwd.z=0; fwd:Normalize()
    local waist=pos+Vector(0,0,36)
    if util.TraceLine({start=waist,endpos=waist+fwd*88,filter=bot,mask=MASK_SOLID_BRUSHONLY}).Hit then return true end
    local trD=util.TraceLine({start=pos+Vector(0,0,8),endpos=pos-Vector(0,0,16),filter=bot,mask=MASK_SOLID_BRUSHONLY})
    return trD.Hit and trD.HitNormal.z>0.85
end

-- ── Grenade reaction ──────────────────────────────────────────────────────
local function HandleGrenReact(bot,bd,now)
    if not bd.nearbyGrenadePos then return false end
    if now-(bd.nearbyGrenadeAt or 0)>2.5 then bd.nearbyGrenadePos=nil; return false end
    if bot:GetPos():DistToSqr(bd.nearbyGrenadePos)>280*280 then bd.nearbyGrenadePos=nil; return false end
    local closeEnemy,closeDist=nil,350*350
    for _,ply in ipairs(TDMBot_GetAlivePlayers()) do
        if TDMBot_AreEnemies(bot,ply) then
            local dsq=TDMBot_DistSqr(bot,ply); if dsq<closeDist then closeDist=dsq; closeEnemy=ply end
        end
    end
    if IsValid(closeEnemy) then
        bd.target=closeEnemy; bd.state="hunt"; bd.nearbyGrenadePos=nil; bd.wantCrouch=false; return false
    end
    local away=bot:GetPos()-bd.nearbyGrenadePos; away.z=0
    if away:LengthSqr()<1 then away=bot:GetForward(); away.z=0 end; away:Normalize()
    bd.goal=bot:GetPos()+away*350; bd.state="retreat"; bd.wantCrouch=false
    bd.wantADS=false; bd.wantAttack=false; bd.tapUntil=nil; bd.grenadeEscapeUntil=now+1.8
    return true
end

-- ── Gadget ────────────────────────────────────────────────────────────────
local function MaybeUseGadget(bot,bd,target,dist,now)
    if not GadgetsEnabled() then
        bd.gadgetPhase=nil; bd.gadgetPhaseAt=0; bd.gadgetSwitchBackTo=nil
        return
    end
    local lo=bd.loadout
    if not lo or not lo.gadget or lo.gadget=="" then return end
    if bd.gadgetPhase or bd.grenPhase or bd.isReloading then return end
    local gt=lo.gadgetType or "other"
    if gt=="launcher" then
        if not IsValid(target) then return end
        if now<(bd.gadgetCooldown or 0) then return end
        if dist<250 or dist>1600 then return end
        if not bot:HasWeapon(lo.gadget) then return end
        if math.random()>0.008 then return end
        bd.gadgetPhase=1; bd.gadgetPhaseAt=now; bd.gadgetSwitchBackTo=FindCombatWep(bot)
        bd.gadgetCooldown=now+math.Rand(18,35)
    elseif gt=="support" then
        if now<(bd.gadgetCooldown or 0) then return end
        if not bot:HasWeapon(lo.gadget) then return end
        local sd=(not IsValid(target) and math.random()<0.012)
                or(IsValid(target) and bd.state=="combat" and math.random()<0.003)
        if not sd then return end
        bd.gadgetPhase=1; bd.gadgetPhaseAt=now; bd.gadgetSwitchBackTo=FindCombatWep(bot)
        bd.gadgetCooldown=now+math.Rand(30,60)
    end
end

local function RunGadgetFSM(bot,bd,now)
    if not bd.gadgetPhase then return false end
    if not GadgetsEnabled() then
        bd.wantAttack=false; bd.tapUntil=nil; bd.wantADS=false
        bd.gadgetPhase=nil; bd.gadgetPhaseAt=0; bd.gadgetSwitchBackTo=nil
        return true
    end
    local lo=bd.loadout; local gt=(lo and lo.gadgetType) or "other"
    if bd.gadgetPhase==1 then
        local gw=lo and lo.gadget
        if gw and bot:HasWeapon(gw) then bot:SelectWeapon(gw) else bd.gadgetPhase=nil; return true end
        bd.wantAttack=false; bd.tapUntil=nil
        -- Freeze movement during gadget use so the bot doesn't wander mid-deploy
        bd.goal=nil; bd.moveForward=0; bd.moveSide=0
        bd.gadgetPhase=2; bd.gadgetPhaseAt=now+(gt=="launcher" and 0.50 or 0.50)
    elseif bd.gadgetPhase==2 and now>=(bd.gadgetPhaseAt or 0) then
        if gt=="launcher" then
            bd.wantADS=true; bd.gadgetPhase=3; bd.gadgetPhaseAt=now+0.40
        else
            -- Support/munitions crate: aim steeply downward so the crate lands
            -- directly in front of the bot on the ground.
            local yaw = bd.aimAngles and bd.aimAngles.y or bot:EyeAngles().y
            local downAng = Angle(50, yaw, 0)   -- 50° down — enough to clear most surfaces
            bd.aimAngles = downAng
            bot:SetEyeAngles(downAng)
            -- Hold IN_ATTACK for the full deploy window rather than a short tap.
            -- ARC9 field upgrades often need a sustained press (deploy animation
            -- can run 0.5–1.5 s).  wantAttack=true is held until Phase 3 clears it.
            bd.wantAttack    = true
            bd.tapUntil      = nil
            bd.wantADS       = false   -- never ADS while deploying a crate
            bd.gadgetPhase   = 3
            bd.gadgetPhaseAt = now + 1.8   -- hold attack for up to 1.8 s
        end
    elseif bd.gadgetPhase==3 and now>=(bd.gadgetPhaseAt or 0) then
        if gt=="launcher" then
            bd.tapUntil=now+0.12; bd.wantAttack=false; bd.wantADS=true
            bd.gadgetPhase=4; bd.gadgetPhaseAt=now+0.70
        else
            -- Deploy done: stop pressing attack, switch back to combat weapon.
            bd.wantAttack = false
            bd.tapUntil   = nil
            local back=bd.gadgetSwitchBackTo
            if back and bot:HasWeapon(back) then bot:SelectWeapon(back) end
            bd.wantADS=false; bd.gadgetPhase=nil; bd.gadgetSwitchBackTo=nil
        end
    elseif bd.gadgetPhase==4 and now>=(bd.gadgetPhaseAt or 0) then
        local back=bd.gadgetSwitchBackTo
        if back and bot:HasWeapon(back) then bot:SelectWeapon(back) end
        bd.wantADS=false; bd.gadgetPhase=nil; bd.gadgetSwitchBackTo=nil
    end
    return true
end

-- Grenades that throw on initial press (no cook needed in ARC9 COD2019).
-- Holding IN_ATTACK for 2 seconds on these does nothing useful.
local INSTANT_THROW_PATTERNS = { "_mol", "_smk", "_smoke", "_stun", "_therm", "_decoy" }
local function IsInstantThrowGrenade(cls)
    if not cls then return false end
    local c = cls:lower()
    for _, pat in ipairs(INSTANT_THROW_PATTERNS) do
        if c:find(pat, 1, true) then return true end
    end
    return false
end
function TDMBot_CombatThink(bot, bd)
    local now = CurTime()
    DecayRecoil(bd, now)
    if now>=(bd.suppressUntil or 0) then bd.suppressPos=nil end

    -- ── GRENADE FSM (highest priority — never interrupt a cook) ───────────
    if bd.grenPhase then
        -- Freeze ALL movement and stop all other actions during throw sequence.
        -- NavThink still runs after CombatThink but bd.goal=nil prevents it from
        -- computing movement inputs. Without this bots run while holding a grenade
        -- and ARC9 interrupts the throw animation.
        bd.goal        = nil
        bd.moveForward = 0
        bd.moveSide    = 0

        if bd.grenPhase == 1 then
            -- Phase 1: equip the grenade weapon
            if bd.grenClass and bot:HasWeapon(bd.grenClass) then bot:SelectWeapon(bd.grenClass) end
            bd.wantAttack = false; bd.tapUntil = nil; bd.wantADS = false
            bd.grenPhase  = 2
            -- Wait for the weapon to actually become active
            local waitTime = bd.grenIsSpawnLob and 0.70 or 0.45
            bd.grenPhaseAt = now + waitTime

        elseif bd.grenPhase == 2 and now >= (bd.grenPhaseAt or 0) then
            -- Phase 2: verify weapon is equipped, then start the throw
            local awCls = IsValid(bot:GetActiveWeapon()) and bot:GetActiveWeapon():GetClass() or ""
            if bd.grenClass and awCls ~= bd.grenClass then
                bot:SelectWeapon(bd.grenClass)
                -- Extend wait if weapon hasn't switched yet (max 3 retries worth)
                bd.grenSwitchRetry = (bd.grenSwitchRetry or 0) + 1
                if bd.grenSwitchRetry > 3 then
                    -- Give up — weapon switch is never going to work
                    bd.grenPhase=nil; bd.grenClass=nil; bd.grenCooldown=now+5; bd.grenSwitchRetry=0
                else
                    bd.grenPhaseAt = now + 0.25
                end
                return
            end
            bd.grenSwitchRetry = 0

            -- Aim toward the target BEFORE pressing IN_ATTACK so the throw goes
            -- in the right direction (the pre-aim angle persists into phase 3).
            if bd.grenTargetPos then
                local toTarget = (bd.grenTargetPos - bot:EyePos())
                local targetAng = toTarget:Angle()
                if bd.grenIsSpawnLob then
                    -- Steep mortar arc
                    local dist = Vector(toTarget.x, toTarget.y, 0):Length()
                    local pitchUp = math.Clamp(42 + (dist/2400)*26, 42, 68)
                    targetAng = Angle(-pitchUp, targetAng.y, 0)
                end
                bd.aimAngles = targetAng
                bot:SetEyeAngles(targetAng)
            end

            local isInstant = IsInstantThrowGrenade(bd.grenClass)
            if isInstant then
                -- Instant-throw grenades (molotov, smoke, stun): single brief press.
                -- Holding doesn't help; the throw happens on the initial press.
                bd.tapUntil   = now + 0.18
                bd.wantAttack = false
                bd.grenPhase  = 4   -- skip cook phase, go straight to cleanup
                bd.grenPhaseAt = now + 0.8
            else
                -- Cook grenades (frag, flash): hold IN_ATTACK to cook, release to throw.
                bd.wantAttack = true
                bd.tapUntil   = nil
                local cookTime = bd.grenIsSpawnLob and math.Rand(0.05, 0.10) or math.Rand(0.8, 1.6)
                bd.grenPhaseAt = now + cookTime
                bd.grenPhase  = 3
                if bd.grenIsSpawnLob then bd.wantJump = true end
            end

        elseif bd.grenPhase == 3 then
            -- Phase 3: cook (hold IN_ATTACK). Re-assert every tick.
            bd.wantAttack = true; bd.tapUntil = nil; bd.wantADS = false
            if now >= (bd.grenPhaseAt or 0) then
                -- Cook done: release IN_ATTACK to throw.
                bd.wantAttack  = false
                bd.grenPhase   = 4
                bd.grenPhaseAt = now + 0.8   -- wait for projectile to clear before switching back
            end

        elseif bd.grenPhase == 4 and now >= (bd.grenPhaseAt or 0) then
            -- Phase 4: switch back to primary weapon
            local back = bd.grenSwitchBackTo
            if back and bot:HasWeapon(back) then bot:SelectWeapon(back) end
            bd.grenPhase       = nil; bd.grenClass      = nil; bd.grenSwitchBackTo = nil
            bd.grenIsLob       = false; bd.grenIsSpawnLob = false; bd.grenTargetPos = nil
            bd.grenSwitchRetry = 0
            bd.grenCooldown    = now + math.Rand(20, 40)
        end
        return
    end

    if bd.nearbyGrenadePos then
        if HandleGrenReact(bot,bd,now) then return end
    end

    if bd.gadgetPhase then RunGadgetFSM(bot,bd,now); return end

    -- UBGL sequence
    if bd.ubglPhase then
        if bd.ubglPhase==1 and now>=(bd.ubglPhaseAt or 0) then
            bd.wantUBGLToggle=true; bd.wantAttack=false; bd.tapUntil=nil
            bd.ubglPhase=2; bd.ubglPhaseAt=now+0.40; bd.wantADS=true; bd.moveForward=0; bd.moveSide=0; return
        elseif bd.ubglPhase==2 and now>=(bd.ubglPhaseAt or 0) then
            bd.tapUntil=now+TAP_HOLD_BOLT; bd.wantAttack=false; bd.ubglPhase=3; bd.ubglPhaseAt=now+0.25
        elseif bd.ubglPhase==3 and now>=(bd.ubglPhaseAt or 0) then
            bd.wantUBGLToggle=true; bd.ubglPhase=nil; bd.ubglCooldown=now+math.Rand(8,16)
        end
        bd.wantADS=false; return
    end

    CheckReloadDone(bot, bd)

    -- ── Target acquisition ────────────────────────────────────────────────
    local target = bd.target
    if not IsValid(target) or not TDMBot_IsAlive(target) then
        if bd.target ~= nil then
            -- Target is confirmed dead or invalid — clear the last-known position too.
            -- Without this, lastKnownTargetPos stays at ground level where the enemy
            -- died, causing the scan anchor to point downward for several seconds.
            bd.target             = nil
            bd.reacting           = nil
            bd.aimNoise           = nil
            bd.lastKnownTargetPos = nil
        end
        target = TDMBot_FindTarget(bot, bd)
        if IsValid(target) then
            bd.target   = target
            bd.reacting = now + (REACT_DELAY[bd.skill] or 0.38) * ((bd.personality and bd.personality.reactionMult) or 1.0)
            bd.aimNoise = nil  -- fresh noise for new target
        end
    end

    if not IsValid(target) then
        bd.wantAttack=false; bd.tapUntil=nil; bd.wantADS=false; bd.state="hunt"
        MaybeUseGadget(bot,bd,nil,math.huge,now)
        -- Spawn mortar lob
        if bd.pendingSpawnLob and not bd.grenPhase and now>=(bd.grenCooldown or 0) then
            local lobPos=bd.pendingSpawnLob; local lobDist=bot:GetPos():Distance(lobPos)
            if lobDist>=600 and lobDist<=2400 then
                local _,gc=FindGrenWep(bot)
                if gc then
                    bd.grenClass=gc; bd.grenSwitchBackTo=FindCombatWep(bot)
                    bd.grenIsLob=true; bd.grenIsSpawnLob=true; bd.grenTargetPos=lobPos
                    bd.grenPhase=1; bd.wantAttack=false; bd.tapUntil=nil
                    bd.moveForward=0; bd.moveSide=0; bd.pendingSpawnLob=nil
                end
            else bd.pendingSpawnLob=nil end
        end
        return
    end

    if bd.reacting and now<bd.reacting then bd.wantAttack=false; bd.tapUntil=nil; return end

    -- Removed damage cover-discipline pause: bots continue to fight while hit.

    -- Glass-LOS: treat enemies visible through a breakable window as fully visible.
    -- TDMBot_CanSee uses MASK_SOLID_BRUSHONLY which counts func_breakable glass as
    -- opaque, so without this bots refuse to engage through any window. Now they
    -- shoot through it (snipers especially benefit). bd.glassLOS lets the fire
    -- gate know it's a glass-engagement and tightens aim further.
    local canSee=TDMBot_CanSee(bot,target)
    bd.glassLOS = false
    if not canSee then
        local gb = GlassInLane(bot, target)
        if gb then canSee = true; bd.glassLOS = true end
    end
    -- Only update lastKnownTargetPos when LOS is genuine. This is what keeps
    -- omniscient targeting from looking like a wallhack \u2014 the bot walks toward
    -- where it knows the enemy is, but its AIM never snaps through a wall.
    if canSee then
        bd.lastSeenAt = now
        bd.lastKnownTargetPos = target:GetPos()
    end

    local dist=math.sqrt(TDMBot_DistSqr(bot,target))
    bd.targetDist=dist
    bd.targetSpeed = target:GetVelocity():Length2D()
    -- At bash range the target is practically on top of the bot; always treat as visible.
    local closeRecentLOS = (dist < BASH_DIST) or ((dist < 210) and ((now - (bd.lastSeenAt or 0)) < 0.55))

    local wr=GetWepRange(bot)
    local wepTooClose=wr.tooClose; local wepIdeal=wr.ideal; local wepTooFar=wr.tooFar
    -- Personality minEngageDist: campers treat anything inside this distance as
    -- "too close" and retreat to keep their preferred sight-line. Rushers have
    -- minEngageDist=50 so this barely affects them.
    local pMinEng = (bd.personality and bd.personality.minEngageDist) or 0
    if pMinEng > wepTooClose then wepTooClose = pMinEng end
    local activeWep=bot:GetActiveWeapon()

    -- ── State machine (hysteresis) ────────────────────────────────────────
    if canSee then
        -- Never retreat when melee-charging: the bot needs to close in to attack,
        -- not back away the moment it reaches weapon range.
        if dist<wepTooClose and not bd.forceMelee then bd.state="retreat"
        elseif dist>wepTooFar then bd.state="hunt"
        elseif bd.state=="hunt" then
            if dist<=wepIdeal*0.90 then bd.state="combat" end
        else bd.state = dist>wepIdeal*1.25 and "hunt" or "combat" end
    else
        if closeRecentLOS then
            -- At point-blank range, transient LOS flicker (corners/props/door frames)
            -- should not fully suppress combat behavior.
            canSee = true
            bd.state = "combat"
        else
        bd.wantAttack=false; bd.tapUntil=nil; bd.wantADS=false; bd.state="hunt"
        -- Glass shoot-out
        local gb,ge=GlassInLane(bot,target)
        if gb and IsValid(ge) then bd.aimGlassTarget=ge:GetPos()+Vector(0,0,36); bd.breakingGlass=true; bd.wantAttack=true
        else bd.breakingGlass=false; bd.aimGlassTarget=nil end
        -- LOS timeout
        local agB=(bd.personality and bd.personality.aggressionBias) or 0.5
        local los=LOS_ABANDON_MIN+(1-math.Clamp(agB,0,1))*(LOS_ABANDON_MAX-LOS_ABANDON_MIN)
        if now-(bd.lastSeenAt or 0)>los then
            local nt=TDMBot_FindTarget(bot,bd)
            if IsValid(nt) and TDMBot_CanSee(bot,nt) then
                bd.target=nt; bd.lastSeenAt=now; bd.aimNoise=nil; bd.lastKnownTargetPos=nil
                bd.reacting=now+(REACT_DELAY[bd.skill] or 0.38)*((bd.personality and bd.personality.reactionMult) or 1.0)*0.5
            elseif not IsValid(nt) then bd.target=nil; bd.lastKnownTargetPos=nil end
            bd.lastSeenAt=now-los*0.5
        end
        if IsValid(activeWep) then TrySuppress(bot,bd,activeWep,target,dist,false) end
        -- Melee-charging bots can attack in close range even without LOS
        -- (target may be just around a corner at 50 units).
        if bd.forceMelee and dist < 80 then
            bd.wantAttack = true; bd.state = "combat"
        end
        return
        end
    end

    bd.breakingGlass=false; bd.aimGlassTarget=nil

    -- ── Weapon checks ─────────────────────────────────────────────────────
    local wep=bot:GetActiveWeapon()
    if not IsValid(wep) then bd.wantAttack=false; bd.tapUntil=nil; return end

    -- Cache fire mode for noise scaling
    bd.wepMode  = GetFireMode(wep)
    bd.wepIsSn  = IsSniperWeapon(wep)

    -- Glass shoot-through
    local gb,ge=GlassInLane(bot,target)
    if gb and IsValid(ge) and not bd.isReloading then bd.wantAttack=true; bd.tapUntil=now+0.25; return end

    -- LMG bipod
    if IsLMGWeapon(wep) and not bd.bipodDeployed and now>=(bd.nextBipodCheck or 0) then
        bd.nextBipodCheck=now+2.0
        local p2=bd.personality
        if p2 and not p2.preferClose and dist>300 and HasBipodSurface(bot) and math.random()<0.40 then
            bd.bipodDeployed=true; bd.bipodHoldUntil=now+math.Rand(8,20); bd.wantProne=true
        end
    end
    if bd.bipodDeployed then
        local fwd=bot:GetForward(); fwd.z=0; fwd:Normalize()
        local toT=(target:GetPos()-bot:GetPos()); toT.z=0; toT:Normalize()
        if now>=(bd.bipodHoldUntil or 0) or fwd:Dot(toT)<0.25 then bd.bipodDeployed=false; bd.wantGetUp=true
        else bd.state="combat"; bd.wantCrouch=true end
    end

    -- Sniper prone
    if bd.wepIsSn and not bd.isProne and not bd.bipodDeployed and now>=(bd.nextProneCheck or 0) then
        bd.nextProneCheck=now+3.0
        local pc = (bd.personality and bd.personality.proneBias) or 0
        if dist>500 and pc > 0 and math.random()<pc then bd.wantProne=true end
    end
    if bd.isProne and dist<200 then bd.wantGetUp=true end

    -- ADS: keep M2 held during most real engagements so bots don't hipfire
    -- semi/sniper weapons in CQB.
    local cls = wep:GetClass()
    local isShotgun = cls:find("_sh_", 1, true) ~= nil
    local isPrecise = (bd.wepMode == "semi" or bd.wepMode == "bolt" or bd.wepIsSn)
    if not bd.isReloading then
        if bd.forceMelee then
            bd.wantADS = false
        elseif dist < 45 then
            -- True face-to-face knife-fight distance: hipfire is fine.
            bd.wantADS = false
        elseif isPrecise then
            -- Semi/sniper/marksman should ADS almost always while engaging.
            bd.wantADS = true
        elseif isShotgun then
            -- Shotguns only ADS outside very close range.
            bd.wantADS = dist > 90
        else
            -- AR/SMG/LMG: ADS in most fights, allow a small CQB hipfire band.
            bd.wantADS = dist > math.max(55, wepTooClose * 0.45)
        end
    end

    -- ── Bash: only when target visible AND bot is clearly facing them ──────
    -- bd.bashTarget is read in StartCommand which sets the view angle atomically
    -- with the button press, preventing "bash into the ground" caused by the
    -- aim lerp overriding CombatThink's angle before StartCommand fires.
    if wep.ARC9 and dist<BASH_DIST and now>=(bd.nextBashAt or 0) then
        local toTgt=(target:EyePos()-bot:EyePos()):GetNormalized()
        local fwd=(bd.aimAngles or bot:EyeAngles()):Forward()
        -- At extreme close range skip the dot check entirely — enemy is in the bot's face.
        -- Beyond that use a loose threshold so partial tracking still triggers a bash.
        if dist < 55 or fwd:Dot(toTgt) > 0.20 then
            -- Store the exact aim angle; StartCommand applies it atomically
            bd.bashTarget  = toTgt:Angle()
            bd.bashUntil   = now + 0.09
            bd.nextBashAt  = now + math.Rand(0.30, 0.50)
            bd.wantADS=false; bd.wantAttack=false; bd.tapUntil=nil
            return
        else
            bd.nextBashAt = now + 0.08  -- not facing yet, retry soon
        end
    end

    MaybeUseGadget(bot, bd, target, dist, now)

    -- Melee charge when out of ammo
    if IsOutOfAmmo(bot) then
        local mc=FindMeleeWep(bot)
        if mc then
            bd.forceMelee=true
            local aw=bot:GetActiveWeapon(); local ac=IsValid(aw) and aw:GetClass() or ""
            if GetSlot(ac)~="melee" and not ac:find("_me_",1,true) then bot:SelectWeapon(mc) end
        end
    else bd.forceMelee=false end

    if bd.forceMelee then
        bd.wantADS = false
        -- ARC9 knife/melee effective range is ~70 units.  Attack below 80;
        -- sprint all the way in by staying in "hunt" state until in range.
        bd.wantAttack = (dist < 80)
        if not bd.wantAttack then bd.tapUntil = nil end
        -- Explicit state overrides the weapon-range state machine so the bot
        -- never retreats and always sprints toward the target until in range.
        if dist >= 80 then bd.state = "hunt" else bd.state = "combat" end
        return
    end

    -- ── Reload ────────────────────────────────────────────────────────────
    if wep:Clip1()<=0 and not bd.isReloading then
        local hasReserve=false
        if wep.GetPrimaryAmmoType then
            local aid=wep:GetPrimaryAmmoType()
            if aid and aid>=0 and bot:GetAmmoCount(aid)>0 then hasReserve=true end
        end
        if hasReserve then
            StartReload(bot,bd,wep)
        else
            -- Find a weapon that has ammo IN the clip (not just reserve)
            local alt=nil
            for _,w in ipairs(bot:GetWeapons()) do
                if IsValid(w) then
                    local cls=w:GetClass(); if cls==wep:GetClass() then continue end
                    local s=GetSlot(cls)
                    if (s=="primary" or s=="secondary") and (w:Clip1() or 0)>0 then alt=cls; break end
                end
            end
            if alt then bot:SelectWeapon(alt)
            else local mc=FindMeleeWep(bot); if mc then bd.forceMelee=true; bot:SelectWeapon(mc) end end
        end
        return
    end
    if bd.isReloading then bd.wantAttack=false; bd.tapUntil=nil; bd.wantADS=false; return end

    -- UBGL
    if now>=(bd.ubglCooldown or 0) and HasUBGL(wep) then
        if dist>800 or math.random()<0.1 then
            bd.ubglPhase=1; bd.ubglPhaseAt=now; bd.wantADS=true; bd.tapUntil=nil; return
        end
    end

    -- Grenade lob in combat
    if now>=(bd.grenCooldown or 0) and dist>320 and dist<1450 then
        local _,gc=FindGrenWep(bot)
        local fc=math.Clamp((dist-320)/(1450-320),0,1)
        if gc and math.random()<(0.010+fc*0.020) and GrenSafe(bot,true) then
            bd.grenClass=gc; bd.grenSwitchBackTo=FindCombatWep(bot)
            bd.grenIsLob=true; bd.grenTargetPos=target:GetPos(); bd.grenPhase=1
            bd.wantAttack=false; bd.tapUntil=nil
        end
    end

    -- ARC9 peek
    if bd.wantADS and now>=(bd.nextPeekRoll or 0) then
        bd.nextPeekRoll=now+math.Rand(3.0,8.0); bd.wantPeek=math.random()<0.30
        if bd.wantPeek then bd.peekUntil=now+math.Rand(0.4,1.2) end
    end
    if bd.wantPeek and now>=(bd.peekUntil or 0) then bd.wantPeek=false end

    -- Suppression refresh
    if now<(bd.suppressUntil or 0) and bd.suppressPos and now>=(bd.suppressRefresh or 0) then
        bd.suppressRefresh=now+math.Rand(0.10,0.20)
        local anchor=target:GetPos() or bd.suppressPos
        bd.suppressPos=anchor+Vector(math.Rand(-40,40),math.Rand(-40,40),0)
    end
    if IsValid(activeWep) then TrySuppress(bot,bd,activeWep,target,dist,true) end

    -- ── Refresh aim noise ────────────────────────────────────────────────
    RefreshNoise(bd, dist, now, target)

    -- ── Aim check before firing ──────────────────────────────────────────
    local suppressing=now<(bd.suppressUntil or 0) and bd.suppressPos and IsLMGWeapon(wep)
    local isPreciseCQB = (bd.wepMode=="semi" or bd.wepMode=="bolt" or bd.wepIsSn)
    local pointBlank = dist < (isPreciseCQB and 90 or 190)

    if not pointBlank then
        if not suppressing and not IsAimedAt(bot,bd,target,dist) then
            bd.wantAttack=false; bd.tapUntil=nil; return
        end
    end

    if FriendlyInLane(bot, target) then bd.wantAttack=false; bd.tapUntil=nil; return end

    -- ── Fire ─────────────────────────────────────────────────────────────
    local nextFire=wep.GetNextPrimaryFire and wep:GetNextPrimaryFire() or 0
    local mode=bd.wepMode

    if now < nextFire then
        -- Weapon still cooling — don't fire this tick, let aim settle.
        -- Burst uses auto-style holding so treat it the same as auto here.
        if mode~="auto" and mode~="burst" then bd.wantAttack=false; bd.tapUntil=nil end
        return
    end

    -- Semi: enforce aim-settle pause so accumulated recoil can decay and
    -- bd.aimAngles can re-centre before the next shot.  Without this bots fire
    -- at maximum weapon RPM with compounding recoil, spraying shots off-target.
    -- Burst weapons skip this: PostBurstDelay on GetNextPrimaryFire already
    -- provides the inter-burst gap; adding semiSettleUntil on top was the
    -- cause of the long awkward pauses between burst volleys.
    if mode=="semi" and now < (bd.semiSettleUntil or 0) then
        bd.wantAttack=false; bd.tapUntil=nil; return
    end

    if mode=="bolt" then
        bd.tapUntil=now+TAP_HOLD_BOLT; bd.wantAttack=false
        AddRecoil(bd,wep,dist)
        -- Bolt: very long noise-stable window; aim settles naturally via long nextFire
        bd.nextNoiseAt=now+(NOISE_INTER[bd.skill or 2] or 0.40)*4.5
    elseif mode=="semi" then
        bd.tapUntil=now+TAP_HOLD_SEMI; bd.wantAttack=false
        AddRecoil(bd,wep,dist)
        -- Settle delay: enough for recoil to decay and aim lerp to re-centre.
        local settle = SEMI_SETTLE[bd.skill or 2] or 0.28
        if bd.wepIsSn and dist < 260 then
            settle = math.max(settle, 0.12)
        end
        bd.semiSettleUntil = now + settle
        -- Sync noise refresh to settle end.
        bd.nextNoiseAt = now + settle
    else
        -- auto and burst: hold trigger and let weapon RPM / PostBurstDelay handle timing.
        bd.wantAttack=true; bd.tapUntil=nil
        AddRecoil(bd,wep,dist)
    end
end
