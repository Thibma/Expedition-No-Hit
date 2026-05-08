-- =============================================================================
-- ExpeditionNoHit v1.0.3 - Clair Obscur: Expedition 33
-- =============================================================================
-- Triggers game over when any hero takes a hit from an enemy.
-- Rules: https://www.teamhitless.com/clair-obscur/
-- =============================================================================

local MOD_NAME    = "ExpeditionNoHit"
local MOD_VERSION = "1.0.3"

-- =============================================================================
-- CONFIGURATION
-- =============================================================================

local CONFIG = {
    DEBUG         = true,
    QUICK_GAME_OVER = false,
}

-- Load user config (config.lua next to this file) and merge into CONFIG.
-- Any key present in config.lua overrides the defaults above.
do
    local ok, userCfg = pcall(require, "config")
    if ok and type(userCfg) == "table" then
        if type(userCfg.debug)         == "boolean" then CONFIG.DEBUG          = userCfg.debug         end
        if type(userCfg.quickGameOver) == "boolean" then CONFIG.QUICK_GAME_OVER = userCfg.quickGameOver end
        print(string.format("[ExpeditionNoHit] config.lua loaded (quickGameOver=%s, debug=%s)\n",
            tostring(CONFIG.QUICK_GAME_OVER), tostring(CONFIG.DEBUG)))
    else
        print(string.format("[ExpeditionNoHit] config.lua not found or invalid — using defaults.\n"))
    end
end

-- =============================================================================
-- PATHS
-- =============================================================================

-- BattleManager: battle lifecycle events
local P_BATTLE     = "/Game/jRPGTemplate/Blueprints/Components/AC_jRPG_BattleManager.AC_jRPG_BattleManager_C"
-- PlayerController: fires on game start and every level reload
local P_CTRL       = "/Script/Engine.PlayerController:ClientRestart"
-- WorldController: fires ResumeExplorationOnBattleEnd on all battle end types (safe for teardown)
local P_CTRL_WORLD = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World.BP_jRPG_Controller_World_C"
-- Character base class: catches all characters that don't override OnDamageReceived
local P_CHAR_BASE  = "/Game/jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_Battle_Base.BP_jRPG_Character_Battle_Base_C"

-- =============================================================================
-- HOOK REGISTRIES
-- =============================================================================
-- Two-tier system to prevent crashes during BattleManager teardown:
--   hookRegistry      — lifecycle hooks, registered once, never removed
--   combatHookRegistry — combat hooks, registered on battle start, removed on battle end / game over

local hookRegistry = {}
local combatHookRegistry = {}

local function trackHook(path, callback)
    local ok, pre, post = pcall(function() return RegisterHook(path, callback) end)
    if ok and type(pre) == "number" then
        table.insert(hookRegistry, { path = path, pre = pre, post = post })
        return true
    end
    return false
end

local function trackCombatHook(path, callback)
    local ok, pre, post = pcall(function() return RegisterHook(path, callback) end)
    if ok and type(pre) == "number" then
        table.insert(combatHookRegistry, { path = path, pre = pre, post = post })
        return true
    end
    return false
end

-- =============================================================================
-- STATE
-- =============================================================================

local state = {
    inBattle             = false,
    gameOverTriggered    = false,
    monitoringActive     = false,  -- gated by 1s guard delay at battle start
    battleCount          = 0,
    hooksRegistered      = false,
    combatHooksRegistered = false,
}

-- =============================================================================
-- LOGGING
-- =============================================================================

local function log(msg)  print(string.format("[%s] %s\n", MOD_NAME, msg)) end
local function dbg(msg)  if CONFIG.DEBUG then print(string.format("[%s][D] %s\n", MOD_NAME, msg)) end end
local function warn(msg) print(string.format("[%s][!] %s\n", MOD_NAME, msg)) end

-- =============================================================================
-- OBJECT ACCESS
-- =============================================================================

