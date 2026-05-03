# Quest Builder

A visual quest automation framework for RuneScape 3, built on a step-based progression system.

---

## Folder Structure

```
Lua_Scripts/
├── quest_builder.lua         ← Builder GUI (run this in the client)
├── Lodestones.lua            ← Lodestone teleport module (used by builder)
├── api.lua                   ← Game API (provided by the client framework)
└── quests/
    ├── api.lua               ← Quest-scoped API wrapper
    ├── quest.lua             ← Dialog & movement helpers
    ├── QuestScript.lua       ← Quest scripting framework
    ├── lodestones.lua        ← Lodestones for generated scripts
    └── <quest_name>.lua      ← Generated/exported quest scripts
```

---

## Quick Start

1. Run **`quest_builder.lua`** inside the RS3 client.
2. Select a quest from the left panel.
3. Switch to the **Builder** tab on the right.
4. Add steps and actions using the `+ Step` button and `+  Add` button.
5. Click **Export Lua** to generate a runnable quest script.
6. Run the exported `quests/<quest_name>.lua` directly.

---

## Builder — Step by Step

### Creating a Step
- Click **`+ Step`** — creates a step at the current quest progress value.
- Set the **Label** (description shown in logs).
- Set the **State Trigger** (optional Lua condition for documentation).
- Add **Notes** for reference.

### Recording Steps Automatically
- Click **`Record Steps`** — the builder auto-creates steps when quest progress changes in-game.
- Click **`Stop Recording`** to finish.

### Path Recorder
- Click **`Record Path`** — records your movement as `walk` actions.
- Use **`+Obj`** / **`+NPC`** buttons to insert interactions at the current position.
- Click **`Stop Path`** to commit all recorded actions into the active step.

### Importing from Bolt Quest Helper
- Click **`Import Bolt`** — parses the Bolt quest helper data file and auto-generates steps with coordinates and NPC interactions.

---

## Action Types Reference

### Movement
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `walk` | Walk directly to coordinates | `qs:moveTo(x, y, z, tol)` |
| `smart_walk` | Walk with lodestone teleport if closer | `smartWalk(x, y, z, tol)` |
| `teleport` | Teleport to a lodestone by name | `LODESTONES.NAME.Teleport()` |

### NPC / Object Interaction
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `talk_npc` | Interact with an NPC | `Interact:NPC("name", "action")` |
| `interact_obj` | Interact with an object (by name or ID) | `Interact:Object(...)` / `API.DoAction_Object1(...)` |
| `kill_npcs` | Attack and kill N NPCs, death detected via Life tracking | `qs:killNPCs("name", count, dist)` |

### Dialog
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `dialog` | Wait for dialog, press options by number then Space | `QUEST:DialogSeq({1,2}, timeout)` |
| `accept_quest` | Click the Accept Quest button | `API.DoAction_Interface(...)` |

### Inventory / Equipment
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `equip_item` | Equip item by ID | `Inventory:Equip(id)` |
| `use_item_obj` | Use inventory item on an object | `API.DoAction_DontResetSelection()` + `DoAction_Inventory1` + `DoAction_Object1` |
| `inv_use` | Use item from inventory | `Inventory:Use(id_or_name)` |
| `inv_eat` | Eat item from inventory | `Inventory:Eat(id_or_name)` |
| `inv_drop` | Drop item from inventory | `Inventory:Drop(id_or_name)` |
| `inv_use_item` | Use item on another item | `Inventory:UseItemOnItem(src, tgt)` |
| `equip_remove` | Unequip an item | `Equipment:Unequip(id_or_name)` |

### Combat / Survival
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `kill_npcs` | Kill N NPCs (death via Life=0 or Life disappearing) | `qs:killNPCs("name", count, dist)` |
| `heal_if_low` | Eat food if HP% below threshold | `qs:healIfLow(threshold)` |
| `activate_prayer` | Activate a prayer or ability by name | `qs:activatePrayer("name")` |
| `loot_all` | Pick up all ground items | `API.DoAction_LootAll_Button()` |
| `pickup_item` | Pick up a specific item by ID | `API.DoAction_G_Items1(...)` |

### Waiting / Sync
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `wait_cutscene` | Press Space through dialogs until cutscene ends | `qs:waitCutscene(timeout)` |
| `wait_npc_appear` | Wait until NPC with given ID is in range | inline loop |
| `wait_npc_gone` | Wait until NPC with given ID leaves | inline loop |
| `sleep` | Wait a fixed number of milliseconds | `API.RandomSleep2(ms, ...)` |

### State / Flags
| Action | Description | Generated Code |
|--------|-------------|----------------|
| `set_flag` | Write a persistence flag file to disk | `qs:setFlag("name")` |
| `check_flag_skip` | If flag exists, skip the rest of this step | `if qs:checkFlag("name") then return end` |

### Custom
| Action | Description |
|--------|-------------|
| `custom` | Raw Lua code — anything goes |

---

## QuestScript API Reference

All methods are available on the `qs` object returned by `QS.new({name="..."})`.

