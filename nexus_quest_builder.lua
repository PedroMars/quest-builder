local API = require("api")
ClearRender()

-- ============================================================================
-- NEXUS QUEST BUILDER v2.0
-- ============================================================================
--
-- WORKFLOW:
--   1. Abre o script — scan automático de todas as quests do cache do jogo.
--   2. Lista de quests com 3 estados: Feita / Nao feita / Automatizada.
--   3. Filtro de texto + filtro por estado.
--   4. Seleciona quest → painel direito mostra progresso e steps automatizados.
--   5. Botões executam ações diretamente no jogo.
--
-- SCAN DE QUESTS:
--   - Itera IDs 1..MAX_QUEST_ID no main loop (20 por tick).
--   - Quest:Get(id) → se retornar dados válidos, adiciona à lista.
--   - Estado derivado de isComplete() / isStarted() + presença na LIBRARY.
-- ============================================================================

-- ============================================================================
-- QUEST LIBRARY (quests automatizadas)
-- Chave = nome exato da quest no jogo.
-- ============================================================================
local LIBRARY = {
    ["The Restless Ghost"] = {
        steps = {
            {
                progress = 0,
                label    = "Iniciar quest — Falar com Father Aereck",
                coords   = { x=3243, y=3207, z=0 },
                npc      = "Father Aereck",
                dialog   = { "I need a quest!", "I need a quest" },
                actions  = {
                    { label="Mover para Father Aereck", fn=function() API.DoAction_WalkerW(WPOINT.new(3243,3207,0)) end },
                    { label="Falar com Father Aereck",  fn=function() Interact:NPC("Father Aereck","Talk to") end },
                }
            },
            {
                progress = 1,
                label    = "Falar com Father Urhney",
                coords   = { x=3240, y=3209, z=0 },
                npc      = "Father Urhney",
                actions  = {
                    { label="Mover para Father Urhney", fn=function() API.DoAction_WalkerW(WPOINT.new(3240,3209,0)) end },
                    { label="Falar com Father Urhney",  fn=function() Interact:NPC("Father Urhney","Talk to") end },
                }
            },
            {
                progress = 2,
                label    = "Equipar amulet e falar com o ghost",
                coords   = { x=3246, y=3193, z=0 },
                npc      = "Restless ghost",
                actions  = {
                    { label="Equipar Ghostspeak Amulet", fn=function() Inventory:Equip(552) end },
                    { label="Falar com Restless ghost",  fn=function() Interact:NPC("Restless ghost","Talk to") end },
                }
            },
            {
                progress = 3,
                label    = "Apanhar ghost skull nas Rocks",
                coords   = { x=3316, y=3149, z=0 },
                object   = "Rocks",
                actions  = {
                    { label="Mover para Rocks",  fn=function() API.DoAction_WalkerW(WPOINT.new(3316,3149,0)) end },
                    { label="Pesquisar Rocks",   fn=function() Interact:Object("Rocks","Search") end },
                }
            },
            {
                progress = 4,
                label    = "Colocar skull no Coffin",
                coords   = { x=3246, y=3193, z=0 },
                object   = "Coffin",
                actions  = {
                    { label="Mover para Coffin",     fn=function() API.DoAction_WalkerW(WPOINT.new(3246,3193,0)) end },
                    { label="Usar Skull no Coffin",  fn=function() Inventory:UseItemOnObject(553,89481) end },
                }
            },
        }
    },
    -- Adiciona mais quests aqui: ["Nome da Quest"] = { steps = { ... } }
}

-- ============================================================================
-- CONFIG
-- ============================================================================
local MAX_QUEST_ID   = 600   -- IDs a varrer (RS3 tem ~400 quests)
local SCAN_PER_TICK  = 20    -- IDs lidos por tick do main loop

-- ============================================================================
-- STATE
-- ============================================================================
local STATE = {
    win_init   = false,
    safe_mode  = false,
    gui_error  = "",

    -- Safety cache
    safe_val = false,
    safe_ttl = 0,

    -- Scan de quests (tick-machine)
    all_quests    = {},   -- { id, name, complete, started, automated } — pure Lua
    scan_seen     = {},   -- name → índice em all_quests (dedup durante scan)
    scan_cursor   = 1,    -- próximo ID a ler
    scan_done     = false,
    scan_progress = 0.0,
    rescan_requested = true,

    -- Filtros
    search_input  = "",
    filter_status = "all",  -- "all" | "done" | "notdone" | "auto"
    filtered      = {},     -- lista filtrada para a UI

    -- QuestData extra (items, notas, rewards)
    quest_extra_data  = nil,
    play_quest_module = nil,  -- quando definido, main loop executa o script

    -- Seleção
    selected_name  = nil,   -- nome da quest selecionada
    selected_entry = nil,   -- entrada em all_quests
    selected_lib   = nil,   -- entrada em LIBRARY (ou nil)

    -- Progresso live da quest selecionada
    quest_progress = -1,
    quest_complete = false,
    quest_started  = false,
    current_step   = nil,

    -- Metadados estáticos da quest (carregados uma vez por seleção)
    quest_meta_loaded  = false,
    quest_difficulty   = nil,   -- string: "Novice", "Master", etc.
    quest_members      = nil,   -- bool: true=members, false=f2p
    quest_points       = nil,   -- number: quest points
    quest_varbit       = nil,   -- number: varbit de progresso
    quest_start_coords = nil,   -- array de { x, y, z }
    quest_req_quests   = nil,   -- array de { name, complete }
    quest_skill_reqs   = nil,   -- array de { skill, level }

    -- Tab activa no painel direito
    right_tab = "info",   -- "info" | "builder"

    -- Script Builder
    builder_steps        = {},    -- array de { progress, label, lua_check, notes, actions={} }
    builder_recording    = false,
    builder_last_prog    = -1,
    builder_active       = 0,     -- índice do step seleccionado (0 = nenhum)
    -- campos de texto do step (sync manual ao mudar de step)
    builder_edit_label      = "",
    builder_edit_lua_check  = "",
    builder_edit_notes      = "",
    -- action editor
    builder_action_sel      = 0,   -- índice da ação selecionada no step atual (0=nenhuma)
    builder_add_type_idx    = 1,   -- índice em ACTION_DEFS para o botão "+"
    builder_export_status   = "",
    builder_import_status   = "",
    builder_bolt_status     = "",

    -- Ação pendente
    action_pending = nil,

    -- Path Recorder
    path_rec_active   = false,
    path_rec_actions  = {},    -- acções gravadas até agora
    path_rec_last_pos = nil,   -- {x,y,z} última posição que gerou waypoint
    path_rec_raw_pos  = nil,   -- {x,y,z} posição no tick anterior (para detectar jump)
    path_rec_min_dist = 8,     -- tiles mínimos entre waypoints de andar
    path_rec_status   = "",    -- texto de estado para UI
    path_rec_step_idx = 0,     -- step destino (0 = usar builder_active)

    -- Action Queue Runner
    action_queue      = {},  -- { action_data, ... } — fila de execução do step
    action_queue_wait = 0,   -- ticks restantes antes da próxima ação

    -- UI
    list_collapsed = false,  -- painel esquerdo minimizado

    -- Auto-save
    builder_autosave_tick = 0,

    -- Progress tracking
    prev_quest_progress = -1,  -- para detectar mudanças
    prog_log            = {},  -- { {progress,cx,cy,cz}, ... } — historial (máx 20)
    builder_follow      = false, -- auto-seleciona step ao mudar de progresso
}

-- ============================================================================
-- SAFETY CHECK (cached 30 ticks)
-- ============================================================================
local function IsSafe()
    if STATE.safe_mode then return false end
    if STATE.safe_ttl > 0 then STATE.safe_ttl = STATE.safe_ttl - 1; return STATE.safe_val end
    local o1, v1 = pcall(API.IsCacheLoaded)
    local o2, v2 = pcall(API.PlayerLoggedIn)
    STATE.safe_val = (o1 and v1 and o2 and v2) or false
    STATE.safe_ttl = 30
    return STATE.safe_val
end

-- Versão sem safe_mode — só verifica cache (para o scan de quests que é read-only)
local function IsCacheReady()
    if STATE.safe_ttl > 0 then return STATE.safe_val end
    local o1, v1 = pcall(API.IsCacheLoaded)
    local o2, v2 = pcall(API.PlayerLoggedIn)
    STATE.safe_val = (o1 and v1 and o2 and v2) or false
    STATE.safe_ttl = 30
    return STATE.safe_val
end

-- ============================================================================
-- TICK: Scan de quests por ID (main loop — SCAN_PER_TICK por iteração)
-- ============================================================================
local function TickQuestScan()
    if STATE.scan_done and not STATE.rescan_requested then return false end
    -- reset pode acontecer mesmo em safe_mode (é só limpar tabelas)
    if STATE.rescan_requested then
        STATE.all_quests    = {}
        STATE.scan_seen     = {}
        STATE.scan_cursor   = 1
        STATE.scan_done     = false
        STATE.scan_progress = 0.0
        STATE.rescan_requested = false
    end
    if not IsCacheReady() then return false end

    local cursor = STATE.scan_cursor
    local limit  = math.min(cursor + SCAN_PER_TICK - 1, MAX_QUEST_ID)

    for id = cursor, limit do
        local ok, qd = pcall(Quest.Get, Quest, id)
        if ok and qd then
            -- qd.name retorna o nome de ecrã (ex: "Cabin Fever"), conforme param id=1 da API
            local ok_n, name = pcall(function() return qd.name end)
            if ok_n and type(name) == "string" and name ~= "" then
                local ok_c, comp    = pcall(function() return qd:isComplete() end)
                local ok_s, started = pcall(function() return qd:isStarted() end)
                local is_complete = (ok_c and comp == true)
                local is_started  = (ok_s and started == true)
                local _slug   = name:gsub("[^%w%s%-_]",""):gsub("%s+","_"):lower()
                local _pascal = name:gsub("[^%w%s]",""):gsub("(%a+)", function(w) return w:sub(1,1):upper()..w:sub(2) end):gsub("%s+","")
                local _base   = "c:/Users/marsu/MemoryError/Lua_Scripts/quests/"
                local function _fexists(p) local f=io.open(p,"r"); if f then f:close() return true end return false end
                local _has_lua = _fexists(_base.._slug..".lua") or _fexists(_base.._pascal..".lua")
                local is_auto = LIBRARY[name] ~= nil or _has_lua

                local existing_idx = STATE.scan_seen[name]
                if existing_idx then
                    -- Já existe: actualizar estado se o novo ID tiver info melhor
                    local ex = STATE.all_quests[existing_idx]
                    if is_complete and not ex.complete then ex.complete = true end
                    if is_started  and not ex.started  then ex.started  = true end
                    if is_auto     and not ex.automated then ex.automated = true end
                else
                    -- Primeira vez que vemos este nome
                    table.insert(STATE.all_quests, {
                        id        = id,
                        name      = name,
                        complete  = is_complete,
                        started   = is_started,
                        automated = is_auto,
                    })
                    STATE.scan_seen[name] = #STATE.all_quests
                end
            end
        end
    end

    STATE.scan_cursor   = limit + 1
    STATE.scan_progress = limit / MAX_QUEST_ID

    if limit >= MAX_QUEST_ID then
        STATE.scan_done = true
        -- Ordenar por nome
        table.sort(STATE.all_quests, function(a, b) return a.name < b.name end)
    end

    return true
end

-- ============================================================================
-- TICK: Filtrar lista (main loop)
-- ============================================================================
local function TickFilter()
    local query  = STATE.search_input:lower()
    local status = STATE.filter_status
    local result = {}

    for _, q in ipairs(STATE.all_quests) do
        -- Filtro de texto
        if query ~= "" and not q.name:lower():find(query, 1, true) then
            goto continue
        end
        -- Filtro de status
        if status == "done"    and not q.complete  then goto continue end
        if status == "notdone" and q.complete       then goto continue end
        if status == "auto"    and not q.automated  then goto continue end

        table.insert(result, q)
        ::continue::
    end

    STATE.filtered = result
end

-- ============================================================================
-- TICK: Progresso live da quest selecionada (main loop)
-- ============================================================================
local function TickQuestProgress()
    if not IsSafe() then return end
    if not STATE.selected_name then return end

    local ok, qd = pcall(Quest.Get, Quest, STATE.selected_name)
    if not ok or not qd then
        STATE.quest_progress = -1
        STATE.quest_complete = false
        STATE.quest_started  = false
        STATE.current_step   = nil
        return
    end

    local ok2, prog  = pcall(function() return qd:getProgress() end)
    local ok3, comp  = pcall(function() return qd:isComplete() end)
    local ok4, start = pcall(function() return qd:isStarted() end)

    local new_prog = (ok2 and type(prog) == "number") and math.floor(prog) or -1
    STATE.quest_complete = (ok3 and comp  == true)
    STATE.quest_started  = (ok4 and start == true)

    -- Detectar mudança de progresso → log + auto-follow
    if new_prog >= 0 and new_prog ~= STATE.prev_quest_progress then
        STATE.prev_quest_progress = new_prog
        local cx, cy, cz = 0, 0, 0
        local ok_p, pos = pcall(API.PlayerCoord)
        if ok_p and pos and pos.x and pos.x ~= 0 then
            cx, cy, cz = pos.x, pos.y, pos.z
        end
        table.insert(STATE.prog_log, 1, { progress=new_prog, cx=cx, cy=cy, cz=cz })
        if #STATE.prog_log > 20 then table.remove(STATE.prog_log) end
        -- Auto-follow: seleciona o step do builder que bate com o novo progresso
        if STATE.builder_follow and #STATE.builder_steps > 0 then
            for i, s in ipairs(STATE.builder_steps) do
                if s.progress == new_prog and STATE.builder_active ~= i then
                    if STATE.builder_active > 0 and STATE.builder_steps[STATE.builder_active] then
                        SyncEditToStep(STATE.builder_steps[STATE.builder_active])
                    end
                    STATE.builder_active = i
                    SyncStepToEdit(s)
                    break
                end
            end
        end
    end
    STATE.quest_progress = new_prog

    -- Step atual
    STATE.current_step = nil
    local lib = STATE.selected_lib
    if lib and lib.steps then
        for _, step in ipairs(lib.steps) do
            if step.progress == STATE.quest_progress then
                STATE.current_step = step
                break
            end
        end
    end

    -- Builder recording: detectar mudança de progresso e criar step com contexto
    if STATE.builder_recording and STATE.quest_progress >= 0
    and STATE.quest_progress ~= STATE.builder_last_prog then
        STATE.builder_last_prog = STATE.quest_progress
        local already = false
        for _, s in ipairs(STATE.builder_steps) do
            if s.progress == STATE.quest_progress then already = true; break end
        end
        if not already then
            -- Capturar contexto no momento da mudança
            local cx, cy, cz = 0, 0, 0
            local has_coord = false
            local ok_pos, pos = pcall(API.PlayerCoord)
            if ok_pos and pos and pos.x and pos.x ~= 0 then
                cx, cy, cz = pos.x, pos.y, pos.z
                has_coord = true
            end

            -- Capturar NPC mais próximo com interação recente
            local npc_name = ""
            local ok_npcs, npcs = pcall(API.ReadAllNPCs)
            if ok_npcs and npcs and #npcs > 0 then
                local best_dist = 999
                for _, n in ipairs(npcs) do
                    local ok_nx, nx = pcall(function() return n.x end)
                    local ok_ny, ny = pcall(function() return n.y end)
                    local ok_nn, nn = pcall(function() return n.Name end)
                    if ok_nx and ok_ny and ok_nn and nn ~= "" then
                        local dist = math.sqrt((nx-cx)^2 + (ny-cy)^2)
                        if dist < best_dist and dist < 5 then
                            best_dist = dist
                            npc_name = nn
                        end
                    end
                end
            end

            -- Varbit usado por esta quest
            local varbit_str = ""
            if STATE.quest_varbit and STATE.quest_varbit > 0 then
                varbit_str = "if API.GetVarbitValue(" .. tostring(STATE.quest_varbit) .. ") == " .. tostring(STATE.quest_progress) .. " then"
            end

            -- Constrói ações iniciais a partir do contexto capturado
            local init_actions = {}
            if has_coord and cx ~= 0 then
                table.insert(init_actions, { type="walk", x=cx, y=cy, z=cz, tol=5 })
            end
            if npc_name ~= "" then
                table.insert(init_actions, { type="talk_npc", name=npc_name, interact="Talk to" })
                table.insert(init_actions, { type="wait_dialog" })
                table.insert(init_actions, { type="skip_dialogs" })
            end

            local new_step = {
                progress  = STATE.quest_progress,
                label     = "Step " .. tostring(STATE.quest_progress),
                lua_check = varbit_str,
                notes     = string.format("Capturado em (%d,%d,%d)", cx, cy, cz),
                actions   = init_actions,
            }
            table.insert(STATE.builder_steps, new_step)
            table.sort(STATE.builder_steps, function(a,b) return a.progress < b.progress end)

            -- Activar e sincronizar o novo step
            for i, s in ipairs(STATE.builder_steps) do
                if s.progress == STATE.quest_progress then
                    STATE.builder_active = i
                    SyncStepToEdit(s)
                    break
                end
            end
            SaveBuilderSteps()
        end
    end

    -- Metadados estáticos — carregados apenas uma vez por seleção
    if STATE.quest_meta_loaded then return end
    STATE.quest_meta_loaded = true

    local function safe(fn) local ok, v = pcall(fn); return ok and v or nil end

    STATE.quest_difficulty = safe(function() return qd.difficulty end)
    STATE.quest_members    = safe(function() return qd.members end)
    STATE.quest_points     = safe(function() return qd.points_reward end)
    STATE.quest_varbit     = safe(function() return qd.progress_varbit end)

    -- Coordenadas de início (COORDGRIDARRAY)
    STATE.quest_start_coords = nil
    local ok_sc, sc = pcall(function() return qd.start_location_path end)
    if ok_sc and type(sc) == "table" and #sc > 0 then
        local coords = {}
        for _, pt in ipairs(sc) do
            local ox, x = pcall(function() return pt.x end)
            local oy, y = pcall(function() return pt.y end)
            local oz, z = pcall(function() return pt.z end)
            if ox and oy then
                table.insert(coords, { x = x or 0, y = y or 0, z = oz and z or 0 })
            end
        end
        if #coords > 0 then STATE.quest_start_coords = coords end
    end

    -- Quests requeridas (QUESTARRAY)
    STATE.quest_req_quests = nil
    local ok_rq, rq = pcall(function() return qd.required_quests end)
    if ok_rq and type(rq) == "table" and #rq > 0 then
        local names = {}
        for _, rqd in ipairs(rq) do
            local ok_rn, rname = pcall(function() return rqd.name end)
            if ok_rn and type(rname) == "string" and rname ~= "" then
                local ok_rc, rcomp = pcall(function() return rqd:isComplete() end)
                table.insert(names, { name = rname, complete = (ok_rc and rcomp == true) })
            end
        end
        if #names > 0 then STATE.quest_req_quests = names end
    end

    -- Requisitos de skill (KVArray — {SkillName = level})
    STATE.quest_skill_reqs = nil
    local ok_sr, sr = pcall(function() return qd.skill_requirements end)
    if ok_sr and type(sr) == "table" then
        local reqs = {}
        for k, v in pairs(sr) do
            table.insert(reqs, { skill = tostring(k), level = tostring(v) })
        end
        if #reqs > 0 then
            table.sort(reqs, function(a, b) return a.skill < b.skill end)
            STATE.quest_skill_reqs = reqs
        end
    end