local function safeIsValid(o)
    if not o then return false end
    local ok, valid = pcall(function() return o:IsValid() end)
    return ok and valid
end

local function getBattleManager()
    local ok, o = pcall(function() return FindFirstOf("AC_jRPG_BattleManager_C") end)
    if not ok or not o then return nil end
    return safeIsValid(o) and o or nil
end

-- Returns the class name string of a UObject, or "" on failure.
-- In the object dump, enemy classes all contain "Enemy" (e.g. BP_EnemyBattle_Lancelier_C).
-- Hero classes do not (e.g. BP_jRPG_Character_Battle_Base_C).
--
-- UE4SS Blueprint hook parameters (including self) are wrapped objects.
-- We try :get() first to unwrap, then fall back to the object directly.
local function getClassName(obj)
    if not obj then return "" end
    -- Unwrap if needed (UE4SS wraps Blueprint hook params, including self)
    local actual = obj
    pcall(function() actual = obj:get() end)
    if not safeIsValid(actual) then return "" end
    local ok, name = pcall(function()
        return actual:GetClass():GetFName():ToString()
    end)
    return (ok and name) or ""
end

local function isEnemy(className)
    return className ~= "" and className:find("Enemy") ~= nil
end

-- =============================================================================
-- HOOK UNREGISTRATION
-- =============================================================================

local unregisterCombatHooks
unregisterCombatHooks = function()
    for _, h in ipairs(combatHookRegistry) do
        pcall(function() UnregisterHook(h.path, h.pre, h.post) end)
    end
    local count = #combatHookRegistry
    combatHookRegistry = {}
    state.combatHooksRegistered = false
    log(string.format("Combat hooks unregistered (%d hooks).", count))
end

-- =============================================================================
-- GAME OVER
-- =============================================================================

-- Tries to call a no-arg method on a UObject by name.
-- "Tried calling a member function but the UObject instance is nullptr" means
-- the method name does NOT exist on that object — not a null object error.
local function tryMethod(obj, method, label)
    local ok, err = pcall(function() obj[method](obj) end)
    if ok then
        log(string.format("Quick game over: %s.%s() succeeded — retry popup should appear.", label, method))
        return true
    end
    -- Only log at debug level: the "nullptr" error just means "method not found".
    dbg(string.format("Quick game over: %s.%s() — not found.", label, method))
    return false
end

-- Tries every known method on BattleManager and WorldController to surface
-- the retry/defeat popup without playing the full game over animation.
-- Returns true if any call succeeded.
--
-- To find the real function name: run the UE4SS object dump (Numpad 7 by
-- default), open ObjectDump.txt, and search for
--   "AC_jRPG_BattleManager_C" or "BP_jRPG_Controller_World_C"
-- Look for UFunctions whose names suggest defeat/retry/game-over.
-- Add the correct name to the first candidates list below.
local function tryQuickGameOver(bm)
    -- BattleManager candidates — extend once you identify the real name in the dump.
    local bmCandidates = {
        "ShowDefeatMenu",      "ShowRetryMenu",       "ShowGameOverScreen",
        "OnDefeat",            "OpenDefeatWidget",    "TriggerDefeat",
        "BP_OnDefeat",         "ShowBattleResult",    "DisplayDefeatUI",
        "ShowBattleOverScreen","OpenGameOverPopup",   "ShowRetryPopup",
        "BP_ShowDefeatMenu",   "ShowDefeatScreen",    "OnBattleDefeat",
    }
    for _, method in ipairs(bmCandidates) do
        if tryMethod(bm, method, "BattleManager") then return true end
    end

    -- WorldController candidates — the retry popup is often owned by the
    -- world/game controller rather than the BattleManager.
    local wc = nil
    pcall(function() wc = FindFirstOf("BP_jRPG_Controller_World_C") end)
    if safeIsValid(wc) then
        local wcCandidates = {
            "ShowDefeatMenu",       "ShowRetryMenu",        "OnBattleDefeat",
            "ShowBattleDefeatWidget","OpenRetryPopup",      "ShowGameOverUI",
            "DisplayDefeatMenu",    "BP_ShowDefeatMenu",    "ShowDefeatScreen",
            "ShowRetryScreen",      "OpenDefeatMenu",       "TriggerGameOver",
        }
        for _, method in ipairs(wcCandidates) do
            if tryMethod(wc, method, "WorldController") then return true end
        end
    else
        dbg("Quick game over: WorldController not found, skipping.")
    end

    return false
