-- What the character panel carries: the inventory, the equipment, and the states on a body.
--
-- `CharacterPanel_c` is the panel the quick menu opens, and it is three things at once - a
-- character sheet, an inventory shared across the party, and a paperdoll of what is worn. The
-- first dump says where the trouble is:
--
--   * **1422 records of the shape `{Index, Object}`.** That is the inventory: a cell is a slot
--     number and a game object, and the object is where every word about the item lives.
--   * A party member's inventory is an `Expander` whose header is an `ls.LSToggleButton` named
--     `ExpanderButton` - the same shape the save-game list uses, which is why the layer
--     announced «Гейл, группа сохранений, развёрнуто, 1 из 3» over an inventory.
--   * The characters are named `ResStr_1732220843`, which is a runtime string reference and
--     not a loca handle, so `Ext.Loca` cannot translate it. Their `EntityUUID` can.
--
-- This only looks. It moves nothing and equips nothing.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-inv", "IV")
--     Mods.BG3Access.IV.all()

local A, Pad = _G.A11y, _G.Pad
local W = {}

local SCREEN = "CharacterPanel_c"

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end
local function P(s) soft(Ext.Utils.Print, "[inv] " .. tostring(s)) end

local function props(o)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) == "table" then return p end
    return {}
end

local function screenNode(want)
    want = tostring(want or SCREEN)
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if ws[i].visible ~= false and str(ws[i].name) == want then return ws[i].node, want end
    end
    return nil, nil
end
W.node = screenNode

