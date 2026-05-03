--[[
  quests/api.lua — Quest-scoped API wrapper

  This file is NOT included in the QuestBuilder distribution because it is
  provided by the RS3 automation client framework.

  HOW TO SET UP:
    Copy   Lua_Scripts/quests/api.lua
    from your client installation into this folder.

  The file wraps all global client globals (API.*, WPOINT, etc.) so that
  QuestScript.lua and quest.lua can require it with a consistent path.
]]

error(
    "[QuestBuilder] quests/api.lua is missing.\n" ..
    "Copy 'Lua_Scripts/quests/api.lua' from your client installation into this folder."
)
