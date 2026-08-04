-- Where a tutorial hint comes from, as opposed to what it looks like on screen.
--
-- Scraping `ModalTutorial_c` works and is fragile in the two ways scraping always is: the
-- text arrives a beat after the panel, and the panel is a template that can be relaid out by
-- any patch. If the game keeps the hints as data - a table of entries, a component on an
-- entity, an event that fires when one is raised - reading that instead is both earlier and
-- steadier. This looks for it in the three places it could be.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-tutsrc", "TS")
--     Mods.BG3Access.TS.all()

local A, Pad = _G.A11y, _G.Pad
local T = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- Text out of whatever shape the game handed it in.
---
--- A resource field is not the `h…g…` string the UI tree carries: it comes back as a
--- `TranslatedString` object, which is why resolving handles by pattern found nothing in the
--- bank while it worked perfectly on the roll panel. The handle is one or two levels inside
--- it, and its spelling has moved between extender builds, so all the shapes are tried.
local function locaOf(v)
    local t = type(v)
    if t == "string" then
        if v:match("^h%x%x%x%x%x%x%x%xg") then
            local s = soft(Ext.Loca.GetTranslatedString, v)
            if type(s) == "string" and s ~= "" then return s end
        end
        return nil
    end
    if t ~= "userdata" then return nil end
    local h = soft(function() return v.Handle end)
    if type(h) == "userdata" then h = soft(function() return h.Handle end) end
    if type(h) == "string" and h ~= "" then
        local s = soft(Ext.Loca.GetTranslatedString, h)
        if type(s) == "string" and s ~= "" then return s end
        return h
    end
    for _, k in ipairs({ "Value", "Text", "String" }) do
        local s = soft(function() return v[k] end)
        if type(s) == "string" and s ~= "" then return s end
    end
    return nil
end
T.locaOf = locaOf

local function widget(name)
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if str(ws[i].name) == name then return ws[i].node, ws[i].visible end
    end
    return nil
end

