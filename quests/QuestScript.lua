--- @module "QuestScript"
--- Step-based quest automation framework for RuneScape 3.
--- The main loop monitors quest progress and executes the matching step function.
--- Steps switch automatically when quest progress changes.
---
--- BASIC USAGE:
---
---   local QS = require("quests.QuestScript")
---
---   local qs = QS.new({
---       name  = "The Restless Ghost",   -- exact in-game quest name (required)
---       debug = false,                  -- print debug logs per step (optional)
---   })
---
---   qs:step(0, "Start quest", function()
---       Interact:NPC("Father Aereck", "Talk-to")
---       qs:waitDialog()
---       qs:optionSelector({"I need a quest"})
---       qs:waitDialogClose()
---       qs:acceptQuest()
---   end)
---
---   qs:step(1, "Talk to Father Urhney", function()
---       qs:moveTo(3240, 3209, 0)
---       Interact:NPC("Father Urhney", "Talk-to")
---       qs:waitDialog()
---   end)
---
---   qs:onComplete(function()
---       API.logInfo("Quest complete!")
---   end)
---
---   qs:run()  -- starts the main loop
---
-------------------------------------------------------------------

local API = require("quests.api")

local QuestScript = {}
QuestScript.__index = QuestScript

-------------------------------------------------------------------
-- COMMON INTERFACES
-------------------------------------------------------------------

local DIALOG_INTERFACES = {
    playerDialog  = { { 1191, 0, -1, -1, 0 } },
    npcDialog     = { { 1184, 2, -1, -1, 0 } },
    serverDialog  = { { 1186, 2, -1, -1, 0 } },
    serverCont    = { { 1189, 2, -1, -1, 0 } },
    chatOptions   = { { 1188, 5, -1, -1 }, { 1188, 3, -1, 5 }, { 1188, 3, 14, 3 } },
    questAccept   = { { 1500, 0, -1, -1, 0 }, { 1500, 409, -1, 0, 0 } },
}

-------------------------------------------------------------------
-- CONSTRUCTOR
-------------------------------------------------------------------

--- Creates a new QuestScript instance.
--- @param config table { name: string, debug?: boolean }
function QuestScript.new(config)
    assert(config and config.name, "[QS] 'name' is required")

    local self = setmetatable({}, QuestScript)
    self.name          = config.name
    self.debug         = config.debug or false
    self._steps        = {}   -- { progress -> { label, fn } }
    self._onComplete   = nil
    self._lastProgress = nil
    return self
end

-------------------------------------------------------------------
-- STEP DEFINITION
-------------------------------------------------------------------

--- Registers a handler for a quest progress value.
--- @param progress number  Quest progress value for this step
--- @param label    string  Step description (shown in logs)
--- @param fn       function Function to execute at this step
function QuestScript:step(progress, label, fn)
    self._steps[progress] = { label = label, fn = fn }
    return self  -- chainable
end

--- Registers a handler called when the quest is marked complete.
--- @param fn function
function QuestScript:onComplete(fn)
    self._onComplete = fn
    return self
end

-------------------------------------------------------------------
-- MAIN LOOP
-------------------------------------------------------------------

--- Starts the main loop. Blocks until the quest completes or the loop stops.
function QuestScript:run()
    API.logInfo(string.format("[QS] Starting quest: %s", self.name))

    local qd = Quest:Get(self.name)
    if not qd then
        API.logWarn(string.format("[QS] Quest '%s' not found in API", self.name))
        return false
    end
    if qd:isComplete() then
        API.logInfo("[QS] Quest already complete — running onComplete and exiting")
        if self._onComplete then self._onComplete() end
        return true
    end

    while API.Read_LoopyLoop() do
        qd = Quest:Get(self.name)
        if not qd then
            API.RandomSleep2(1000, 200, 200)
            goto continue
        end

        if qd:isComplete() then
            API.logInfo("[QS] Quest completed!")
            if self._onComplete then self._onComplete() end
            return true
        end

        local progress = qd:getProgress()

        if progress ~= self._lastProgress then
            self._lastProgress = progress
            local stepInfo = self._steps[progress]
            local label = stepInfo and stepInfo.label or "unknown step"
            API.logInfo(string.format("[QS] Progress: %d | %s", progress, label))
        end

        local stepInfo = self._steps[progress]
        if stepInfo and stepInfo.fn then
            if self.debug then
                API.logInfo(string.format("[QS-DBG] Running step %d: %s", progress, stepInfo.label))
            end
            local ok, err = pcall(stepInfo.fn)
            if not ok then
                API.logWarn(string.format("[QS] Error in step %d: %s", progress, tostring(err)))
            end
        else
            if self.debug then
                API.logInfo(string.format("[QS-DBG] No handler for progress %d — waiting...", progress))
            end
            API.RandomSleep2(1000, 200, 200)
        end

        ::continue::
    end

    return false