end

-- ============================================================================
-- THEME
-- ============================================================================
local function PushTheme()
    ImGui.PushStyleColor(ImGuiCol.WindowBg,      0.06, 0.06, 0.08, 0.95)
    ImGui.PushStyleColor(ImGuiCol.TitleBg,       0.15, 0.25, 0.42, 1.00)
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive, 0.20, 0.32, 0.55, 1.00)
    ImGui.PushStyleColor(ImGuiCol.Header,        0.26, 0.59, 0.98, 0.31)
    ImGui.PushStyleColor(ImGuiCol.Button,        0.20, 0.48, 0.80, 0.55)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.26, 0.59, 0.98, 1.00)
    ImGui.PushStyleColor(ImGuiCol.Text,          1.00, 1.00, 1.00, 1.00)
    ImGui.PushStyleColor(ImGuiCol.ChildBg,       0.07, 0.07, 0.10, 1.00)
end
local function PopTheme() ImGui.PopStyleColor(8) end

-- ============================================================================
-- STACK SAFETY
-- ============================================================================
local STK = { tbl=false, child=false, colors=0 }
local function StkReset()   STK.tbl=false; STK.child=false; STK.colors=0 end
local function StkCleanup()
    if STK.tbl    then pcall(ImGui.EndTable);                    STK.tbl    = false end
    if STK.child  then pcall(ImGui.EndChild);                    STK.child  = false end
    if STK.colors > 0 then pcall(ImGui.PopStyleColor, STK.colors); STK.colors = 0  end
end

-- ============================================================================
-- ACTION SYSTEM — definições, helpers, geração de código
-- ============================================================================

local ACTION_DEFS = {
    { id="walk",         label="Andar ate",           cr=0.4, cg=0.7, cb=1.0 },
    { id="smart_walk",   label="Smart Walk (Lode)",   cr=0.2, cg=1.0, cb=0.6 },
    { id="teleport",     label="Teleporte",            cr=0.6, cg=0.4, cb=1.0 },
    { id="talk_npc",     label="Falar com NPC",        cr=0.9, cg=0.7, cb=0.2 },
    { id="interact_obj", label="Interagir Objeto",     cr=0.9, cg=0.5, cb=0.2 },
    -- Dialogo unificado: espera abrir, prime Space em texto, escolhe opção por número.
    -- seq="" → só Space em tudo.  seq="1,2" → escolhe 1 depois 2 e depois Space.
    { id="dialog",       label="Dialogo",              cr=0.3, cg=0.95, cb=0.6 },
    { id="accept_quest", label="Aceitar Quest",        cr=0.3, cg=1.0,  cb=0.4 },
    { id="equip_item",   label="Equipar Item",         cr=0.9, cg=0.4,  cb=0.8 },
    { id="use_item_obj", label="Item em Objeto",       cr=0.9, cg=0.5,  cb=0.6 },
    { id="kill_npcs",    label="Matar NPCs",            cr=1.0, cg=0.3,  cb=0.3 },
    { id="inv_use",      label="Inv: Usar Item",       cr=0.9, cg=0.5,  cb=0.9 },
    { id="inv_eat",      label="Inv: Comer Item",      cr=0.9, cg=0.7,  cb=0.3 },
    { id="inv_drop",     label="Inv: Dropar Item",     cr=0.7, cg=0.4,  cb=0.4 },
    { id="inv_use_item", label="Inv: Item em Item",    cr=0.9, cg=0.5,  cb=0.7 },
    { id="equip_remove",    label="Equip: Desequipar",     cr=0.5, cg=0.4,  cb=0.9 },
    { id="wait_cutscene",   label="Aguardar Cutscene",    cr=0.8, cg=0.6,  cb=1.0 },
    { id="heal_if_low",     label="Curar se HP baixo",    cr=1.0, cg=0.4,  cb=0.4 },
    { id="activate_prayer", label="Ativar Oracao",        cr=0.6, cg=0.8,  cb=1.0 },
    { id="wait_npc_appear", label="Aguardar NPC aparecer",cr=0.8, cg=0.9,  cb=0.5 },
    { id="wait_npc_gone",   label="Aguardar NPC sumir",   cr=0.6, cg=0.7,  cb=0.4 },
    { id="loot_all",        label="Apanhar tudo",          cr=1.0, cg=0.8,  cb=0.3 },
    { id="pickup_item",     label="Apanhar Item chao",    cr=1.0, cg=0.7,  cb=0.2 },
    { id="set_flag",        label="Definir Flag",          cr=0.5, cg=0.9,  cb=0.5 },
    { id="check_flag_skip", label="Skip se Flag existe",  cr=0.5, cg=0.7,  cb=0.5 },
    { id="sleep",           label="Aguardar (ms)",        cr=0.5, cg=0.5,  cb=0.5 },
    { id="custom",       label="Lua Customizado",      cr=1.0, cg=0.4,  cb=0.4 },
    -- Legado (mantidos para retrocompatibilidade)
    { id="wait_dialog",  label="[old] Aguardar Dialog",cr=0.3, cg=0.6,  cb=0.4 },
    { id="skip_dialogs", label="[old] Skip Dialogos",  cr=0.3, cg=0.6,  cb=0.4 },
    { id="dialog_seq",   label="[old] Dialog Sequencia",cr=0.3,cg=0.6,  cb=0.6 },
    { id="select_num",   label="[old] Opcao Numero",   cr=0.3, cg=0.6,  cb=0.4 },
    { id="select_text",  label="[old] Opcao Texto",    cr=0.3, cg=0.6,  cb=0.5 },
}

-- Índice rápido id→def
local ACTION_BY_ID = {}
for _, d in ipairs(ACTION_DEFS) do ACTION_BY_ID[d.id] = d end

-- Lista de labels para o Combo
local ACTION_LABELS = {}
for _, d in ipairs(ACTION_DEFS) do table.insert(ACTION_LABELS, d.label) end

--- Resumo de uma linha para mostrar na lista de ações.
local function ActionSummary(a)
    local t = a.type or ""
    if t == "walk"         then return string.format("(%d, %d, %d)  tol:%d", a.x or 0, a.y or 0, a.z or 0, a.tol or 5)
    elseif t == "smart_walk"   then return string.format("(%d, %d, %d)  tol:%d", a.x or 0, a.y or 0, a.z or 0, a.tol or 5)
    elseif t == "teleport"     then return a.lodestone or "?"
    elseif t == "talk_npc"     then return '"'..(a.name or "")..'"  '..(a.interact or "Talk to")
    elseif t == "interact_obj" then
        local dist_s = ((a.dist or 0) > 0) and ("  dist:"..(a.dist)) or ""
        if a.use_id and (a.obj_id or 0) > 0 then
            return string.format("id:%d  0x%X%s", a.obj_id or 0, a.action_offset or 0x29, dist_s)
        end
        return '"'..(a.name or "")..'"  '..(a.action or "Use")..dist_s
    elseif t == "dialog" then
        local seq = (a.seq or ""):match("%S") and ("{"..a.seq.."}") or "{}"
        return seq .. "  timeout:" .. (a.timeout or 10) .. "s"
    elseif t == "accept_quest" then return ""
    elseif t == "equip_item"   then return "id:"..(a.item_id or 0)
    elseif t == "use_item_obj" then return "item:"..(a.item_id or 0).."  obj:"..(a.obj_id or 0)
    elseif t == "kill_npcs"    then return string.format("x%d  \"%s\"  dist:%d", a.kill_count or 1, a.npc_name or "", a.dist or 50)
    elseif t == "inv_use"      then return (a.item_ref or "")
    elseif t == "inv_eat"      then return (a.item_ref or "")
    elseif t == "inv_drop"     then return (a.item_ref or "")
    elseif t == "inv_use_item" then return (a.item_ref or "").." → "..(a.target_ref or "")
    elseif t == "equip_remove" then return (a.item_ref or "")
    elseif t == "wait_cutscene"   then return "timeout:" .. (a.timeout or 60) .. "s"
    elseif t == "heal_if_low"     then return "hp<" .. (a.hp_threshold or 50) .. "%"
    elseif t == "activate_prayer" then return '"' .. (a.prayer_name or "") .. '"'
    elseif t == "wait_npc_appear" then return string.format("id:%d  timeout:%ds", a.npc_id or 0, a.timeout or 30)
    elseif t == "wait_npc_gone"   then return string.format("id:%d  timeout:%ds", a.npc_id or 0, a.timeout or 30)
    elseif t == "loot_all"        then return ""
    elseif t == "pickup_item"     then return "id:" .. (a.item_id or 0)
    elseif t == "set_flag"        then return '"' .. (a.flag_name or "") .. '"'
    elseif t == "check_flag_skip" then return '"' .. (a.flag_name or "") .. '"'
    elseif t == "sleep"           then return (a.ms or 1000).."ms"
    elseif t == "custom"          then return ((a.code or ""):sub(1, 35))
    -- legado
    elseif t == "wait_dialog"  then return "timeout:"..(a.timeout or 10).."s"
    elseif t == "dialog_seq"   then return "{"..(a.seq or "").."}  timeout:"..(a.timeout or 10).."s"
    elseif t == "select_num"   then return "opcao "..(a.n or 1)
    elseif t == "select_text"  then return '"'..(a.text or "")..'"'
    elseif t == "skip_dialogs" then return ""
    end
    return ""
end

local function fmtRef(ref)
    local n = tonumber(ref)
    if n then return tostring(math.floor(n)) else return string.format('"%s"', (ref or ""):gsub('"', '\\"')) end
end

--- Gera as linhas de Lua para uma ação.
local function ActionToCode(a)
    local t = a.type or ""
    if t == "walk" then
        return { string.format("    qs:moveTo(%d, %d, %d, %d)", a.x or 0, a.y or 0, a.z or 0, a.tol or 5) }
    elseif t == "smart_walk" then
        return { string.format("    smartWalk(%d, %d, %d, %d)", a.x or 0, a.y or 0, a.z or 0, a.tol or 5) }
    elseif t == "teleport" then
        return { string.format('    LODESTONES.%s.Teleport()', a.lodestone or "AL_KHARID") }
    elseif t == "talk_npc" then
        return { string.format('    Interact:NPC("%s", "%s")', a.name or "", a.interact or "Talk to") }
    elseif t == "interact_obj" then
        if a.use_id and (a.obj_id or 0) > 0 then
            return { string.format('    API.DoAction_Object1(0x%X, API.OFF_ACT_GeneralObject_route0, {%d}, 50)', a.action_offset or 0x29, a.obj_id or 0) }
        end
        local dist = (a.dist or 0) > 0 and (", " .. tostring(a.dist)) or ""
        return { string.format('    Interact:Object("%s", "%s"%s)', a.name or "", a.action or "Use", dist) }
    elseif t == "dialog" then
        -- Ação unificada: espera dialog, prime Space em texto, escolhe opções por número.
        -- Equivalente a processDialogByNumbers({...}, timeout) do OnePiercingNote.
        local nums = {}
        for n in (a.seq or ""):gmatch("%d+") do table.insert(nums, n) end
        local tbl = #nums > 0 and ("{"..table.concat(nums, ", ").."}") or "{}"
        return { string.format("    QUEST:DialogSeq(%s, %d)", tbl, a.timeout or 10) }
    elseif t == "accept_quest" then
        return { "    API.DoAction_Interface(0x24,0xffffffff,1,1500,409,-1,API.OFF_ACT_GeneralInterface_route)" }
    -- ---- legado (mantidos para scripts antigos) ----
    elseif t == "wait_dialog" then
        return { string.format("    QUEST:WaitForDialogBox(%d)", a.timeout or 10) }
    elseif t == "dialog_seq" then
        local nums = {}
        for n in (a.seq or ""):gmatch("%d+") do table.insert(nums, n) end
        local tbl = #nums > 0 and ("{"..table.concat(nums, ", ").."}") or "{}"
        return { string.format("    QUEST:DialogSeq(%s, %d)", tbl, a.timeout or 10) }
    elseif t == "select_num" then
        local n = a.n or 1
        return {
            string.format("    API.KeyboardPress2(0x%X, 60, 100)  -- opcao %d", 0x30 + n, n),
            "    API.RandomSleep2(400, 100, 100)",
        }
    elseif t == "select_text" then
        return { string.format('    QUEST:OptionSelector({ "%s" })', (a.text or ""):gsub('"', '\\"')) }
    elseif t == "skip_dialogs" then
        return {
            "    while API.Read_LoopyLoop() and QUEST:DialogBoxOpen() do",
            "        QUEST:PressSpace()",
            "    end",
        }
    elseif t == "equip_item" then
        return { string.format("    Inventory:Equip(%d)", a.item_id or 0) }
    elseif t == "use_item_obj" then
        return {
            "    API.DoAction_DontResetSelection()",
            string.format("    API.DoAction_Inventory1(%d, 0, 0, API.OFF_ACT_Bladed_interface_route)", a.item_id or 0),
            "    API.RandomSleep2(600, 100, 0)",
            string.format("    API.DoAction_Object1(0x24, API.OFF_ACT_GeneralObject_route0, {%d}, 50)", a.obj_id or 0),
            "    API.RandomSleep2(800, 100, 100)",
        }
    elseif t == "kill_npcs" then
        return { string.format('    qs:killNPCs("%s", %d, %d)', (a.npc_name or ""):gsub('"','\\"'), a.kill_count or 1, a.dist or 50) }
    elseif t == "inv_use" then
        return { "    Inventory:Use("..fmtRef(a.item_ref)..")" }
    elseif t == "inv_eat" then
        return { "    Inventory:Eat("..fmtRef(a.item_ref)..")" }
    elseif t == "inv_drop" then
        return { "    Inventory:Drop("..fmtRef(a.item_ref)..")" }
    elseif t == "inv_use_item" then
        return { "    Inventory:UseItemOnItem("..fmtRef(a.item_ref)..", "..fmtRef(a.target_ref)..")" }
    elseif t == "equip_remove" then
        return { "    Equipment:Unequip("..fmtRef(a.item_ref)..")" }
    elseif t == "wait_cutscene" then
        return { string.format("    qs:waitCutscene(%d)", a.timeout or 60) }
    elseif t == "heal_if_low" then
        return { string.format("    qs:healIfLow(%d)", a.hp_threshold or 50) }
    elseif t == "activate_prayer" then
        return { string.format('    qs:activatePrayer("%s")', (a.prayer_name or ""):gsub('"', '\\"')) }
    elseif t == "wait_npc_appear" then
        local id, to = a.npc_id or 0, a.timeout or 30
        return {
            string.format("    do local _t=os.clock() while API.Read_LoopyLoop() and os.clock()-_t<%d do", to),
            string.format("        local _r=API.GetAllObjArray1({%d},50,{1})", id),
            "        if _r and #_r>0 and _r[1].Id and _r[1].Id>0 then break end",
            "        API.RandomSleep2(600,100,100) end end",
        }
    elseif t == "wait_npc_gone" then
        local id, to = a.npc_id or 0, a.timeout or 30
        return {
            string.format("    do local _t=os.clock() while API.Read_LoopyLoop() and os.clock()-_t<%d do", to),
            string.format("        local _r=API.GetAllObjArray1({%d},50,{1})", id),
            "        if not _r or #_r==0 or not _r[1].Id or _r[1].Id==0 then break end",
            "        API.RandomSleep2(600,100,100) end end",
        }
    elseif t == "loot_all" then
        return {
            "    API.DoAction_LootAll_Button()",
            "    API.RandomSleep2(800, 100, 200)",
        }
    elseif t == "pickup_item" then
        return {
            string.format("    API.DoAction_G_Items1(0x2d, 0xffffffff, 1, %d, -1, API.OFF_ACT_GeneralInterface_route)", a.item_id or 0),
            "    API.RandomSleep2(600, 100, 100)",
        }
    elseif t == "set_flag" then
        return { string.format('    qs:setFlag("%s")', (a.flag_name or ""):gsub('"', '\\"')) }
    elseif t == "check_flag_skip" then
        return { string.format('    if qs:checkFlag("%s") then return end', (a.flag_name or ""):gsub('"', '\\"')) }
    elseif t == "sleep" then
        local ms = a.ms or 1000
        local v = math.max(50, math.floor(ms * 0.1))
        return { string.format("    API.RandomSleep2(%d, %d, %d)", ms, v, v) }
    elseif t == "custom" then
        return { "    " .. (a.code or "") }
    end
    return {}
