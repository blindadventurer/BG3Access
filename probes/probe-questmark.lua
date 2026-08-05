-- Does the shipped journal table actually reach the object an objective is about?
--
-- Everything in a11y-questdata was joined offline, out of the paks, and offline the chain is
-- exact by construction. What no file can answer is whether the UUIDs in it are the UUIDs of
-- the world in front of the player right now - so this walks the whole chain live and writes
-- down where it breaks, if it breaks:
--
--   the journal line -> its loca handle -> the objective -> its markers -> a UUID
--   -> Ext.Entity.Get -> a position -> distance and bearing from the character
--
-- Reads only. Nothing here moves the character or touches game state.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-questmark", "QM")
--     Mods.BG3Access.A11yBoot.globals.QM.run()
--
-- The answer goes to <SE>/A11y/questmark.json, because half of it is Russian and the console
-- input buffer is ANSI. The console gets an ASCII summary line, which is enough to know
-- whether to bother reading the file.

local M = {}

local B = Mods.BG3Access.A11yBoot
local G = B.globals

local function soft(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function P(s) Ext.Utils.Print("[qm] " .. tostring(s)) end

--- Every objective the shipped table can see for one quest id, for context in the file.
local function questRows(qd, quest)
    local out = {}
    if qd == nil or quest == nil then return out end
    for oid, row in pairs(qd.obj) do
        if row[1] == quest then
            local marks = {}
            for i = 3, #row do marks[#marks + 1] = row[i] end
            out[#out + 1] = { objective = oid, markers = marks }
        end
    end
    return out
end

function M.run()
    local Nav, Pad, qd = G.Nav, G.Pad, G.QuestData
    local r = { at = soft(Ext.Utils.MonotonicTime) }

    -- 1. Is the table here at all, and how big.
    if qd == nil then
        r.table = "MISSING"
    else
        local n, m, q = 0, 0, 0
        for _ in pairs(qd.obj or {}) do n = n + 1 end
        for _ in pairs(qd.mk or {}) do m = m + 1 end
        for _ in pairs(qd.q or {}) do q = q + 1 end
        local oh = 0
        for _ in pairs(qd.oh or {}) do oh = oh + 1 end
        r.table = { build = qd.BUILD, objectives = n, markers = m, quests = q, byHandle = oh }
    end

    -- 2. What the layer thinks the current task is, and where it came from.
    local obj = soft(function() return Nav.objective() end)
    if obj == nil then
        r.objective = "nil - neither the minimap nor the journal has anything"
    else
        r.objective = { text = obj.text, handle = obj.handle, quest = obj.quest,
                        fromBook = obj.fromBook, place = obj.place, turns = obj.turns,
                        markers = obj.markers }
    end

    -- The journal half, separately: it is the source of the handle, and it is empty until the
    -- player has opened the journal once in this session.
    local book = Pad and Pad.book
    if book == nil then
        r.book = "nil - the journal has not been opened in this session"
    else
        r.book = { title = book.title, quests = #(book.quests or {}), tasks = {} }
        for i, t in ipairs(book.tasks or {}) do
            r.book.tasks[i] = { text = t.text, handle = t.handle, done = t.done,
                                priority = t.priority }
        end
    end

    -- 3. Which objective that is, by handle or by text.
    local oid, how = soft(function() return Nav.objectiveId(obj) end)
    if oid == nil and obj ~= nil then
        -- Worth separating: no handle at all is a different failure from a handle the table
        -- does not know, and both look like "nothing found" from outside.
        local idx = soft(function() return Nav.questTextIndex() end)
        local n = 0
        for _ in pairs(idx or {}) do n = n + 1 end
        r.lookup = { resolved = false, textIndex = n,
                     handleKnown = (obj.handle ~= nil and qd ~= nil and qd.oh[obj.handle] ~= nil) }
    else
        r.lookup = { resolved = oid ~= nil, objective = oid, how = how }
    end
    if oid ~= nil and qd ~= nil then
        local row = qd.obj[oid]
        r.lookup.quest = row and row[1]
        r.lookup.markers = {}
        for i = 3, #(row or {}) do r.lookup.markers[i - 2] = row[i] end
        r.siblings = questRows(qd, row and row[1])
    end

    -- 4. Every marker point of that objective, resolved or not. The whole question is here:
    -- a UUID out of a pak either names something in this world or it does not.
    r.points = {}
    if oid ~= nil and qd ~= nil then
        local row = qd.obj[oid] or {}
        for i = 3, #row do
            local pts = qd.mk[row[i]]
            for j = 1, #(pts or {}) do
                local p = pts[j]
                local e = soft(function() return Ext.Entity.Get(p[3]) end)
                local pos = e and soft(function() return e.Transform.Transform.Translate end)
                local label = p[4] and Pad and soft(function() return Pad.loca(p[4]) end)
                local name = e and soft(function() return e.DisplayName.Name:Get() end)
                r.points[#r.points + 1] = {
                    marker = row[i], level = p[1], kind = p[2], uuid = p[3],
                    label = label, entity = e ~= nil, entityName = name,
                    pos = pos and { pos[1], pos[2], pos[3] } or nil,
                }
            end
        end
    end

    -- 5. And what the layer would now say, which is the thing the player actually gets.
    local marks = soft(function() return Nav.questMarks(obj) end)
    r.marks = {}
    for i = 1, #(marks or {}) do
        local it = marks[i]
        r.marks[i] = { name = it.name, dist = it.dist, dir = it.dir, marker = it.marker }
    end

    -- Where the character is, so a distance in the file can be checked against the world.
    local me = soft(function() return Nav.me() end)
    local mp = me and soft(function() return me.Transform.Transform.Translate end)
    if mp then r.me = { mp[1], mp[2], mp[3] } end

    soft(function() Ext.IO.SaveFile("A11y/questmark.json", Ext.Json.Stringify(r)) end)

    -- ASCII only: the console input buffer is ANSI and the file carries the Russian.
    P("table=" .. (type(r.table) == "table" and (r.table.objectives .. " objectives") or "MISSING") ..
      " objective=" .. (type(r.objective) == "table" and "yes" or "no") ..
      " handle=" .. tostring(obj and obj.handle ~= nil) ..
      " resolved=" .. tostring(r.lookup and r.lookup.resolved) ..
      " points=" .. #r.points .. " marks=" .. #r.marks)
    P("written A11y/questmark.json")
    return r
end

--- Force the chain with a quest id, when the journal is not talking.
---
--- `run()` can only test what the layer currently believes the task is, and that belief has
--- its own failure modes upstream of anything here. This takes the question apart: given a
--- quest the player is demonstrably on, walk every objective the table has for it and resolve
--- each one against the world. If the UUIDs are right, the objectives of the current step
--- come back with a distance whatever the journal is doing.
---
---     Mods.BG3Access.A11yBoot.globals.QM.quest("TUT_NautiloidEscape")
function M.quest(quest)
    local Nav, Pad, qd = G.Nav, G.Pad, G.QuestData
    if qd == nil then P("no QuestData") return nil end

    local out = { quest = quest, title = nil, objectives = {} }
    local q = qd.q[quest]
    if q and q[1] and Pad then out.title = soft(function() return Pad.loca(q[1]) end) end

    local me = soft(function() return Nav.me() end)
    local mp = me and soft(function() return me.Transform.Transform.Translate end)
    if mp then out.me = { mp[1], mp[2], mp[3] } end

    local hit, miss = 0, 0
    for oid, row in pairs(qd.obj) do
        if row[1] == quest then
            local rec = { objective = oid, handle = row[2], points = {} }
            if row[2] and Pad then rec.text = soft(function() return Pad.loca(row[2]) end) end
            -- Through questMarks, not around it: the point is to test the code the player
            -- will actually be running, not a second implementation of it that agrees.
            local marks = soft(function() return Nav.questMarks({ handle = row[2] }) end)
            for i = 1, #(marks or {}) do
                local it = marks[i]
                rec.points[i] = { name = it.name, dist = it.dist, dir = it.dir,
                                  marker = it.marker }
            end
            if #rec.points > 0 then hit = hit + 1 else miss = miss + 1 end
            out.objectives[#out.objectives + 1] = rec
        end
    end

    soft(function() Ext.IO.SaveFile("A11y/questmark-quest.json", Ext.Json.Stringify(out)) end)
    P("quest " .. quest .. ": " .. #out.objectives .. " objectives, " .. hit ..
      " reached a place, " .. miss .. " did not")
    P("written A11y/questmark-quest.json")
    return out
end

--- What the open journal actually holds, node by node.
---
--- `Pad.journalScan` came back with two quests and no tasks, and from outside those are the
--- same answer: nothing to point at. This dumps the tree while the screen is up, keeping any
--- node that carries one of the fields the scan keys on - so the question becomes which field
--- is missing rather than whether the walk ran.
---
---     Mods.BG3Access.A11yBoot.globals.QM.journal()
function M.journal()
    local Pad = G.Pad
    if Pad == nil then P("no Pad") return nil end

    local ws = soft(function() return Pad.findWidgets() end) or {}
    local node, name = nil, nil
    for i = 1, #ws do
        local n = tostring(ws[i].name)
        if n:find("Journal", 1, true) then node, name = ws[i].node, n end
    end
    if node == nil then
        P("no Journal widget in the tree - is the journal open?")
        return nil
    end

    -- Sixty thousand, and the number is the point. The first run of this stopped at four
    -- thousand with budgetLeft = 0, which means the dump was cut off rather than finished -
    -- and `Pad.journalScan`, the thing being diagnosed, walks the same tree with a budget of
    -- two thousand. So "no tasks found" may be nothing but a walk that never got there.
    local rows, budget = {}, { n = 60000 }
    local seen, dup, ids = 0, 0, {}
    local KEYS = { "Description", "IsCompleted", "ObjectivePriority", "QuestIsInProgress",
                   "IsSelected", "IsExpanded", "HasPlayerSeenLastUpdate", "Text", "Title" }
    local function rec(o, depth, path)
        if o == nil or budget.n <= 0 or depth > 26 then return end
        budget.n = budget.n - 1
        -- The same node reached twice is what a 60000-node journal really was. `Pad.readRow`
        -- keeps a seen set for exactly this reason and `journalScan` does not, so its budget
        -- of two thousand can be eaten by a cycle long before it reaches anything.
        local id = tostring(o)
        if ids[id] then dup = dup + 1 return end
        ids[id] = true
        seen = seen + 1
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) ~= "table" then return end

        local keep = nil
        for _, k in ipairs(KEYS) do
            if p[k] ~= nil then
                keep = keep or {}
                keep[k] = tostring(p[k])
            end
        end
        local nm = p.Name and tostring(p.Name) or nil
        local cls = soft(function() return tostring(Ext.Types.GetObjectType(o)) end)
        -- Text nodes are how the captions arrive; without them the records have no context.
        local txt = nil
        if p.Text ~= nil then txt = tostring(p.Text) end
        if keep ~= nil or (nm ~= nil and nm ~= "") then
            rows[#rows + 1] = { depth = depth, cls = cls, name = nm, text = txt,
                                props = keep, vis = p.IsVisible }
        end

        local ch, cn = G.A11y.kids(o)
        for i = 1, (cn or 0) do rec(ch[i], depth + 1, path) end
    end
    rec(node, 0, "")

    -- And what the scan makes of the same tree, right now.
    local quests, tasks = nil, nil
    soft(function() quests, tasks = Pad.journalScan(node) end)
    local out = { widget = name, rows = rows, budgetLeft = budget.n, visited = seen, revisits = dup,
                  scan = { quests = quests, tasks = tasks } }
    soft(function() Ext.IO.SaveFile("A11y/questmark-journal.json", Ext.Json.Stringify(out)) end)
    P("journal " .. name .. ": " .. seen .. " unique nodes, " .. dup .. " revisits, " .. #rows .. " interesting, budget left " .. budget.n .. ", scan says " ..
      #(quests or {}) .. " quests / " .. #(tasks or {}) .. " tasks")
    P("written A11y/questmark-journal.json")
    return out
end

P("loaded; run with QM.run()")
return M