end

-------------------------------------------------------------------
-- MOVEMENT HELPERS
-------------------------------------------------------------------

--- Walks the player to coordinates and waits until arrived.
--- @param x number
--- @param y number
--- @param z number
--- @param tolerance? number (default 2)
function QuestScript:moveTo(x, y, z, tolerance)
    tolerance = tolerance or 2
    API.logInfo(string.format("[QS] Moving to (%d,%d,%d)", x, y, z))
    while API.Read_LoopyLoop() do
        local pos = API.PlayerCoord()
        local dist = math.sqrt((pos.x - x)^2 + (pos.y - y)^2)
        if dist <= tolerance and pos.z == z then break end
        if not API.IsPlayerMoving_(API.GetLocalPlayerName()) then
            API.DoAction_WalkerW(WPOINT.new(
                x + math.random(-tolerance, tolerance),
                y + math.random(-tolerance, tolerance),
                z
            ))
        end
        API.RandomSleep2(600, 100, 100)
    end
end

-------------------------------------------------------------------
-- DIALOG HELPERS
-------------------------------------------------------------------

--- Returns true if any dialog window is open.
function QuestScript:isDialogOpen()
    for _, iface in pairs(DIALOG_INTERFACES) do
        if iface ~= DIALOG_INTERFACES.chatOptions and iface ~= DIALOG_INTERFACES.questAccept then
            local res = API.ScanForInterfaceTest2Get(false, iface)
            if res and #res > 0 and res[1].x and res[1].x ~= 0 then
                return true
            end
        end
    end
    return false
end

--- Waits up to `timeout` seconds for a dialog window to appear.
--- @param timeout? number (default 10)
function QuestScript:waitDialog(timeout)
    timeout = timeout or 10
    local t = os.clock()
    while API.Read_LoopyLoop() and not self:isDialogOpen() do
        if os.clock() - t > timeout then
            API.logWarn("[QS] Timeout waiting for dialog")
            return false
        end
        API.RandomSleep2(400, 100, 100)
    end
    return true
end

--- Waits up to `timeout` seconds for the dialog to close.
--- @param timeout? number (default 15)
function QuestScript:waitDialogClose(timeout)
    timeout = timeout or 15
    local t = os.clock()
    while API.Read_LoopyLoop() and self:isDialogOpen() do
        if os.clock() - t > timeout then
            API.logWarn("[QS] Timeout waiting for dialog to close")
            return false
        end
        API.RandomSleep2(400, 100, 100)
    end
    return true
end

--- Presses Space to advance dialog.
function QuestScript:pressSpace()
    API.KeyboardPress2(0x20, 40, 60)
    API.RandomSleep2(400, 200, 200)
end

--- Presses Space repeatedly until all dialogs close.
--- @param timeout? number (default 30)
function QuestScript:skipDialogs(timeout)
    timeout = timeout or 30
    local t = os.clock()
    while API.Read_LoopyLoop() and self:isDialogOpen() do
        if os.clock() - t > timeout then break end
        self:pressSpace()
    end
end

--- Selects the first matching dialog option from the list.
--- @param options table  List of option strings to try
--- @return boolean
function QuestScript:optionSelector(options)
    for _, optionText in ipairs(options) do
        local n = tonumber(API.Dialog_Option(optionText))
        if n and n > 0 then
            local key = 0x30 + n
            API.KeyboardPress2(key, 60, 100)
            API.RandomSleep2(400, 200, 300)
            return true
        end
    end
    return false
end

-------------------------------------------------------------------
-- QUEST HELPERS
-------------------------------------------------------------------

