-- ============================================================
-- aislopmatch_bots / bot_think.lua
-- Per-frame think dispatcher + StartCommand input driver.
--
-- For player.CreateNextBot bots ALL input must go through
-- GM:StartCommand / the StartCommand hook.
-- ============================================================

-- Per-bot think tick. 0.10 = 10 Hz/bot; previously 0.08 (12.5 Hz) which gave
-- no behavioural benefit but a 25% higher cost across 16 bots. Aim/strafe
-- still update at this rate, which is well below human reaction time.
local THINK_INTERVAL = 0.10

local AIM_LERP = { [1]=0.12, [2]=0.25, [3]=0.55 }

-- ── Round-active guard ───────────────────────────────────────
local function RoundIsPlayable()
    if TDM_Round then
        if TDM_Round.waiting then return false end
        if TDM_Round.warmup  then return false end
        if TDM_Round.active == false then return false end
    end
    return true
end

-- ── Weapon auto-select ───────────────────────────────────────
local function EnsureActiveWeapon(bot, bd)
    if bd.grenPhase or bd.gadgetPhase then return end

    local wep  = bot:GetActiveWeapon()
    local cls  = IsValid(wep) and wep:GetClass() or ""
    local def  = (cls ~= "" and TDM_GetWeaponDef) and TDM_GetWeaponDef(cls) or nil
    local slot = def and tostring(def.slot or "") or ""
    local isMelee = slot == "melee" or cls:find("_me_", 1, true) ~= nil

    if bd.forceMelee and isMelee then return end

    -- Helper: does a weapon entity have usable ammo?
    local function hasAmmo(w)
        if not IsValid(w) then return false end
        if (w:Clip1() or 0) > 0 then return true end
        if w.GetPrimaryAmmoType then
            local aid = w:GetPrimaryAmmoType()
            if aid and aid >= 0 and bot:GetAmmoCount(aid) > 0 then return true end
        end
        return false
    end

    local lo = bd.loadout

    local function isLikelyGadgetClass(wc)
        if not wc or wc == "" then return false end
        if lo and lo.gadget and lo.gadget ~= "" and wc == lo.gadget then return true end
        local c = wc:lower()
        return c:find("launcher", 1, true) ~= nil
            or c:find("rocket", 1, true) ~= nil
            or c:find("rpg", 1, true) ~= nil
            or c:find("_gl_", 1, true) ~= nil
            or c:find("_rl_", 1, true) ~= nil
            or c:find("claymore", 1, true) ~= nil
            or c:find("mine", 1, true) ~= nil
            or c:find("ammo", 1, true) ~= nil
            or c:find("crate", 1, true) ~= nil
            or c:find("support", 1, true) ~= nil
    end

    -- If already holding the loadout's chosen primary weapon with ammo, keep it.
    -- This covers both true primary-slot weapons AND weapons that were promoted to
    -- lo.primary because they were the only combat weapon available (e.g. pistol-only
    -- round in Gunfight), regardless of what slot TDM classifies them as.
    if lo and lo.primary and lo.primary ~= "" and cls == lo.primary and hasAmmo(wep) then return end

    -- If already holding a PRIMARY-slot weapon (and no loadout primary is set),
    -- keep it too.
    if slot == "primary" and hasAmmo(wep) then return end

    -- Priority 1: the loadout's chosen primary weapon (if it has ammo)
    if lo and lo.primary and lo.primary ~= "" then
        local pw = bot:GetWeapon(lo.primary)
        if IsValid(pw) and hasAmmo(pw) then
            if cls ~= lo.primary then bot:SelectWeapon(lo.primary) end
            return
        end
    end

    -- Priority 2: any primary-slot weapon with ammo
    for _, w in ipairs(bot:GetWeapons()) do
        if IsValid(w) then
            local wc  = w:GetClass()
            local wd  = TDM_GetWeaponDef and TDM_GetWeaponDef(wc)
            local ws  = wd and tostring(wd.slot or "") or ""
            if ws == "primary" and hasAmmo(w) then
                bot:SelectWeapon(wc); return
            end
        end
    end

    -- Priority 3: the loadout's chosen secondary (pistol)
    if lo and lo.secondary and lo.secondary ~= "" then
        local sw = bot:GetWeapon(lo.secondary)
        if IsValid(sw) and hasAmmo(sw) then
            if cls ~= lo.secondary then bot:SelectWeapon(lo.secondary) end
            return
        end
    end

    -- Priority 4: any secondary-slot weapon with ammo
    for _, w in ipairs(bot:GetWeapons()) do
        if IsValid(w) then
            local wc  = w:GetClass()
            local wd  = TDM_GetWeaponDef and TDM_GetWeaponDef(wc)
            local ws  = wd and tostring(wd.slot or "") or ""
            if ws == "secondary" and hasAmmo(w) then
                bot:SelectWeapon(wc); return
            end
        end
    end

    -- Priority 5: anything with ammo (combat fallback)
    for _, w in ipairs(bot:GetWeapons()) do
        if IsValid(w) then
            local wc  = w:GetClass()
            local wd  = TDM_GetWeaponDef and TDM_GetWeaponDef(wc)
            local ws  = wd and tostring(wd.slot or "") or ""
            if ws ~= "melee" and ws ~= "grenade" and ws ~= "gadget"
               and not wc:find("_me_", 1, true)
               and not isLikelyGadgetClass(wc)
               and hasAmmo(w) then
                bot:SelectWeapon(wc); return
            end
        end
    end

    -- Priority 6: melee ONLY when CombatThink has explicitly confirmed all ammo
    -- is gone (bd.forceMelee = true).  Never switch to knife passively — weapons
    -- can momentarily show 0 clip right after spawn before ammo is loaded, and
    -- an unconditional fallback here causes bots to equip a knife mid-spawn.
    if bd.forceMelee and not isMelee then
        for _, w in ipairs(bot:GetWeapons()) do
            if IsValid(w) then
                local wc = w:GetClass()
                local wd = TDM_GetWeaponDef and TDM_GetWeaponDef(wc)
                local ws = wd and tostring(wd.slot or "") or ""
                if ws == "melee" or wc:find("_me_", 1, true) then
                    bot:SelectWeapon(wc); return
                end
            end
        end
    end
