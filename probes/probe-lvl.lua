-- What the level-up screen is made of.
--
-- `CharacterLevelUp_c` is on screen while the player picks a class, a subclass, abilities,
-- skills and spells - the one screen where a wrong choice is permanent - and the layer has
-- never had a line of code aimed at it. A first dump showed why it half works and half does
-- not: the path to a spell row reads
--
--     CharacterLevelUp_c/1/1/levelUpControl/levelUp/3/leftSidePanels/gameplaySubPanel/...
--
-- so the character-creation landmarks are in there somewhere, wrapped in two levels the
-- creation screen does not have (`levelUpControl`, `levelUp`, `leftSidePanels`). And the
-- rows themselves carry no text at all: an available spell is a record with `Selected`,
-- `NotAvailable` and a `Spell` object, exactly like the roll panel's boosts.
--
-- This only looks. It presses nothing.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-lvl", "LV")
--     Mods.BG3Access.LV.all()

local A, Pad = _G.A11y, _G.Pad
local W = {}

local SCREEN = "CharacterLevelUp_c"

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end
local function P(s) soft(Ext.Utils.Print, "[lvl] " .. tostring(s)) end

local function props(o)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) == "table" then return p end
    return {}
end

--- The level-up widget, or whatever was asked for, if it is up.
local function screenNode(want)
    want = tostring(want or SCREEN)
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if ws[i].visible ~= false and str(ws[i].name) == want then return ws[i].node, want end
    end
    return nil, nil
end
W.node = screenNode

