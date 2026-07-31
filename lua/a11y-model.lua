-- Reading the screens the widget tree cannot reach.
--
-- GetRoot() is bound to a single Noesis view. While Options or Load is open it returns
-- either nil or the main-menu tree again (§С6), so on those screens there are no widgets
-- to announce and the focus watcher goes silent. What does survive is the model: BG3's UI
-- is MVVM, every element carries a DataContext (ui::DCWidget) holding the real data, and
-- the save list was read from the main menu with the load screen shut (§С7).
--
-- The first sweep (M.viewHunt) found the rest of the machinery, which no earlier session
-- had looked at:
--   * the client ECS holds gui::registration::VM*DataSingletonComponent - the registered
--     view models themselves - plus gui::input::TrackingSingletonComponent and
--     ecl::sound::UIPanelStateSingletonComponent, which should name the open panel;
--   * the type registry knows ui::UIStateMachine, ui::UIWidget and Array<ui::UIWidget>,
--     i.e. the engine does keep a list of every widget, not just the one GetRoot returns.
--
-- Loaded after a11y-menu.lua, whose helpers it reuses:
--     Model = load(Ext.IO.LoadFile("A11y/a11y-model.lua"))()

local A = _G.A11y
if A == nil then
    _P("[model] a11y-menu is not loaded - push it first")
    error("a11y-model needs A11y")
end

local M = {}
local try, soft, props = A.try, A.soft, A.props

-- helpers ---------------------------------------------------------------------

local function str(v)
    return tostring(soft(function() return tostring(v) end))
end
M.str = str

--- GetAllProperties flattens every object to "ui::DCWidget (00000193062D7AC0)". A value in
--- that shape means a live object sits behind the name and GetProperty can fetch it —
--- which is the only way down into the model, since the flattened string is a dead end.
local function looksObject(v)
    return type(v) == "string" and v:find("::") ~= nil and v:find("%(%x+%)") ~= nil
end

local function isCollection(s)
    return type(s) == "string" and s:find("Collection") ~= nil
end

--- Localised text arrives as a handle ("hdf7b1184g…") everywhere in the model, exactly as
--- Osi.GetDisplayName does (E10). Resolve it, or hand back what came in.
function M.loca(v)
    if type(v) ~= "string" then return v end
    if v:match("^h%x%x%x%x%x%x%x%xg") == nil then return v end
    local t = soft(function() return Ext.Loca.GetTranslatedString(v) end)
    if type(t) == "string" and t ~= "" then return t end
    return v
end

-- flattening -------------------------------------------------------------------