### Constructor

```lua
local QS = require("quests.QuestScript")
local qs = QS.new({
    name  = "Quest Name",   -- exact in-game quest name (required)
    debug = false,          -- print debug logs per step (optional)
})
```

### Step Definition

```lua
qs:step(progress, label, fn)
```
Registers a function to run when quest progress equals `progress`.

```lua
qs:onComplete(fn)
```
Registers a function to run when the quest is marked complete.

```lua
qs:run()
```
Starts the main loop. Blocks until the quest is complete or the loop stops.

---

### Movement

```lua
qs:moveTo(x, y, z, tolerance)
```
Walks to `(x, y, z)` and waits until within `tolerance` tiles. Default tolerance: 2.

---

### Dialog Helpers

```lua
qs:isDialogOpen()          -- returns true if any dialog box is open
qs:waitDialog(timeout)     -- waits up to timeout seconds for a dialog to appear
qs:waitDialogClose(timeout)-- waits up to timeout seconds for a dialog to close
qs:pressSpace()            -- presses Space bar once
qs:skipDialogs(timeout)    -- presses Space repeatedly until all dialogs close
qs:optionSelector(options) -- selects the first matching option text from the list
```

---

### Quest Helpers

```lua
qs:acceptQuest(timeout)          -- clicks Accept Quest if interface is open
qs:getProgress()                 -- returns current quest progress number
qs:waitForProgress(expected, timeout) -- waits until progress reaches expected value
                                      -- if expected is nil, waits for any change
```

---

### Inventory / Equipment

```lua
qs:hasItem(itemId)    -- returns true if item is in inventory
qs:equipItem(itemId)  -- equips item from inventory by ID
```

---

### Combat

```lua
qs:killNPCs(npc_name, count, dist)
```
Attacks and kills `count` instances of `npc_name` within `dist` tiles.
Death is detected when `ReadLpInteracting().Life` reaches 0 or the NPC
disappears after having a confirmed Life > 0. Handles auto-retargeting.

---

### Survival

```lua
qs:healIfLow(threshold)
```
Eats common food from inventory if current HP% < `threshold` (default 50).
Tries: Shark, Lobster, Swordfish, Monkfish, Cavefish, Rocktail, Sailfish, etc.

```lua
qs:activatePrayer(prayer_name)
```
Activates a prayer or ability by its exact in-game name.
Example: `qs:activatePrayer("Protect from Magic")`

---

### Cutscene

```lua
qs:waitCutscene(timeout)
```
Waits for dialogs to appear and presses Space until the cutscene ends.
Timeout defaults to 60 seconds.

---

### NPC Tracking

```lua
qs:waitNPCAppear(npc_id, timeout)  -- waits until NPC with ID is in range
qs:waitNPCGone(npc_id, timeout)    -- waits until NPC with ID leaves range
```

---

### Persistence Flags

Flags are stored in `quests/flags/<QuestName>_<flagName>.flag`.
Useful for multi-session quests — the flag persists between script runs.

```lua
qs:setFlag("blood_diamond_done")   -- creates the flag file
qs:checkFlag("blood_diamond_done") -- returns true if flag file exists
```

**Typical usage:**
```lua
qs:step(11, "Get Blood Diamond", function()
    if qs:checkFlag("blood_done") then return end  -- already done, skip
    -- ... do the blood diamond section ...
    qs:setFlag("blood_done")
end)
```

---

## Lodestones Reference

Available lodestone names for `LODESTONES.NAME.Teleport()`:

```
AL_KHARID, ANACHRONIA, ARDOUGNE, ASHDALE, BANDIT_CAMP, BURTHOPE,
CANIFIS, CATHERBY, DRAYNOR_VILLAGE, EAGLES_PEAK, EDGEVILLE, FALADOR,
FORT_FORINTHRY, FREMENNIK_PROVINCE, KARAMJA, LUNAR_ISLE, LUMBRIDGE,
MENAPHOS, OOGLOG, PORT_SARIM, PRIFDDINAS, SEERS_VILLAGE, TAVERLEY,
TIRANNWN, UM, VARROCK, WILDERNESS, YANILLE
```

---

## Example — Rune Mythos

See `examples/rune_mythos.lua` for a complete working quest script.

Key patterns used:
- `QUEST:DialogSeq({1}, 10)` — press option 1 then Space to close dialog
- `QUEST:DialogSeq({}, 10)` — just press Space through all dialogs
- `API.DoAction_Interface(...)` — accept quest popup
- `API.DoAction_Object1(...)` — interact with object by ID

---

## Tips

- Use **`Record Steps`** first to auto-capture progress values and positions.
- Use **`Import Bolt`** to get NPC names and coordinates from Bolt quest helper data.
- The **`>` / `<` button** on the left panel collapses the quest list to give more space to the builder.
- Steps auto-save every ~6 seconds and immediately on add/remove/reorder.
- Use `debug = true` in `QS.new()` to get per-tick logs while testing.
- Use `check_flag_skip` at the start of long sections to resume after a crash.