-- A value worth writing down: numbers, bools and short strings as themselves, longer strings
-- clipped, everything else as its type alone.
local function value(v)
    local t = type(v)
    if t == "number" or t == "boolean" then return v end
    if t == "string" then return (#v > 300) and (v:sub(1, 300) .. "...") or v end
    return nil
end

local function shortText(p, cls, label)
    local out = {}
    for _, s in ipairs(A.strings(p.Text, label)) do
        if type(s) == "string" and s ~= "" then out[#out + 1] = (#s > 90) and (s:sub(1, 90) .. "...") or s end
    end
    if #out == 0 then return nil end
    return table.concat(out, " | ")
end

--- The shape of the screen: one line per node, indented, with everything that says what it is.
---
--- Deliberately not deduplicated and not pruned by class - the point is to find the names to
--- aim at, and a name on a node that holds no text is exactly as useful as one that does.
function W.tree(depth, budget, want)
    local node, found = screenNode(want)
    if node == nil then P("no visible " .. tostring(want or SCREEN)) return nil end

    local rows, left = {}, { n = budget or 4000 }
    local function rec(o, d, idx)
        if o == nil or d > (depth or 8) or left.n <= 0 then return end
        left.n = left.n - 1
        local p = props(o)
        local cls, label = A.splitToString(A.realType(o))
        local ch, cn = A.kids(o)
        local bits = {}
        local nm = str(p.Name)
        if nm ~= "nil" and nm ~= "" then bits[#bits + 1] = "name=" .. nm end
        if p.IsVisible == false then bits[#bits + 1] = "hidden" end
        if p.IsSelected == true then bits[#bits + 1] = "SELECTED" end
        if p.IsFocused == true then bits[#bits + 1] = "FOCUSED" end
        if p.IsKeyboardFocusWithin == true then bits[#bits + 1] = "focuswithin" end
        if p.ActualWidth == nil and p.IsVisible == nil then bits[#bits + 1] = "record" end
        local t = shortText(p, cls, label)
        if t ~= nil then bits[#bits + 1] = "text=" .. t end
        rows[#rows + 1] = string.rep("  ", d) .. "[" .. tostring(idx) .. "] " .. cls ..
                          (cn > 0 and (" (" .. cn .. ")") or "") ..
                          (#bits > 0 and ("  " .. table.concat(bits, "  ")) or "")
        for i = 1, cn do rec(ch[i], d + 1, i) end
    end
    rec(node, 0, 0)
    P(found .. ": " .. #rows .. " rows, " .. ((budget or 4000) - left.n) .. " nodes")
    A.write("lvl_tree", rows)
    return rows
end

--- Every named node in the screen, however deep, with the path to it.
---
--- The first dump found `gameplaySubPanel` eleven levels down, which means the landmark walk
--- the creation screen uses could reach it - but nothing said what else is down there or
--- whether the tab strip and the summary are named the same way. This answers that in one
--- pass and is the map everything else is written against.
function W.names(budget, want)
    local node, found = screenNode(want)
    if node == nil then P("no visible " .. tostring(want or SCREEN)) return nil end

    local out, left, seen = {}, { n = budget or 40000 }, {}
    local function rec(o, d, path)
        if o == nil or d > 26 or left.n <= 0 then return end
        left.n = left.n - 1
        local p = props(o)
        if p.IsVisible == false then return end
        local nm = str(p.Name)
        local cls = select(1, A.splitToString(A.realType(o)))
        local here = path
        if nm ~= "nil" and nm ~= "" and not nm:find("^PART_") then
            here = path .. "/" .. nm
            if not seen[here] then
                seen[here] = true
                out[#out + 1] = { at = here, cls = cls, depth = d }
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1, here) end
    end
    rec(node, 0, "")
    P(found .. ": " .. #out .. " named nodes, " .. ((budget or 40000) - left.n) .. " walked")
    A.write("lvl_names", out)
    return out
end

--- What the layer's own character-creation machinery makes of this screen.
---
--- If `landmarks` finds the panels here, most of the creation reader applies unchanged and
--- the work is wiring, not writing. If it finds nothing, the wrappers are in the way and
--- the walk has to be taught about them.
function W.marks()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local out = {}
    for _, budget in ipairs({ 400, 1200, 4000 }) do
        local m = soft(Pad.landmarks, node, budget)
        local got = {}
        if type(m) == "table" then
            for k, v in pairs(m) do
                if k ~= "nodes" then got[#got + 1] = k end
            end
            table.sort(got)
            out[#out + 1] = { budget = budget, nodes = m.nodes, found = table.concat(got, ",") }
            P("budget " .. budget .. " -> " .. m.nodes .. " nodes, found: " ..
              (table.concat(got, ",") ~= "" and table.concat(got, ",") or "(nothing)"))
        end
    end
    local tab = soft(Pad.tabState, node)
    if type(tab) == "table" then
        P("tab: " .. tostring(tab.name) .. " " .. tostring(tab.index) .. "/" .. tostring(tab.count))
        out.tab = tab
    else
        P("tab: (none)")
    end
    A.write("lvl_marks", out)
    return out
end

--- Every record on the screen that carries an object, and what that object holds.
---
--- The spell rows are the reason: they have no text of their own, only `Selected`,
--- `NotAvailable` and a `Spell`. Whatever names a spell is inside that object, and the same
--- shape is likely to hold for feats, abilities and skills.
function W.records(budget, want)
    local node, found = screenNode(want)
    if node == nil then P("no visible " .. tostring(want or SCREEN)) return nil end

    local out, left, kinds = {}, { n = budget or 40000 }, {}
    local function unfold(v, d)
        if d > 2 then return "<deep>" end
        local p = soft(function() return v:GetAllProperties() end)
        if type(p) ~= "table" then return "<" .. type(v) .. ">" end
        local rec = {}
        for k, vv in pairs(p) do
            local val = value(vv)
            if val ~= nil then rec[tostring(k)] = val
            elseif type(vv) == "userdata" then rec[tostring(k)] = unfold(vv, d + 1)
            else rec[tostring(k)] = "<" .. type(vv) .. ">" end
        end
        return rec
    end

    local function rec(o, d, path)
        if o == nil or d > 26 or left.n <= 0 then return end
        left.n = left.n - 1
        local p = props(o)
        local isElement = (p.ActualWidth ~= nil or p.IsVisible ~= nil)
        if not isElement then
            local sig, fields = {}, {}
            for k, v in pairs(p) do
                sig[#sig + 1] = tostring(k)
                local val = value(v)
                if val ~= nil then fields[tostring(k)] = val
                elseif type(v) == "userdata" then fields[tostring(k)] = unfold(v, 1)
                else fields[tostring(k)] = "<" .. type(v) .. ">" end
            end
            table.sort(sig)
            local key = table.concat(sig, ",")
            if next(fields) ~= nil then
                kinds[key] = (kinds[key] or 0) + 1
                -- Three of each shape is enough to see the pattern and small enough to read.
                if kinds[key] <= 3 then
                    out[#out + 1] = { at = path, shape = key, fields = fields }
                end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            local kp = props(ch[i])
            local knm = str(kp.Name)
            rec(ch[i], d + 1, path .. "/" .. ((knm ~= "nil" and knm ~= "") and knm or tostring(i)))
        end
    end
    rec(node, 0, found)

    local summary = {}
    for k, v in pairs(kinds) do summary[#summary + 1] = v .. "x  " .. k end
    table.sort(summary)
    for i = 1, #summary do P(summary[i]) end
    A.write("lvl_records", { samples = out, kinds = summary })
    return out
end

-- Flat, because `A.write` folds anything more than three levels deep into "<depth>" - which
-- is exactly what happened to the first attempt at reading a spell: the object was unfolded
-- correctly and written out as the string "<depth>".
local function flat(v, prefix, out, d)
    out = out or {}
    d = d or 0
    if d > 3 then out[prefix] = "<deep>" return out end
    local p = soft(function() return v:GetAllProperties() end)
    if type(p) ~= "table" then out[prefix] = "<" .. type(v) .. ">" return out end
    for k, vv in pairs(p) do
        local key = prefix .. "." .. tostring(k)
        local val = value(vv)
        if val ~= nil then out[key] = val
        elseif type(vv) == "userdata" then flat(vv, key, out, d + 1)
        else out[key] = "<" .. type(vv) .. ">" end
    end
    return out
end

--- The element the game says the player is on, and everything hanging off it.
---
--- The row under the cursor is an `ls:LSButton` named `spellButton` with no text in it at
--- all - the markup gives it an icon and a focus frame and nothing else. Its name is in the
--- record it is bound to, so this reads the chain both ways: the text under the focused
--- node, and the record beside it unfolded flat.
function W.focus()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    -- focusChain hands back the focused node; the ancestry it walked through is left in
    -- Pad.focusPath, and that is the part worth reading here.
    local leaf = soft(Pad.focusChain, node)
    local chain = Pad.focusPath or {}
    local viaWidget = soft(Pad.widgetFocus, node)
    P("focusChain leaf=" .. str(leaf and props(leaf).Name) .. "  widgetFocus=" ..
      str(viaWidget and props(viaWidget).Name) .. "  chain=" .. tostring(#chain))
    local out = {}
    for i = 1, #chain do
        local o = chain[i]
        local p = props(o)
        local cls, label = A.splitToString(A.realType(o))
        local step = {
            depth = i,
            cls = cls,
            name = str(p.Name),
            text = shortText(p, cls, label),
            focused = (p.IsFocused == true),
        }
        local d = soft(Pad.dataOf, o)
        if type(d) == "table" then
            local rec = {}
            for k, v in pairs(d) do
                local val = value(v)
                if val ~= nil then rec[tostring(k)] = val
                elseif type(v) == "userdata" then
                    for kk, vv in pairs(flat(v, tostring(k), {}, 1)) do rec[kk] = vv end
                else rec[tostring(k)] = "<" .. type(v) .. ">" end
            end
            step.record = rec
        end
        local t = soft(A.collectText, o, 40, 8)
        if type(t) == "table" and #t > 0 then step.under = table.concat(t, " | ") end
        out[#out + 1] = step
        P(i .. ". " .. cls .. " " .. str(p.Name) .. (step.focused and " FOCUSED" or "") ..
          (step.under and ("  under=" .. step.under) or "") ..
          (step.record and "  +record" or ""))
    end
    A.write("lvl_focus", out)
    return out
end

--- One spell row, unfolded whole, wherever the first one is.
---
--- The question this settles is the only one that matters for the spell tabs: what names a
--- spell. Everything in the panel is bound to `ls:VMSpellReference` - `Spell`, `Selected`,
--- `NotAvailable` - and `Spell` is where the name has to be.
function W.spellsample(budget)
    local node, found = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local out, left, taken = {}, { n = budget or 40000 }, 0
    local function rec(o, d, path)
        if o == nil or d > 26 or left.n <= 0 or taken >= 3 then return end
        left.n = left.n - 1
        local p = props(o)
        local isElement = (p.ActualWidth ~= nil or p.IsVisible ~= nil)
        if not isElement and p.Spell ~= nil and type(p.Spell) == "userdata" then
            taken = taken + 1
            local rec2 = flat(p.Spell, "Spell", {}, 1)
            rec2["_at"] = path
            rec2["_Selected"] = (p.Selected == true)
            rec2["_NotAvailable"] = (p.NotAvailable == true)
            out[#out + 1] = rec2
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            local kp = props(ch[i])
            local knm = str(kp.Name)
            rec(ch[i], d + 1, path .. "/" .. ((knm ~= "nil" and knm ~= "") and knm or tostring(i)))
        end
    end
    rec(node, 0, found)
    P("spell samples: " .. #out)
    A.write("lvl_spell", out)
    return out
end

--- The focused row itself, from every angle at once.
---
--- The row has no text and its record is not one of its children, so something else has to
--- carry the name across. Four candidates, and this asks all of them in one pass rather than
--- one console round trip each: the button's own properties, the three bound properties a
--- miss on which would throw (so each is pcall'd), the records hanging off the ItemsControl
--- it belongs to, and the row's position among its siblings - because if the records come
--- back in drawing order, position is the whole mapping.
function W.leaf()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local leaf = soft(Pad.widgetFocus, node)
    if leaf == nil then P("nothing focused") return nil end
    local out = { props = {}, asked = {}, kids = {}, siblings = {}, items = {} }

    local p = props(leaf)
    for k, v in pairs(p) do
        local val = value(v)
        out.props[tostring(k)] = (val ~= nil) and val or ("<" .. type(v) .. ">")
    end
    P("leaf " .. str(p.Name) .. " " .. select(1, A.splitToString(A.realType(leaf))))

    for _, want in ipairs({ "DataContext", "CommandParameter", "Content", "Tag", "ToolTip" }) do
        local got = soft(function() return leaf:GetProperty(want) end)
        if got == nil then
            out.asked[want] = "<nil>"
        elseif type(got) == "userdata" then
            local rec = flat(got, want, {}, 2)
            local n = 0
            for k, v in pairs(rec) do out.asked[k] = v n = n + 1 end
            if n == 0 then out.asked[want] = "<opaque userdata>" end
        else
            out.asked[want] = tostring(got)
        end
        P("  " .. want .. " -> " .. tostring(out.asked[want] or "(unfolded)"))
    end

    local ch, cn = A.kids(leaf)
    for i = 1, cn do
        out.kids[i] = select(1, A.splitToString(A.realType(ch[i]))) .. " " .. str(props(ch[i]).Name)
    end

    -- Where the row sits among its siblings, and what the list it belongs to holds. The
    -- chain from focusChain is the only ancestry available - Noesis `Parent` is the logical
    -- parent and comes back nil at the first template boundary.
    local chain = Pad.focusPath or {}
    for i = #chain - 1, 1, -1 do
        local parent = chain[i]
        local pc = select(1, A.splitToString(A.realType(parent)))
        local pch, pcn = A.kids(parent)
        if pc:find("Panel", 1, true) or pc:find("ItemsControl", 1, true) then
            local target = tostring(chain[i + 1])
            for j = 1, pcn do
                if tostring(pch[j]) == target then
                    out.siblings[#out.siblings + 1] = pc .. ": child " .. j .. " of " .. pcn
                    P("  " .. pc .. ": row is child " .. j .. " of " .. pcn)
                end
            end
        end
        if pc:find("ItemsControl", 1, true) then
            for j = 1, pcn do
                local kp = props(pch[j])
                if kp.ActualWidth == nil and kp.IsVisible == nil then
                    local nm = kp.Spell and str(soft(function() return kp.Spell:GetAllProperties().Name end)) or "(no Spell)"
                    out.items[#out.items + 1] = j .. ": " .. nm ..
                        (kp.Selected == true and " SELECTED" or "") ..
                        (kp.NotAvailable == true and " unavailable" or "")
                end
            end
            P("  ItemsControl holds " .. #out.items .. " records")
            break
        end
    end
    A.write("lvl_leaf", out)
    return out
end

--- Name the focused row, two ways, and print both so the wrong one shows itself.
---
--- Way one is a path nobody would guess and the property dump handed over: the button's
--- `ToolTip` is a live object, its `TemplatedParent` is the button as the tooltip sees it,
--- and *that* one carries `DataContext` - which the button's own `GetAllProperties()` does
--- not, because the context is inherited rather than set on it.
---
--- Way two needs no such luck: the records hang off the `ItemsControl` as children that are
--- not elements, after the one visual child, and the generated rows sit in the same order
--- under the panel. So the row's index among its siblings maps onto the record list. It is
--- arithmetic on a layout assumption, which is why it is worth checking against way one
--- rather than trusting either alone.
function W.name()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local leaf = soft(Pad.widgetFocus, node)
    if leaf == nil then P("nothing focused") return nil end
    local out = {}

    -- Way one.
    local tip = soft(function() return leaf:GetProperty("ToolTip") end)
    local tp = tip and soft(function() return tip:GetProperty("TemplatedParent") end)
    local dc = tp and soft(function() return tp:GetProperty("DataContext") end)
    if dc ~= nil then
        local dp = soft(function() return dc:GetAllProperties() end)
        if type(dp) == "table" then
            local bits = {}
            for k, v in pairs(dp) do bits[#bits + 1] = tostring(k) end
            table.sort(bits)
            out.viaTooltip = { shape = table.concat(bits, ",") }
            if type(dp.Spell) == "userdata" then
                local sp = soft(function() return dp.Spell:GetAllProperties() end) or {}
                out.viaTooltip.name = Pad.loca(str(sp.Name))
                out.viaTooltip.level = sp.Level
                out.viaTooltip.school = str(sp.SpellSchool)
                out.viaTooltip.selected = (dp.Selected == true)
                out.viaTooltip.notAvailable = (dp.NotAvailable == true)
            end
            P("via tooltip: " .. tostring(out.viaTooltip.name) .. "  (" ..
              out.viaTooltip.shape .. ")")
        end
    else
        P("via tooltip: nothing")
    end

    -- Way two.
    if soft(Pad.pathTo, node, leaf) then
        local chain = Pad.focusPath or {}
        local idx, list = nil, nil
        for i = #chain - 1, 1, -1 do
            local parent, kid = chain[i], chain[i + 1]
            local cls = select(1, A.splitToString(A.realType(parent)))
            local ch, cn = A.kids(parent)
            if idx == nil and (cls:find("Panel", 1, true) or cls:find("Presenter", 1, true)) then
                for j = 1, cn do
                    if tostring(ch[j]) == tostring(kid) then
                        if cls:find("Panel", 1, true) then idx = j end
                        break
                    end
                end
            end
            if cls:find("ItemsControl", 1, true) then
                list = {}
                for j = 1, cn do
                    local kp = props(ch[j])
                    if kp.ActualWidth == nil and kp.IsVisible == nil then
                        local nm = "(empty slot)"
                        if type(kp.Spell) == "userdata" then
                            local sp = soft(function() return kp.Spell:GetAllProperties() end) or {}
                            nm = Pad.loca(str(sp.Name))
                        end
                        list[#list + 1] = nm .. (kp.Selected == true and " [выбрано]" or "") ..
                                          (kp.NotAvailable == true and " [нет]" or "")
                    end
                end
                out.viaPosition = { index = idx, count = #list, list = list,
                                    itemsControl = str(props(parent).Name) }
                P("via position: row " .. tostring(idx) .. " of " .. #list .. " in " ..
                  str(props(parent).Name) .. " -> " .. tostring(idx and list[idx]))
                for j = 1, math.min(#list, 12) do P("    " .. j .. ". " .. list[j]) end
                break
            end
        end
    else
        P("via position: pathTo failed")
    end

    A.write("lvl_name", out)
    return out
end

--- Whether a spell row can say what the spell *does*, and not only what it is called.
---
--- `Spell.Name` is a loca handle, which gives the name and nothing else. `Spell.ExtenderData`
--- is the extender's own view of the same object, and if it carries the stats id then
--- `M.spellFacts` - cost, reach, save, damage, school, and the game's own sentence - applies
--- to the level-up screen unchanged. That is the difference between "Огненные ладони" and
--- "Огненные ладони. Действие, область 5 м, спасбросок Ловкости, урон 3к6 огнём."
function W.ed()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local found = nil
    local function rec(o, d)
        if o == nil or d > 26 or found ~= nil then return end
        local p = props(o)
        if p.ActualWidth == nil and p.IsVisible == nil and type(p.Spell) == "userdata" then
            found = p.Spell
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(node, 0)
    if found == nil then P("no spell record on screen") return nil end

    local sp = soft(function() return found:GetAllProperties() end) or {}
    local out = { name = str(sp.Name), translated = Pad.loca(str(sp.Name)),
                  level = sp.Level, school = str(sp.SpellSchool) }
    if type(sp.ExtenderData) == "userdata" then
        local e = soft(function() return sp.ExtenderData:GetAllProperties() end)
        if type(e) == "table" then
            for k, v in pairs(e) do
                local val = value(v)
                out["ED." .. tostring(k)] = (val ~= nil) and val or ("<" .. type(v) .. ">")
            end
        else
            -- Not a Noesis object: the extender hands its own userdata here, so the fields
            -- have to be asked for by name rather than enumerated.
            for _, want in ipairs({ "Id", "Prototype", "OriginatorPrototype", "SpellId",
                                    "Name", "PrototypeId", "SpellPrototype" }) do
                local got = soft(function() return sp.ExtenderData[want] end)
                if got ~= nil then out["ED." .. want] = str(got) end
            end
        end
    end
    -- And the same question asked the other way: does the layer's own index know this handle?
    out.viaSpellBook = str(soft(Pad.spellIdFor, str(sp.Name)))
    for k, v in pairs(out) do P("  " .. k .. " = " .. tostring(v)) end
    A.write("lvl_ed", out)
    return out
end

--- How dear it is to know every spell by its name, and not just the ones already learnt.
---
--- `Pad.spellIdFor` is built from the character's own spell book, so on this screen it answers
--- nothing: the spells being chosen are precisely the ones not learnt yet. The index that
--- would answer is every `SpellData` entry keyed by its `DisplayName` handle - and the only
--- question is what it costs to build, because a second-long freeze on a keypress is not
--- something to ship without knowing about it.
function W.statsindex()
    local t0 = tonumber(soft(Ext.Utils.MonotonicTime)) or 0
    local ids = soft(Ext.Stats.GetStats, "SpellData")
    if ids == nil then P("Ext.Stats.GetStats('SpellData') is nil") return nil end
    local n = tonumber(soft(function() return #ids end)) or 0
    local t1 = tonumber(soft(Ext.Utils.MonotonicTime)) or 0
    local by, hits = {}, 0
    for i = 1, n do
        local id = soft(function() return ids[i] end)
        local e = id ~= nil and soft(Ext.Stats.Get, id) or nil
        local h = e ~= nil and soft(function() return e.DisplayName end) or nil
        if type(h) == "string" and h ~= "" then
            -- Stats handles carry a version suffix ("h1234…;3"); the UI's do not.
            local bare = h:match("^([^;]+)") or h
            if by[bare] == nil then by[bare] = id hits = hits + 1 end
        end
    end
    local t2 = tonumber(soft(Ext.Utils.MonotonicTime)) or 0
    P("SpellData: " .. n .. " ids in " .. (t1 - t0) .. " ms, " .. hits ..
      " named in " .. (t2 - t1) .. " ms")
    -- And the one the player is looking at, end to end.
    local probe = "h5c7a28e3geb16g40abg82e9g066a3384ecc1"
    P("  " .. Pad.loca(probe) .. " -> " .. tostring(by[probe]))
    if by[probe] ~= nil then P("  facts: " .. tostring(Pad.spellFacts(by[probe]))) end
    A.write("lvl_statsindex", { count = n, named = hits, listMs = t1 - t0, buildMs = t2 - t1,
                                probe = by[probe] })
    return by
end

--- The tab strip as the game keeps it: icons with a Tag, and no text anywhere.
---
--- `Pad.tabState` returns nothing here and this is why - the level-up tabs carry no caption,
--- only `Tag="skills"`, `Tag="feat"` and so on, and `tabItems` drops any item it cannot read
--- a string out of. So the position is real and the name has to come from the Tag.
function W.tabs()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local strip = soft(Pad.namedNode, node, "gameplayTabs", 12)
    if strip == nil then
        local m = soft(Pad.landmarks, node, 4000)
        strip = m and (m.tabs or m.strip)
    end
    if strip == nil then P("no tab strip") return nil end
    -- The ListBox's own answer, which is what the markup keys every panel off:
    -- `{Binding ElementName=gameplayTabs, Path=SelectedItem.Tag}`.
    local sp = props(strip)
    P("strip SelectedIndex=" .. str(sp.SelectedIndex) .. " Items=" .. str(sp.Items) ..
      " SelectedItem=" .. str(sp.SelectedItem))
    local selTag = nil
    if type(sp.SelectedItem) == "userdata" then
        local ip = props(sp.SelectedItem)
        selTag = str(ip.Tag)
        P("SelectedItem: name=" .. str(ip.Name) .. " tag=" .. selTag)
    end
    local out, seen = { selectedIndex = sp.SelectedIndex, selectedTag = selTag }, {}
    local function rec(o, d)
        if o == nil or d > 6 or #out >= 40 then return end
        local p = props(o)
        local cls = select(1, A.splitToString(A.realType(o)))
        if cls:find("ListBoxItem", 1, true) then
            local id = str(p.Name)
            if not seen[id] then
                seen[id] = true
                out[#out + 1] = {
                    name = id, tag = str(p.Tag),
                    selected = (p.IsSelected == true),
                    visible = (p.IsVisible ~= false),
                    text = (soft(A.collectText, o, 24, 5) or {})[1],
                }
            end
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(strip, 0)
    for i = 1, #out do
        P(i .. ". " .. out[i].name .. " tag=" .. out[i].tag ..
          (out[i].selected and " SELECTED" or "") .. (out[i].visible and "" or " hidden") ..
          (out[i].text and ("  text=" .. tostring(out[i].text)) or ""))
    end
    A.write("lvl_tabs", out)
    return out
end

--- What the layer says about this screen today, through its own eyes.
function W.now()
    local a = soft(Pad.active, 200, 4000)
    if a == nil then P("Pad.active found nothing") return nil end
    P("active: " .. str(a.name) .. ", " .. tostring(a.texts and #a.texts or 0) .. " texts")
    local lines = soft(Pad.linesOf, a)
    if type(lines) == "table" then
        for i = 1, math.min(#lines, 60) do P("  " .. i .. ". " .. tostring(lines[i])) end
        P("(" .. #lines .. " lines)")
    end
    local chain = soft(Pad.focusChain, a.node) or soft(function() return Pad.focusPath end)
    A.write("lvl_now", { name = str(a.name), texts = a.texts, lines = lines,
                         focus = a.focus and { text = a.focus.text } or nil })
    return lines
end

--- Watch what changes as the player moves. One pass a second, difference only.
---
--- The same trick the roll panel's bonus section was read with: whatever the d-pad does to
--- this screen, the strings that change are the ones under the cursor, and that needs no
--- theory about how the carousel models selection.
function W.watch(seconds)
    local last = nil
    local until_ = (seconds or 60)
    local n = 0
    local id
    id = Ext.Events.Tick:Subscribe(function()
        n = n + 1
        if n % 30 ~= 0 then return end
        if n / 30 > until_ then Ext.Events.Tick:Unsubscribe(id) P("watch done") return end
        local node = screenNode()
        if node == nil then return end
        local marks = soft(Pad.landmarks, node, 4000)
        local now = {}
        if type(marks) == "table" then
            for _, key in ipairs({ "panel", "sub", "summary" }) do
                if marks[key] ~= nil then
                    local t = soft(Pad.visibleScan, marks[key], 900, 40)
                    if type(t) == "table" and t.texts then
                        now[#now + 1] = key .. ": " .. table.concat(t.texts, " | ")
                    end
                end
            end
        end
        local joined = table.concat(now, "\n")
        if joined ~= last then
            last = joined
            P("--- change ---")
            for i = 1, #now do P(now[i]) end
        end
    end)
    _G.A11Y_LVL_WATCH = id
    P("watching for " .. until_ .. "s")
end

function W.unwatch()
    if _G.A11Y_LVL_WATCH ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(_G.A11Y_LVL_WATCH) end)
        _G.A11Y_LVL_WATCH = nil
        P("unwatched")
    end
end

function W.all()
    W.marks()
    W.names()
    W.tree(10, 6000)
    W.records()
    W.now()
end

return W