end

--- Executa uma acção directamente no jogo (sem gerar código).
local function ExecuteAction(a)
    local t = a.type or ""
    if t == "walk" then
        API.DoAction_WalkerW(WPOINT.new(a.x or 0, a.y or 0, a.z or 0))
    elseif t == "smart_walk" then
        local dx, dy, dz = a.x or 0, a.y or 0, a.z or 0
        local p = API.PlayerCoord()
        local d2dest = math.sqrt((p.x-dx)^2+(p.y-dy)^2)
        local SW_LODES = {
            {n="AL_KHARID",          x=3297, y=3184, z=0},
            {n="ANACHRONIA",         x=5431, y=2338, z=0},
            {n="ARDOUGNE",           x=2634, y=3348, z=0},
            {n="ASHDALE",            x=2474, y=2708, z=2},
            {n="BANDIT_CAMP",        x=2899, y=3544, z=0},
            {n="BURTHOPE",           x=2899, y=3544, z=0},
            {n="CANIFIS",            x=3517, y=3515, z=0},
            {n="CATHERBY",           x=2811, y=3449, z=0},
            {n="DRAYNOR_VILLAGE",    x=3105, y=3298, z=0},
            {n="EAGLES_PEAK",        x=2366, y=3479, z=0},
            {n="EDGEVILLE",          x=3067, y=3505, z=0},
            {n="FALADOR",            x=2967, y=3403, z=0},
            {n="FORT_FORINTHRY",     x=3298, y=3525, z=0},
            {n="FREMENNIK_PROVINCE", x=2712, y=3677, z=0},
            {n="KARAMJA",            x=2761, y=3147, z=0},
            {n="LUNAR_ISLE",         x=2085, y=3914, z=0},
            {n="LUMBRIDGE",          x=3233, y=3221, z=0},
            {n="MENAPHOS",           x=3216, y=2716, z=0},
            {n="OOGLOG",             x=2532, y=2871, z=0},
            {n="PORT_SARIM",         x=3011, y=3215, z=0},
            {n="PRIFDDINAS",         x=2208, y=3360, z=1},
            {n="SEERS_VILLAGE",      x=2689, y=3482, z=0},
            {n="TAVERLEY",           x=2878, y=3442, z=0},
            {n="TIRANNWN",           x=2254, y=3149, z=0},
            {n="UM",                 x=1084, y=1768, z=1},
            {n="VARROCK",            x=3214, y=3376, z=0},
            {n="YANILLE",            x=2560, y=3094, z=0},
        }
        local bestL, bestD = nil, math.huge
        for _, l in ipairs(SW_LODES) do
            local d = math.sqrt((l.x-dx)^2+(l.y-dy)^2)
            if d < bestD then bestD=d; bestL=l end
        end
        if bestL and bestD < d2dest then
            local ok, LODES = pcall(require, "Lodestones")
            if ok and LODES and LODES[bestL.n] then
                LODES[bestL.n].Teleport()
                API.RandomSleep2(2000, 500, 500)
            end
        end
        API.DoAction_WalkerW(WPOINT.new(dx, dy, dz))
    elseif t == "teleport" then
        local ok, LODES = pcall(require, "Lodestones")
        if ok and LODES then
            local key = (a.lodestone or "LUMBRIDGE"):upper():gsub(" ","_")
            if LODES[key] then LODES[key].Teleport() end
        end
    elseif t == "talk_npc" then
        Interact:NPC(a.name or "", a.interact or "Talk to")
    elseif t == "interact_obj" then
        if a.use_id and (a.obj_id or 0) > 0 then
            API.DoAction_Object1(a.action_offset or 0x29, API.OFF_ACT_GeneralObject_route0, {a.obj_id}, 50)
        else
            Interact:Object(a.name or "", a.action or "Use")
        end
    elseif t == "dialog" then
        local ok, QUEST = pcall(require, "quests.quest")
        if ok and QUEST then
            local nums = {}
            for n in ((a.seq or ""):gmatch("%d+")) do table.insert(nums, tonumber(n)) end
            QUEST:DialogSeq(nums, a.timeout or 10)
        end
    elseif t == "wait_dialog" then
        API.RandomSleep2(600, 100, 100)
    elseif t == "select_num" then
        local n = math.max(1, math.min(9, a.n or 1))
        API.KeyboardPress2(0x30 + n, 60, 100)
        API.RandomSleep2(400, 100, 100)
    elseif t == "select_text" then
        API.RandomSleep2(200, 50, 50)
    elseif t == "skip_dialogs" then
        API.KeyboardPress2(0x20, 60, 100)
    elseif t == "accept_quest" then
        API.DoAction_Interface(0x24,0xffffffff,1,1500,409,-1,API.OFF_ACT_GeneralInterface_route)
    elseif t == "equip_item" then
        Inventory:Equip(a.item_id or 0)
    elseif t == "use_item_obj" then
        API.DoAction_DontResetSelection()
        API.DoAction_Inventory1(a.item_id or 0, 0, 0, API.OFF_ACT_Bladed_interface_route)
        API.RandomSleep2(600, 100, 0)
        API.DoAction_Object1(0x24, API.OFF_ACT_GeneralObject_route0, {a.obj_id or 0}, 50)
        API.RandomSleep2(800, 100, 100)
    elseif t == "kill_npcs" then
        local _name, _count = a.npc_name or "", a.kill_count or 1
        local _killed, _hadTarget, _prevLife = 0, false, -1
        while API.Read_LoopyLoop() and _killed < _count do
            local _inter = API.ReadLpInteracting()
            local _life  = _inter and _inter.Life or -1
            if _hadTarget then
                if _life == 0 then
                    _killed = _killed + 1
                    API.logInfo(string.format("[KILL] %d/%d (Life=0)", _killed, _count))
                    _hadTarget = false; _prevLife = -1
                    API.RandomSleep2(700, 100, 200)
                elseif _life < 0 then
                    if _prevLife > 0 then
                        -- tinha vida confirmada e desapareceu: morreu
                        _killed = _killed + 1
                        API.logInfo(string.format("[KILL] %d/%d (desapareceu prevLife=%d)", _killed, _count, _prevLife))
                        _hadTarget = false; _prevLife = -1
                        API.RandomSleep2(700, 100, 200)
                    else
                        -- leitura espuria antes de confirmar vida: verificar target
                        local _tgt = API.ReadTargetInfo99(true)
                        if not (_tgt and _tgt.Target_Id and _tgt.Target_Id > 0) then
                            _hadTarget = false; _prevLife = -1
                        end
                        API.RandomSleep2(200, 50, 50)
                    end
                else
                    _prevLife = _life  -- vida confirmada, guardar para proximo tick
                end
            else
                if _name ~= "" then Interact:NPC(_name, "Attack") end
                API.RandomSleep2(800, 100, 200)
                local _check = API.ReadLpInteracting()
                if _check and _check.Life and _check.Life > 0 then
                    _hadTarget = true; _prevLife = _check.Life
                end
            end
            API.RandomSleep2(400, 50, 100)
        end
    elseif t == "inv_use" then
        Inventory:Use(tonumber(a.item_ref) or a.item_ref or 0)
    elseif t == "inv_eat" then
        Inventory:Eat(tonumber(a.item_ref) or a.item_ref or 0)
    elseif t == "inv_drop" then
        Inventory:Drop(tonumber(a.item_ref) or a.item_ref or 0)
    elseif t == "inv_use_item" then
        Inventory:UseItemOnItem(tonumber(a.item_ref) or a.item_ref or 0, tonumber(a.target_ref) or a.target_ref or 0)
    elseif t == "equip_remove" then
        Equipment:Unequip(tonumber(a.item_ref) or a.item_ref or 0)
    elseif t == "wait_cutscene" then
        local _tout = a.timeout or 60
        local _t = os.clock()
        local function _dlg()
            for _, iface in ipairs({{1191,0,-1,-1,0},{1184,2,-1,-1,0},{1186,2,-1,-1,0},{1189,2,-1,-1,0}}) do
                local ok, r = pcall(API.ScanForInterfaceTest2Get, false, {iface})
                if ok and r and #r > 0 and r[1] and r[1].x and r[1].x ~= 0 then return true end
            end
            return false
        end
        API.RandomSleep2(600, 100, 100)
        local _td = os.clock()
        while API.Read_LoopyLoop() and not _dlg() do
            if os.clock() - _td > 10 then break end
            API.RandomSleep2(400, 100, 100)
        end
        while API.Read_LoopyLoop() and os.clock() - _t < _tout do
            if _dlg() then
                API.KeyboardPress2(0x20, 40, 60)
                API.RandomSleep2(350, 50, 100)
            else
                API.RandomSleep2(700, 100, 200)
                if not _dlg() then break end
            end
        end
    elseif t == "heal_if_low" then
        local _thresh = a.hp_threshold or 50
        if API.GetHPrecent() < _thresh then
            local _foods = {385, 379, 373, 7946, 15272, 15270, 23087, 361, 329, 333, 2142, 2140, 2138}
            local _inv = API.ReadInvArrays33()
            if _inv then
                for _, _fid in ipairs(_foods) do
                    local _found = false
                    for _, _it in pairs(_inv) do
                        if _it.itemid1 == _fid then _found = true; break end
                    end
                    if _found then
                        Inventory:Eat(_fid)
                        API.RandomSleep2(1200, 200, 200)
                        break
                    end
                end
            end
        end
    elseif t == "activate_prayer" then
        API.DoAction_Ability(a.prayer_name or "", 1, API.OFF_ACT_GeneralInterface_route)
        API.RandomSleep2(600, 100, 100)
    elseif t == "wait_npc_appear" then
        local _id, _tout = a.npc_id or 0, a.timeout or 30
        local _t = os.clock()
        while API.Read_LoopyLoop() and os.clock() - _t < _tout do
            local _r = API.GetAllObjArray1({_id}, 50, {1})
            if _r and #_r > 0 and _r[1].Id and _r[1].Id > 0 then break end
            API.RandomSleep2(600, 100, 100)
        end
    elseif t == "wait_npc_gone" then
        local _id, _tout = a.npc_id or 0, a.timeout or 30
        local _t = os.clock()
        while API.Read_LoopyLoop() and os.clock() - _t < _tout do
            local _r = API.GetAllObjArray1({_id}, 50, {1})
            if not _r or #_r == 0 or not _r[1].Id or _r[1].Id == 0 then break end
            API.RandomSleep2(600, 100, 100)
        end
    elseif t == "loot_all" then
        API.DoAction_LootAll_Button()
        API.RandomSleep2(800, 100, 200)
    elseif t == "pickup_item" then
        API.DoAction_G_Items1(0x2d, 0xffffffff, 1, a.item_id or 0, -1, API.OFF_ACT_GeneralInterface_route)
        API.RandomSleep2(600, 100, 100)
    elseif t == "set_flag" then
        local _fn = a.flag_name or ""
        if _fn ~= "" and STATE.selected_name then
            local _dir = "c:/Users/marsu/MemoryError/Lua_Scripts/quests/flags/"
            local _qn = (STATE.selected_name or ""):gsub("[^%w]", "_")
            local _f = io.open(_dir .. _qn .. "_" .. _fn .. ".flag", "w")
            if _f then _f:write("1"); _f:close() end
        end
    elseif t == "check_flag_skip" then
        local _fn = a.flag_name or ""
        if _fn ~= "" and STATE.selected_name then
            local _dir = "c:/Users/marsu/MemoryError/Lua_Scripts/quests/flags/"
            local _qn = (STATE.selected_name or ""):gsub("[^%w]", "_")
            local _f = io.open(_dir .. _qn .. "_" .. _fn .. ".flag", "r")
            if _f then _f:close(); STATE.action_queue = {} end
        end
    elseif t == "sleep" then
        local ms = a.ms or 1000
        API.RandomSleep2(ms, math.max(50, math.floor(ms*0.1)), math.max(50, math.floor(ms*0.1)))
    elseif t == "custom" then
        local fn, err = load(a.code or "")
        if fn then pcall(fn) end
    end
end

--- Avança a fila de execução de acções (chamado no main loop a cada tick).
local function TickActionQueue()
    if #STATE.action_queue == 0 then return end
    if STATE.action_queue_wait > 0 then
        STATE.action_queue_wait = STATE.action_queue_wait - 1
        return
    end
    local a = table.remove(STATE.action_queue, 1)
    local ok, err = pcall(ExecuteAction, a)
    if not ok then
        STATE.gui_error = "Exec: " .. tostring(err)
        STATE.action_queue = {}
        return
    end
    local t = a.type or ""
    if t == "sleep" then
        STATE.action_queue_wait = math.max(1, math.floor((a.ms or 1000) / 50))
    elseif t == "walk" or t == "smart_walk" then
        STATE.action_queue_wait = 5
    else
        STATE.action_queue_wait = 6
    end
end

--- Cria uma nova ação com valores padrão para o tipo dado.
local function NewAction(type_id)
    local t = type_id or "walk"
    if t == "walk"         then return { type="walk",         x=0,  y=0,  z=0, tol=5 }
    elseif t == "smart_walk"   then return { type="smart_walk",   x=0,  y=0,  z=0, tol=5 }
    elseif t == "teleport"     then return { type="teleport",     lodestone="AL_KHARID" }
    elseif t == "talk_npc"     then return { type="talk_npc",     name="", interact="Talk to" }
    elseif t == "interact_obj" then return { type="interact_obj", name="", action="Use", dist=0, use_id=false, obj_id=0, action_offset=0x29 }
    elseif t == "dialog"       then return { type="dialog",       seq="", timeout=10 }
    elseif t == "wait_dialog"  then return { type="wait_dialog",  timeout=10 }
    elseif t == "dialog_seq"   then return { type="dialog_seq",   seq="1", timeout=10 }
    elseif t == "select_num"   then return { type="select_num",   n=1 }
    elseif t == "select_text"  then return { type="select_text",  text="" }
    elseif t == "skip_dialogs" then return { type="skip_dialogs" }
    elseif t == "accept_quest" then return { type="accept_quest" }
    elseif t == "equip_item"   then return { type="equip_item",   item_id=0 }
    elseif t == "use_item_obj" then return { type="use_item_obj", item_id=0, obj_id=0 }
    elseif t == "kill_npcs"    then return { type="kill_npcs", npc_name="", kill_count=1, dist=50 }
    elseif t == "inv_use"      then return { type="inv_use",      item_ref="" }
    elseif t == "inv_eat"      then return { type="inv_eat",      item_ref="" }
    elseif t == "inv_drop"     then return { type="inv_drop",     item_ref="" }
    elseif t == "inv_use_item" then return { type="inv_use_item", item_ref="", target_ref="" }
    elseif t == "equip_remove" then return { type="equip_remove", item_ref="" }
    elseif t == "wait_cutscene"   then return { type="wait_cutscene",   timeout=60 }
    elseif t == "heal_if_low"     then return { type="heal_if_low",     hp_threshold=50 }
    elseif t == "activate_prayer" then return { type="activate_prayer", prayer_name="" }
    elseif t == "wait_npc_appear" then return { type="wait_npc_appear", npc_id=0, timeout=30 }
    elseif t == "wait_npc_gone"   then return { type="wait_npc_gone",   npc_id=0, timeout=30 }
    elseif t == "loot_all"        then return { type="loot_all" }
    elseif t == "pickup_item"     then return { type="pickup_item",     item_id=0 }
    elseif t == "set_flag"        then return { type="set_flag",        flag_name="" }
    elseif t == "check_flag_skip" then return { type="check_flag_skip", flag_name="" }
    elseif t == "sleep"           then return { type="sleep",           ms=1000 }
    elseif t == "custom"          then return { type="custom",          code="" }
    end
    return { type=t }
end

--- Garante que um step tem o campo `actions` (migra formato antigo se necessário).
local function EnsureActions(step)
    if step.actions then return end
    step.actions = {}
    -- Migra campos antigos
    if step.has_coord and (step.cx or 0) ~= 0 then
        table.insert(step.actions, { type="walk", x=step.cx, y=step.cy, z=step.cz or 0, tol=5 })
    end
    if (step.npc or "") ~= "" then
        table.insert(step.actions, { type="talk_npc", name=step.npc, interact="Talk to" })
        table.insert(step.actions, { type="wait_dialog" })
    end
    if (step.object or "") ~= "" then
        table.insert(step.actions, { type="interact_obj", name=step.object, action="Use" })
        table.insert(step.actions, { type="wait_dialog" })
    end
    local dlg = {}
    for opt in ((step.dialog or ""):gmatch("[^\n]+")) do
        if opt:match("%S") then table.insert(dlg, opt) end
    end
    for _, opt in ipairs(dlg) do
        table.insert(step.actions, { type="select_text", text=opt })
    end
    if #dlg > 0 then
        table.insert(step.actions, { type="skip_dialogs" })
    end