end

local function triggerGameOver(reason)
    if state.gameOverTriggered then return end
    state.gameOverTriggered = true
    state.inBattle = false

    log("========================================")
    log(string.format("  NO-HIT FAILED: %s", reason))
    log("========================================")

    local bm = getBattleManager()
    if not bm then
        warn("BattleManager not found — cannot show game over screen. Reset manually.")
        return
    end

    -- Unregister combat hooks BEFORE ending the battle to prevent callbacks
    -- firing on a partially-destroyed BattleManager during teardown.
    unregisterCombatHooks()

    if CONFIG.QUICK_GAME_OVER then
        log("Quick game over enabled — attempting to skip animation.")
        if not tryQuickGameOver(bm) then
            -- No direct popup method found; fall back to the standard sequence.
            warn("Quick game over: no direct method worked — falling back to ForceBattleEnd(2).")
            local ok, err = pcall(function() bm:ForceBattleEnd(2) end)
            if ok then
                log("ForceBattleEnd(2) called (fallback). Game over screen should appear.")
            else
                warn(string.format("ForceBattleEnd(2) failed: %s", tostring(err)))
            end
        end
    else
        local ok, err = pcall(function() bm:ForceBattleEnd(2) end)
        if ok then
            log("ForceBattleEnd(2) called. Game over screen should appear.")
        else
            warn(string.format("ForceBattleEnd(2) failed: %s", tostring(err)))
        end
    end
end

-- =============================================================================
-- COMBAT HOOKS (registered on battle start, unregistered on battle end / game over)
-- =============================================================================

local registerCombatHooks
registerCombatHooks = function()
    if state.combatHooksRegistered then return end
    state.combatHooksRegistered = true

    -- OnDamageReceived: primary hit detection
    --
    -- Confirmed signature (object dump):
    --   Damage (DoubleProperty), Critical? (Bool), Weakness? (Bool), Resistant? (Bool),
    --   Element (Byte), Reason (Byte), DamageCharacterSource (ObjectProperty → BP_jRPG_Character_Battle_Base_C)
    --
    -- UE4SS Blueprint hook parameters (including self) are wrapped — use :get() to unwrap.
    -- Identity is read from the UObject class name: enemy classes contain "Enemy".

    local function handleOnDamageReceived(self, Damage, Reason, DamageCharacterSource)
        if not state.inBattle or state.gameOverTriggered or not state.monitoringActive then return end

        -- Read wrapped parameter values (UE4SS Blueprint hook params need :get())
        local dmgAmt = 0
        pcall(function() dmgAmt = Damage:get() end)

        -- Get source UObject from wrapped parameter
        local source = nil
        pcall(function() source = DamageCharacterSource:get() end)

        local targetClass = getClassName(self)
        local sourceClass = getClassName(source)

        dbg(string.format("OnDamageReceived: target=%s source=%s dmg=%.0f",
            targetClass, sourceClass, dmgAmt))

        -- Target must be identified and must NOT be an enemy (i.e. it is a hero)
        if targetClass == "" then return end
        if isEnemy(targetClass) then return end

        -- Source must be identified and must be an enemy
        if sourceClass == "" then
            dbg("Source unknown — skipped.")
            return
        end
        if not isEnemy(sourceClass) then
            dbg(string.format("Source '%s' is not an enemy — ignored (friendly/self damage).", sourceClass))
            return
        end

        -- Ignore intentional touch-mechanic hits from Troubadour quest enemy (dmg is expected to be 0)
        if sourceClass == "BP_EnemyBattle_Troubadour_Quest_C" and dmgAmt == 0 then
            dbg(string.format("Source '%s' ignored (Troubadour quest touch mechanic, dmg=%.0f).", sourceClass, dmgAmt))
            return
        end

        -- Enemy hit a hero → game over
        triggerGameOver(string.format("%s hit by %s (dmg=%.0f)", targetClass, sourceClass, dmgAmt))
    end

    local ok_base = trackCombatHook(P_CHAR_BASE .. ":OnDamageReceived",
        function(self, Damage, Critical, Weakness, Resistant, Element, Reason, DamageCharacterSource)
            handleOnDamageReceived(self, Damage, Reason, DamageCharacterSource)
        end)

    if ok_base then
        log("Combat: OnDamageReceived hook connected. Hit detection ACTIVE.")
    else
        warn("Combat: OnDamageReceived hook failed — hits will NOT be detected!")
    end