end

-- ── Strafe flip ──────────────────────────────────────────────
local STRAFE_CHANGE       = 1.5   -- seconds between direction flips at normal range
local STRAFE_CHANGE_CLOSE = 0.35  -- faster flips when brawling up close

local function UpdateStrafe(bd)
    local now  = CurTime()
    local dist = bd.targetDist or math.huge
    local precise = (bd.wepMode == "semi" or bd.wepMode == "bolt" or bd.wepIsSn)
    local interval = (dist < 250) and STRAFE_CHANGE_CLOSE or STRAFE_CHANGE
    if precise and dist < 260 then
        interval = interval * 1.25
    end
    if now >= (bd.nextStrafeFlip or 0) then
        bd.nextStrafeFlip = now + interval + math.Rand(0, 0.2)
        -- Stronger strafe magnitude at close range for visible side-stepping.
        -- Precise weapons get reduced strafe in CQB to preserve ADS accuracy.
        local mag
        if precise and dist < 260 then
            mag = math.random(20, 60)
        else
            mag = (dist < 250) and math.random(180, 280) or math.random(50, 110)
        end
        bd.strafeDir = (math.random(0,1) == 0) and mag or -mag
    end
end

-- ── StartCommand: all player-bot inputs ──────────────────────
hook.Add("StartCommand", "TDMBots_StartCommand", function(ply, cmd)
    if not ply:IsBot() then return end
    local bd = TDMBots and TDMBots[ply]
    if not bd then return end
    if not ply:Alive() then return end
    local now = CurTime()
    local tbagActive = now < (bd.tbagUntil or 0)

    cmd:SetViewAngles(bd.aimAngles or ply:EyeAngles())

    -- ── Movement ─────────────────────────────────────────────
    local goal = bd.goal
    local desiredFwd, desiredSide = 0, 0
    local combatDist = bd.targetDist or math.huge
    local closeRange = IsValid(bd.target) and combatDist < 250

    if goal and not tbagActive then
        local myPos  = ply:GetPos()
        local yaw    = (bd.aimAngles or ply:EyeAngles()).y
        local myAng  = Angle(0, yaw, 0)
        local dir    = goal - myPos
        dir.z        = 0
        local distSqr = dir:LengthSqr()

        if distSqr > 50*50 then
            dir:Normalize()
            local fwd = myAng:Forward(); fwd.z = 0
            local fwdLen = fwd:Length()
            if fwdLen > 0.001 then fwd = fwd / fwdLen end
            local rgt = myAng:Right(); rgt.z = 0
            local rgtLen = rgt:Length()
            if rgtLen > 0.001 then rgt = rgt / rgtLen end

            if closeRange then
                -- At close range: suppress forward/back and commit to pure lateral strafe.
                -- This stops the oscillation caused by the goal dot-product flipping sign
                -- as the nearby target moves perpendicular to the bot's facing.
                desiredFwd  = 0
                desiredSide = (bd.strafeDir or 0)
            else
                desiredFwd  = math.Clamp(dir:Dot(fwd) * 400, -400, 400)
                desiredSide = math.Clamp(dir:Dot(rgt) * 400 + (bd.strafeDir or 0) * 0.4, -400, 400)
            end
        end
    elseif not goal and bd.state == "combat" and IsValid(bd.target) and not tbagActive then
        -- In combat with no nav goal: pure lateral strafe, no forward drift
        desiredSide = (bd.strafeDir or 0)
        desiredFwd  = 0
    end

    local preciseCQB = (bd.wepMode == "semi" or bd.wepMode == "bolt" or bd.wepIsSn)
        and (bd.targetDist or math.huge) < 260
    if preciseCQB and bd.wantADS then
        -- Reduce movement while ADS with precise weapons in CQB; moving spread
        -- is a major source of misses even when aim direction is correct.
        desiredFwd  = desiredFwd * 0.12
        desiredSide = desiredSide * 0.20
    end

    local moveLerp = (goal and 0.28) or 0.16
    bd.moveForward = Lerp(moveLerp, bd.moveForward or 0, desiredFwd)
    bd.moveSide    = Lerp(moveLerp, bd.moveSide or 0, desiredSide)
    cmd:SetForwardMove(bd.moveForward)
    cmd:SetSideMove(bd.moveSide)

    -- ── Button state ─────────────────────────────────────────
    local buttons = 0

    if tbagActive then
        bd.wantAttack = false
        bd.tapUntil   = nil
    end

    if bd.wantAttack then
        buttons = bit.bor(buttons, IN_ATTACK)
    elseif bd.tapUntil and now < bd.tapUntil then
        buttons = bit.bor(buttons, IN_ATTACK)
    end

    if now < (bd.bashUntil or 0) then
        -- Bash: use the exact angle set by CombatThink (aimed directly at target).
        -- Applying the angle here (in StartCommand) is atomic with the button press,
        -- preventing the "bash into ground" bug where the lerp in TDMBot_Think
        -- overrides the snap before StartCommand fires.
        if bd.bashTarget then
            cmd:SetViewAngles(bd.bashTarget)
        end
        buttons = bit.bor(buttons, IN_ATTACK)
        buttons = bit.bor(buttons, IN_USE)
    end

    if bd.wantReload then
        buttons       = bit.bor(buttons, IN_RELOAD)
        bd.wantReload = false
    end

    if bd.wantInspect then
        buttons        = bit.bor(buttons, IN_USE)
        buttons        = bit.bor(buttons, IN_RELOAD)
        bd.wantInspect = false
    end

    local vaulting   = now < (bd.vaultUntil or 0)
    local crouchJumping = now < (bd.crouchJumpUntil or 0)
    local goalDistSqr = 0
    if goal then
        local toGoal = goal - ply:GetPos()
        toGoal.z = 0
        goalDistSqr = toGoal:LengthSqr()
    end

    local attackingNow = bd.wantAttack
        or (bd.tapUntil and now < bd.tapUntil)
        or now < (bd.bashUntil or 0)

    -- ── Sprint: allowed in hunt/retreat even when target is visible ──
    -- Bots sprint when moving toward a distant goal in hunt/retreat states.
    -- Also sprint when rushing a visible close-range target.
    local canSprint = goal
        and goalDistSqr > 180 * 180
        and not bd.wantADS
        and not bd.grenPhase
        and not bd.ubglPhase
        and not bd.isReloading
        and not vaulting
        and not attackingNow
        and bd.state ~= "cover"
        and now >= (bd.coverHoldUntil or 0)
        and not bd.isProne
        and not bd.bipodDeployed
        and (bd.state == "hunt" or bd.state == "retreat"
             or (bd.state == "combat" and goal and goalDistSqr > 350*350))

    -- ── Slide: randomly crouch-while-sprinting for ARC9 slide mechanic ──
    local slideActive = now < (bd.slideUntil or 0)
    if canSprint and not slideActive and not bd.wantSlide then
        -- Track how long we've been sprinting continuously
        if not bd.sprintStartAt then bd.sprintStartAt = now end
        local sprintDur = now - bd.sprintStartAt
        -- After 0.4-1.0s of sprinting, random chance to slide
        if sprintDur > 0.4 and now >= (bd.nextSlideRoll or 0) then
            bd.nextSlideRoll = now + math.Rand(2.0, 5.0)
            if math.random() < 0.22 then
                bd.wantSlide  = true
                bd.slideUntil = now + math.Rand(0.5, 0.9)
            end
        end
    elseif not canSprint then
        bd.sprintStartAt = nil
    end

    if tbagActive then
        -- Tbag crouch toggles
        local phase = math.floor((now - (bd.tbagStart or now)) / 0.40)
        if phase % 2 == 0 then
            buttons = bit.bor(buttons, IN_DUCK)
        end
    elseif slideActive and canSprint then
        -- Slide: duck while holding sprint
        buttons = bit.bor(buttons, IN_DUCK)
        buttons = bit.bor(buttons, IN_SPEED)
        bd.wantSlide = false
    elseif bd.wantCrouch and not canSprint and bd.state ~= "combat" then
        buttons = bit.bor(buttons, IN_DUCK)
    elseif vaulting then
        buttons = bit.bor(buttons, IN_DUCK)
    end

    if crouchJumping then
        buttons = bit.bor(buttons, IN_DUCK)
    end

    -- ── Prone double-tap duck sequence ───────────────────────
    -- Simulates two quick presses of IN_DUCK to trigger prone in supported mods.
    if bd.wantProne and not bd.isProne then
        bd.pronePhase   = 1
        bd.pronePhaseAt = now
        bd.wantProne    = false
    elseif bd.wantGetUp and bd.isProne then
        bd.pronePhase   = 1
        bd.pronePhaseAt = now
        bd.wantGetUp    = false
    end

    if bd.pronePhase then
        if bd.pronePhase == 1 then
            buttons = bit.bor(buttons, IN_DUCK)
            if now >= bd.pronePhaseAt + 0.06 then
                bd.pronePhase   = 2
                bd.pronePhaseAt = now
            end
        elseif bd.pronePhase == 2 then
            -- Release duck for a brief gap
            if now >= bd.pronePhaseAt + 0.07 then
                bd.pronePhase   = 3
                bd.pronePhaseAt = now
            end
        elseif bd.pronePhase == 3 then
            buttons = bit.bor(buttons, IN_DUCK)
            if now >= bd.pronePhaseAt + 0.12 then
                bd.pronePhase = nil
                bd.isProne    = not bd.isProne
                if bd.isProne then
                    -- Slow movement to reflect prone state
                    ply:SetWalkSpeed(60)
                else
                    local walkCV   = GetConVar("tdm_player_speed")
                    local sprintCV = GetConVar("tdm_sprint_speed")
                    local baseWalk   = walkCV   and walkCV:GetInt()   or 180
                    local baseSprint = sprintCV and sprintCV:GetInt() or 240
                    local spdMult = (bd.personality and bd.personality.roamSpeedMult) or 1.0
                    ply:SetWalkSpeed(math.floor(baseWalk   * spdMult))
                    ply:SetRunSpeed (math.floor(baseSprint * spdMult))
                end
            end
        end
    end

    if bd.wantJump and ply:IsOnGround() and not bd.isProne then
        buttons     = bit.bor(buttons, IN_JUMP)
        bd.wantJump = false
    end

    if canSprint and not tbagActive and not slideActive then
        buttons = bit.bor(buttons, IN_SPEED)
    end

    -- UBGL toggle
    if bd.wantUBGLToggle then
        buttons           = bit.bor(buttons, IN_ATTACK2)
        buttons           = bit.bor(buttons, IN_USE)
        bd.wantUBGLToggle = false
    elseif bd.wantADS and not bd.ubglPhase then
        buttons = bit.bor(buttons, IN_ATTACK2)
    end

    -- ── ARC9 peek: hold IN_WALK while ADS for tactical lean ──
    -- The exact key depends on the server's ARC9 peek binding.
    -- IN_WALK is the most common candidate for a C-bind lean.
    if bd.wantPeek and bd.wantADS and not bd.ubglPhase then
        buttons = bit.bor(buttons, IN_WALK)
    end

    if bd.wantUseDoor then
        buttons         = bit.bor(buttons, IN_USE)
        bd.wantUseDoor  = false
    end

    if bd.wantUse then
        buttons    = bit.bor(buttons, IN_USE)
        bd.wantUse = false
    end

    cmd:SetButtons(buttons)
end)