end

-- ============================================================================
-- GUI: Cor por estado
-- ============================================================================
local function StatusColor(q)
    if q.automated then return 0.4, 0.8, 1.0, 1.0 end  -- azul = automatizado
    if q.complete   then return 0.3, 0.9, 0.3, 1.0 end  -- verde = feita
    return 0.85, 0.85, 0.85, 1.0                         -- branco = nao feita
end

local function StatusLabel(q)
    if q.automated then return "[AUTO]" end
    if q.complete   then return "[OK]  " end
    return "[ ]   "
end

local DIFF_COLORS = {
    ["Novice"]       = { 0.3, 0.9, 0.3, 1.0 },
    ["Intermediate"] = { 0.9, 0.9, 0.2, 1.0 },
    ["Experienced"]  = { 1.0, 0.6, 0.1, 1.0 },
    ["Master"]       = { 0.9, 0.3, 0.3, 1.0 },
    ["Grandmaster"]  = { 0.7, 0.3, 1.0, 1.0 },
    ["Special"]      = { 0.3, 0.9, 0.9, 1.0 },
}
local function DiffColor(diff)
    local c = diff and DIFF_COLORS[diff]
    return c and c[1] or 0.7, c and c[2] or 0.7, c and c[3] or 0.7, 1.0
end