--- Every property of the widget root, with its type - not only the scalars a record dump
--- keeps. A model hanging off the widget would show up here as userdata and nowhere else.
function T.rootProps(name)
    local node = widget(name or "ModalTutorial_c")
    if node == nil then return "not up" end
    local p = soft(function() return node:GetAllProperties() end)
    if type(p) ~= "table" then return "no properties" end
    local keys = {}
    for k in pairs(p) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local v = p[k]
        out[#out + 1] = string.format("%-34s %-10s %s", k, type(v), str(v):sub(1, 90))
    end
    Ext.IO.SaveFile("A11y/tutsrc_props.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] " .. #keys .. " properties -> tutsrc_props.txt")
    return #keys
end

--- Anything in the extender's own type system whose name mentions a tutorial.
---
--- This is the question "does the engine expose the hints at all" asked of the API rather
--- than of the screen. A hit here is worth more than any amount of tree walking.
function T.types(pattern)
    pattern = pattern or "utorial"
    local out = {}
    local names = soft(Ext.Types.GetAllTypes)
    if type(names) == "table" then
        for _, n in ipairs(names) do
            if tostring(n):find(pattern) then out[#out + 1] = "TYPE " .. tostring(n) end
        end
    end
    -- The static data banks, where BG3 keeps its guid resources.
    local kinds = soft(Ext.StaticData.GetAllTypes) or soft(Ext.StaticData.GetTypes)
    if type(kinds) == "table" then
        for _, k in ipairs(kinds) do
            if tostring(k):find(pattern) then out[#out + 1] = "STATIC " .. tostring(k) end
        end
    end
    -- Stats objects, in case the entries are stats rather than resources.
    for _, kind in ipairs({ "TutorialEntry", "TutorialModalEntry", "TutorialEvent" }) do
        local s = soft(Ext.Stats.GetStats, kind)
        if type(s) == "table" and #s > 0 then
            out[#out + 1] = "STATS " .. kind .. " n=" .. #s .. " first=" .. tostring(s[1])
        end
    end
    Ext.IO.SaveFile("A11y/tutsrc_types.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] " .. #out .. " matches for '" .. pattern .. "' -> tutsrc_types.txt")
    for i = 1, math.min(#out, 20) do Ext.Utils.Print("  " .. out[i]) end
    return #out
end

--- Which entities carry a tutorial-shaped component right now.
function T.entities(pattern)
    pattern = pattern or "utorial"
    local out = {}
    local all = soft(Ext.Entity.GetAllEntitiesWithComponent)
    local names = soft(Ext.Types.GetAllTypes)
    if type(names) == "table" then
        for _, n in ipairs(names) do
            local nm = tostring(n)
            if nm:find(pattern) then
                local ents = soft(Ext.Entity.GetAllEntitiesWithComponent, nm)
                out[#out + 1] = "COMP " .. nm .. " ents=" ..
                                tostring(type(ents) == "table" and #ents or "?")
            end
        end
    end
    Ext.IO.SaveFile("A11y/tutsrc_ents.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] " .. #out .. " components -> tutsrc_ents.txt")
    for i = 1, math.min(#out, 20) do Ext.Utils.Print("  " .. out[i]) end
    return #out
end

--- The data records hanging under the panel, in full and with their types.
---
--- `recordOf` in probe-appear keeps only booleans, numbers and strings, which is what a
--- readable dump wants and exactly what would hide a model object. Here everything is kept.
function T.data(name)
    local node = widget(name or "ModalTutorial_c")
    if node == nil then return "not up" end
    local out, n, seen = {}, 0, {}
    local function isElement(o)
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) ~= "table" then return false end
        return p.ActualWidth ~= nil or p.IsHitTestVisible ~= nil or p.IsVisible ~= nil
    end
    local function rec(o, depth)
        if o == nil or n >= 400 or depth > 20 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local ch, cn = A.kids(o)
        for i = 1, cn do
            if isElement(ch[i]) then
                rec(ch[i], depth + 1)
            else
                local p = soft(function() return ch[i]:GetAllProperties() end)
                if type(p) == "table" then
                    local keys = {}
                    for k in pairs(p) do keys[#keys + 1] = tostring(k) end
                    table.sort(keys)
                    out[#out + 1] = "-- data at depth " .. depth .. " (" ..
                                    str(A.realType(ch[i])):sub(1, 60) .. ")"
                    for _, k in ipairs(keys) do
                        out[#out + 1] = string.format("   %-30s %-10s %s",
                            k, type(p[k]), str(p[k]):sub(1, 100))
                    end
                end
            end
        end
    end
    rec(node, 0)
    Ext.IO.SaveFile("A11y/tutsrc_data.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] data records -> tutsrc_data.txt (" .. #out .. " lines)")
    return #out
end

--- A guid resource bank, entry by entry, with every loca handle resolved.
---
--- This is the answer to "where do the hints come from": not the panel, which is a view of
--- them, but a table the game ships. If it is readable then a hint can be read the moment it
--- is raised, in full, without waiting for a template to fill.
function T.bank(kind, cap)
    kind = kind or "TutorialModalEntry"
    local ids = soft(Ext.StaticData.GetAll, kind)
    if type(ids) ~= "table" then
        Ext.Utils.Print("[tutsrc] GetAll(" .. kind .. ") gave " .. type(ids))
        return nil
    end
    local out = { kind .. ": " .. #ids .. " entries" }
    for i = 1, math.min(#ids, cap or 400) do
        local r = soft(Ext.StaticData.Get, ids[i], kind)
        if type(r) == "userdata" or type(r) == "table" then
            local p = soft(function() return r:GetAllProperties() end)
            if type(p) ~= "table" then p = r end
            local keys = {}
            for k in pairs(p) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "== " .. tostring(ids[i])
            for _, k in ipairs(keys) do
                local v = p[k]
                local text = locaOf(v)
                local s = (text ~= nil) and text or str(v)
                if type(v) ~= "function" then
                    out[#out + 1] = string.format("   %-26s %s",
                        k, (s:gsub("[\r\n]+", " / ")):sub(1, 300))
                end
            end
        end
    end
    Ext.IO.SaveFile("A11y/tutsrc_bank_" .. kind .. ".txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] " .. kind .. ": " .. #ids .. " entries -> tutsrc_bank_" ..
                    kind .. ".txt")
    return #ids
end

--- One property of the panel's data context, opened up.
---
--- `Data` on the widget's DCWidget is a component and not a scalar, which is exactly where an
--- id naming the entry on screen would sit - and exactly what a record dump drops.
function T.expand(name, prop)
    local node = widget(name or "ModalTutorial_c")
    if node == nil then return "not up" end
    local out, seen = {}, {}
    local function open(o, label, depth)
        if o == nil or depth > 4 then return end
        local id = tostring(o)
        if seen[id] then out[#out + 1] = string.rep("  ", depth) .. label .. " (seen)" return end
        seen[id] = true
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) ~= "table" then
            out[#out + 1] = string.rep("  ", depth) .. label .. " = " .. str(o)
            return
        end
        out[#out + 1] = string.rep("  ", depth) .. label .. " {" .. str(A.realType(o)) .. "}"
        local keys = {}
        for k in pairs(p) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = p[k]
            local t = type(v)
            if t == "string" or t == "number" or t == "boolean" then
                local s = str(v)
                if t == "string" and v:match("^h%x%x%x%x%x%x%x%xg") then
                    local tr = soft(Ext.Loca.GetTranslatedString, v)
                    if type(tr) == "string" and tr ~= "" then s = s .. "  -> " .. tr end
                end
                out[#out + 1] = string.rep("  ", depth + 1) .. k .. " = " .. s:sub(1, 160)
            elseif t == "userdata" and k:sub(1, 1) ~= "." then
                open(v, k, depth + 1)
            end
        end
    end
    local p = soft(function() return node:GetAllProperties() end) or {}
    local start = p[prop or "DataContext"]
    open(start, prop or "DataContext", 0)
    Ext.IO.SaveFile("A11y/tutsrc_expand.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] expanded -> tutsrc_expand.txt (" .. #out .. " lines)")
    return #out
end

-- Opening a Noesis collection ------------------------------------------------------------
--
-- `UnifiedTutorials`, `Tutorials` and `TutorialNotifications` come back as
-- `Noesis::BaseCollection`, and a walk over `GetAllProperties` does not open one: a collection
-- has no properties to speak of, it has a count and an indexer, and which spelling of those
-- the binding exposes is not something to guess at. So every shape is tried and what each one
-- answered is written down; the reader of the file picks the one that worked.

local function probeAccess(o, out, label)
    out[#out + 1] = "-- " .. tostring(label)
    local function try(name, fn)
        local ok, r = pcall(fn)
        if ok then
            out[#out + 1] = string.format("   %-24s %-9s %s", name, type(r), str(r):sub(1, 90))
            return r
        end
        out[#out + 1] = string.format("   %-24s ERR       %s", name, tostring(r):sub(1, 80))
        return nil
    end
    try("tostring", function() return tostring(o) end)
    local tn = try("GetObjectType", function() return Ext.Types.GetObjectType(o) end)
    try("#o", function() return #o end)
    try("o.Count", function() return o.Count end)
    try("o.Length", function() return o.Length end)
    try("o.ChildrenCount", function() return o.ChildrenCount end)
    try("o:Count()", function() return o:Count() end)
    try("o:GetCount()", function() return o:GetCount() end)
    try("o[0]", function() return o[0] end)
    try("o[1]", function() return o[1] end)
    try("o:Get(0)", function() return o:Get(0) end)
    try("o:GetItem(0)", function() return o:GetItem(0) end)
    try("o:Item(0)", function() return o:Item(0) end)
    try("o:Child(0)", function() return o:Child(0) end)
    try("pairs count", function()
        local n = 0
        for _ in pairs(o) do n = n + 1 end
        return n
    end)
    try("ipairs count", function()
        local n = 0
        for _ in ipairs(o) do n = n + 1 end
        return n
    end)
    -- What the extender itself says the type is made of, which is the answer when every
    -- guess above fails.
    if tn ~= nil then
        local ti = soft(Ext.Types.GetTypeInfo, tostring(tn))
        if ti ~= nil then
            out[#out + 1] = "   type " .. tostring(tn) .. " kind=" ..
                            str(soft(function() return ti.Kind end))
            soft(function()
                local names = {}
                for k, v in pairs(ti.Members or {}) do
                    names[#names + 1] = tostring(k) .. ":" ..
                        tostring(soft(function() return tostring(v.TypeName) end) or "?")
                end
                table.sort(names)
                for _, s in ipairs(names) do out[#out + 1] = "     member " .. s end
            end)
        end
    end
    return out
end

--- Find an object carrying a named property anywhere in the data-context graph, and open it.
---
--- Searched across every widget, not just the tutorial panel: the collections hang off a
--- shared data context, and the panel that led us to them is gone the moment the hint is
--- dismissed - which is most of the time.
function T.collection(prop, widgetName)
    prop = prop or "UnifiedTutorials"
    local ws = soft(Pad.findWidgets) or {}
    local found, out, seen = nil, {}, {}

    local function hunt(o, depth, trail)
        if o == nil or found ~= nil or depth > 5 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) ~= "table" then return end
        if p[prop] ~= nil then
            found = { obj = p[prop], where = trail .. "." .. prop }
            return
        end
        for k, v in pairs(p) do
            local ks = tostring(k)
            if type(v) == "userdata" and ks:sub(1, 1) ~= "." and ks ~= "Parent" then
                hunt(v, depth + 1, trail .. "." .. ks)
            end
        end
    end

    for i = 1, #ws do
        local nm = str(ws[i].name)
        if widgetName == nil or nm == widgetName then
            local p = soft(function() return ws[i].node:GetAllProperties() end)
            if type(p) == "table" and p.DataContext ~= nil then
                hunt(p.DataContext, 0, nm .. ".DataContext")
            end
        end
        if found ~= nil then break end
    end

    if found == nil then
        Ext.Utils.Print("[tutsrc] " .. prop .. " not found on any widget")
        return nil
    end

    out[#out + 1] = "found at " .. found.where
    probeAccess(found.obj, out, prop)
    Ext.IO.SaveFile("A11y/tutsrc_coll_" .. prop .. ".txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] " .. prop .. " at " .. found.where ..
                    " -> tutsrc_coll_" .. prop .. ".txt")
    T.last = found.obj
    return found.where
end

--- Walk a collection with whichever accessor turned out to work, and print the entries.
function T.items(prop, getter, count, widgetName)
    if T.last == nil or prop ~= nil then soft(T.collection, prop, widgetName) end
    local o = T.last
    if o == nil then return nil end
    local n = tonumber(count)
    if n == nil then
        n = soft(function() return o.Count end) or soft(function() return #o end) or 0
    end
    local out = { tostring(prop) .. ": " .. tostring(n) .. " items" }
    for i = 0, math.min(tonumber(n) or 0, 200) - 1 do
        local it = nil
        if getter == "index" then it = soft(function() return o[i] end)
        elseif getter == "index1" then it = soft(function() return o[i + 1] end)
        elseif getter == "get" then it = soft(function() return o:Get(i) end)
        elseif getter == "item" then it = soft(function() return o:Item(i) end)
        else it = soft(function() return o[i] end) or soft(function() return o:Get(i) end) end
        if it == nil then
            out[#out + 1] = "[" .. i .. "] nil"
        else
            out[#out + 1] = "[" .. i .. "] " .. str(A.realType(it))
            local p = soft(function() return it:GetAllProperties() end)
            if type(p) == "table" then
                local keys = {}
                for k in pairs(p) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    local v = p[k]
                    local text = locaOf(v)
                    local s = (text ~= nil) and text or str(v)
                    if type(v) ~= "function" and k:sub(1, 1) ~= "." then
                        out[#out + 1] = string.format("      %-26s %s",
                            k, (s:gsub("[\r\n]+", " / ")):sub(1, 200))
                    end
                end
            end
        end
    end
    Ext.IO.SaveFile("A11y/tutsrc_items_" .. tostring(prop) .. ".txt", table.concat(out, "\n"))
    Ext.Utils.Print("[tutsrc] items -> tutsrc_items_" .. tostring(prop) .. ".txt")
    return n
end

function T.all()
    soft(T.types)
    soft(T.entities)
    soft(T.rootProps)
    soft(T.data)
end

Ext.Utils.Print("[tutsrc] ready: TS.all() / TS.types(p) / TS.entities(p) / TS.rootProps() / TS.data()")
return T