-- ── Per-bot AI tick ──────────────────────────────────────────
function TDMBot_Think(bot, bd)
    if not IsValid(bot) then return end

    local now = CurTime()
    if now < (bd._nextThink or 0) then return end
    bd._nextThink = now + THINK_INTERVAL

    if not RoundIsPlayable() then
        bd.wantAttack = false
        bd.wantADS    = false

        -- Pre-round fidget look-around
        if now >= (bd.nextIntroLook or 0) then
            bd.nextIntroLook = now + math.Rand(0.9, 2.0)
            local baseYaw = (bd.aimAngles and bd.aimAngles.y) or bot:EyeAngles().y
            bd.introLookTarget = Angle(
                math.Rand(-15, 2),  -- negative=up; keep near eye-level, never down
                baseYaw + math.Rand(-40, 40),
                0
            )
        end
        if bd.introLookTarget then
            if bd.aimAngles then
                bd.aimAngles = LerpAngle(0.18, bd.aimAngles, bd.introLookTarget)
            else
                bd.aimAngles = bd.introLookTarget
            end
            bot:SetEyeAngles(bd.aimAngles)
        end

        local now2 = CurTime()
        if now2 >= (bd.nextFidget or 0) then
            bd.nextFidget = now2 + math.Rand(2.5, 7.0)
            local roll = math.random()
            if roll < 0.32 then
                bd.wantReload = true
            elseif roll < 0.55 then
                bd.wantUse = true
            elseif roll < 0.61 then
                bd.wantInspect = true
            end
        end
        return
    end

    -- Kill taunt (t-bag)
    if now < (bd.tbagUntil or 0) then
        bd.wantAttack = false
        bd.tapUntil   = nil
        bd.wantADS    = false
        bd.goal       = nil

        if bd.tbagPos then
            -- Look toward victim but keep pitch near horizontal — not at the ground.
            local toVictim = (bd.tbagPos - bot:GetPos())
            local yaw = toVictim:Angle().y
            local look = Angle(-5, yaw, 0)   -- slight upward tilt, never at floor
            if bd.aimAngles then
                bd.aimAngles = LerpAngle(0.35, bd.aimAngles, look)
            else
                bd.aimAngles = look
            end
            bot:SetEyeAngles(bd.aimAngles)
        end
        return
    end

    EnsureActiveWeapon(bot, bd)
    UpdateStrafe(bd)
    TDMBot_CombatThink(bot, bd)
    -- While climbing a ladder, pin bd.goal to the ladder exit so the bot
    -- faces up and forward rather than getting stuck against the wall below.
    if bd.onLadder and bd.ladderGoal then
        bd.goal = bd.ladderGoal
    end
    -- Guard against missing nav function (prevents runtime error if file
    -- wasn't loaded for some reason). Try to include the nav module once,
    -- then fall back to a lightweight roam goal so bots keep moving.
    if not TDMBot_NavThink then
        pcall(function() include("aislopmatch_bots/bot_nav.lua") end)
    end
    if TDMBot_NavThink then
        TDMBot_NavThink(bot, bd)
    else
        -- Lightweight fallback: pick or refresh a roam destination
        local now = CurTime()
        local botPos = bot:GetPos()
        if not bd.roamDest or botPos:DistToSqr(bd.roamDest) < 150*150 or now >= (bd.nextRoamRefresh or 0) then
            bd.nextRoamRefresh = now + math.Rand(6, 10)
            if navmesh and navmesh.GetNavAreaCount and navmesh.GetNavAreaCount() > 0 then
                local ra = navmesh.GetRandomNavArea and navmesh.GetRandomNavArea() or nil
                bd.roamDest = (ra and ra:GetCenter()) or TDMBot_RandomMapPos()
            else
                bd.roamDest = TDMBot_RandomMapPos()
            end
        end
        bd.goal = bd.roamDest
    end

    -- Bipod: freeze movement when deployed
    if bd.bipodDeployed then
        bd.goal = nil
    end

    -- Tactical reload between engagements
    if bd.state ~= "combat" and not bd.isReloading and not bd.grenPhase then
        local wep = bot:GetActiveWeapon()
        if IsValid(wep) and now >= (bd.nextTactReload or 0) then
            local clip    = wep:Clip1() or 0
            local maxClip = wep.Primary and wep.Primary.ClipSize or 30
            if maxClip > 0 and clip > 0 and clip < (maxClip * 0.45) then
                if math.random() < 0.5 then
                    if now >= (bd.nextReloadAllowed or 0) and not bd.isReloading then
                        bd.wantAttack  = false
                        bd.tapUntil    = nil
                        bd.wantReload  = true
                        bd.isReloading = true
                        bd.reloadStartAt = now
                        bd.reloadDoneAt  = now + math.max(1.0, ((IsValid(wep) and wep.ReloadTime) or 2.5) + 0.2)
                        bd.nextReloadAllowed = now + 0.9
                    end
                end
            end
            bd.nextTactReload = now + math.Rand(3.0, 7.0)
        end
    end

    -- Passive crouch outside combat. crouchFreq is a per-personality 0..1 knob,
    -- scaled by 0.06 so a Camper (0.85) crouches at ~5% per roll while a Rusher
    -- (0.05) is essentially never crouching. Combined with the slower roll rate
    -- below this gives campers a clearly recognisable hunched silhouette.
    if bd.state ~= "combat" then
        local p = bd.personality
        if p and now >= (bd.nextCrouchFlip or 0)
           and now >= (bd.coverHoldUntil or 0) then
            bd.nextCrouchFlip = now + math.Rand(8.0, 14.0)
            bd.wantCrouch = math.random() < (p.crouchFreq * 0.06)
        end
    end


    -- During any grenade OR gadget phase: freeze movement (overrides NavThink goal).
    -- Aim for combat lobs is handled here via lerp; spawn lob aim was set in CombatThink phase 2.
    if bd.gadgetPhase then bd.goal = nil end
    if bd.grenPhase then
        bd.goal = nil
        if bd.grenIsLob and bd.grenTargetPos and not bd.grenIsSpawnLob then
            local from = bot:EyePos()
            local flat = Vector(bd.grenTargetPos.x-from.x, bd.grenTargetPos.y-from.y, 0)
            if flat:LengthSqr() > 1 then
                local dist    = flat:Length()
                local pitchUp = math.Clamp(24 + (dist/1450)*20, 24, 46)
                local lobAim  = Angle(-pitchUp, flat:Angle().y, 0)
                bd.aimAngles  = bd.aimAngles and LerpAngle(0.40, bd.aimAngles, lobAim) or lobAim
                bot:SetEyeAngles(bd.aimAngles)
                return
            end
        end
    end

    -- ── Aim toward glass target when breaking through ────────
    -- ── Aim toward glass target when breaking through ────────
    if bd.breakingGlass and bd.aimGlassTarget then
        local ang = (bd.aimGlassTarget - bot:EyePos()):Angle()
        if bd.aimAngles then
            bd.aimAngles = LerpAngle(0.4, bd.aimAngles, ang)
        else
            bd.aimAngles = ang
        end
        bot:SetEyeAngles(bd.aimAngles)
        return
    end

    -- ── Aim: smooth lerp toward target ───────────────────────
    -- At close range, snap aim faster so the bot can track a rapidly strafing
    -- enemy. Normal lerp speed already handles longer range engagement.
    local lerpSpeed = AIM_LERP[bd.skill or 2] or 0.25
    local combatDist2 = bd.targetDist or math.huge
    if combatDist2 < 200 then
        lerpSpeed = math.min(lerpSpeed * 2.2, 0.85)  -- much snappier inside brawl range
    end
    -- Standing enemies should be tracked almost instantly at close range.
    local tgtSpd = bd.targetSpeed or math.huge
    if tgtSpd < 25 then
        if combatDist2 < 350 then lerpSpeed = math.max(lerpSpeed, 0.72) end
        if combatDist2 < 180 then lerpSpeed = math.max(lerpSpeed, 0.90) end
    end
    local liveAim = TDMBot_ComputeLiveAim(bot, bd)

    -- 360/720 no-scope spin override
    if bd.noscopeActive then
        local elapsed  = now - (bd.noscopeStartTime or now)
        local duration = bd.noscopeDuration or 0.5
        local frac     = math.Clamp(elapsed / duration, 0, 1)
        local spunDeg  = bd.noscopeTargetDeg * bd.noscopeDir * frac
        local spinYaw  = (bd.noscopeStartYaw or 0) + spunDeg
        local spinPitch = 0
        if liveAim then spinPitch = liveAim.p end
        local spinAng = Angle(spinPitch, spinYaw, 0)
        bd.aimAngles  = spinAng
        bot:SetEyeAngles(spinAng)

        if frac >= 1 then
            if bd.noscopeLucky and liveAim then
                bd.aimAngles = liveAim
                bot:SetEyeAngles(liveAim)
            end
            bd.tapUntil         = now + 0.15
            bd.wantAttack       = false
            bd.wantADS          = false
            bd.noscopeActive    = false
            bd.noscopeCooldown  = now + math.Rand(30, 80)
        end
        return
    end

    if liveAim then
        if bd.aimAngles then
            bd.aimAngles = LerpAngle(lerpSpeed, bd.aimAngles, liveAim)
        else
            bd.aimAngles = liveAim
        end
        bot:SetEyeAngles(bd.aimAngles)
    elseif bd.goal or bd.lastKnownTargetPos then
        local anchorPos = bd.goal or bd.lastKnownTargetPos
        local toAnchor  = anchorPos - bot:GetPos()
        toAnchor.z = 0

        -- During damage flinch / cover: don't apply random yaw scan.
        -- Previously the random yaw fired every 0.2-0.6s regardless of state,
        -- making bots spin away from whoever just shot them.
        local suppressScan = (now < (bd.damageFlinchUntil or 0))
                          or (now < (bd.coverHoldUntil    or 0))

        if toAnchor:LengthSqr() < 90*90 then
            if bd.aimAngles then
                local levelAng = Angle(0, bd.aimAngles.y, 0)
                bd.aimAngles = LerpAngle(0.55, bd.aimAngles, levelAng)
                bot:SetEyeAngles(bd.aimAngles)
            end
        elseif toAnchor:LengthSqr() > 1 and not suppressScan then
            local travelAng = toAnchor:Angle()
            if now >= (bd.nextScanUpdate or 0) then
                local sharpCheck = math.random() < 0.20
                local yawOff   = sharpCheck and math.Rand(55, 80) * (math.random(0,1)==0 and 1 or -1)
                                            or  math.Rand(-40, 40)
                -- Pitch: negative=up, positive=down (Source Engine convention).
                -- Hard-limit to max 2° below horizontal.
                local pitchOff = math.Rand(-18, 2)
                bd.scanYawOffset   = yawOff
                bd.scanPitchOffset = pitchOff
                bd.nextScanUpdate  = now + (sharpCheck and math.Rand(0.20, 0.45)
                                                        or  math.Rand(0.25, 0.55))
            end
            local targetAng = Angle(
                math.Clamp((bd.scanPitchOffset or 0), -20, 2),
                travelAng.y + (bd.scanYawOffset or 0),
                0
            )
            local sharpSnap = math.abs(bd.scanYawOffset or 0) > 50
            local scanLerp  = sharpSnap and 0.45 or 0.40
            if bd.aimAngles then
                bd.aimAngles = LerpAngle(scanLerp, bd.aimAngles, targetAng)
            else
                bd.aimAngles = targetAng
            end
            bot:SetEyeAngles(bd.aimAngles)
        elseif toAnchor:LengthSqr() > 1 then
            -- Flinching: face anchor direction at eye-level, no random yaw.
            local holdAng = Angle(0, toAnchor:Angle().y, 0)
            if bd.aimAngles then
                bd.aimAngles = LerpAngle(0.30, bd.aimAngles, holdAng)
            else
                bd.aimAngles = holdAng
            end
            bot:SetEyeAngles(bd.aimAngles)
        end
    else
        -- No target, no goal: snap to eye-level.
        if bd.aimAngles then
            local levelAng = Angle(0, bd.aimAngles.y, 0)
            bd.aimAngles = LerpAngle(0.55, bd.aimAngles, levelAng)
            bot:SetEyeAngles(bd.aimAngles)
        end
    end

    -- ── Hard pitch clamp (catch-all) ─────────────────────────────────────
    -- Instantly corrects any lingering downward angle when there is no live
    -- aim target.  p * 0.25 = 75% removed per tick ≈ gone in 2 ticks.
    if bd.aimAngles and not liveAim then
        local p = bd.aimAngles.p
        if p > 3 then
            bd.aimAngles = Angle(p * 0.25, bd.aimAngles.y, 0)
            bot:SetEyeAngles(bd.aimAngles)
        end
    end
end