--- Clicks Accept Quest if the accept interface is open.
--- @param timeout? number (default 10)
function QuestScript:acceptQuest(timeout)
    timeout = timeout or 10
    local t = os.clock()
    while API.Read_LoopyLoop() do
        if os.clock() - t > timeout then
            API.logWarn("[QS] Timeout waiting for accept quest interface")
            return false
        end
        local res = API.ScanForInterfaceTest2Get(false, DIALOG_INTERFACES.questAccept)
        if res and #res > 0 and res[1].x and res[1].x ~= 0 then
            API.logInfo("[QS] Accepting quest...")
            API.DoAction_Interface(0xffffffff, 0xffffffff, 1, 1500, 409, -1, API.OFF_ACT_GeneralInterface_route)
            API.RandomSleep2(1000, 200, 200)
            return true
        end
        API.RandomSleep2(400, 100, 100)
    end
    return false
end

--- Returns the current quest progress number.
--- @return number
function QuestScript:getProgress()
    local qd = Quest:Get(self.name)
    return qd and qd:getProgress() or 0
end

--- Waits until quest progress reaches `expectedProgress` (or any change if nil).
--- @param expectedProgress? number  Target progress value; nil = wait for any change
--- @param timeout? number (default 60)
function QuestScript:waitForProgress(expectedProgress, timeout)
    timeout = timeout or 60
    local startProg = self:getProgress()
    local t = os.clock()
    while API.Read_LoopyLoop() do
        if os.clock() - t > timeout then
            API.logWarn("[QS] Timeout waiting for progress")
            return false
        end
        local current = self:getProgress()
        if expectedProgress then
            if current == expectedProgress then return true end
        else
            if current ~= startProg then return true end
        end
        API.RandomSleep2(500, 100, 100)
    end
    return false
end

-------------------------------------------------------------------
-- INVENTORY / EQUIPMENT HELPERS
-------------------------------------------------------------------

--- Returns true if the inventory contains the given item ID.
--- @param itemId number
--- @return boolean
function QuestScript:hasItem(itemId)
    local inv = API.ReadInvArrays33()
    if inv then
        for _, item in pairs(inv) do
            if item.itemid1 == itemId then return true end
        end
    end
    return false
end

--- Equips an item from inventory by ID.
--- @param itemId number
function QuestScript:equipItem(itemId)
    if self:hasItem(itemId) then
        Inventory:Equip(itemId)
        API.RandomSleep2(800, 100, 100)
        return true
    end
    API.logWarn(string.format("[QS] Item %d not found in inventory", itemId))
    return false
end

-------------------------------------------------------------------
-- COMBAT HELPERS
-------------------------------------------------------------------

--- Attacks and kills `count` instances of `npc_name` within `dist` tiles.
--- Death is confirmed when ReadLpInteracting().Life reaches 0, or the NPC
--- disappears after having a confirmed Life > 0. Handles auto-retargeting.
--- @param npc_name string  NPC name to attack
--- @param count    number  Number to kill (default 1)
--- @param dist     number  Attack range in tiles (default 50)
--- @return number          Number actually killed
function QuestScript:killNPCs(npc_name, count, dist)
    count = count or 1
    dist  = dist  or 50
    local killed    = 0
    local hadTarget = false
    local prevLife  = -1  -- last confirmed Life > 0 reading

    API.logInfo(string.format("[QS] Killing %d x '%s'", count, npc_name or ""))

    while API.Read_LoopyLoop() and killed < count do
        local inter = API.ReadLpInteracting()
        local life  = inter and inter.Life or -1

        if hadTarget then
            if life == 0 then
                killed = killed + 1
                API.logInfo(string.format("[QS] Kill %d/%d (Life=0)", killed, count))
                hadTarget = false; prevLife = -1
                API.RandomSleep2(700, 100, 200)
            elseif life < 0 then
                if prevLife > 0 then
                    -- NPC disappeared after confirmed life: counts as dead
                    killed = killed + 1
                    API.logInfo(string.format("[QS] Kill %d/%d (vanished, prevLife=%d)", killed, count, prevLife))
                    hadTarget = false; prevLife = -1
                    API.RandomSleep2(700, 100, 200)
                else
                    -- Spurious read before life was ever confirmed — do not count
                    local tgt = API.ReadTargetInfo99(true)
                    if not (tgt and tgt.Target_Id and tgt.Target_Id > 0) then
                        hadTarget = false; prevLife = -1
                    end
                    API.RandomSleep2(200, 50, 50)
                end
            else
                prevLife = life
            end
        else
            Interact:NPC(npc_name, "Attack")
            API.RandomSleep2(800, 100, 200)
            local check = API.ReadLpInteracting()
            if check and check.Life and check.Life > 0 then
                hadTarget = true; prevLife = check.Life
            end
        end

        API.RandomSleep2(400, 50, 100)
    end

    return killed
end