local function value(v)
    local t = type(v)
    if t == "number" or t == "boolean" then return v end
    if t == "string" then return (#v > 300) and (v:sub(1, 300) .. "...") or v end
    return nil
end

-- Flat, because `A.write` folds anything past three levels into the string "<depth>" - which
-- is exactly what happened to the first look at an inventory cell: `Object` was there and
-- came out as the word "<depth>".
local function flat(v, prefix, out, d, maxd)
    out = out or {}
    d = d or 0
    if d > (maxd or 2) then out[prefix] = "<deep>" return out end
    local p = soft(function() return v:GetAllProperties() end)
    if type(p) ~= "table" then out[prefix] = "<" .. type(v) .. ">" return out end
    for k, vv in pairs(p) do
        local key = prefix .. "." .. tostring(k)
        local val = value(vv)
        if val ~= nil then out[key] = val
        elseif type(vv) == "userdata" then flat(vv, key, out, d + 1, maxd)
        else out[key] = "<" .. type(vv) .. ">" end
    end
    return out
end
W.flat = flat

--- The first few inventory cells, unfolded whole.
---
--- The one question that decides everything else on this screen: what names an item, what says
--- how many there are, how heavy it is, what it is worth, and whether it is worn.
function W.cells(want, budget)
    local node, found = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    want = want or 4
    local out, left, taken = {}, { n = budget or 60000 }, 0
    local function rec(o, d, path)
        if o == nil or d > 26 or left.n <= 0 or taken >= want then return end
        left.n = left.n - 1
        local p = props(o)
        local isElement = (p.ActualWidth ~= nil or p.IsVisible ~= nil)
        if not isElement and p.Index ~= nil and type(p.Object) == "userdata" then
            taken = taken + 1
            -- Deep enough to reach `Object.Stats.Weight`, which is an object and not a
            -- number: at two levels it came back as the word "<deep>".
            local rec2 = flat(p.Object, "Object", {}, 1, 3)
            rec2["_at"] = path
            rec2["_Index"] = p.Index
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
    P("cells: " .. #out)
    A.write("inv_cells", out)
    return out
end

--- The element the game says the cursor is on, and everything reachable from it.
---
--- An inventory cell is a generated row like a spell row is, so the same two routes apply -
--- the record beside it, and the tooltip's TemplatedParent. Both are asked here, along with
--- the ancestry, because on this screen the row's *container* matters as much as the row: the
--- same cell means different things in a party member's bag and in the equipment paperdoll.
function W.focus()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local leaf = soft(Pad.widgetFocus, node)
    if leaf == nil then P("nothing focused") return nil end
    local out = { chain = {} }

    local p = props(leaf)
    local cls = select(1, A.splitToString(A.realType(leaf)))
    P("leaf " .. cls .. " " .. str(p.Name))
    out.leaf = { cls = cls, name = str(p.Name) }
    for k, v in pairs(p) do
        local val = value(v)
        out["leaf." .. tostring(k)] = (val ~= nil) and val or ("<" .. type(v) .. ">")
    end

    local rec = soft(Pad.dataBehind, leaf)
    if type(rec) == "table" then
        local bits = {}
        for k in pairs(rec) do bits[#bits + 1] = tostring(k) end
        table.sort(bits)
        P("record: " .. table.concat(bits, ","))
        out.recordShape = table.concat(bits, ",")
        for k, v in pairs(rec) do
            local val = value(v)
            if val ~= nil then out["rec." .. tostring(k)] = val
            elseif type(v) == "userdata" then
                for kk, vv in pairs(flat(v, "rec." .. tostring(k), {}, 1, 2)) do out[kk] = vv end
            else out["rec." .. tostring(k)] = "<" .. type(v) .. ">" end
        end
    else
        P("record: none")
    end

    -- The ancestry, which says which of the panel's several lists the cursor is in.
    if soft(Pad.pathTo, node, leaf) then
        local chain = Pad.focusPath or {}
        for i = 1, #chain do
            local q = chain[i]
            local qp = props(q)
            local qc = select(1, A.splitToString(A.realType(q)))
            local t = (soft(A.collectText, q, 12, 4) or {})[1]
            out.chain[i] = qc .. " " .. str(qp.Name) .. (t and ("  «" .. tostring(t) .. "»") or "")
            P("  " .. i .. ". " .. out.chain[i])
        end
    end
    A.write("inv_focus", out)
    return out
end

--- What the selected character is wearing, from the model rather than from the paperdoll.
---
--- `Equipment` on a character record names every slot the game has - Amulet, Boots, Breast,
--- Cloak, Gloves, Helmet, LightSource, MeleeMainHand, MeleeOffHand, MusicalInstrument,
--- RangedMainHand, RangedOffHand, Ring, Ring2, Underwear, VanityBody, VanityBoots - so "what
--- am I wearing" needs no walk of the tree at all if the slots hold what they look like.
function W.equip()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local vm = soft(Pad.dataOf, node)
    if type(vm) ~= "table" then P("no widget record") return nil end
    local cp = vm.CurrentPlayer
    if type(cp) ~= "userdata" then P("no CurrentPlayer") return nil end
    local cpp = soft(function() return cp:GetAllProperties() end)
    if type(cpp) ~= "table" then P("CurrentPlayer opaque") return nil end
    local sel = cpp.SelectedCharacter
    if type(sel) ~= "userdata" then P("no SelectedCharacter") return nil end
    local sp = soft(function() return sel:GetAllProperties() end) or {}

    local out = { uuid = str(sp.EntityUUID), name = str(sp.Name) }
    if type(sp.Equipment) == "userdata" then
        for k, v in pairs(flat(sp.Equipment, "Equipment", {}, 0, 3)) do out[k] = v end
    end
    P("equipment of " .. out.name .. " (" .. out.uuid .. ")")
    A.write("inv_equip", out)
    return out
end

--- The states on the body: what is helping and what is hurting.
function W.status()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local vm = soft(Pad.dataOf, node)
    if type(vm) ~= "table" then return nil end
    local cp = type(vm.CurrentPlayer) == "userdata"
        and soft(function() return vm.CurrentPlayer:GetAllProperties() end) or nil
    if type(cp) ~= "table" or type(cp.SelectedCharacter) ~= "userdata" then return nil end
    local sp = soft(function() return cp.SelectedCharacter:GetAllProperties() end) or {}

    local out = {}
    for _, field in ipairs({ "StatusEffects", "Tags" }) do
        local coll = sp[field]
        if type(coll) == "userdata" then
            -- A Noesis collection answers to Count and an indexer through GetAllProperties on
            -- each element; try the collection as an object first and say what came back.
            local cprops = soft(function() return coll:GetAllProperties() end)
            if type(cprops) == "table" then
                for k, v in pairs(cprops) do
                    local val = value(v)
                    out[field .. "." .. tostring(k)] = (val ~= nil) and val or ("<" .. type(v) .. ">")
                end
            else
                out[field] = "<opaque " .. type(coll) .. ">"
            end
        end
    end
    -- And the same question through the entity, which is where the world reader already gets
    -- statuses from and needs no view model at all.
    local uuid = str(sp.EntityUUID)
    out._uuid = uuid
    A.write("inv_status", out)
    for k, v in pairs(out) do P("  " .. k .. " = " .. tostring(v)) end
    return out
end

--- A cell of the grid, found in the tree rather than under the cursor.
---
--- The player's cursor is where it is, and the question - what does the reader get when it
--- lands on an item - has to be answerable without moving it. So this finds the first
--- `CellRoot` on the tree and asks it everything the reader would: its own text, the record
--- beside it, the record through the tooltip, and the record of its parent list.
function W.cellnode()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local found, parent = nil, nil
    local function rec(o, d, up)
        if o == nil or d > 26 or found ~= nil then return end
        local p = props(o)
        if p.IsVisible == false then return end
        if str(p.Name) == "CellRoot" then found, parent = o, up return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1, o) end
    end
    rec(node, 0, nil)
    if found == nil then P("no CellRoot on the tree") return nil end

    local out = {}
    local p = props(found)
    out.cls = select(1, A.splitToString(A.realType(found)))
    out.name = str(p.Name)
    out.focusable = p.Focusable
    out.text = table.concat(soft(A.collectText, found, 40, 8) or {}, " | ")
    P("CellRoot " .. out.cls .. " focusable=" .. tostring(p.Focusable) ..
      " text=«" .. tostring(out.text) .. "»")

    for _, where in ipairs({ { "dataOf", found }, { "dataBehind", found },
                            { "parent.dataOf", parent } }) do
        if where[2] ~= nil then
            local fn = (where[1] == "dataBehind") and Pad.dataBehind or Pad.dataOf
            local r = soft(fn, where[2])
            if type(r) == "table" then
                local bits = {}
                for k in pairs(r) do bits[#bits + 1] = tostring(k) end
                table.sort(bits)
                out[where[1]] = table.concat(bits, ",")
                P("  " .. where[1] .. ": " .. out[where[1]])
                if type(r.Object) == "userdata" then
                    for k, v in pairs(flat(r.Object, where[1] .. ".Object", {}, 1, 1)) do
                        out[k] = v
                    end
                end
            else
                out[where[1]] = "(nothing)"
                P("  " .. where[1] .. ": nothing")
            end
        end
    end
    A.write("inv_cellnode", out)
    return out
end

--- Every item on the panel as name against type, which is the one field being guessed at.
---
--- `ItemType` reads plausibly on most rows and not on all of them - a shovel came out as
--- «свиток» - and a category said wrong is worse than one not said. This lists the pairs so
--- the table can be built from what the game actually uses rather than from what it looks
--- like it uses.
function W.types(budget)
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local out, left, seen = {}, { n = budget or 200000 }, {}
    local function rec(o, d)
        if o == nil or d > 26 or left.n <= 0 then return end
        left.n = left.n - 1
        local p = props(o)
        local isElement = (p.ActualWidth ~= nil or p.IsVisible ~= nil)
        if not isElement and type(p.Object) == "userdata" then
            local obj = soft(function() return p.Object:GetAllProperties() end)
            if type(obj) == "table" then
                local nm = Pad.loca(str(obj.Name))
                local key = nm .. "|" .. str(obj.ItemType)
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = { name = nm, itemType = str(obj.ItemType),
                                      typeText = Pad.loca(str(obj.TypeText)),
                                      useType = str(obj.UseType),
                                      isEquipment = (obj.IsEquipment == true),
                                      equipped = str(obj.Equipped),
                                      slot = str(obj.EquipmentSlotType) }
                end
            end
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(node, 0)
    P("types: " .. #out .. " distinct")
    A.write("inv_types", out)
    return out
end

--- The buttons this screen actually answers to, and what each one does.
---
--- The player's question was «я не понимаю как надевать предметы» - and the game does say,
--- in a row of icons along the bottom that a screen reader has never had a word of. Each hint
--- is a control carrying `BoundEvent` - the input event, `UIAccept`, `UIMessageBoxY`,
--- `UIFilter` - and a `Tag` or `Content` holding its caption. The pair is the answer.
---
--- Walked across every visible widget, not just this one: the shared hint bar lives in
--- `Overlay`, which is where X for the context menu was read off before.
function W.hints(budget)
    local ws = soft(Pad.findWidgets) or {}
    local out, seen = {}, {}
    for wi = 1, #ws do
        local w = ws[wi]
        if w.visible ~= false then
            local left = { n = budget or 40000 }
            local function rec(o, d)
                if o == nil or d > 26 or left.n <= 0 then return end
                left.n = left.n - 1
                local p = props(o)
                if p.IsVisible == false then return end
                local ev = str(p.BoundEvent)
                if ev ~= "nil" and ev ~= "" then
                    local cap = Pad.loca(str(p.Tag))
                    if type(cap) ~= "string" or cap == "nil" or cap == "" or cap:find("^h%x") then
                        cap = (soft(A.collectText, o, 30, 6) or {})[1]
                    end
                    local key = ev .. "|" .. tostring(cap)
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = { screen = str(w.name), event = ev,
                                          caption = cap, enabled = p.IsEnabled }
                        P(str(w.name) .. "  " .. ev .. " -> " .. tostring(cap) ..
                          (p.IsEnabled == false and " (disabled)" or ""))
                    end
                end
                local ch, cn = A.kids(o)
                for i = 1, cn do rec(ch[i], d + 1) end
            end
            rec(w.node, 0)
        end
    end
    P("hints: " .. #out)
    A.write("inv_hints", out)
    return out
end

--- The hint bar, which is the game answering "what can I do with this".
---
--- `ls:AlignableWrapPanel x:Name="Hints"` holds one button per action the panel offers, all
--- of them `Visibility="Collapsed"` and shown by triggers - so **whichever are visible are
--- exactly the actions available for the thing under the cursor**, and their captions change
--- with it: `ItemActionButton`'s Tag is bound through `GetUseActionConverter`, which is the
--- verb for this item («Надеть», «Выпить»).
---
--- Dumped child by child rather than searched for by `BoundEvent`, because the first attempt
--- looked for that property and found four nodes in the whole game with a caption of nil.
function W.hintbar(want)
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local bar = soft(Pad.namedNode, node, tostring(want or "Hints"), 14)
    if bar == nil then P("no node named " .. tostring(want or "Hints")) return nil end

    local out = {}
    local function rec(o, d)
        if o == nil or d > 8 then return end
        local p = props(o)
        local cls = select(1, A.splitToString(A.realType(o)))
        local ev = str(p.BoundEvent)
        local nm = str(p.Name)
        if ev ~= "nil" or nm ~= "nil" then
            out[#out + 1] = {
                depth = d, cls = cls, name = nm, event = ev,
                tag = Pad.loca(str(p.Tag)),
                visible = (p.IsVisible ~= false),
                enabled = p.IsEnabled,
                text = table.concat(soft(A.collectText, o, 40, 6) or {}, " | "),
            }
            local e = out[#out]
            P(string.rep(" ", d) .. cls .. " " .. nm .. "  ev=" .. ev ..
              (e.visible and "" or " hidden") .. "  tag=" .. tostring(e.tag) ..
              "  text=«" .. e.text .. "»")
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(bar, 0)
    A.write("inv_hintbar", out)
    return out
end

--- Which physical button each interface event is bound to.
---
--- The hint bar names its actions by event - `UIAccept`, `UIMessageBoxY`, `ContextMenu` - and
--- the game turns those into glyphs through `FindInputEventConverter` over
--- `CurrentPlayer.UIData.InputEvents`. If that table can be read, the layer can say «A» and
--- «Y» from the player's own bindings instead of from a table of guesses that a remap breaks.
function W.inputevents()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local vm = soft(Pad.dataOf, node)
    if type(vm) ~= "table" or type(vm.CurrentPlayer) ~= "userdata" then return nil end
    local cp = soft(function() return vm.CurrentPlayer:GetAllProperties() end)
    if type(cp) ~= "table" or type(cp.UIData) ~= "userdata" then return nil end
    local ui = soft(function() return cp.UIData:GetAllProperties() end)
    if type(ui) ~= "table" then return nil end

    local out = { _type = type(ui.InputEvents) }
    local ev = ui.InputEvents
    if type(ev) == "userdata" then
        local p = soft(function() return ev:GetAllProperties() end)
        if type(p) == "table" then
            for k, v in pairs(p) do out["prop." .. tostring(k)] = str(v) end
        end
        -- A Noesis collection answers to pairs even where GetAllProperties does not.
        local ok = pcall(function()
            local n = 0
            for k, v in pairs(ev) do
                n = n + 1
                if n > 60 then break end
                local vp = (type(v) == "userdata")
                    and soft(function() return v:GetAllProperties() end) or nil
                if type(vp) == "table" then
                    local bits = {}
                    for k2, v2 in pairs(vp) do bits[#bits + 1] = tostring(k2) .. "=" .. str(v2) end
                    table.sort(bits)
                    out["item." .. tostring(k)] = table.concat(bits, " ")
                else
                    out["item." .. tostring(k)] = str(v)
                end
            end
            out._count = n
        end)
        out._iterable = ok
    end
    for k, v in pairs(out) do P("  " .. k .. " = " .. tostring(v):sub(1, 160)) end
    A.write("inv_inputevents", out)
    return out
end

--- Where a string on screen actually lives.
---
--- The equipment slots label themselves - «Ближний бой», «Источник света», «Лагерь» all turn
--- up in a sweep of the panel - and no walk of the named nodes found a slot control. So ask
--- the other way round: find the text, and report the ancestry that leads to it.
function W.findText(want, budget)
    local node, found = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    want = tostring(want)
    local out, left = {}, { n = budget or 200000 }
    local stack = {}
    local function rec(o, d)
        if o == nil or d > 30 or left.n <= 0 or #out >= 8 then return end
        left.n = left.n - 1
        local p = props(o)
        if p.IsVisible == false then return end
        local cls, label = A.splitToString(A.realType(o))
        stack[#stack + 1] = cls .. "/" .. str(p.Name)
        for _, s in ipairs(A.strings(p.Text, label)) do
            if type(s) == "string" and s:find(want, 1, true) then
                out[#out + 1] = { text = s, path = table.concat(stack, " > "), depth = d,
                                  focusable = p.Focusable }
                P("«" .. s .. "» at " .. table.concat(stack, " > "))
                break
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
        stack[#stack] = nil
    end
    rec(node, 0)
    P(found .. ": " .. #out .. " hits for «" .. want .. "», " ..
      ((budget or 200000) - left.n) .. " nodes")
    A.write("inv_find", out)
    return out
end

--- Any named node on the panel, asked everything the reader would ask it.
---
--- The same question `cellnode` answers, for whichever control is being worked on next -
--- an equipment slot, a stat row, a tab - without waiting for the player's cursor to be
--- somewhere in particular. `want` is matched exactly; `nth` picks among the repeats.
function W.at(want, nth)
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    want, nth = tostring(want), tonumber(nth) or 1
    local found, seen = nil, 0
    local function rec(o, d)
        if o == nil or d > 26 or found ~= nil then return end
        local p = props(o)
        if p.IsVisible == false then return end
        if str(p.Name) == want then
            seen = seen + 1
            if seen >= nth then found = o return end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(node, 0)
    if found == nil then P("no visible node named " .. want) return nil end

    local p = props(found)
    local out = {
        cls = select(1, A.splitToString(A.realType(found))),
        focusable = p.Focusable,
        text = table.concat(soft(A.collectText, found, 60, 8) or {}, " | "),
    }
    P(want .. ": " .. out.cls .. " focusable=" .. tostring(p.Focusable) ..
      " text=«" .. out.text .. "»")
    for k, v in pairs(p) do
        local val = value(v)
        out["prop." .. tostring(k)] = (val ~= nil) and val or ("<" .. type(v) .. ">")
    end
    local r = soft(Pad.dataBehind, found)
    if type(r) == "table" then
        local bits = {}
        for k in pairs(r) do bits[#bits + 1] = tostring(k) end
        table.sort(bits)
        out.shape = table.concat(bits, ",")
        P("  record: " .. out.shape)
        for k, v in pairs(r) do
            local val = value(v)
            if val ~= nil then out["rec." .. tostring(k)] = val
            elseif type(v) == "userdata" then
                for kk, vv in pairs(flat(v, "rec." .. tostring(k), {}, 1, 2)) do out[kk] = vv end
            else out["rec." .. tostring(k)] = "<" .. type(v) .. ">" end
        end
    else
        P("  record: none")
    end
    A.write("inv_at_" .. want, out)
    return out
end

--- The states on a character, asked of the entity rather than of the view model.
---
--- `StatusEffects` on the record is a collection `GetAllProperties` will not open, so the
--- interface is a dead end for this. The client ECS is not: the world reader already works
--- through `Ext.Entity`, and a status container there is a plain list of names.
function W.entstatus(uuid)
    local nav = _G.Nav
    local me = nil
    if uuid ~= nil then me = soft(Ext.Entity.Get, uuid)
    elseif nav ~= nil and nav.me ~= nil then me = soft(nav.me) end
    if me == nil then me = soft(function() return Ext.Entity.GetLocalPlayer() end) end
    if me == nil then P("no entity") return nil end

    local out = {}
    local comps = soft(function() return me:GetAllComponentNames() end)
    if type(comps) == "table" then
        local names = {}
        for i = 1, #comps do
            local n = str(comps[i])
            if n:lower():find("status", 1, true) then names[#names + 1] = n end
        end
        out.statusComponents = table.concat(names, ", ")
        P("status components: " .. out.statusComponents)
    end
    for _, field in ipairs({ "StatusContainer", "ServerStatusContainer", "StatusImmunities" }) do
        local c = soft(function() return me[field] end)
        if c == nil then goto continue end
        -- Not Stringify: the container keys by entity handle, and Ext.Json refuses a table
        -- whose keys are neither strings nor numbers ("Can only stringify string or number
        -- table keys"). Walk it instead and keep the values, which are the status names.
        local dumped = soft(function() return Ext.Types.Serialize(c) end)
        if type(dumped) == "table" then
            local n = 0
            for k, v in pairs(dumped) do
                n = n + 1
                if n > 40 then break end
                if type(v) == "table" then
                    local inner = {}
                    for k2, v2 in pairs(v) do
                        inner[#inner + 1] = tostring(k2) .. "=" .. tostring(v2)
                        if #inner > 8 then break end
                    end
                    out[field .. "." .. tostring(k)] = table.concat(inner, " ")
                else
                    out[field .. "." .. tostring(k)] = tostring(v)
                end
            end
            P(field .. ": " .. n .. " entries")
        else
            out[field] = "<opaque>"
            P(field .. ": opaque")
        end
        ::continue::
    end
    A.write("inv_entstatus", out)
    return out
end

--- Every named node of the panel, with the path to it.
function W.names(budget)
    local node, found = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local out, left, seen = {}, { n = budget or 60000 }, {}
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
    P(found .. ": " .. #out .. " named, " .. ((budget or 60000) - left.n) .. " walked")
    A.write("inv_names", out)
    return out
end

--- The tabs of the panel, and which one is open.
function W.tabs()
    local node = screenNode()
    if node == nil then P("no visible " .. SCREEN) return nil end
    local out = {}
    -- The open tab names itself: `Tabs/TabName` held «Инвентарь» in the first dump.
    local tabName = soft(Pad.namedNode, node, "TabName", 12)
    if tabName ~= nil then
        out.open = (soft(A.collectText, tabName, 12, 4) or {})[1]
        P("open tab: " .. tostring(out.open))
    end
    -- And the strip itself, whatever it turns out to be called.
    local marks = soft(Pad.landmarks, node, 2000)
    if type(marks) == "table" then
        local got = {}
        for k in pairs(marks) do if k ~= "nodes" then got[#got + 1] = k end end
        table.sort(got)
        out.landmarks = table.concat(got, ",")
        P("landmarks: " .. out.landmarks .. " in " .. tostring(marks.nodes) .. " nodes")
        local strip = marks.tabs or marks.strip
        if strip ~= nil then
            local sp = props(strip)
            out.selectedIndex = sp.SelectedIndex
            local items, sel = soft(Pad.tabItems, strip)
            if type(items) == "table" then
                out.items = {}
                for i = 1, #items do
                    out.items[i] = items[i].text .. (items[i].selected and " SELECTED" or "")
                end
                P("strip: " .. #items .. " items, selected " .. tostring(sel))
            end
        end
    end
    A.write("inv_tabs", out)
    return out
end

--- Every visible widget and every string in it, for when the panel you want is not the widget
--- you expected.
function W.sweep(budget, depth)
    local ws = soft(Pad.findWidgets) or {}
    local out = {}
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false then
            local info = soft(function() return Pad.visibleScan(w.node, budget or 1500, depth or 60) end)
            if type(info) == "table" and info.texts ~= nil and #info.texts > 0 then
                out[#out + 1] = { screen = str(w.name), n = #info.texts,
                                  texts = table.concat(info.texts, " | ") }
                P(str(w.name) .. ": " .. #info.texts)
            end
        end
    end
    A.write("inv_sweep", out)
    return out
end

--- What the layer says about this panel today.
function W.now()
    local a = soft(Pad.active, 200, 6000)
    if a == nil then P("Pad.active found nothing") return nil end
    P("active: " .. str(a.name) .. ", " .. tostring(a.texts and #a.texts or 0) .. " texts")
    A.write("inv_now", { name = str(a.name), texts = a.texts, lines = soft(Pad.linesOf, a),
                         lastFocus = str(Pad.lastFocus), lastScreen = str(Pad.lastScreen) })
    return a
end

function W.all()
    W.tabs()
    W.names()
    W.cells()
    W.equip()
    W.status()
    W.focus()
    W.now()
end

return W
