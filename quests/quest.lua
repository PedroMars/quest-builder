local ScriptName = "Quest toolbox"
local Author = "Spectre011"
local ScriptVersion = "1.1.0"
local ReleaseDate = "03-05-2025"
local DiscordHandle = "not_spectre011"

--[[
Changelog:
v1.0.0 - 03-05-2025
    - Initial release.
v1.1.0 - 08-05-2025
    - Added functions
    - Changed . to :
]]

local API = require("quests.api")

local QUEST = {}

QUEST.Interfaces = {}

QUEST.Interfaces.ChatOptions = { { 1188, 5, -1, -1}, { 1188, 3, -1, 5}, { 1188, 3, 14, 3} }

-- Simple sleep
---@param seconds number
---@return boolean
function QUEST:Sleep(seconds)
    local endTime = os.clock() + seconds
    while API.Read_LoopyLoop() and os.clock() < endTime do
    end
    return true
end

-- Returns true if a dialog option box is currently open
---@return boolean
function QUEST:HasOption()
    local option = API.ScanForInterfaceTest2Get(false, self.Interfaces.ChatOptions)

    if #option > 0 and #option[1].textids > 0 then
        return option[1].textids
    end

    return false
end

-- Selects the first option found in the given table.
--[[Table example:
local options = {
    "Could I have the key back?",
    "6,000? Seems fair!",
    "Teleport to the clan camp south of Falador.",
    "I wish to drop it."
}
]]
---@param options table
---@return boolean
function QUEST:OptionSelector(options)
    for i, optionText in ipairs(options) do
        local optionNumber = tonumber(API.Dialog_Option(optionText))
        if optionNumber and optionNumber > 0 then
            local keyCode = 0x30 + optionNumber
            API.KeyboardPress2(keyCode, 60, 100)
            API.RandomSleep2(400,300,600)
            return true
        end
    end
    return false
end

-- Returns true if a dialog window is currently open
---@return boolean
function QUEST:DialogBoxOpen()
    local vbState = API.VB_FindPSett(2874, 1, 0).state
    return vbState ~= 0 and vbState ~= 8 and vbState ~= 18
end

-- Presses Space bar with a sleep added after
---@return boolean
function QUEST:PressSpace()
    return API.KeyboardPress2(0x20, 40, 60), API.RandomSleep2(400,300,600)
end

-- Busy-waits for a dialog box to appear, with a timeout in seconds
---@param timeout number
---@return boolean
function QUEST:WaitForDialogBox(timeout)
    local startTime = os.clock()
    while API.Read_LoopyLoop() and not QUEST:DialogBoxOpen() do
        if os.clock() - startTime > timeout then
            return false
        end
        QUEST:Sleep(0.6)
    end
    return true
end

-- Checks if the player is within a circular area
---@param x number
---@param y number
---@param z number
---@param radius number
---@return boolean
function QUEST:IsPlayerInArea(x, y, z, radius)
    local coord = API.PlayerCoord()
    local dx = math.abs(coord.x - x)
    local dy = math.abs(coord.y - y)
    local distance = math.sqrt(dx^2 + dy^2)
    if distance <= radius and coord.z == z then
        return true
    else
        return false
    end
end

-- Walks to a location, waiting until within the specified tolerance
---@param x number
---@param y number
---@param z number
---@param Tolerance number
---@return boolean
function QUEST:MoveTo(X, Y, Z, Tolerance)
    while API.Read_LoopyLoop() and not QUEST:IsPlayerInArea(X, Y, Z, Tolerance + 2) do
        if not API.IsPlayerMoving_(API.GetLocalPlayerName()) then
            print("Not moving. Walking...")
            API.DoAction_WalkerW(WPOINT.new(X + math.random(-Tolerance, Tolerance),Y + math.random(-Tolerance, Tolerance),Z))
        end
        QUEST:Sleep(0.6)
    end
    return true
end

-- Waits until the object with the given ID and type appears
---@return boolean
function QUEST:WaitForObjectToAppear(ObjID, ObjType)
    local objects = API.GetAllObjArray1({ObjID}, 75, {ObjType})
    if objects and #objects > 0 then
        for _, object in ipairs(objects) do
            local id = object.Id or 0
            local objType = object.Type or 0
            if id == ObjID and objType == ObjType then
                return true
            end
        end
    else
        print("No objects found on this attempt.")
    end
    QUEST:Sleep(0.6)
    return true
end

-- Returns true if an object with the given ID, range and type exists
---@param ObjID number
---@param Range number
---@param ObjType number
---@return boolean
function QUEST:DoesObjectExist(ObjID, Range, ObjType)
    local objects = API.GetAllObjArray1({ObjID}, Range, {ObjType})
    if objects and #objects > 0 then
        for _, object in ipairs(objects) do
            if object.Id == ObjID and ObjType == object.Type then
                return true
            end
        end
    end
    return false
end

-- Returns true if the Bool1 field of an object (type 12) equals 1
---@param ObjID number
---@return boolean
function QUEST:Bool1Check(ObjID)
    local objects = API.GetAllObjArray1({ObjID}, 75, {12})
    if objects and #objects > 0 then
        for _, object in ipairs(objects) do
            if object.Bool1 == 1 then
                return true
            end
        end
    end
    return false
end

-- Returns true if the player is currently in a cutscene
---@return boolean
function QUEST:IsInCutscene()
    return API.GetVarbitValue(16903) == 1
end

-- Processes a dialog sequence by option number.
-- Waits for the dialog box to open, then presses each number in order.
-- When the number list is exhausted, presses Space to advance.
-- Returns false if no dialog appears within the timeout.
---@param numbers table  Sequence of option numbers, e.g. {1, 2, 3}
---@param timeout number Max seconds to wait for the dialog (default 10)
---@return boolean
function QUEST:DialogSeq(numbers, timeout)
    numbers = numbers or {}
    timeout = timeout or 10

    if not QUEST:WaitForDialogBox(timeout) then
        print("[QUEST:DialogSeq] Timeout - dialog did not appear")
        return false
    end

    local idx = 1
    while API.Read_LoopyLoop() and QUEST:DialogBoxOpen() do
        if QUEST:HasOption() then
            if idx <= #numbers then
                local keyCode = 0x30 + numbers[idx]
                API.KeyboardPress2(keyCode, 60, 100)
                API.RandomSleep2(400, 300, 600)
                idx = idx + 1
            else
                QUEST:PressSpace()
            end
        else
            QUEST:PressSpace()
        end
        QUEST:Sleep(0.6)
    end

    return true
end

return QUEST