end

-- =============================================================================
-- BATTLE LIFECYCLE
-- =============================================================================

local function onBattleStart()
    state.battleCount       = state.battleCount + 1
    state.inBattle          = true
    state.gameOverTriggered = false
    state.monitoringActive  = false

    log(string.format("=== Battle #%d STARTED — No-hit monitoring ACTIVE ===", state.battleCount))
    registerCombatHooks()

    -- 1s guard delay: suppress damage events from battle initialization
    ExecuteWithDelay(1000, function()
        if state.inBattle and not state.gameOverTriggered then
            state.monitoringActive = true
            log("Monitoring ACTIVE.")
        end
    end)
end

-- =============================================================================
-- LIFECYCLE HOOKS (registered once, never unregistered)
-- =============================================================================

local function registerLifecycleHooks()
    if state.hooksRegistered then return end
    state.hooksRegistered = true

    -- Battle start: hook both entry points so the mod fires regardless of asset cache state.
    -- OnBattleDependenciesFullyLoaded only fires when assets must be streamed from disk;
    -- if they are already cached the game skips it and calls StartBattle/StartBattleNEW directly.
    local function onBattleStartGuarded()
        if not state.inBattle then onBattleStart() end
    end
    trackHook(P_BATTLE .. ":StartBattleNEW", onBattleStartGuarded)
    trackHook(P_BATTLE .. ":StartBattle",    onBattleStartGuarded)
    log("Lifecycle: battle-start hooks registered (StartBattleNEW + StartBattle).")

    -- Battle end: fires on victory, defeat, and retreat
    local ok_end = trackHook(P_CTRL_WORLD .. ":ResumeExplorationOnBattleEnd", function()
        if state.inBattle or state.combatHooksRegistered then
            dbg("ResumeExplorationOnBattleEnd: battle ended — clearing state.")
            state.inBattle        = false
            state.monitoringActive = false
            unregisterCombatHooks()
        end
    end)
    if ok_end then
        log("Lifecycle: battle-end hook registered (ResumeExplorationOnBattleEnd).")
    else
        warn("Lifecycle: ResumeExplorationOnBattleEnd failed. Combat hooks may outlive battle.")
    end
end

-- =============================================================================
-- ENTRY POINT
-- =============================================================================

log(string.format("%s v%s loading...", MOD_NAME, MOD_VERSION))

RegisterHook(P_CTRL, function()
    log("ClientRestart fired.")
    if state.inBattle then
        -- ClientRestart can fire mid-battle (e.g. free-aim camera transition).
        -- Do NOT reset combat state — monitoring must stay active.
        dbg("ClientRestart mid-battle — combat state preserved.")
    else
        state.monitoringActive  = false
        state.gameOverTriggered = false
    end
    registerLifecycleHooks()
    log(string.format("%s ready.", MOD_NAME))
end)

log(string.format("%s v%s loaded. Waiting for game start.", MOD_NAME, MOD_VERSION))