-- ============================================================================
-- GUI: PAINEL ESQUERDO — Lista com busca e filtros
-- ============================================================================
local function DrawQuestList()
    -- Barra de busca
    ImGui.PushItemWidth(-1)
    local ch, nv = ImGui.InputText("##search", STATE.search_input)
    if ch then STATE.search_input = nv end
    ImGui.PopItemWidth()

    ImGui.Spacing()

    -- Filtros de status (radio-style via botões coloridos)
    local filters = {
        { key="all",     label="Todas"       },
        { key="done",    label="Feitas"      },
        { key="notdone", label="Nao feitas"  },
        { key="auto",    label="Automato"    },
    }
    for fi, f in ipairs(filters) do
        local is_active = (STATE.filter_status == f.key)
        if is_active then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.26, 0.59, 0.98, 1.0)
            STK.colors = STK.colors + 1
        end
        if ImGui.SmallButton(f.label .. "##ft" .. tostring(fi)) then
            STATE.filter_status = f.key
        end
        if is_active then
            ImGui.PopStyleColor(1)
            STK.colors = STK.colors - 1
        end
        if fi < #filters then ImGui.SameLine() end
    end

    ImGui.Spacing()

    -- Status do scan
    if not STATE.scan_done then
        ImGui.ProgressBar(STATE.scan_progress, -1, 12,
            string.format("Scan: %d/%d", STATE.scan_cursor, MAX_QUEST_ID))
    else
        local n_done = 0; local n_auto = 0; local n_not = 0
        for _, q in ipairs(STATE.all_quests) do
            if q.automated then n_auto = n_auto + 1
            elseif q.complete then n_done = n_done + 1
            else n_not = n_not + 1 end
        end
        ImGui.TextColored(0.5,0.5,0.5,1, string.format(
            "%d quests | %d feitas | %d auto | %d nao feitas",
            #STATE.all_quests, n_done, n_auto, n_not))
        ImGui.SameLine()
        if ImGui.SmallButton("Refresh##scan") then
            STATE.rescan_requested = true
        end
    end

    ImGui.Separator()
    ImGui.TextColored(0.5,0.5,0.5,1, tostring(#STATE.filtered) .. " resultado(s)")

    -- Lista scrollavel
    ImGui.BeginChild("QuestList", 0, 0, true)
    STK.child = true

    for _, q in ipairs(STATE.filtered) do
        local is_selected = (STATE.selected_name == q.name)
        local r, g, b, a  = StatusColor(q)
        local prefix = StatusLabel(q)
        ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
        STK.colors = STK.colors + 1
        if ImGui.Selectable(prefix .. q.name .. "##q" .. tostring(q.id), is_selected) then
            STATE.selected_name      = q.name
            STATE.selected_entry     = q
            STATE.selected_lib       = LIBRARY[q.name]
            STATE.quest_progress     = -1
            STATE.current_step       = nil
            STATE.quest_meta_loaded  = false
            STATE.quest_difficulty   = nil
            STATE.quest_members      = nil
            STATE.quest_points       = nil
            STATE.quest_varbit       = nil
            STATE.quest_start_coords = nil
            STATE.quest_req_quests   = nil
            STATE.quest_skill_reqs   = nil
            STATE.builder_recording    = false
            STATE.builder_steps        = {}
            STATE.builder_active        = 0
            STATE.builder_last_prog     = -1
            STATE.builder_action_sel    = 0
            STATE.builder_export_status = ""
            STATE.builder_import_status = ""
            STATE.builder_bolt_status   = ""
            STATE.quest_extra_data      = nil
            STATE.play_quest_module     = nil
            LoadBuilderSteps(q.name)
            LoadQuestExtraData(q.name)
        end
        ImGui.PopStyleColor(1)
        STK.colors = STK.colors - 1
    end

    ImGui.EndChild()
    STK.child = false
end

-- ============================================================================
-- GUI: BUILDER — helpers
-- ============================================================================
-- Sincroniza os campos de texto do step para STATE (chamado ao mudar de step).
local function SyncStepToEdit(s)
    STATE.builder_edit_label     = s and (s.label     or "") or ""
    STATE.builder_edit_lua_check = s and (s.lua_check or "") or ""
    STATE.builder_edit_notes     = s and (s.notes     or "") or ""
    STATE.builder_action_sel     = 0
    if s then EnsureActions(s) end
end

-- Grava os campos de texto de STATE de volta no step.
local function SyncEditToStep(s)
    if not s then return end
    s.label     = STATE.builder_edit_label
    s.lua_check = STATE.builder_edit_lua_check
    s.notes     = STATE.builder_edit_notes
end

-- ============================================================================
-- IMPORT: lê ficheiro gerado pelo QuestRecorder e popula builder_steps
-- ============================================================================
local function ImportRecording()
    if not STATE.selected_name then return "Sem quest selecionada" end

    local function slug(name)
        return name:gsub("[^%w%s%-_]", ""):gsub("%s+", "_"):lower()
    end
    local path = "c:/Users/marsu/MemoryError/Lua_Scripts/quests/recordings/" .. slug(STATE.selected_name) .. ".lua"

    local fn, err = loadfile(path)
    if not fn then
        return "Gravacao nao encontrada: recordings/" .. slug(STATE.selected_name) .. ".lua"
    end

    local ok, data = pcall(fn)
    if not ok or type(data) ~= "table" then
        return "Erro ao ler gravacao: " .. tostring(data)
    end

    local entries = data.entries
    if not entries or #entries == 0 then
        return "Gravacao vazia (0 entries)"
    end

    -- Garante que está a editar o step certo antes de importar
    if STATE.builder_active > 0 and STATE.builder_steps[STATE.builder_active] then
        SyncEditToStep(STATE.builder_steps[STATE.builder_active])
    end

    -- Atualiza varbit se disponível e ainda não temos
    if data.varbit and data.varbit > 0 and (not STATE.quest_varbit or STATE.quest_varbit == 0) then
        STATE.quest_varbit = data.varbit
    end

    local added, updated = 0, 0
    for _, e in ipairs(entries) do
        local prog = e.progress

        -- Lua_check automático
        local lua_check = ""
        if STATE.quest_varbit and STATE.quest_varbit > 0 then
            lua_check = "if API.GetVarbitValue(" .. tostring(STATE.quest_varbit) .. ") == " .. tostring(prog) .. " then"
        end

        -- Nota automática
        local notes = string.format("Capturado em (%d,%d,%d)", e.cx or 0, e.cy or 0, e.cz or 0)

        -- Verifica se já existe step com este progress
        local existing = nil
        for _, s in ipairs(STATE.builder_steps) do
            if s.progress == prog then existing = s; break end
        end

        if existing then
            EnsureActions(existing)
            -- Atualiza lua_check e notes se ainda estão vazios
            if (existing.lua_check or "") == "" and lua_check ~= "" then
                existing.lua_check = lua_check
            end
            if (existing.notes or "") == "" then existing.notes = notes end
            -- Adiciona walk se ainda não houver nenhum e temos coords
            local has_walk = false
            for _, a in ipairs(existing.actions) do if a.type == "walk" then has_walk = true end end
            if not has_walk and (e.cx or 0) ~= 0 then
                table.insert(existing.actions, 1, { type="walk", x=e.cx, y=e.cy, z=e.cz or 0, tol=5 })
            end
            -- Adiciona talk_npc se não há nenhum e temos npc
            local has_talk = false
            for _, a in ipairs(existing.actions) do if a.type == "talk_npc" then has_talk = true end end
            if not has_talk and (e.npc or "") ~= "" then
                table.insert(existing.actions, { type="talk_npc", name=e.npc, interact="Talk to" })
                table.insert(existing.actions, { type="wait_dialog" })
                table.insert(existing.actions, { type="skip_dialogs" })
            end
            updated = updated + 1
        else
            local init_actions = {}
            if (e.cx or 0) ~= 0 then
                table.insert(init_actions, { type="walk", x=e.cx, y=e.cy, z=e.cz or 0, tol=5 })
            end
            if (e.npc or "") ~= "" then
                table.insert(init_actions, { type="talk_npc", name=e.npc, interact="Talk to" })
                table.insert(init_actions, { type="wait_dialog" })
                table.insert(init_actions, { type="skip_dialogs" })
            end
            table.insert(STATE.builder_steps, {
                progress  = prog,
                label     = "Step " .. tostring(prog),
                lua_check = lua_check,
                notes     = notes,
                actions   = init_actions,
            })
            added = added + 1
        end
    end

    -- Ordena por progress
    table.sort(STATE.builder_steps, function(a, b) return a.progress < b.progress end)

    -- Seleciona o primeiro step importado
    if #STATE.builder_steps > 0 and STATE.builder_active == 0 then
        STATE.builder_active = 1
        SyncStepToEdit(STATE.builder_steps[1])
    end

    return string.format("Importado: +%d novos, %d atualizados (%d total)", added, updated, #STATE.builder_steps)
end

-- ============================================================================
-- BOLT IMPORT — converte ficheiros bolt-questhelper para steps do builder
-- bolt.x = RS3.x  |  bolt.z = RS3.y  |  bolt.y = altura raw (ignorar)
-- ============================================================================

local BOLT_QUESTS_PATH = "c:/Users/marsu/MemoryError/Lua_Scripts/bolt-questhelper-1.6.0/quests/"

local function boltSlug(name)
    return name:lower()
        :gsub("'", "")
        :gsub("[^%w%s%-]", "")
        :gsub("%s+", "-")
        :gsub("%-+", "-")
end

-- Carrega o ficheiro Bolt num sandbox e extrai metadados da quest:
-- neededItems, recommendedItems, questReqs, combatNPCs, steps[].text
function LoadBoltQuestInfo(qname)
    if not qname then return nil end
    local slug = boltSlug(qname)
    local path = BOLT_QUESTS_PATH .. slug .. ".lua"
    local f = io.open(path, "r")
    if not f then return nil end
    local code = f:read("*a")
    f:close()

    -- Stubs para as classes Bolt
    local captured = {}
    local function stub_fn() return {} end
    local function stub_new(...) return {} end
    local stub_mt = { __index = function(_, k) return setmetatable({new=stub_new}, {__call=stub_fn}) end }
    local fake_Quest = {
        new = function(self, data) captured = data or {}; return captured end
    }
    local fake_Types = {
        QuestReq = {
            skill            = function(name, lvl) return {name=name, level=lvl} end,
            ironmanOnlySkill = function(name, lvl) return {name=name, level=lvl, ironman=true} end,
        }
    }
    local fake_Enums = setmetatable({}, {__index=function(_,k)
        return setmetatable({},{__index=function(_,v) return v end})
    end})
    local fake_require = function(mod)
        if mod == "core.quest"      then return fake_Quest end
        if mod == "core.types"      then return fake_Types end
        if mod == "core.enums"      then return fake_Enums end
        return setmetatable({}, stub_mt)
    end
    local env = setmetatable({
        require = fake_require,
        Quest   = fake_Quest,
        Types   = fake_Types,
        Enums   = fake_Enums,
        Model   = setmetatable({},{__index=function(_,k) return setmetatable({},{__call=stub_fn,__index=function(_,k2) return stub_fn end}) end}),
        Vertex  = setmetatable({},{__call=stub_fn}),
        Models  = setmetatable({},{__index=function(_,k) return setmetatable({},{__index=function() return {} end}) end}),
        Action  = setmetatable({},{__index=function(_,k) return {new=stub_new} end}),
        Condition=setmetatable({},{__index=function(_,k) return {new=stub_new} end}),
        ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
        math=math, table=table, string=string, type=type, pcall=pcall,
    }, {__index=function(_,k) return nil end})

    local fn, err = load(code, "@bolt/"..slug, "t", env)
    if not fn then return nil end
    local ok = pcall(fn)
    if not ok or type(captured) ~= "table" then return nil end

    -- Normalizar para o formato do QuestData
    local result = { _from_bolt = true }

    -- neededItems: { ["Item"] = {quantity=N} } → required_items
    if type(captured.neededItems) == "table" then
        result.required_items = {}
        for name, v in pairs(captured.neededItems) do
            if type(name) == "string" then
                local qty = type(v) == "table" and (v.quantity or 1) or 1
                table.insert(result.required_items, { name=name, amount=qty })
            end
        end
        table.sort(result.required_items, function(a,b) return a.name < b.name end)
    end

    -- recommendedItems → recommended_items
    if type(captured.recommendedItems) == "table" then
        result.recommended_items = {}
        for name, v in pairs(captured.recommendedItems) do
            if type(name) == "string" then
                local qty = type(v) == "table" and (v.quantity or 1) or 1
                table.insert(result.recommended_items, { name=name, amount=qty })
            end
        end
        table.sort(result.recommended_items, function(a,b) return a.name < b.name end)
    end

    -- questReqs (skills) → notes sobre skills (já mostrados da API, mas por completude)
    if type(captured.questReqs) == "table" and #captured.questReqs > 0 then
        result.skill_reqs = {}
        for _, req in ipairs(captured.questReqs) do
            if req.name and req.level then
                table.insert(result.skill_reqs, req.name .. " " .. req.level)
            end
        end
    end

    -- combatNPCs → notes
    if type(captured.combatNPCs) == "table" then
        result.combat_npcs = {}
        for name, v in pairs(captured.combatNPCs) do
            if type(name) == "string" then
                local lvl = type(v) == "table" and v.level or "?"
                local opt = type(v) == "table" and v.optional and " (opcional)" or ""
                table.insert(result.combat_npcs, name .. " (lv " .. tostring(lvl) .. ")" .. opt)
            end
        end
    end

    -- steps[].text → walkthrough
    if type(captured.steps) == "table" and #captured.steps > 0 then
        result.walkthrough = {}
        for i, step in ipairs(captured.steps) do
            local title = type(step.title) == "string" and step.title or nil
            local text  = type(step.text)  == "string" and step.text  or nil
            if title then table.insert(result.walkthrough, "=== " .. title .. " ===") end
            if text then
                -- strip HTML básico
                text = text:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&")
                text = text:gsub("^%s+",""):gsub("%s+$","")
                if text ~= "" then table.insert(result.walkthrough, text) end
            end
            -- itens do step
            if type(step.neededItems) == "table" then
                local items = {}
                for n, v in pairs(step.neededItems) do
                    if type(n) == "string" then
                        table.insert(items, n .. (type(v)=="table" and v.quantity and v.quantity>1 and " x"..v.quantity or ""))
                    end
                end
                if #items > 0 then
                    table.insert(result.walkthrough, "  Itens: " .. table.concat(items, ", "))
                end
            end
            if title or text then table.insert(result.walkthrough, "") end
        end
    end

    -- metadata
    result.members  = captured.members
    result.length   = type(captured.length) == "string" and captured.length or nil
    result.prereqs  = type(captured.prereqQuests) == "table" and captured.prereqQuests or nil

    return result
end

-- Extrai blocos de depth-2 da tabela `local steps = {...}`.
-- Lida corretamente com strings, comentários e blocos aninhados.
local function extractBoltStepBlocks(content)
    local blocks = {}
    local steps_pos = content:find("local%s+steps%s*=")
    if not steps_pos then return blocks end
    local array_open = content:find("{", steps_pos)
    if not array_open then return blocks end

    local pos = array_open + 1
    local depth = 1
    local block_start = nil
    local len = #content

    while pos <= len do
        local ch = content:sub(pos, pos)
        -- comentário de linha
        if ch == "-" and content:sub(pos, pos+1) == "--" then
            local eol = content:find("\n", pos+2)
            pos = eol and (eol+1) or (len+1)
        -- string com aspas simples ou duplas
        elseif ch == '"' or ch == "'" then
            local q = ch; pos = pos + 1
            while pos <= len do
                local sc = content:sub(pos, pos)
                if     sc == "\\" then pos = pos + 2
                elseif sc == q    then break
                else                   pos = pos + 1 end
            end
            pos = pos + 1
        -- long string [[ ]]
        elseif ch == "[" and content:sub(pos, pos+1) == "[[" then
            local e = content:find("]]", pos+2)
            pos = e and (e+3) or (len+1)
        elseif ch == "{" then
            depth = depth + 1
            if depth == 2 then block_start = pos end
            pos = pos + 1
        elseif ch == "}" then
            if depth == 2 and block_start then
                table.insert(blocks, content:sub(block_start, pos))
                block_start = nil
            end
            depth = depth - 1
            if depth == 0 then break end
            pos = pos + 1
        else
            pos = pos + 1
        end
    end
    return blocks
end

-- Padrões de texto bolt que indicam "falar com NPC X": extrai nome do NPC
local function extractNPCFromBoltText(text)
    if not text then return nil end
    -- "talk to Dr Nabanik", "speak to Cook", "talk to Father Aereck"
    local npc = text:match("[Tt]alk%s+to%s+([A-Z][%w%s'%-]+[%w'])")
              or text:match("[Ss]peak%s+to%s+([A-Z][%w%s'%-]+[%w'])")
              or text:match("[Rr]eturn%s+to%s+([A-Z][%w%s'%-]+[%w'])")
              or text:match("[Rr]eport%s+to%s+([A-Z][%w%s'%-]+[%w'])")
    if npc then
        -- limita a 3 palavras para evitar apanhar frases longas
        local words = {}
        for w in npc:gmatch("%S+") do
            table.insert(words, w)
            if #words >= 3 then break end
        end
        npc = table.concat(words, " ")
        -- remove pontuação final
        npc = npc:gsub("[%.,%?!]+$", "")
    end
    return npc
end

local function parseBoltBlock(block, idx)
    local title = block:match('title%s*=%s*"([^"]*)"')
    local text  = block:match('text%s*=%s*"([^"]*)"')
    if text then
        text = text:gsub("<[^>]+>", ""):gsub("&lt;","<"):gsub("&gt;",">")
        if #text > 120 then text = text:sub(1,120).."..." end
    end
    local label = title or (text and text:sub(1,55)) or ("Bolt Step "..idx)
    local notes = text or ""
    local actions = {}

    -- Action.Direction:new(bolt_x, bolt_height, bolt_z) → smart_walk(RS3.x, RS3.y)
    local bx, bz = block:match("Action%.Direction:new%(([%d%.%-]+),%s*[%d%.%-]+,%s*([%d%.%-]+)")
    if bx then
        table.insert(actions, {
            type="smart_walk",
            x=math.floor(tonumber(bx)+0.5),
            y=math.floor(tonumber(bz)+0.5),
            z=0, tol=5
        })
    end

    -- ConversationHighlight → select_text
    local has_conv = false
    for opt in block:gmatch('ConversationHighlight:new%("([^"]+)"') do
        table.insert(actions, {type="select_text", text=opt})
        has_conv = true
    end
    if has_conv then table.insert(actions, {type="skip_dialogs"}) end

    -- QuestStarted → accept_quest (sobrescreve opções de dialogo)
    if block:find("QuestStarted:new") then
        for i = #actions, 1, -1 do
            if actions[i].type == "select_text" or actions[i].type == "skip_dialogs" then
                table.remove(actions, i)
            end
        end
        table.insert(actions, {type="accept_quest"})
    end

    -- Se o texto menciona "talk to NPC" e não havia ConversationHighlight, gera talk_npc
    if not has_conv and not block:find("QuestStarted:new") then
        local npc = extractNPCFromBoltText(text or title)
        if npc then
            table.insert(actions, {type="talk_npc", name=npc, interact="Talk to"})
            table.insert(actions, {type="wait_dialog"})
            table.insert(actions, {type="skip_dialogs"})
        end
    end

    -- Fallback: se não tinha Direction, usa DistanceTo como destino de smart_walk
    if not bx then
        local cx, cz = block:match("DistanceTo:new%(([%d%.%-]+),%s*[%d%.%-]+,%s*([%d%.%-]+)")
        if cx then
            table.insert(actions, 1, {
                type="smart_walk",
                x=math.floor(tonumber(cx)+0.5),
                y=math.floor(tonumber(cz)+0.5),
                z=0, tol=8
            })
        end
    end

    return { label=label, notes=notes, actions=actions }
end

local function ImportFromBolt()
    if not STATE.selected_name then return "Sem quest selecionada" end

    local slug = boltSlug(STATE.selected_name)
    local path = BOLT_QUESTS_PATH .. slug .. ".lua"
    local f = io.open(path, "r")
    if not f then
        return "Bolt: não encontrado — " .. slug .. ".lua"
    end
    local content = f:read("*a"); f:close()

    if STATE.builder_active > 0 and STATE.builder_steps[STATE.builder_active] then
        SyncEditToStep(STATE.builder_steps[STATE.builder_active])
    end

    local blocks = extractBoltStepBlocks(content)
    if #blocks == 0 then
        return "Bolt: sem steps encontrados em " .. slug .. ".lua"
    end

    -- Começa progress a seguir ao último step existente
    local base_prog = 0
    if #STATE.builder_steps > 0 then
        base_prog = (STATE.builder_steps[#STATE.builder_steps].progress or 0) + 1
    end

    local added = 0
    for i, block in ipairs(blocks) do
        local p    = parseBoltBlock(block, i)
        local prog = base_prog + (i - 1)
        local exists = false
        for _, s in ipairs(STATE.builder_steps) do
            if s.progress == prog then exists = true; break end
        end
        if not exists then
            table.insert(STATE.builder_steps, {
                progress=prog, label=p.label,
                lua_check="", notes=p.notes, actions=p.actions,
            })
            added = added + 1
        end
    end

    table.sort(STATE.builder_steps, function(a,b) return a.progress < b.progress end)

    if added > 0 then
        for i, s in ipairs(STATE.builder_steps) do
            if s.progress == base_prog then
                STATE.builder_active = i; SyncStepToEdit(s); break
            end
        end
    end

    return string.format("Bolt: %d steps de %d blocos (%s)", added, #blocks, slug..".lua")
end

local function ExportQuestScript()
    if not STATE.selected_name       then return "Sem quest selecionada" end
    if #STATE.builder_steps == 0     then return "Sem steps definidos"   end
    local qname = STATE.selected_name
    local L, lines = nil, {}
    L = function(s) table.insert(lines, s) end

    L("--- Quest Script: " .. qname)
    L("--- Gerado pelo Nexus Quest Builder")
    L("")
    L('local API        = require("api")')
    L('local QUEST      = require("quests.quest")')
    L('local LODESTONES = require("Lodestones")')
    L('local QS         = require("quests.QuestScript")')
    L("")
    L("local qs = QS.new({")
    L('    name  = "' .. qname .. '",')
    L("    debug = true,")
    L("})")
    L("")
    L("-- IDs (preencher conforme necessário)")
    L("local ITEM = {}")
    L("local OBJ  = {}")
    L("")
    L("-- smartWalk: teleporta para a lodestone mais próxima do destino se valer a pena")
    L("local _SW_LODES = {")
    L("    {n='AL_KHARID',x=3297,y=3184},{n='ARDOUGNE',x=2634,y=3348},")
    L("    {n='BANDIT_CAMP',x=2899,y=3544},{n='BURTHOPE',x=2899,y=3544},")
    L("    {n='CANIFIS',x=3517,y=3515},{n='CATHERBY',x=2811,y=3449},")
    L("    {n='DRAYNOR_VILLAGE',x=3105,y=3298},{n='EAGLES_PEAK',x=2366,y=3479},")
    L("    {n='EDGEVILLE',x=3067,y=3505},{n='FALADOR',x=2967,y=3403},")
    L("    {n='FORT_FORINTHRY',x=3298,y=3525},{n='FREMENNIK_PROVINCE',x=2712,y=3677},")
    L("    {n='KARAMJA',x=2761,y=3147},{n='LUMBRIDGE',x=3233,y=3221},")
    L("    {n='MENAPHOS',x=3216,y=2716},{n='OOGLOG',x=2532,y=2871},")
    L("    {n='PORT_SARIM',x=3011,y=3215},{n='PRIFDDINAS',x=2208,y=3360},")
    L("    {n='SEERS_VILLAGE',x=2689,y=3482},{n='TAVERLEY',x=2878,y=3442},")
    L("    {n='TIRANNWN',x=2254,y=3149},{n='VARROCK',x=3214,y=3376},")
    L("    {n='YANILLE',x=2560,y=3094},")
    L("}")
    L("local function smartWalk(dx, dy, dz, tol)")
    L("    local p = API.PlayerCoord()")
    L("    local d2dest = math.sqrt((p.x-dx)^2+(p.y-dy)^2)")
    L("    local bestL, bestD = nil, math.huge")
    L("    for _, l in ipairs(_SW_LODES) do")
    L("        local d = math.sqrt((l.x-dx)^2+(l.y-dy)^2)")
    L("        if d < bestD then bestD=d; bestL=l end")
    L("    end")
    L("    if bestL and bestD < d2dest then")
    L("        API.logInfo('[QUEST] Smart Walk: lode '..bestL.n..' (d2dest='..math.floor(bestD)..' < player='..math.floor(d2dest)..')')")
    L("        LODESTONES[bestL.n].Teleport()")
    L("        API.RandomSleep2(2000, 500, 500)")
    L("    end")
    L("    qs:moveTo(dx, dy, dz or 0, tol or 5)")
    L("end")
    L("")

    for _, step in ipairs(STATE.builder_steps) do
        EnsureActions(step)
        -- Comentários de cabeçalho
        L("-- Step " .. tostring(step.progress) .. ": " .. (step.label or ""))
        if (step.lua_check or "") ~= "" then
            L("-- State_Trigger: " .. step.lua_check)
        end
        if (step.notes or "") ~= "" then
            for note_line in step.notes:gmatch("[^\n]+") do
                if note_line:match("%S") then L("-- Nota: " .. note_line) end
            end
        end
        L('qs:step(' .. tostring(step.progress) .. ', "' .. (step.label or "") .. '", function()')
        for _, a in ipairs(step.actions) do
            for _, line in ipairs(ActionToCode(a)) do L(line) end
        end
        L("end)")
        L("")
    end

    L("qs:onComplete(function()")
    L('    API.logInfo("[QUEST] ' .. qname .. ' concluida!")')
    L("    API.Write_LoopyLoop(false)")
    L("end)")
    L("")
    L("API.Write_fake_mouse_do(false)")
    L("API.SetMaxIdleTime(10)")
    L("")
    L("qs:run()")
    L("")

    local content = table.concat(lines, "\n")
    local fname = qname:gsub("[^%w%s%-_]", ""):gsub("%s+", "_"):lower()
    local path = "c:/Users/marsu/MemoryError/Lua_Scripts/quests/" .. fname .. ".lua"
    local f = io.open(path, "w")
    if not f then return "Erro ao abrir: " .. path end
    f:write(content)
    f:close()
    SaveBuilderSteps()
    return "Exportado: quests/" .. fname .. ".lua"
end

BUILDER_SAVE_DIR = "c:/Users/marsu/MemoryError/Lua_Scripts/quests/"

function BuilderSlug(qname)
    return (qname or ""):gsub("[^%w%s%-_]", ""):gsub("%s+", "_"):lower()
end

function SaveBuilderSteps()
    if not STATE.selected_name or #STATE.builder_steps == 0 then return end
    local path = BUILDER_SAVE_DIR .. BuilderSlug(STATE.selected_name) .. "_builder.json"
    local ok, encoded = pcall(API.JsonEncode, STATE.builder_steps)
    if not ok or type(encoded) ~= "string" then return end
    local f = io.open(path, "w")
    if not f then return end
    f:write(encoded)
    f:close()
end

function QuestPascal(qname)
    return (qname or ""):gsub("[^%w%s]",""):gsub("(%a+)", function(w) return w:sub(1,1):upper()..w:sub(2) end):gsub("%s+","")
end

function LoadQuestExtraData(qname)
    STATE.quest_extra_data = nil
    if not qname then return end
    local mod = "quests.QuestData." .. QuestPascal(qname)
    package.loaded[mod] = nil
    local ok, data = pcall(require, mod)
    if ok and type(data) == "table" then
        STATE.quest_extra_data = data
    else
        -- fallback: tentar dados do Bolt
        STATE.quest_extra_data = LoadBoltQuestInfo(qname)
    end
end

function LoadBuilderSteps(qname)
    if not qname then return end
    local slug = BuilderSlug(qname)
    local path = BUILDER_SAVE_DIR .. slug .. "_builder.json"
    local f = io.open(path, "r")
    if not f then
        -- tentar também com pascal case
        path = BUILDER_SAVE_DIR .. QuestPascal(qname) .. "_builder.json"
        f = io.open(path, "r")
    end
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end
    local ok, data = pcall(API.JsonDecode, raw)
    if not ok or type(data) ~= "table" then return end
    for _, step in ipairs(data) do
        if step.actions then
            for _, a in ipairs(step.actions) do
                if a.use_id == nil then a.use_id = false end
            end
        end
    end
    STATE.builder_steps = data
end

-- ============================================================================
-- GUI: BUILDER — painel principal
-- ============================================================================
-- ============================================================================
-- PATH RECORDER
-- ============================================================================

local PATH_REC_LODES = {
    { name="Al Kharid",            x=3297, y=3184 },
    { name="Ardougne",             x=2634, y=3348 },
    { name="Bandit Camp",          x=3218, y=2993 },
    { name="Burthorpe",            x=2899, y=3544 },
    { name="Catherby",             x=2809, y=3451 },
    { name="Draynor Village",      x=3105, y=3298 },
    { name="Eagles Peak",          x=2328, y=3499 },
    { name="Edgeville",            x=3067, y=3506 },
    { name="Falador",              x=2967, y=3403 },
    { name="Fremennik Province",   x=2712, y=3677 },
    { name="Karamja",              x=2761, y=3147 },
    { name="Lumbridge",            x=3233, y=3221 },
    { name="Lunar Isle",           x=2085, y=3913 },
    { name="Menaphos",             x=3211, y=2694 },
    { name="Oo'glog",              x=2530, y=2871 },
    { name="Ourania",              x=2469, y=3244 },
    { name="Port Sarim",           x=3011, y=3216 },
    { name="Seers Village",        x=2690, y=3482 },
    { name="Taverley",             x=2895, y=3443 },
    { name="Tirannwn",             x=2254, y=3148 },
    { name="Varrock",              x=3214, y=3376 },
    { name="Void Knights Outpost", x=2640, y=2676 },
    { name="Yanille",              x=2529, y=3094 },
}

local function PathRec_NearestLodestone(px, py, threshold)
    threshold = threshold or 15
    local best, bestd = nil, math.huge
    for _, lode in ipairs(PATH_REC_LODES) do
        local d = math.sqrt((px-lode.x)^2 + (py-lode.y)^2)
        if d < bestd then bestd = d; best = lode end
    end
    if best and bestd <= threshold then return best.name end
    return nil
end

local function PathRec_NearestObject(px, py, maxdist)
    maxdist = maxdist or 10
    local ok, objs = pcall(API.ReadAllObjectsArray, {0}, {-1}, {})
    if not ok or not objs then return nil end
    local best, bestd = nil, maxdist
    for _, o in ipairs(objs) do
        local ox = o.CalcX or o.x or 0
        local oy = o.CalcY or o.y or 0
        local d = math.sqrt((ox-px)^2 + (oy-py)^2)
        if d < bestd and o.Name and o.Name ~= "" and o.Action and o.Action ~= "" then
            bestd = d; best = o
        end
    end
    return best
end

local function PathRec_NearestNPC(px, py, maxdist)
    maxdist = maxdist or 10
    local ok, npcs = pcall(API.ReadAllObjectsArray, {1}, {-1}, {})
    if not ok or not npcs then return nil end
    local best, bestd = nil, maxdist
    for _, n in ipairs(npcs) do
        local nx = n.CalcX or n.x or 0
        local ny = n.CalcY or n.y or 0
        local d = math.sqrt((nx-px)^2 + (ny-py)^2)
        if d < bestd and n.Name and n.Name ~= "" then
            bestd = d; best = n
        end
    end
    return best
end

local function PathRec_CommitActions()
    local steps = STATE.builder_steps
    local idx   = (STATE.path_rec_step_idx > 0) and STATE.path_rec_step_idx or STATE.builder_active
    local step  = (idx > 0) and steps[idx] or nil
    if not step then
        -- criar step novo se não há nenhum seleccionado
        local prog = math.max(0, STATE.quest_progress >= 0 and STATE.quest_progress or #steps)
        step = { progress=prog, label="Path "..tostring(prog), lua_check="", notes="", actions={} }
        table.insert(steps, step)
        table.sort(steps, function(a,b) return a.progress < b.progress end)
        for i, s in ipairs(steps) do
            if s == step then STATE.builder_active = i; SyncStepToEdit(s); break end
        end
    end
    EnsureActions(step)
    for _, a in ipairs(STATE.path_rec_actions) do
        table.insert(step.actions, a)
    end
end

local function TickPathRecorder()
    if not STATE.path_rec_active then return end

    local ok, pos = pcall(API.PlayerCoord)
    if not ok or not pos or (pos.x == 0 and pos.y == 0) then return end

    local px, py, pz = pos.x, pos.y, pos.z

    -- Primeira posição — apenas inicializar
    if not STATE.path_rec_raw_pos then
        STATE.path_rec_raw_pos  = {x=px, y=py, z=pz}
        STATE.path_rec_last_pos = {x=px, y=py, z=pz}
        STATE.path_rec_status   = string.format("Gravando… pos:(%d,%d)", px, py)
        return
    end

    local lp   = STATE.path_rec_last_pos
    local raw  = STATE.path_rec_raw_pos
    local jump = math.sqrt((px-raw.x)^2 + (py-raw.y)^2)

    STATE.path_rec_raw_pos = {x=px, y=py, z=pz}

    if jump > 60 then
        -- Teleporte — verificar lodestone
        local lname = PathRec_NearestLodestone(px, py, 20)
        if lname then
            table.insert(STATE.path_rec_actions, { type="teleport", lodestone=lname:upper():gsub(" ","_") })
        else
            table.insert(STATE.path_rec_actions, { type="sleep", ms=2000 })
        end
        table.insert(STATE.path_rec_actions, { type="walk", x=px, y=py, z=pz, tol=5 })
        STATE.path_rec_last_pos = {x=px, y=py, z=pz}
        STATE.path_rec_status = string.format("Teleporte→(%d,%d) | %d acoes", px, py, #STATE.path_rec_actions)

    elseif jump > 8 and jump <= 60 then
        -- Salto médio — porta/escada/ladder; inserir walk (user pode trocar por interact)
        table.insert(STATE.path_rec_actions, { type="walk", x=px, y=py, z=pz, tol=5 })
        STATE.path_rec_last_pos = {x=px, y=py, z=pz}
        STATE.path_rec_status = string.format("Salto(%d t)→(%d,%d) | %d acoes", math.floor(jump), px, py, #STATE.path_rec_actions)

    else
        -- Movimento normal — só regista quando afasta suficiente do último waypoint
        local fromLast = math.sqrt((px-lp.x)^2 + (py-lp.y)^2)
        if fromLast >= STATE.path_rec_min_dist then
            table.insert(STATE.path_rec_actions, { type="walk", x=px, y=py, z=pz, tol=5 })
            STATE.path_rec_last_pos = {x=px, y=py, z=pz}
            STATE.path_rec_status = string.format("(%d,%d) | %d acoes", px, py, #STATE.path_rec_actions)
        end
    end
end

local function DrawQuestBuilder()
    if not STATE.selected_name then
        ImGui.TextColored(0.5,0.5,0.5,1, "Seleciona uma quest na lista.")
        return
    end

    local steps = STATE.builder_steps

    -- ---- Toolbar ----
    if STATE.builder_recording then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.65, 0.15, 0.15, 1.0)
        STK.colors = STK.colors + 1
        if ImGui.Button("[ ] Parar Gravacao##rec", 170, 22) then
            STATE.builder_recording = false
        end
        ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
        ImGui.SameLine()
        ImGui.TextColored(1.0,0.3,0.3,1, "REC")
        ImGui.SameLine()
        ImGui.TextColored(0.6,0.6,0.6,1, "progress: " .. tostring(STATE.quest_progress))
    else
        if ImGui.Button("Gravar Steps##rec", 140, 22) then
            STATE.builder_recording = true
            STATE.builder_last_prog = STATE.quest_progress
        end
    end
    ImGui.SameLine()
    if ImGui.Button("+ Step##addman", 70, 22) then
        local prog = STATE.quest_progress >= 0 and STATE.quest_progress or #steps
        local already = false
        for _, s in ipairs(steps) do if s.progress == prog then already = true end end
        if not already then
            -- guardar edits antes de mudar
            if STATE.builder_active > 0 and steps[STATE.builder_active] then
                SyncEditToStep(steps[STATE.builder_active])
            end
            table.insert(steps, {
                progress=prog, label="Step "..tostring(prog),
                lua_check="", notes="", actions={}
            })
            table.sort(steps, function(a,b) return a.progress < b.progress end)
            for i, s in ipairs(steps) do
                if s.progress == prog then STATE.builder_active = i; SyncStepToEdit(s); break end
            end
            SaveBuilderSteps()
        end
    end
    ImGui.SameLine()
    if ImGui.Button("Importar Gravacao##imp", 150, 22) then
        if STATE.builder_active > 0 and steps[STATE.builder_active] then
            SyncEditToStep(steps[STATE.builder_active])
        end
        STATE.builder_import_status = ImportRecording()
        STATE.builder_export_status = ""
        STATE.builder_bolt_status   = ""
        SaveBuilderSteps()
    end
    ImGui.SameLine()
    if ImGui.Button("Importar Bolt##blt", 120, 22) then
        if STATE.builder_active > 0 and steps[STATE.builder_active] then
            SyncEditToStep(steps[STATE.builder_active])
        end
        STATE.builder_bolt_status   = ImportFromBolt()
        STATE.builder_import_status = ""
        STATE.builder_export_status = ""
        SaveBuilderSteps()
    end
    ImGui.SameLine()
    if ImGui.Button("Guardar##save", 80, 22) then
        if STATE.builder_active > 0 and steps[STATE.builder_active] then
            SyncEditToStep(steps[STATE.builder_active])
        end
        SaveBuilderSteps()
        STATE.builder_export_status = "Steps guardados."
    end
    ImGui.SameLine()
    if ImGui.Button("Exportar Lua##exp", 110, 22) then
        if STATE.builder_active > 0 and steps[STATE.builder_active] then
            SyncEditToStep(steps[STATE.builder_active])
        end
        STATE.builder_export_status = ExportQuestScript()
        STATE.builder_import_status = ""
    end
    ImGui.SameLine()
    -- ---- Botão Correr Step / Parar Queue ----
    if #STATE.action_queue > 0 then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.60, 0.18, 0.10, 1.0)
        STK.colors = STK.colors + 1
        if ImGui.Button("■ Parar##qstop", 75, 22) then
            STATE.action_queue      = {}
            STATE.action_queue_wait = 0
        end
        ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
        ImGui.SameLine()
        ImGui.TextColored(1, 0.55, 0.1, 1, string.format("▶ %d ac. rest.", #STATE.action_queue))
    else
        local run_step = (STATE.builder_active > 0) and steps[STATE.builder_active]
        if run_step then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.10, 0.55, 0.20, 1.0)
            STK.colors = STK.colors + 1
            if ImGui.Button("Correr Step##rune", 100, 22) then
                SyncEditToStep(run_step)
                EnsureActions(run_step)
                STATE.action_queue      = {}
                STATE.action_queue_wait = 0
                for _, ac in ipairs(run_step.actions) do
                    table.insert(STATE.action_queue, ac)
                end
            end
            ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
        end
    end

    -- ---- Path Recorder toolbar ----
    ImGui.Spacing()
    if STATE.path_rec_active then
        -- Botão PARAR (vermelho)
        ImGui.PushStyleColor(ImGuiCol.Button, 0.65, 0.12, 0.12, 1.0)
        STK.colors = STK.colors + 1
        if ImGui.Button("■ Parar Path##prstop", 110, 22) then
            PathRec_CommitActions()
            STATE.path_rec_active   = false
            STATE.path_rec_actions  = {}
            STATE.path_rec_last_pos = nil
            STATE.path_rec_raw_pos  = nil
            STATE.path_rec_status   = string.format("Path inserido (%d acoes)", #(STATE.builder_steps[STATE.builder_active] and STATE.builder_steps[STATE.builder_active].actions or {}))
        end
        ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
        ImGui.SameLine()
        -- Botão + Interact
        if ImGui.Button("+Obj##pri", 50, 22) then
            local p = STATE.path_rec_raw_pos
            if p then
                local obj = PathRec_NearestObject(p.x, p.y, 12)
                local nm  = obj and obj.Name  or ""
                local ac  = obj and obj.Action or "Use"
                table.insert(STATE.path_rec_actions, { type="interact_obj", name=nm, action=ac, dist=8 })
                STATE.path_rec_status = string.format("+Interact '%s' '%s'", nm, ac)
            end
        end
        ImGui.SameLine()
        -- Botão + NPC
        if ImGui.Button("+NPC##prn", 50, 22) then
            local p = STATE.path_rec_raw_pos
            if p then
                local npc = PathRec_NearestNPC(p.x, p.y, 12)
                local nm  = npc and npc.Name or ""
                table.insert(STATE.path_rec_actions, { type="talk_npc", name=nm, interact="Talk to" })
                table.insert(STATE.path_rec_actions, { type="wait_dialog", timeout=10 })
                STATE.path_rec_status = string.format("+NPC '%s'", nm)
            end
        end
        ImGui.SameLine()
        -- Botão + Lodestone (usa posição actual)
        if ImGui.Button("+Lode##prl", 52, 22) then
            local p = STATE.path_rec_raw_pos
            if p then
                local lname = PathRec_NearestLodestone(p.x, p.y, 30) or "AL_KHARID"
                table.insert(STATE.path_rec_actions, { type="teleport", lodestone=lname:upper():gsub(" ","_") })
                STATE.path_rec_status = string.format("+Lodestone '%s'", lname)
            end
        end
        ImGui.SameLine()
        -- Botão desfazer último
        if ImGui.Button("<-##prundo", 30, 22) then
            if #STATE.path_rec_actions > 0 then
                table.remove(STATE.path_rec_actions)
                STATE.path_rec_status = string.format("Desfeito | %d acoes", #STATE.path_rec_actions)
            end
        end
        ImGui.SameLine()
        ImGui.TextColored(1.0, 0.35, 0.35, 1, "●REC")
        ImGui.SameLine()
        ImGui.TextColored(0.8, 0.8, 0.5, 1, STATE.path_rec_status)
    else
        ImGui.PushStyleColor(ImGuiCol.Button, 0.12, 0.50, 0.30, 1.0)
        STK.colors = STK.colors + 1
        if ImGui.Button("Gravar Path##prstart", 110, 22) then
            STATE.path_rec_active   = true
            STATE.path_rec_actions  = {}
            STATE.path_rec_last_pos = nil
            STATE.path_rec_raw_pos  = nil
            STATE.path_rec_step_idx = STATE.builder_active
            STATE.path_rec_status   = "Iniciando…"
            STATE.builder_export_status = ""
            STATE.builder_import_status = ""
            STATE.builder_bolt_status   = ""
        end
        ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
        ImGui.SameLine()
        ImGui.TextColored(0.5,0.5,0.5,1, "Anda o caminho, usa +Obj/+NPC p/ interacoes")
        if STATE.path_rec_status ~= "" and not STATE.path_rec_active then
            ImGui.SameLine()
            ImGui.TextColored(0.4,1,0.7,1, STATE.path_rec_status)
        end
    end

    -- Feedback de import/export/bolt (uma linha abaixo da toolbar)
    if STATE.builder_import_status ~= "" then
        local is_err = STATE.builder_import_status:find("nao encontrada") or STATE.builder_import_status:find("Erro")
        if is_err then ImGui.TextColored(1,0.4,0.4,1, STATE.builder_import_status)
        else          ImGui.TextColored(0.4,1,0.8,1, STATE.builder_import_status) end
    elseif STATE.builder_bolt_status ~= "" then
        local is_err = STATE.builder_bolt_status:find("nao encontrado") or STATE.builder_bolt_status:find("sem steps")
        if is_err then ImGui.TextColored(1,0.4,0.4,1, STATE.builder_bolt_status)
        else          ImGui.TextColored(0.4,0.9,1.0,1, STATE.builder_bolt_status) end
    elseif STATE.builder_export_status ~= "" then
        local is_err = STATE.builder_export_status:find("Erro")
        if is_err then ImGui.TextColored(1,0.4,0.4,1, STATE.builder_export_status)
        else           ImGui.TextColored(0.4,1,0.4,1, STATE.builder_export_status) end
    end

    -- ---- Badge de progresso live ----
    if STATE.selected_name then
        local prog = STATE.quest_progress
        if prog >= 0 then
            if STATE.quest_complete then
                ImGui.TextColored(0.2,1.0,0.3,1, "COMPLETA")
            else
                ImGui.TextColored(0.4,0.85,1.0,1, "Prog jogo: " .. tostring(prog))
            end
            -- Historial das últimas mudanças
            if #STATE.prog_log > 1 then
                ImGui.SameLine()
                local parts = {}
                for i = math.min(6, #STATE.prog_log), 1, -1 do
                    table.insert(parts, tostring(STATE.prog_log[i].progress))
                end
                ImGui.TextColored(0.45,0.45,0.45,1, " [" .. table.concat(parts, "→") .. "]")
            end
        end
        ImGui.SameLine()
        local fc, fv = ImGui.Checkbox("Auto-seguir##follow", STATE.builder_follow)
        if fc then STATE.builder_follow = fv end
    end

    ImGui.Separator()

    -- ---- Dois painéis: lista de steps (esq) + editor (dir) ----
    ImGui.BeginChild("##bsteplist", 185, 0, true)
    STK.child = true
    if #steps == 0 then
        ImGui.TextColored(0.5,0.5,0.5,1, "Sem steps.\nUsa Gravar\nou + Step.")
    else
        for i, s in ipairs(steps) do
            local is_cur      = (STATE.builder_active == i)
            local is_game_pos = (STATE.quest_progress >= 0 and s.progress == STATE.quest_progress)
            local prefix = is_game_pos and ">> " or "   "
            local lbl = string.format("%s[%d] %s##bs%d",
                prefix, s.progress, (s.label or ""):sub(1,18), i)
            if is_cur then
                ImGui.PushStyleColor(ImGuiCol.Header, 0.26,0.59,0.98,0.6)
                STK.colors = STK.colors + 1
            elseif is_game_pos then
                ImGui.PushStyleColor(ImGuiCol.Header, 0.80,0.50,0.05,0.55)
                STK.colors = STK.colors + 1
            end
            if ImGui.Selectable(lbl, is_cur or is_game_pos) then
                if STATE.builder_active ~= i then
                    if STATE.builder_active > 0 and steps[STATE.builder_active] then
                        SyncEditToStep(steps[STATE.builder_active])
                    end
                    STATE.builder_active = i
                    SyncStepToEdit(s)
                end
            end
            if is_cur or is_game_pos then
                ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
            end
        end
    end
    ImGui.EndChild(); STK.child = false

    ImGui.SameLine()

    ImGui.BeginChild("##bstepedit", 0, 0, true)
    STK.child = true

    local idx  = STATE.builder_active
    local step = (idx > 0) and steps[idx] or nil

    if not step then
        ImGui.TextColored(0.5,0.5,0.5,1, "Seleciona um step para editar.")
    else
        -- cabeçalho do step + botão remover
        ImGui.TextColored(0.9,0.85,0.3,1, "Step " .. tostring(step.progress))
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Button, 0.55,0.15,0.15,1)
        STK.colors = STK.colors + 1
        if ImGui.SmallButton("Remover##delstep") then
            table.remove(steps, idx)
            STATE.builder_active = math.max(0, idx - 1)
            SyncStepToEdit(STATE.builder_active > 0 and steps[STATE.builder_active] or nil)
            SaveBuilderSteps()
        end
        ImGui.PopStyleColor(1); STK.colors = STK.colors - 1

        ImGui.Spacing()

        -- Label
        ImGui.Text("Label:")
        ImGui.PushItemWidth(-1)
        local c1, v1 = ImGui.InputText("##blabel"..tostring(idx), STATE.builder_edit_label)
        if c1 then STATE.builder_edit_label = v1; step.label = v1 end
        ImGui.PopItemWidth()

        -- Lua_Check
        ImGui.TextColored(0.4,0.8,1.0,1, "State Trigger:")
        ImGui.PushItemWidth(-1)
        local c5,v5=ImGui.InputText("##blua"..tostring(idx), STATE.builder_edit_lua_check)
        if c5 then STATE.builder_edit_lua_check=v5; step.lua_check=v5 end
        ImGui.PopItemWidth()

        -- Notas
        ImGui.TextColored(0.6,0.6,0.6,1, "Notas:")
        ImGui.PushItemWidth(-1)
        local c6,v6=ImGui.InputTextMultiline("##bnotes"..tostring(idx), STATE.builder_edit_notes,-1,38)
        if c6 then STATE.builder_edit_notes=v6; step.notes=v6 end
        ImGui.PopItemWidth()

        ImGui.Spacing()
        ImGui.Separator()
        ImGui.TextColored(0.9,0.85,0.3,1, "ACOES:")
        ImGui.Spacing()

        -- ---- Lista de ações ----
        EnsureActions(step)
        local actions = step.actions
        local a_sel   = STATE.builder_action_sel
        local to_remove, move_up, move_down = nil, nil, nil

        for ai, a in ipairs(actions) do
            local def      = ACTION_BY_ID[a.type] or { label=a.type, cr=0.7, cg=0.7, cb=0.7 }
            local is_sel   = (a_sel == ai)

            -- botão ×
            ImGui.PushStyleColor(ImGuiCol.Button, 0.5,0.1,0.1,1)
            STK.colors = STK.colors + 1
            if ImGui.SmallButton("x##ax"..tostring(ai)) then to_remove = ai end
            ImGui.PopStyleColor(1); STK.colors = STK.colors - 1

            ImGui.SameLine()

            -- botão ↑
            if ImGui.SmallButton("^##au"..tostring(ai)) then move_up = ai end
            ImGui.SameLine()
            -- botão ↓
            if ImGui.SmallButton("v##ad"..tostring(ai)) then move_down = ai end
            ImGui.SameLine()
            -- botão ▶ (executar só esta ação)
            ImGui.PushStyleColor(ImGuiCol.Button, 0.10, 0.50, 0.18, 1.0)
            STK.colors = STK.colors + 1
            if ImGui.SmallButton(">##ar"..tostring(ai)) then
                local a_ref = a
                STATE.action_pending = function() ExecuteAction(a_ref) end
            end
            ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
            ImGui.SameLine()

            -- Linha clicável com label colorida + summary
            if is_sel then
                ImGui.PushStyleColor(ImGuiCol.Header,        0.26,0.59,0.98,0.5)
                ImGui.PushStyleColor(ImGuiCol.HeaderHovered, 0.26,0.59,0.98,0.7)
                STK.colors = STK.colors + 2
            end
            local row_label = string.format("[%s]  %s##ar%d", def.label, ActionSummary(a), ai)
            if ImGui.Selectable(row_label, is_sel, 0, 0, 16) then
                STATE.builder_action_sel = (is_sel and 0 or ai)
            end
            if is_sel then
                ImGui.PopStyleColor(2); STK.colors = STK.colors - 2
            end
        end

        -- Aplica reordenamento / remoção
        if to_remove then
            table.remove(actions, to_remove)
            if STATE.builder_action_sel >= to_remove then
                STATE.builder_action_sel = math.max(0, STATE.builder_action_sel - 1)
            end
            SaveBuilderSteps()
        end
        if move_up and move_up > 1 then
            actions[move_up], actions[move_up-1] = actions[move_up-1], actions[move_up]
            if a_sel == move_up then STATE.builder_action_sel = move_up - 1
            elseif a_sel == move_up - 1 then STATE.builder_action_sel = move_up end
            SaveBuilderSteps()
        end
        if move_down and move_down < #actions then
            actions[move_down], actions[move_down+1] = actions[move_down+1], actions[move_down]
            if a_sel == move_down then STATE.builder_action_sel = move_down + 1
            elseif a_sel == move_down + 1 then STATE.builder_action_sel = move_down end
            SaveBuilderSteps()
        end

        ImGui.Spacing()

        -- ---- Botão + Adicionar ----
        if ImGui.SmallButton("+  Adicionar##actadd") then
            local new_type = ACTION_DEFS[STATE.builder_add_type_idx] and ACTION_DEFS[STATE.builder_add_type_idx].id or "walk"
            local na = NewAction(new_type)
            table.insert(actions, na)
            STATE.builder_action_sel = #actions
            SaveBuilderSteps()
        end
        ImGui.SameLine()
        ImGui.PushItemWidth(160)
        local cc, vi = ImGui.Combo("##acttype", STATE.builder_add_type_idx - 1, ACTION_LABELS)
        if cc then STATE.builder_add_type_idx = vi + 1 end
        ImGui.PopItemWidth()

        -- ---- Editor inline da ação selecionada ----
        local a_idx = STATE.builder_action_sel
        if a_idx > 0 and actions[a_idx] then
            ImGui.Spacing()
            ImGui.Separator()
            local a = actions[a_idx]
            local def = ACTION_BY_ID[a.type] or { label=a.type, cr=0.9, cg=0.7, cb=0.2 }
            ImGui.TextColored(def.cr, def.cg, def.cb, 1.0, "Editar: " .. def.label)
            local aid = tostring(idx).."_"..tostring(a_idx)  -- id único por step+acao

            if a.type == "walk" or a.type == "smart_walk" then
                ImGui.PushItemWidth(72)
                local cx,vx=ImGui.InputInt("X##wx"..aid, a.x or 0); if cx then a.x=vx end
                ImGui.SameLine()
                local cy,vy=ImGui.InputInt("Y##wy"..aid, a.y or 0); if cy then a.y=vy end
                ImGui.SameLine()
                local cz,vz=ImGui.InputInt("Z##wz"..aid, a.z or 0); if cz then a.z=vz end
                ImGui.SameLine()
                local ct,vt=ImGui.InputInt("Tol##wt"..aid, a.tol or 5); if ct then a.tol=vt end
                ImGui.PopItemWidth()
                if ImGui.SmallButton("Capturar pos##wcap"..aid) then
                    local a_ref = a
                    STATE.action_pending = function()
                        local pos = API.PlayerCoord()
                        if pos and pos.x and pos.x ~= 0 then
                            a_ref.x=pos.x; a_ref.y=pos.y; a_ref.z=pos.z
                        end
                    end
                end
                if a.type == "smart_walk" then
                    ImGui.SameLine()
                    ImGui.TextColored(0.2,1.0,0.6,1, " [auto-lode]")
                end

            elseif a.type == "teleport" then
                ImGui.Text("Lodestone (ex: AL_KHARID):")
                ImGui.PushItemWidth(-1)
                local c,v=ImGui.InputText("##tplod"..aid, a.lodestone or ""); if c then a.lodestone=v end
                ImGui.PopItemWidth()

            elseif a.type == "talk_npc" then
                ImGui.Text("Nome do NPC:")
                ImGui.PushItemWidth(-1)
                local c,v=ImGui.InputText("##tnname"..aid, a.name or ""); if c then a.name=v end
                ImGui.PopItemWidth()
                ImGui.Text("Interacao (Talk to, Attack, ...):")
                ImGui.PushItemWidth(-1)
                local c2,v2=ImGui.InputText("##tnact"..aid, a.interact or "Talk to"); if c2 then a.interact=v2 end
                ImGui.PopItemWidth()

            elseif a.type == "interact_obj" then
                local cu,vu = ImGui.Checkbox("Por ID##ioid"..aid, a.use_id or false); if cu then a.use_id=vu end
                if a.use_id then
                    ImGui.SameLine()
                    ImGui.Text("  ID do Objeto:")
                    ImGui.SameLine()
                    ImGui.PushItemWidth(110)
                    local c,v=ImGui.InputInt("##ioobjid"..aid, a.obj_id or 0); if c then a.obj_id=math.max(0,v) end
                    ImGui.PopItemWidth()
                    ImGui.Text("Action offset (hex):")
                    ImGui.SameLine()
                    ImGui.PushItemWidth(90)
                    local c2,v2=ImGui.InputInt("##iooffset"..aid, a.action_offset or 0x29); if c2 then a.action_offset=math.max(0,v2) end
                    ImGui.PopItemWidth()
                    ImGui.TextColored(0.6,0.8,1,1, string.format("Gera: API.DoAction_Object1(0x%X, OFF_ACT_..., {%d}, 50)", a.action_offset or 0x29, a.obj_id or 0))
                else
                    ImGui.Text("Nome do Objeto:")
                    ImGui.PushItemWidth(-1)
                    local c,v=ImGui.InputText("##ioname"..aid, a.name or ""); if c then a.name=v end
                    ImGui.PopItemWidth()
                    ImGui.Text("Acao (Use, Search, Open, ...):")
                    ImGui.PushItemWidth(140)
                    local c2,v2=ImGui.InputText("##ioact"..aid, a.action or "Use"); if c2 then a.action=v2 end
                    ImGui.PopItemWidth()
                end
                ImGui.SameLine()
                ImGui.Text("  Distancia (0=auto):")
                ImGui.SameLine()
                ImGui.PushItemWidth(60)
                local c3,v3=ImGui.InputInt("##iodist"..aid, a.dist or 0); if c3 then a.dist=math.max(0,v3) end
                ImGui.PopItemWidth()

            elseif a.type == "dialog" then
                ImGui.Text("Opcoes (ex: 1,2,3  ou vazio = so espaco):")
                ImGui.PushItemWidth(180)
                local c,v=ImGui.InputText("##dlgseq"..aid, a.seq or ""); if c then a.seq=v end
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.Text("  Timeout:")
                ImGui.SameLine()
                ImGui.PushItemWidth(60)
                local c2,v2=ImGui.InputInt("##dlgtout"..aid, a.timeout or 10); if c2 then a.timeout=math.max(1,v2) end
                ImGui.PopItemWidth()
                local seq_str = (a.seq or "") ~= "" and ("{".. (a.seq or "") .."}, ") or "{}, "
                ImGui.TextColored(0.3,0.95,0.6,1, "Gera: QUEST:DialogSeq("..seq_str..(a.timeout or 10)..")")

            elseif a.type == "wait_dialog" then
                ImGui.Text("Timeout (segundos):")
                ImGui.PushItemWidth(80)
                local c,v=ImGui.InputInt("##wdtout"..aid, a.timeout or 10); if c then a.timeout=math.max(1,v) end
                ImGui.PopItemWidth()

            elseif a.type == "dialog_seq" then
                ImGui.Text("Sequencia de opcoes (ex: 1,2,3):")
                ImGui.PushItemWidth(180)
                local c,v=ImGui.InputText("##dsseq"..aid, a.seq or "1"); if c then a.seq=v end
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.Text("  Timeout:")
                ImGui.SameLine()
                ImGui.PushItemWidth(60)
                local c2,v2=ImGui.InputInt("##dstout"..aid, a.timeout or 10); if c2 then a.timeout=math.max(1,v2) end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.9,0.7,1, "Gera: QUEST:DialogSeq({".. (a.seq or "1") .."}, "..(a.timeout or 10)..")")

            elseif a.type == "select_num" then
                ImGui.Text("Numero da opcao (1-9):")
                ImGui.PushItemWidth(60)
                local c,v=ImGui.InputInt("##snnum"..aid, a.n or 1); if c then a.n=math.max(1,math.min(9,v)) end
                ImGui.PopItemWidth()

            elseif a.type == "select_text" then
                ImGui.Text("Texto da opcao:")
                ImGui.PushItemWidth(-1)
                local c,v=ImGui.InputText("##stxt"..aid, a.text or ""); if c then a.text=v end
                ImGui.PopItemWidth()

            elseif a.type == "skip_dialogs" then
                ImGui.TextColored(0.5,0.5,0.5,1,"(sem parametros)")

            elseif a.type == "accept_quest" then
                ImGui.TextColored(0.5,0.5,0.5,1,"(sem parametros)")

            elseif a.type == "equip_item" then
                ImGui.Text("Item ID:")
                ImGui.PushItemWidth(100)
                local c,v=ImGui.InputInt("##eqid"..aid, a.item_id or 0); if c then a.item_id=v end
                ImGui.PopItemWidth()

            elseif a.type == "use_item_obj" then
                ImGui.Text("Item ID:")
                ImGui.PushItemWidth(100)
                local c,v=ImGui.InputInt("##uioitem"..aid, a.item_id or 0); if c then a.item_id=v end
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.Text("  Object ID:")
                ImGui.SameLine()
                ImGui.PushItemWidth(100)
                local c2,v2=ImGui.InputInt("##uioobj"..aid, a.obj_id or 0); if c2 then a.obj_id=v2 end
                ImGui.PopItemWidth()

            elseif a.type == "kill_npcs" then
                ImGui.Text("Nome do NPC:")
                ImGui.PushItemWidth(200)
                local c,v = ImGui.InputText("##knnm"..aid, a.npc_name or ""); if c then a.npc_name=v end
                ImGui.PopItemWidth()
                ImGui.Text("Quantidade a matar:")
                ImGui.PushItemWidth(80)
                local c2,v2 = ImGui.InputInt("##knct"..aid, a.kill_count or 1); if c2 then a.kill_count=math.max(1,v2) end
                ImGui.PopItemWidth()
                ImGui.SameLine(); ImGui.Text("  Distância de ataque:")
                ImGui.SameLine()
                ImGui.PushItemWidth(80)
                local c3,v3 = ImGui.InputInt("##knds"..aid, a.dist or 50); if c3 then a.dist=math.max(1,v3) end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.8,0.5,1, "Deteta morte por Target_Id (UID unico) — funciona com varios NPCs do mesmo tipo")

            elseif a.type == "inv_use" or a.type == "inv_eat" or a.type == "inv_drop" or a.type == "equip_remove" then
                ImGui.Text("Item (ID ou nome):")
                ImGui.PushItemWidth(200)
                local c,v = ImGui.InputText("##invref"..aid, a.item_ref or ""); if c then a.item_ref=v end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.5,0.5,1, "Ex: 12345 ou \"Bronze sword\"")

            elseif a.type == "inv_use_item" then
                ImGui.Text("Item fonte (ID ou nome):")
                ImGui.PushItemWidth(170)
                local c,v = ImGui.InputText("##invsrc"..aid, a.item_ref or ""); if c then a.item_ref=v end
                ImGui.PopItemWidth()
                ImGui.SameLine(); ImGui.Text(" em ")
                ImGui.SameLine()
                ImGui.PushItemWidth(170)
                local c2,v2 = ImGui.InputText("##invtgt"..aid, a.target_ref or ""); if c2 then a.target_ref=v2 end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.5,0.5,1, "Ex: 12345 ou \"Item name\"")

            elseif a.type == "wait_cutscene" then
                ImGui.Text("Timeout (s):")
                ImGui.PushItemWidth(80)
                local c,v=ImGui.InputInt("##wcts"..aid, a.timeout or 60); if c then a.timeout=math.max(5,v) end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.8,0.6,1,1, "Pressiona Space em dialogos ate cutscene terminar")

            elseif a.type == "heal_if_low" then
                ImGui.Text("HP minimo (%):")
                ImGui.PushItemWidth(80)
                local c,v=ImGui.InputInt("##hpth"..aid, a.hp_threshold or 50); if c then a.hp_threshold=math.max(1,math.min(99,v)) end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.5,0.5,1, "Come comida comum se HP < threshold (Shark, Lobster, Monkfish...)")

            elseif a.type == "activate_prayer" then
                ImGui.Text("Nome da oracao/habilidade:")
                ImGui.PushItemWidth(-1)
                local c,v=ImGui.InputText("##prname"..aid, a.prayer_name or ""); if c then a.prayer_name=v end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.5,0.5,1, "Ex: Protect from Magic, Soul Split, Piety...")

            elseif a.type == "wait_npc_appear" then
                ImGui.Text("ID do NPC:")
                ImGui.PushItemWidth(110)
                local c,v=ImGui.InputInt("##wnapid"..aid, a.npc_id or 0); if c then a.npc_id=math.max(0,v) end
                ImGui.PopItemWidth()
                ImGui.SameLine(); ImGui.Text("  Timeout (s):")
                ImGui.SameLine()
                ImGui.PushItemWidth(70)
                local c2,v2=ImGui.InputInt("##wnapt"..aid, a.timeout or 30); if c2 then a.timeout=math.max(1,v2) end
                ImGui.PopItemWidth()

            elseif a.type == "wait_npc_gone" then
                ImGui.Text("ID do NPC:")
                ImGui.PushItemWidth(110)
                local c,v=ImGui.InputInt("##wngpid"..aid, a.npc_id or 0); if c then a.npc_id=math.max(0,v) end
                ImGui.PopItemWidth()
                ImGui.SameLine(); ImGui.Text("  Timeout (s):")
                ImGui.SameLine()
                ImGui.PushItemWidth(70)
                local c2,v2=ImGui.InputInt("##wngpt"..aid, a.timeout or 30); if c2 then a.timeout=math.max(1,v2) end
                ImGui.PopItemWidth()

            elseif a.type == "loot_all" then
                ImGui.TextColored(0.5,0.5,0.5,1, "Apanha todos os itens do chao (DoAction_LootAll_Button)")

            elseif a.type == "pickup_item" then
                ImGui.Text("Item ID:")
                ImGui.PushItemWidth(110)
                local c,v=ImGui.InputInt("##pkuid"..aid, a.item_id or 0); if c then a.item_id=math.max(0,v) end
                ImGui.PopItemWidth()

            elseif a.type == "set_flag" then
                ImGui.Text("Nome da flag:")
                ImGui.PushItemWidth(220)
                local c,v=ImGui.InputText("##sfname"..aid, a.flag_name or ""); if c then a.flag_name=v end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.5,0.5,1, "Guarda em quests/flags/<quest>_<flag>.flag")

            elseif a.type == "check_flag_skip" then
                ImGui.Text("Nome da flag:")
                ImGui.PushItemWidth(220)
                local c,v=ImGui.InputText("##cfname"..aid, a.flag_name or ""); if c then a.flag_name=v end
                ImGui.PopItemWidth()
                ImGui.TextColored(0.5,0.9,0.5,1, "Se flag existir: salta o resto do step (return)")

            elseif a.type == "sleep" then
                ImGui.Text("Duração (ms):")
                ImGui.PushItemWidth(100)
                local c,v=ImGui.InputInt("##slms"..aid, a.ms or 1000); if c then a.ms=math.max(0,v) end
                ImGui.PopItemWidth()

            elseif a.type == "custom" then
                ImGui.Text("Codigo Lua:")
                ImGui.PushItemWidth(-1)
                local c,v=ImGui.InputTextMultiline("##cstm"..aid, a.code or "",-1,60); if c then a.code=v end
                ImGui.PopItemWidth()
            end

            -- Preview do código desta ação
            local code_lines = ActionToCode(a)
            if #code_lines > 0 then
                ImGui.TextColored(0.4,0.4,0.4,1, "→  "..table.concat(code_lines, "\n   "))
            end
        end

        ImGui.Spacing()
        ImGui.Separator()

        -- Preview do step completo
        if ImGui.CollapsingHeader("Preview do step##prev") then
            local pv = {}
            if (step.lua_check or "") ~= "" then
                table.insert(pv, "-- "..step.lua_check)
            end
            table.insert(pv, string.format('qs:step(%d, "%s", function()', step.progress, step.label or ""))
            for _, a in ipairs(actions) do
                for _, line in ipairs(ActionToCode(a)) do
                    table.insert(pv, line)
                end
            end
            table.insert(pv, "end)")
            ImGui.TextUnformatted(table.concat(pv,"\n"))
        end
    end

    ImGui.EndChild(); STK.child = false
end

-- ============================================================================
-- GUI: PAINEL DIREITO — Detalhes e ações
-- ============================================================================
local function DrawQuestDetail()
    if not STATE.selected_name then
        ImGui.TextColored(0.5,0.5,0.5,1, "Seleciona uma quest na lista.")
        return
    end

    local q   = STATE.selected_entry
    local lib = STATE.selected_lib

    -- Cabeçalho + badge de estado
    ImGui.TextColored(1.0,0.85,0.0,1.0, STATE.selected_name)
    ImGui.SameLine()
    do
        local _s = BuilderSlug(STATE.selected_name or "")
        local _p = QuestPascal(STATE.selected_name or "")
        local function _fe2(p) local f=io.open(p,"r"); if f then f:close() return true end return false end
        local _hauto = lib ~= nil or #STATE.builder_steps > 0
                    or _fe2(BUILDER_SAVE_DIR.._s..".lua") or _fe2(BUILDER_SAVE_DIR.._p..".lua")
        if _hauto then
            ImGui.TextColored(0.4,0.8,1.0,1.0, "[AUTOMATIZADA]")
        elseif q and q.complete then
            ImGui.TextColored(0.3,0.9,0.3,1.0, "[FEITA]")
        else
            ImGui.TextColored(0.7,0.7,0.7,1.0, "[NAO FEITA]")
        end
    end

    -- Badges inline: dificuldade / members / QP / varbit
    do
        local diff = STATE.quest_difficulty
        if diff and diff ~= "" then
            ImGui.SameLine()
            local dr, dg, db, da = DiffColor(diff)
            ImGui.TextColored(dr, dg, db, da, "[" .. diff .. "]")
        end
        local mem = STATE.quest_members
        if mem ~= nil then
            ImGui.SameLine()
            if mem then
                ImGui.TextColored(0.9, 0.7, 0.2, 1.0, "[P2P]")
            else
                ImGui.TextColored(0.5, 0.9, 0.5, 1.0, "[F2P]")
            end
        end
        local qp = STATE.quest_points
        if qp and qp > 0 then
            ImGui.SameLine()
            ImGui.TextColored(0.9, 0.85, 0.3, 1.0, tostring(qp) .. " QP")
        end
        local vb = STATE.quest_varbit
        if vb and vb > 0 then
            ImGui.SameLine()
            ImGui.TextColored(0.4, 0.6, 0.9, 1.0, "varbit:" .. tostring(vb))
        end
    end

    ImGui.Separator()

    if not IsSafe() then
        ImGui.TextColored(1.0,0.5,0.0,1.0, "Aguardando cache/login...")
        return
    end

    -- Secção de informações detalhadas (requerimentos, coords de início)
    if STATE.quest_meta_loaded then
        local has_info = STATE.quest_start_coords or STATE.quest_req_quests or STATE.quest_skill_reqs
        if has_info and ImGui.CollapsingHeader("Informacoes da Quest##qinfo") then
            -- Local de início
            local sc = STATE.quest_start_coords
            if sc and #sc > 0 then
                ImGui.TextColored(0.5, 0.9, 0.5, 1.0, "Local de inicio:")
                ImGui.SameLine()
                local pt = sc[1]
                ImGui.Text(string.format("(%d, %d, %d)", pt.x, pt.y, pt.z))
                if #sc > 1 then
                    for i = 2, #sc do
                        local p = sc[i]
                        ImGui.BulletText(string.format("(%d, %d, %d)", p.x, p.y, p.z))
                    end
                end
            end

            -- Requisitos de skill
            local sr = STATE.quest_skill_reqs
            if sr and #sr > 0 then
                ImGui.Spacing()
                ImGui.TextColored(0.9, 0.6, 0.2, 1.0, "Requisitos de skill:")
                local cols = math.min(4, #sr)
                if ImGui.BeginTable("##skillreqs", cols) then
                    STK.tbl = true
                    for _, req in ipairs(sr) do
                        ImGui.TableNextColumn()
                        ImGui.Text(req.skill .. " " .. req.level)
                    end
                    ImGui.EndTable()
                    STK.tbl = false
                end
            end

            -- Quests requeridas
            local rq = STATE.quest_req_quests
            if rq and #rq > 0 then
                ImGui.Spacing()
                ImGui.TextColored(0.6, 0.8, 1.0, 1.0, "Quests requeridas:")
                for _, r in ipairs(rq) do
                    if r.complete then
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.9, 0.3, 1.0)
                        STK.colors = STK.colors + 1
                        ImGui.BulletText("[OK] " .. r.name)
                        ImGui.PopStyleColor(1)
                        STK.colors = STK.colors - 1
                    else
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.4, 0.4, 1.0)
                        STK.colors = STK.colors + 1
                        ImGui.BulletText("[ ] " .. r.name)
                        ImGui.PopStyleColor(1)
                        STK.colors = STK.colors - 1
                    end
                end
            end

            ImGui.Spacing()
        end
    end

    ImGui.Separator()

    -- Progresso live
    if STATE.quest_progress < 0 then
        ImGui.TextColored(0.6,0.6,0.6,1, "Progresso: carregando...")
    elseif STATE.quest_complete then
        ImGui.TextColored(0.2,1.0,0.3,1, "QUEST COMPLETA")
    elseif not STATE.quest_started then
        ImGui.TextColored(0.8,0.8,0.2,1, "Progresso: " .. tostring(STATE.quest_progress) .. "  (nao iniciada)")
    else
        ImGui.TextColored(0.4,0.8,1.0,1, "Progresso: " .. tostring(STATE.quest_progress))
    end

    -- Barra de progresso (só se houver steps definidos)
    if lib and lib.steps and #lib.steps > 0 then
        local maxProg = lib.steps[#lib.steps].progress
        local frac = (maxProg > 0 and STATE.quest_progress >= 0)
            and math.min(1.0, STATE.quest_progress / maxProg) or 0.0
        ImGui.ProgressBar(frac, -1, 16,
            tostring(STATE.quest_progress) .. "/" .. tostring(maxProg))
    end

    ImGui.Spacing()
    ImGui.Separator()

    -- Deteção de automação (LIBRARY + ficheiro lua)
    local slug      = BuilderSlug(STATE.selected_name or "")
    local pascal    = QuestPascal(STATE.selected_name or "")
    local function _fe(p) local f=io.open(p,"r"); if f then f:close() return true end return false end
    local lua_slug   = _fe(BUILDER_SAVE_DIR..slug..".lua")
    local lua_pascal = _fe(BUILDER_SAVE_DIR..pascal..".lua")
    local lua_exists = lua_slug or lua_pascal
    local has_auto   = lib ~= nil or #STATE.builder_steps > 0 or lua_exists

    -- Botão ▶ Play (para qualquer tipo de automação com ficheiro)
    if lua_exists then
        local play_mod = lua_slug and ("quests."..slug) or ("quests."..pascal)
        ImGui.Spacing()
        ImGui.PushStyleColor(ImGuiCol.Button, 0.1, 0.55, 0.15, 1.0)
        STK.colors = STK.colors + 1
        if ImGui.Button("▶  Executar Quest##play", -1, 30) then
            STATE.play_quest_module = play_mod
        end
        ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
    end

    ImGui.Spacing()
    ImGui.Separator()

    -- Step atual (só se LIBRARY)
    local step = STATE.current_step
    if lib then
        if step then
            ImGui.TextColored(1.0,0.85,0.0,1, "Step atual:")
            ImGui.Text(step.label or "")

            if step.coords then
                local c = step.coords
                ImGui.TextColored(0.5,0.9,0.5,1,
                    string.format("Coords: (%d, %d, %d)", c.x, c.y, c.z))
                ImGui.SameLine()
                if ImGui.SmallButton("Mover##coords") then
                    local cx, cy, cz = c.x, c.y, c.z
                    STATE.action_pending = function()
                        API.DoAction_WalkerW(WPOINT.new(cx, cy, cz))
                    end
                end
            end

            if step.npc then
                ImGui.TextColored(0.6,0.8,1.0,1, "NPC: " .. step.npc)
                ImGui.SameLine()
                if ImGui.SmallButton("Talk##npc") then
                    local n = step.npc
                    STATE.action_pending = function() Interact:NPC(n,"Talk to") end
                end
            end

            if step.object then
                ImGui.TextColored(0.9,0.7,0.4,1, "Objeto: " .. step.object)
                ImGui.SameLine()
                if ImGui.SmallButton("Usar##obj") then
                    local o = step.object
                    STATE.action_pending = function() Interact:Object(o,"Use") end
                end
            end

            if step.dialog and #step.dialog > 0 then
                ImGui.Spacing()
                ImGui.TextColored(0.7,0.7,0.7,1, "Dialogo:")
                for _, dopt in ipairs(step.dialog) do
                    ImGui.BulletText(dopt)
                end
            end

            if step.actions and #step.actions > 0 then
                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Text("Acoes:")
                ImGui.Spacing()
                for ai, act in ipairs(step.actions) do
                    if ImGui.Button(act.label .. "##a" .. tostring(ai), -1, 24) then
                        local fn = act.fn
                        STATE.action_pending = fn
                    end
                end
            end

        elseif STATE.quest_complete then
            ImGui.TextColored(0.2,1.0,0.3,1, "Todos os steps concluidos!")
        else
            ImGui.TextColored(0.6,0.6,0.6,1,
                "Sem step para progresso " .. tostring(STATE.quest_progress))
        end

        ImGui.Spacing()
        ImGui.Separator()

        -- Lista de todos os steps
        if lib.steps and ImGui.CollapsingHeader("Todos os steps##allsteps") then
            ImGui.BeginChild("StepList", 0, 180, true)
            STK.child = true
            for _, s in ipairs(lib.steps) do
                local isCur  = (s.progress == STATE.quest_progress)
                local isDone = (STATE.quest_progress > s.progress)
                local r, g, b = 0.7, 0.7, 0.7
                if isCur  then r,g,b = 1.0,0.85,0.0 end
                if isDone then r,g,b = 0.3,0.8,0.3  end
                local prefix = isDone and "[x] " or (isCur and "[>] " or "[ ] ")
                ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, 1.0)
                STK.colors = STK.colors + 1
                ImGui.Text(prefix .. tostring(s.progress) .. ": " .. (s.label or ""))
                ImGui.PopStyleColor(1)
                STK.colors = STK.colors - 1
            end
            ImGui.EndChild()
            STK.child = false
        end

    end  -- fim do bloco lib (steps LIBRARY)

    -- QuestData extra — mostra para TODAS as quests que tenham ficheiro QuestData
    local ed = STATE.quest_extra_data
    if ed then
        if ed.required_items and #ed.required_items > 0 then
            ImGui.Spacing(); ImGui.Separator()
            ImGui.TextColored(1.0,0.5,0.3,1, "Itens necessarios:")
            for _, item in ipairs(ed.required_items) do
                local txt = item.name or "?"
                if item.amount and item.amount ~= 1 then txt = txt.." x"..item.amount end
                if item.notes and item.notes ~= "" then txt = txt.."  ("..item.notes..")" end
                ImGui.BulletText(txt)
            end
        end
        if ed.recommended_items and #ed.recommended_items > 0 then
            ImGui.Spacing(); ImGui.Separator()
            ImGui.TextColored(0.5,0.85,1.0,1, "Recomendados:")
            for _, item in ipairs(ed.recommended_items) do
                local txt = item.name or "?"
                if item.amount and item.amount ~= 1 then txt = txt.." x"..item.amount end
                if item.notes and item.notes ~= "" then txt = txt.."  ("..item.notes..")" end
                ImGui.BulletText(txt)
            end
        end
        if ed.notes and #ed.notes > 0 then
            ImGui.Spacing(); ImGui.Separator()
            ImGui.TextColored(1.0,0.85,0.3,1, "Notas:")
            for _, note in ipairs(ed.notes) do
                ImGui.BulletText(tostring(note))
            end
        end
        if ed.rewards and #ed.rewards > 0 then
            ImGui.Spacing(); ImGui.Separator()
            ImGui.TextColored(0.4,1.0,0.4,1, "Recompensas:")
            for _, r in ipairs(ed.rewards) do
                ImGui.BulletText(tostring(r))
            end
        end
        if ed.walkthrough and #ed.walkthrough > 0 then
            ImGui.Spacing()
            if ImGui.CollapsingHeader("Walkthrough##wt") then
                for _, line in ipairs(ed.walkthrough) do
                    if line == "" then ImGui.Spacing()
                    else ImGui.TextWrapped(line) end
                end
            end
        end
    end
end

-- ============================================================================
-- MAIN GUI CALLBACK
-- ============================================================================
local function DrawUI()
    if not STATE.win_init then
        ImGui.SetNextWindowSize(980, 640, ImGuiCond.FirstUseEver)
        STATE.win_init = true
    end

    PushTheme()
    local visible = ImGui.Begin("Nexus Quest Builder v2.0", true)

    if visible then
        local sc, sv = ImGui.Checkbox("SAFE MODE##sm", STATE.safe_mode)
        if sc then STATE.safe_mode = sv end
        if STATE.safe_mode then
            ImGui.SameLine(); ImGui.TextColored(1,0.3,0.3,1, "ATIVO")
        end
        if STATE.gui_error ~= "" then
            ImGui.SameLine()
            ImGui.TextColored(1,0.4,0.4,1, "Err: " .. STATE.gui_error)
            ImGui.SameLine()
            if ImGui.SmallButton("X##err") then STATE.gui_error = "" end
        end
        ImGui.Separator()

        local left_w = STATE.list_collapsed and 28 or 320

        ImGui.BeginChild("LeftPanel", left_w, 0, true)
        StkReset()
        if STATE.list_collapsed then
            if ImGui.Button(">##lstexp", 20, 0) then STATE.list_collapsed = false end
        else
            if ImGui.SmallButton("<##lstcol") then STATE.list_collapsed = true end
            ImGui.SameLine()
            ImGui.TextColored(0.5,0.5,0.5,1, "Lista")
            local ok1, err1 = pcall(DrawQuestList)
            if not ok1 then StkCleanup(); STATE.gui_error = tostring(err1) end
        end
        ImGui.EndChild()

        ImGui.SameLine()

        ImGui.BeginChild("RightPanel", 0, 0, true)
        StkReset()

        -- Tabs: Informacao | Builder
        local tabs = { { key="info", label="Informacao" }, { key="builder", label="Builder" } }
        for ti, tab in ipairs(tabs) do
            local is_active = (STATE.right_tab == tab.key)
            if is_active then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.48, 0.80, 1.0)
                STK.colors = STK.colors + 1
            end
            if ImGui.Button(tab.label .. "##rtab" .. tostring(ti), 120, 22) then
                STATE.right_tab = tab.key
            end
            if is_active then
                ImGui.PopStyleColor(1); STK.colors = STK.colors - 1
            end
            if ti < #tabs then ImGui.SameLine() end
        end
        ImGui.Separator()

        if STATE.right_tab == "info" then
            local ok2, err2 = pcall(DrawQuestDetail)
            if not ok2 then StkCleanup(); STATE.gui_error = tostring(err2) end
        elseif STATE.right_tab == "builder" then
            local ok3, err3 = pcall(DrawQuestBuilder)
            if not ok3 then StkCleanup(); STATE.gui_error = tostring(err3) end
        end

        ImGui.EndChild()
    end

    ImGui.End()
    PopTheme()
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
DrawImGui(DrawUI)

while API.Read_LoopyLoop() do
    -- 1. Scan de quests (sempre corre — é read-only, safe_mode não bloqueia)
    local ok1, err1 = pcall(TickQuestScan)
    if not ok1 then STATE.gui_error = "Scan: " .. tostring(err1) end

    -- 2. Filtrar lista (puro Lua, zero C++)
    TickFilter()

    -- 3. Progresso live da quest selecionada
    if not STATE.safe_mode and STATE.selected_name then
        local ok, err = pcall(TickQuestProgress)
        if not ok then STATE.gui_error = "Progress: " .. tostring(err) end
    end

    -- 4. Path recorder (tick de posição)
    if STATE.path_rec_active then
        local ok, err = pcall(TickPathRecorder)
        if not ok then STATE.path_rec_status = "Erro: " .. tostring(err) end
    end

    -- 5. Executar ação pendente (single-shot)
    if STATE.action_pending then
        local fn = STATE.action_pending
        STATE.action_pending = nil
        local ok, err = pcall(fn)
        if not ok then
            STATE.gui_error = "Action: " .. tostring(err)
            API.logWarn("[QuestBuilder] " .. tostring(err))
        end
    end

    -- 6. Auto-save do builder (a cada ~120 ticks ≈ 6s, cobre edits de campos)
    STATE.builder_autosave_tick = STATE.builder_autosave_tick + 1
    if STATE.builder_autosave_tick >= 120 then
        STATE.builder_autosave_tick = 0
        if STATE.selected_name and #STATE.builder_steps > 0 then
            pcall(SaveBuilderSteps)
        end
    end

    -- 7. Action queue runner (Correr Step — executa uma ação por tick)
    if #STATE.action_queue > 0 then
        local ok, err = pcall(TickActionQueue)
        if not ok then
            STATE.gui_error = "Queue: " .. tostring(err)
            STATE.action_queue = {}
        end
    end

    -- 8. Play quest — executa o script completo e para o builder
    if STATE.play_quest_module then
        local mod = STATE.play_quest_module
        STATE.play_quest_module = nil
        package.loaded[mod] = nil
        API.logInfo("[QuestBuilder] A executar: " .. mod)
        local ok, err = pcall(require, mod)
        if not ok then
            STATE.gui_error = "Play: " .. tostring(err)
            API.logWarn("[QuestBuilder] Erro ao executar quest: " .. tostring(err))
        end
        API.Write_LoopyLoop(false)
    end

    API.RandomSleep2(50, 20, 20)
end