-------------------------------------------------------------------
-- CUTSCENE / HEALING / PRAYER / NPC TRACKING / FLAGS
-------------------------------------------------------------------

--- Waits through a cutscene, pressing Space on dialogs until everything closes.
--- @param timeout? number (default 60)
function QuestScript:waitCutscene(timeout)
    timeout = timeout or 60
    local t = os.clock()
    API.RandomSleep2(600, 100, 100)
    local td = os.clock()
    while API.Read_LoopyLoop() and not self:isDialogOpen() do
        if os.clock() - td > 10 then break end
        API.RandomSleep2(400, 100, 100)
    end
    while API.Read_LoopyLoop() do
        if os.clock() - t > timeout then
            API.logWarn("[QS] Cutscene timeout")
            break
        end
        if self:isDialogOpen() then
            self:pressSpace()
            API.RandomSleep2(350, 50, 100)
        else
            API.RandomSleep2(700, 100, 200)
            if not self:isDialogOpen() then break end
        end
    end
end

--- Eats food from inventory if HP% is below the threshold.
--- @param threshold? number  Minimum HP percentage before eating (default 50)
--- @return boolean  true if food was eaten
function QuestScript:healIfLow(threshold)
    threshold = threshold or 50
    if API.GetHPrecent() >= threshold then return false end
    local FOODS = {385, 379, 373, 7946, 15272, 15270, 23087, 361, 329, 333, 2142, 2140, 2138, 1895, 1893}
    local inv = API.ReadInvArrays33()
    if not inv then return false end
    for _, fid in ipairs(FOODS) do
        local found = false
        for _, item in pairs(inv) do
            if item.itemid1 == fid then found = true; break end
        end
        if found then
            Inventory:Eat(fid)
            API.RandomSleep2(1200, 200, 200)
            return true
        end
    end
    API.logWarn("[QS] No food found in inventory")
    return false
end

--- Activates a prayer or ability by its exact in-game name.
--- @param prayer_name string  e.g. "Protect from Magic"
function QuestScript:activatePrayer(prayer_name)
    API.DoAction_Ability(prayer_name, 1, API.OFF_ACT_GeneralInterface_route)
    API.RandomSleep2(600, 100, 100)
end

--- Waits until an NPC with the given ID appears within range.
--- @param npc_id number
--- @param timeout? number (default 30)
--- @return boolean
function QuestScript:waitNPCAppear(npc_id, timeout)
    timeout = timeout or 30
    local t = os.clock()
    while API.Read_LoopyLoop() do
        if os.clock() - t > timeout then
            API.logWarn(string.format("[QS] Timeout waiting for NPC id=%d to appear", npc_id))
            return false
        end
        local r = API.GetAllObjArray1({npc_id}, 50, {1})
        if r and #r > 0 and r[1].Id and r[1].Id > 0 then return true end
        API.RandomSleep2(600, 100, 100)
    end
    return false
end

--- Waits until an NPC with the given ID leaves the area.
--- @param npc_id number
--- @param timeout? number (default 30)
--- @return boolean
function QuestScript:waitNPCGone(npc_id, timeout)
    timeout = timeout or 30
    local t = os.clock()
    while API.Read_LoopyLoop() do
        if os.clock() - t > timeout then
            API.logWarn(string.format("[QS] Timeout waiting for NPC id=%d to leave", npc_id))
            return false
        end
        local r = API.GetAllObjArray1({npc_id}, 50, {1})
        if not r or #r == 0 or not r[1].Id or r[1].Id == 0 then return true end
        API.RandomSleep2(600, 100, 100)
    end
    return false
end

local _FLAGS_DIR = "quests/flags/"

--- Creates a persistence flag file on disk.
--- Flags survive script restarts — useful for multi-session quests.
--- @param flag_name string
function QuestScript:setFlag(flag_name)
    local qn = self.name:gsub("[^%w]", "_")
    local path = _FLAGS_DIR .. qn .. "_" .. flag_name .. ".flag"
    local f = io.open(path, "w")
    if f then f:write("1"); f:close()
        API.logInfo(string.format("[QS] Flag set: %s", flag_name))
    end
end

--- Returns true if the named flag file exists on disk.
--- @param flag_name string
--- @return boolean
function QuestScript:checkFlag(flag_name)
    local qn = self.name:gsub("[^%w]", "_")
    local path = _FLAGS_DIR .. qn .. "_" .. flag_name .. ".flag"
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

return QuestScript