--- Flatten any engine object to path/value rows.
---
--- Flat on purpose, for two reasons. The JSON writer collapses anything deeper than three
--- levels to "<depth>" (which is why saves.json came back with items = "<depth>"), and flat
--- rows are directly diffable — comparing two of these is how the field that follows the
--- pad's focus gets found rather than guessed.
---
--- Three object shapes turn up in this engine and each needs its own access:
---   * Noesis objects answer GetAllProperties(), and a property holding another object has
---     to be re-fetched with GetProperty() because the flattened string is a dead end;
---   * Noesis collections take a numeric index from 1 and raise on any string key (§С7);
---   * Script Extender structs (ECS components, input manager) enumerate under pairs().
local function flatten(o, path, rows, seen, depth, opts)
    if #rows >= opts.budget then return end
    local t = type(o)
    if o == nil then rows[#rows + 1] = { path = path, value = "nil" } return end
    if t == "boolean" or t == "number" or t == "string" then
        rows[#rows + 1] = { path = path, value = o }
        return
    end
    if t == "function" or t == "thread" then return end
    if depth > opts.maxDepth then
        rows[#rows + 1] = { path = path, value = "<deeper> " .. str(o) }
        return
    end

    local id = tostring(o)
    if seen[id] then rows[#rows + 1] = { path = path, value = "<seen> " .. id } return end
    seen[id] = true

    if t == "table" then
        local keys = {}
        for k in pairs(o) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        for _, k in ipairs(keys) do
            flatten(o[k], path .. "." .. tostring(k), rows, seen, depth + 1, opts)
        end
        return
    end

    local s = str(o)

    if isCollection(s) then
        local n = tonumber(soft(function() return #o end)) or 0
        rows[#rows + 1] = { path = path .. ".#", value = n }
        -- The reported length is not always the truth on these proxies, so keep reading
        -- past it until the indices genuinely run out.
        local misses = 0
        for i = 1, opts.maxItems do
            if #rows >= opts.budget then return end
            local item = soft(function() return o[i] end)
            if item == nil then
                misses = misses + 1
                if i > n and misses >= 3 then break end
            else
                misses = 0
                flatten(item, path .. "[" .. i .. "]", rows, seen, depth + 1, opts)
            end
        end
        return
    end

    local p = soft(function() return o:GetAllProperties() end)
    if type(p) == "table" then
        local names = {}
        for k in pairs(p) do names[#names + 1] = tostring(k) end
        table.sort(names)
        for _, k in ipairs(names) do
            if #rows >= opts.budget then return end
            local v = p[k]
            local sub = path .. "." .. k
            if looksObject(v) then
                -- Fetching by name is safe here: the name came out of GetAllProperties, so
                -- it exists and cannot take the 150x throwing path (E5).
                local live = soft(function() return o:GetProperty(k) end)
                if live ~= nil and type(live) == "userdata" then
                    flatten(live, sub, rows, seen, depth + 1, opts)
                else
                    rows[#rows + 1] = { path = sub, value = v }
                end
            else
                flatten(v, sub, rows, seen, depth + 1, opts)
            end
        end
        return
    end

    local fields = {}
    soft(function()
        for k, v in pairs(o) do
            if type(v) ~= "function" then fields[#fields + 1] = { tostring(k), v } end
        end
    end)
    if #fields == 0 then
        rows[#rows + 1] = { path = path, value = s }
        return
    end
    table.sort(fields, function(x, y) return x[1] < y[1] end)
    for _, kv in ipairs(fields) do
        if #rows >= opts.budget then return end
        flatten(kv[2], path .. "." .. kv[1], rows, seen, depth + 1, opts)
    end
end

--- Flatten one object and write it out. Returns the rows.
function M.dump(obj, tag, budget, maxDepth, maxItems)
    local rows, seen = {}, {}
    flatten(obj, tag or "obj", rows, seen,
            0, { budget = budget or 3000, maxDepth = maxDepth or 6,
                 maxItems = maxItems or 64 })
    _P("[model] dump " .. tostring(tag) .. ": " .. #rows .. " rows")
    A.write("model_" .. tostring(tag or "dump"), { tag = tag, count = #rows, rows = rows })
    return rows
end
M.flattenInto = flatten

-- 1. is there another way into the other views? --------------------------------

--- Everything that could hand us a second Noesis view, in one dump.
---
--- Only GetRoot had ever been used, and it does not follow the active screen. Sweep #1
--- answered: the state machine is nil, cursor control and picking helper are gameplay
--- objects, and the real lead is elsewhere — the client ECS and the ui::UIWidget list.
function M.viewHunt()
    local out = { accessors = {}, types = {}, entity = {} }

    for _, name in ipairs({ "GetStateMachine", "GetCursorControl", "GetDragDrop",
                            "GetPickingHelper", "GetRoot" }) do
        local r = try(function()
            if name == "GetPickingHelper" or name == "GetDragDrop" then
                return Ext.ClientUI[name](1)
            end
            return Ext.ClientUI[name]()
        end)
        local rec = { ok = r.ok, err = r.error, kind = type(r.value) }
        if r.value ~= nil then
            rec.str = str(r.value)
            rec.type = str(soft(Ext.Types.GetObjectType, r.value))
            local p = soft(function() return r.value:GetAllProperties() end)
            if type(p) == "table" then
                rec.props = {}
                for k, v in pairs(p) do rec.props[tostring(k)] = str(v) end
            end
            local en = {}
            soft(function()
                for k, v in pairs(r.value) do en[#en + 1] = tostring(k) .. "=" .. type(v) end
            end)
            table.sort(en)
            rec.enumerated = en
        end
        out.accessors[name] = rec
    end

    local all = soft(Ext.Types.GetAllTypes)
    local matched = {}
    if all ~= nil then
        soft(function()
            for k, v in pairs(all) do
                local n = type(k) == "string" and k or tostring(v)
                if n:find("View") or n:find("Widget") or n:find("Screen") or
                   n:find("UIObject") or n:find("ui::") or n:find("UIManager") then
                    matched[#matched + 1] = n
                end
            end
        end)
    end
    table.sort(matched)
    out.types = matched

    local api = {}
    soft(function()
        for k, v in pairs(Ext.Entity) do api[#api + 1] = tostring(k) .. "=" .. type(v) end
    end)
    table.sort(api)
    out.entity.api = api

    local ents = soft(function() return Ext.Entity.GetAllEntities() end)
    if type(ents) == "table" then
        out.entity.count = #ents
        local compSet = {}
        for i = 1, math.min(#ents, 200) do
            local names = soft(function() return ents[i]:GetAllComponentNames() end)
            if type(names) == "table" then
                for _, n in pairs(names) do
                    local s = tostring(n)
                    compSet[s] = (compSet[s] or 0) + 1
                end
            end
        end
        local comps = {}
        for n, c in pairs(compSet) do comps[#comps + 1] = n .. " x" .. c end
        table.sort(comps)
        out.entity.components = comps
    end

    _P("[model] viewHunt: " .. #out.types .. " ui-shaped types, entities=" ..
       tostring(out.entity.count) .. " -> view_hunt.json")
    A.write("view_hunt", out)
    return out
end

-- 2. the UI machinery in the ECS ------------------------------------------------

-- The names that came out of the first sweep and could carry a screen. VM*Data are the
-- registered view models, UIPanelState should name what is open, and input Tracking is the
-- candidate for "is the game in controller mode right now", which the layer has so far had
-- to infer from behaviour.
M.GUI_COMPONENTS = {
    "gui::registration::VMGlobalDataSingletonComponent",
    "gui::registration::VMLocalPlayerDataSingletonComponent",
    "gui::registration::VMCharacterDataSingletonComponent",
    "gui::registration::VMDialogueDataSingletonComponent",
    "gui::registration::VMInventoryDataSingletonComponent",
    "gui::registration::VMItemDataSingletonComponent",
    "gui::registration::VMPassiveDataSingletonComponent",
    "gui::registration::VMCombatDataSingletonComponent",
    "gui::input::TrackingSingletonComponent",
    "gui::UIReadyComponent",
    "gui::mod::RequestedModsSingletonComponent",
    "gui::lariannet::NotificationSingletonComponent",
    "ecl::sound::UIPanelStateSingletonComponent",
    "ecl::sound::UIPanelPostHUDRequestsSingletonComponent",
    "ecl::UIFrameIdSingletonComponent",
    "ecl::gamestate::StateSingletonComponent",
}

--- Which component names does the runtime actually accept, and what is behind each one?
---
--- Two unknowns at once: the Lua-facing name (the registry lists C++ names like
--- gui::registration::VMGlobalDataSingletonComponent, while the entity accessor is usually
--- the short form) and the field layout. Both are answered by trying and recording, never
--- by assuming — a guessed property name is the expensive throwing path (E5).
function M.guiHunt(extraNames)
    local out = { registered = {}, lookups = {}, entityKeys = {} }

    local reg = soft(function() return Ext.Entity.GetRegisteredComponentTypes() end)
    if type(reg) == "table" then
        local hits = {}
        for k, v in pairs(reg) do
            local n = type(k) == "string" and k or tostring(v)
            if n:find("gui") or n:find("UI") or n:find("ui::") or n:find("Widget") then
                hits[#hits + 1] = n
            end
        end
        table.sort(hits)
        out.registered = hits
        out.registeredCount = #hits
        _P("[model] registered ui-ish component types: " .. #hits)
    else
        out.registered = { "GetRegisteredComponentTypes -> " .. type(reg) }
    end

    local names = {}
    for _, n in ipairs(M.GUI_COMPONENTS) do names[#names + 1] = n end
    if type(extraNames) == "table" then
        for _, n in ipairs(extraNames) do names[#names + 1] = n end
    end
    -- The short form is what an entity accessor usually looks like, so try both.
    local expanded = {}
    for _, n in ipairs(names) do
        expanded[#expanded + 1] = n
        local short = n:match("([^:]+)$")
        if short then
            expanded[#expanded + 1] = short
            local trimmed = short:gsub("Component$", ""):gsub("Singleton$", "")
            if trimmed ~= short then expanded[#expanded + 1] = trimmed end
        end
    end

    for _, n in ipairs(expanded) do
        local r = try(function() return Ext.Entity.GetAllEntitiesWithComponent(n) end)
        local rec = { ok = r.ok, err = r.error, kind = type(r.value) }
        if type(r.value) == "table" then
            rec.count = #r.value
            if #r.value > 0 then
                local e = r.value[1]
                rec.entity = str(e)
                -- pairs() on an entity lists the component accessors it actually has, which
                -- is the mapping from C++ name to Lua name we are missing.
                local keys = {}
                soft(function()
                    for k in pairs(e) do keys[#keys + 1] = tostring(k) end
                end)
                table.sort(keys)
                rec.entityKeys = keys
                if #keys > 0 then out.entityKeys[n] = keys end
            end
        end
        if rec.ok and (rec.count or 0) > 0 then
            out.lookups[n] = rec
            _P("[model] " .. n .. " -> " .. tostring(rec.count) .. " entities")
        elseif rec.ok then
            out.lookups[n] = { ok = true, count = 0 }
        else
            out.lookups[n] = { ok = false, err = r.error }
        end
    end

    A.write("gui_hunt", out)
    return out
end

--- Everything behind one component, flattened.
function M.component(componentName, accessor, tag)
    local ents = soft(function() return Ext.Entity.GetAllEntitiesWithComponent(componentName) end)
    if type(ents) ~= "table" or #ents == 0 then
        _P("[model] no entity carries " .. tostring(componentName))
        return nil
    end
    local e = ents[1]
    local comp = accessor and soft(function() return e[accessor] end) or nil
    if comp == nil then
        -- No accessor given (or it missed): dump the entity itself, which enumerates its
        -- components as fields.
        return M.dump(e, tag or "entity", 3000, 4)
    end
    return M.dump(comp, tag or accessor, 3000, 6)
end

--- Type members, for the types the sweep turned up. Cheap, and it says what to look for.
function M.typeInfo(list)
    list = list or { "ui::UIStateMachine", "ui::UIState", "ui::UIStateInstance",
                     "ui::UIStateWidget", "ui::UIWidget", "ui::UIWidgetMetadata",
                     "ui::ViewModel", "ui::DCWidget", "Array<ui::UIWidget>",
                     "gui::input::TrackingSingletonComponent",
                     "ecl::sound::UIPanelStateSingletonComponent" }
    local out = {}
    for _, n in ipairs(list) do
        local ti = soft(Ext.Types.GetTypeInfo, n)
        if ti == nil then
            out[n] = { found = false }
        else
            local rec = { found = true, kind = str(soft(function() return ti.Kind end)),
                          members = {} }
            soft(function()
                for k, v in pairs(ti.Members) do
                    rec.members[tostring(k)] = str(soft(function() return v.TypeName end))
                end
            end)
            soft(function()
                local ms = {}
                for k in pairs(ti.Methods) do ms[#ms + 1] = tostring(k) end
                table.sort(ms)
                rec.methods = ms
            end)
            out[n] = rec
            local n0 = 0
            for _ in pairs(rec.members) do n0 = n0 + 1 end
            _P("[model] " .. n .. ": " .. rec.kind .. ", " .. n0 .. " members")
        end
    end
    A.write("type_info", out)
    return out
end

-- 3. the model graph off the visual tree ----------------------------------------

--- Every distinct DataContext hanging off the visual tree, kept for later use.
---
--- Kept in a global on purpose: the whole point is to still hold these once the tree they
--- came from is gone, so they must outlive a module reload the same way subscription ids do.
function M.keep()
    local seen, kept = {}, {}
    local visited = A.walk(function(o, depth, i)
        local p = props(o)
        local dc = p.DataContext
        if dc == nil or type(dc) ~= "userdata" then return end
        local id = tostring(dc)
        if seen[id] then return end
        seen[id] = true
        kept[#kept + 1] = { obj = dc, id = id, depth = depth, order = i,
                            type = str(soft(Ext.Types.GetObjectType, dc)),
                            from = select(1, A.splitToString(A.realType(o))) }
    end)
    _G.A11Y_DCS = kept
    M.kept = kept
    _P("[model] kept " .. #kept .. " data contexts from " .. visited .. " nodes")
    for i = 1, math.min(#kept, 12) do
        _P("   " .. i .. ". " .. kept[i].type .. " under " .. tostring(kept[i].from) ..
           " d" .. kept[i].depth)
    end
    return kept
end

--- Do the kept contexts still answer on a later frame?
---
--- Noesis node handles expire within about a tick, and if model objects behave the same way
--- the approach collapses: on an unreadable screen there is no tree left to re-acquire them
--- from. This is the experiment that decides it, so it reports per object, not as a verdict.
function M.alive(tag)
    local kept = M.kept or _G.A11Y_DCS
    if kept == nil then _P("[model] nothing kept yet - call Model.keep()") return nil end
    local rows, ok = {}, 0
    for i = 1, #kept do
        local r = try(function() return kept[i].obj:GetAllProperties() end)
        local n = 0
        if r.ok and type(r.value) == "table" then
            for _ in pairs(r.value) do n = n + 1 end
            ok = ok + 1
        end
        rows[i] = { i = i, type = kept[i].type, ok = r.ok, propCount = n, err = r.error }
    end
    _P("[model] alive(" .. tostring(tag) .. "): " .. ok .. "/" .. #kept .. " contexts answered")
    A.write("model_alive_" .. tostring(tag or "now"),
            { tag = tag, ok = ok, total = #kept, rows = rows })
    return ok, #kept
end

--- One flat snapshot of everything reachable from the kept contexts.
function M.scan(tag, budget, maxDepth)
    local kept = M.kept or _G.A11Y_DCS
    if kept == nil then _P("[model] nothing kept - call Model.keep() first") return nil end
    local opts = { budget = budget or 4000, maxDepth = maxDepth or 5, maxItems = 64 }

    local rows, seen = {}, {}
    for i = 1, #kept do
        if #rows >= opts.budget then break end
        flatten(kept[i].obj, "dc" .. i, rows, seen, 0, opts)
    end

    local map = {}
    for _, r in ipairs(rows) do map[r.path] = r.value end
    M.snaps = M.snaps or {}
    M.snaps[tostring(tag or "now")] = map

    _P("[model] scan(" .. tostring(tag) .. "): " .. #rows .. " rows")
    A.write("model_scan_" .. tostring(tag or "now"),
            { tag = tag, count = #rows, contexts = #kept, rows = rows })
    return rows
end

--- What changed between two scans — the pad moves, and whatever field follows it shows up
--- here as the only difference.
function M.diff(a, b)
    M.snaps = M.snaps or {}
    local x, y = M.snaps[tostring(a)], M.snaps[tostring(b)]
    if x == nil or y == nil then
        _P("[model] need both scans: " .. tostring(a) .. "=" .. tostring(x ~= nil) ..
           " " .. tostring(b) .. "=" .. tostring(y ~= nil))
        return nil
    end
    local changed, added, removed = {}, {}, {}
    for k, v in pairs(x) do
        if y[k] == nil then removed[#removed + 1] = k .. " = " .. tostring(v)
        elseif y[k] ~= v then
            changed[#changed + 1] = k .. ": " .. tostring(v) .. " -> " .. tostring(y[k])
        end
    end
    for k, v in pairs(y) do
        if x[k] == nil then added[#added + 1] = k .. " = " .. tostring(v) end
    end
    table.sort(changed) table.sort(added) table.sort(removed)

    _P("[model] diff " .. tostring(a) .. " -> " .. tostring(b) .. ": " .. #changed ..
       " changed, " .. #added .. " added, " .. #removed .. " removed")
    for i = 1, math.min(#changed, 25) do _P("   ~ " .. changed[i]) end
    for i = 1, math.min(#added, 15) do _P("   + " .. added[i]) end
    A.write("model_diff", { a = tostring(a), b = tostring(b), changed = changed,
                            added = added, removed = removed })
    return changed, added, removed
end

--- Re-acquire the contexts and scan in one call, for use while a sub-screen is open: if the
--- tree is gone the kept objects are all we have, and if it is not, refreshing is better.
function M.refresh(tag)
    local total = A.walk(function() end)
    if total >= 20 then M.keep()
    else _P("[model] tree unreadable (" .. total .. " nodes) - using contexts kept earlier") end
    return M.scan(tag)
end

_P("[model] a11y-model loaded. viewHunt / guiHunt / typeInfo / keep / scan / diff")
return M
