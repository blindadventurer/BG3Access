-- What a skill actually does, and where a line spoken outside a dialogue lives.
--
-- Two complaints from the same session, and both are about text the layer never reaches:
--
--   * A character says something in the world - a remark on entering a room, a companion's
--     aside - and it is subtitled on screen and never read. The dialogue reader only runs when
--     `Dialogue_c` is up, and none of this is that.
--   * In the round menu a slot is announced by name and nothing else. "Направленный луч" does
--     not say what it does, how far it reaches, or what it costs, and in a fight the wheel is
--     the whole interface.
--
-- Neither can be answered by guessing a widget name, so nothing here assumes one. It records
-- what is on the tree and what changes on it, and the answer is read out of that.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-skill", "SK")
--     Mods.BG3Access.SK.widgets()     -- everything up now, with the text it carries
--     Mods.BG3Access.SK.radial()      -- hold the bumper first: every slot's whole record
--     Mods.BG3Access.SK.stats("Target_MagicMissile")
--     Mods.BG3Access.SK.watch(60)     -- 60 s of new text appearing anywhere, dialogue excluded
--     Mods.BG3Access.SK.stop()

local A, Pad = _G.A11y, _G.Pad
local M = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end
local function P(s) soft(Ext.Utils.Print, "[skill] " .. tostring(s)) end

local function save(name, tbl)
    local js = soft(Ext.Json.Stringify, tbl)
    if js == nil then P("could not stringify " .. name) return end
    soft(Ext.IO.SaveFile, "A11y/" .. name, js)
    P("wrote A11y/" .. name)
end

--- Every property of a Noesis object, flattened to short strings.
---
--- Values are truncated rather than dropped: a description is the thing being looked for here,
--- but a hundred of them at full length is a file nobody reads.
local function flatten(o, cap)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(p) do
        local s = str(v)
        if #s > (cap or 160) then s = s:sub(1, cap or 160) .. "…" end
        out[str(k)] = s
    end
    return out
end
M.flatten = flatten

-- 1. What is on the tree -----------------------------------------------------------------
--
-- Wide on purpose. The subtitle host is whichever of these carries the line, and its name is
-- exactly what is not known.

function M.widgets(cap)
    local ws = soft(Pad.findWidgets) or {}
    local out = {}
    for i = 1, #ws do
        local w = ws[i]
        local texts = soft(Pad.textsOf, w.node, nil, cap or 12) or {}
        out[#out + 1] = { name = str(w.name), visible = w.visible ~= false, texts = texts }
        if #texts > 0 then
            P(str(w.name) .. (w.visible ~= false and "" or " (hidden)") .. ": " ..
              table.concat(texts, " | "):sub(1, 200))
        end
    end
    save("skill-widgets.json", { at = soft(Ext.Utils.MonotonicTime), widgets = out })
    return out
end

-- 2. The wheel, whole --------------------------------------------------------------------
--
-- `radialSlot` takes three fields off the item's data context and the layer says those. This
-- takes every field there is, on every slot, so that what else is on the record - a spell id
-- above all, which is the way into the stats - stops being a guess.

function M.radial()
    local ws = soft(Pad.findWidgets) or {}
    local out, found = {}, false
    for i = 1, #ws do
        local w = ws[i]
        local nm = str(w.name)
        if w.visible ~= false and (nm == "ActionRadials" or nm == "shortcutsMenu") then
            found = true
            local radial, page, pages = soft(Pad.findRadial, w.node)
            if radial == nil then
                P(nm .. ": no radial inside it")
            else
                local items = soft(Pad.radialItems, radial) or {}
                local sel = tonumber(soft(function() return radial:GetAllProperties().SelectedIndex end))
                P(nm .. ": page " .. str(page) .. "/" .. str(pages) .. ", " .. #items ..
                  " slots, SelectedIndex " .. str(sel))
                for k = 1, #items do
                    local ip = soft(function() return items[k]:GetAllProperties() end)
                    local rec = nil
                    if type(ip) == "table" and type(ip.DataContext) == "userdata" then
                        rec = flatten(ip.DataContext)
                    end
                    out[#out + 1] = { widget = nm, slot = k, selected = (sel ~= nil and k == sel + 1),
                                      item = type(ip) == "table" and flatten(items[k]) or nil,
                                      record = rec }
                end
            end
        end
    end
    if not found then P("no wheel is up - hold the bumper and run this again") end
    save("skill-radial.json", { at = soft(Ext.Utils.MonotonicTime), slots = out })
    return out
end

-- 3. The stats entry behind a slot -------------------------------------------------------
--
-- Where the words the player is missing actually live. `Ext.Stats.Get` answers for a spell by
-- its id; the fields worth having are the description and the numbers around it, and which of
-- them exist is measured here rather than assumed.

M.STAT_FIELDS = { "DisplayName", "Description", "DescriptionParams", "ExtraDescription",
                  "ShortDescription", "ShortDescriptionParams", "TooltipDamageList",
                  "TooltipAttackSave", "TooltipStatusApply", "TooltipUpcastDescription",
                  "SpellType", "Level", "SpellSchool", "TargetRadius", "AreaRadius",
                  "Range", "UseCosts", "HitCosts", "RitualCosts", "SpellProperties",
                  "SpellRoll", "SpellSuccess", "SpellFail", "Cooldown", "PrepareEffect",
                  "RequirementConditions", "VerbalIntent", "AmountOfTargets" }

function M.stats(id)
    if type(id) ~= "string" or id == "" then P("stats(id) wants a spell id") return nil end
    local e = soft(Ext.Stats.Get, id)
    if e == nil then P("no stats entry '" .. id .. "'") return nil end
    local out = { id = id }
    for _, f in ipairs(M.STAT_FIELDS) do
        local v = soft(function() return e[f] end)
        if v ~= nil and str(v) ~= "" then
            out[f] = str(v)
            P(f .. " = " .. str(v):sub(1, 200))
        end
    end
    save("skill-stats.json", out)
    return out
end

--- The words the game keeps about a spell, resolved rather than left as handles.
---
--- The point of asking is whether there is a *short* form. The mechanical facts a wheel slot
--- can carry - cost, reach, damage - say nothing at all about something like Rage, whose whole
--- meaning is in prose, and the full description is far too long to say between two turns of
--- the stick.
function M.describe(id)
    local e = soft(Ext.Stats.Get, id)
    if e == nil then P("no stats entry '" .. tostring(id) .. "'") return nil end
    local function L(h)
        if type(h) ~= "string" or h == "" or h:sub(1, 1) ~= "h" then return nil end
        local r = soft(Ext.Loca.GetTranslatedString, h)
        return r ~= nil and str(r) or nil
    end
    local out = { id = id }
    for _, f in ipairs({ "DisplayName", "Description", "ShortDescription", "ExtraDescription",
                         "DescriptionParams", "ShortDescriptionParams", "TooltipStatusApply",
                         "SpellProperties", "Duration", "UseCosts" }) do
        local v = soft(function() return e[f] end)
        if v ~= nil and str(v) ~= "" then
            out[f] = str(v)
            local t = L(str(v))
            if t ~= nil then
                out[f .. "_text"] = t
                P(f .. ": " .. t)
            else
                P(f .. " = " .. str(v))
            end
        end
    end
    save("skill-describe.json", out)
    return out
end

--- Every spell this character can cast, from the model rather than from the wheel.
---
--- The wheel is only up while a bumper is held, which makes it a poor place to learn from. The
--- spellbook is there all the time.
function M.spells(cap)
    local me = soft(function() return Ext.Entity.GetLocalPlayer and Ext.Entity.GetLocalPlayer() end)
    if me == nil and _G.Nav ~= nil then me = soft(_G.Nav.me) end
    if me == nil then P("no local character") return nil end
    local book = soft(function() return me.SpellBook end)
    if book == nil then P("no SpellBook component on the character") return nil end
    local list = soft(function() return book.Spells end)
    if list == nil then P("SpellBook carries no Spells") return nil end
    local out = {}
    local n = tonumber(soft(function() return #list end)) or 0
    P("spells: " .. n)
    for i = 1, math.min(n, cap or 40) do
        local s = soft(function() return list[i] end)
        if s ~= nil then
            local id = soft(function() return s.Id and s.Id.OriginatorPrototype end)
                    or soft(function() return s.Id.Prototype end)
            out[#out + 1] = { i = i, id = str(id), fields = flatten(s, 80) }
        end
    end
    save("skill-spells.json", { at = soft(Ext.Utils.MonotonicTime), spells = out })
    return out
end

-- 3b. One named widget, all the way down --------------------------------------------------
--
-- `textsOf` is the layer's ordinary walk and it is capped - 24 strings, 24 levels - because it
-- runs sixty times a second on everything. A line spoken over a character's head may well sit
-- deeper than that, and "the walk found nothing" and "there is nothing there" are not the same
-- answer. This one is uncapped, dumps the data record as well as the tree, and is only ever
-- run by hand.

function M.dump(name, depth)
    local ws = soft(Pad.findWidgets) or {}
    local out = {}
    for i = 1, #ws do
        local w = ws[i]
        if str(w.name) == name then
            local rec = { name = name, visible = w.visible ~= false }
            rec.props = flatten(w.node, 100)
            local p = soft(function() return w.node:GetAllProperties() end)
            if type(p) == "table" and type(p.DataContext) == "userdata" then
                rec.data = flatten(p.DataContext, 200)
            end
            -- The tree, by hand, with no cap and every class kept.
            local texts, nodes = {}, 0
            local function rec2(o, d)
                if o == nil or d > (depth or 30) or nodes > 4000 then return end
                nodes = nodes + 1
                local pp = soft(function() return o:GetAllProperties() end)
                if type(pp) == "table" then
                    local t = pp.Text
                    if type(t) == "string" and t ~= "" then
                        texts[#texts + 1] = str(A and A.realType and select(2, A.splitToString(A.realType(o))) or "") ~= t
                            and (str(o) .. " | " .. t) or t
                    end
                    local _, label = A.splitToString(A.realType(o))
                    if type(label) == "string" and label ~= "" and label ~= "?" then
                        texts[#texts + 1] = "label: " .. label
                    end
                end
                local ch, cn = A.kids(o)
                for k = 1, cn do rec2(ch[k], d + 1) end
            end
            soft(rec2, w.node, 0)
            rec.nodes, rec.texts = nodes, texts
            P(name .. ": " .. nodes .. " nodes, " .. #texts .. " strings")
            for k = 1, math.min(#texts, 40) do P("   " .. texts[k]:sub(1, 180)) end
            out[#out + 1] = rec
        end
    end
    if #out == 0 then P("no widget named " .. tostring(name)) end
    save("skill-dump.json", { at = soft(Ext.Utils.MonotonicTime), widgets = out })
    return out
end

-- 3c. Catch a widget that only exists while a button is held -------------------------------
--
-- `ActionRadials` is on the tree only while the bumper is down and `Dialogue_c` only during a
-- conversation, so neither can be dumped by typing a line at the console and hoping. This arms
-- a tick handler that dumps each of them the first time it appears and then gets out of the way.
--
--     Mods.BG3Access.SK.arm()   -- then open the wheel once, and talk to somebody once

M.armId = nil
M.armGot = {}

--- Every field of every slot, next to the map the layer resolves them through.
---
--- Both halves in one file on purpose: the whole question is whether the handle on a slot is
--- the same handle the spell's stats entry displays under, and two files measured minutes apart
--- would not settle it.
local function radialSnapshot()
    local slots = M.radial()
    local book = {}
    local me = soft(function() return Ext.Entity.GetLocalPlayer and Ext.Entity.GetLocalPlayer() end)
    if me == nil and _G.Nav ~= nil then me = soft(_G.Nav.me) end
    local list = me ~= nil and soft(function() return me.SpellBook.Spells end) or nil
    if list ~= nil then
        local n = tonumber(soft(function() return #list end)) or 0
        for i = 1, n do
            local s = soft(function() return list[i] end)
            local id = s ~= nil and (soft(function() return s.Id.OriginatorPrototype end)
                                  or soft(function() return s.Id.Prototype end)) or nil
            if type(id) == "string" and id ~= "" then
                local e = soft(Ext.Stats.Get, id)
                book[#book + 1] = { id = id,
                                    displayName = e ~= nil and str(soft(function() return e.DisplayName end)) or nil }
            end
        end
    end
    save("skill-radial.json", { at = soft(Ext.Utils.MonotonicTime), slots = slots, book = book })
    P("radial captured: " .. #slots .. " slots, " .. #book .. " known spells")
end

--- The dialogue box with every node named, which is what says where a stray caption comes from.
local function dialogueSnapshot(node)
    local out = {}
    local function rec(o, d, path)
        if o == nil or d > 40 or #out > 400 then return end
        local p = soft(function() return o:GetAllProperties() end)
        local cls, label = A.splitToString(A.realType(o))
        local nm = type(p) == "table" and str(p.Name) or ""
        local here = path .. "/" .. cls .. (nm ~= "" and ("[" .. nm .. "]") or "")
        if type(p) == "table" then
            local t = p.Text
            if type(t) == "string" and t ~= "" then
                out[#out + 1] = { path = here, text = t, visible = p.IsVisible }
            end
            if type(label) == "string" and label ~= "" and label ~= "?" and label ~= tostring(t) then
                out[#out + 1] = { path = here, label = label, visible = p.IsVisible }
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1, here) end
    end
    soft(rec, node, 0, "")
    -- The box arrives on the tree before it has anything in it, the same way the tutorial modal
    -- does. Capturing on the frame it appears captures an empty tree and answers nothing, so a
    -- thin dump is refused and the caller tries again next pass.
    if #out < 4 then return 0 end
    save("skill-dialogue.json", { at = soft(Ext.Utils.MonotonicTime), nodes = out })
    P("dialogue captured: " .. #out .. " strings")
    for i = 1, math.min(#out, 30) do
        P("   " .. (out[i].text or out[i].label or "") .. "   <- " .. out[i].path:sub(-90))
    end
    return #out
end

function M.arm()
    M.disarm()
    M.armGot = {}
    local ticks = 0
    M.armId = soft(function()
        return Ext.Events.Tick:Subscribe(function()
            ticks = ticks + 1
            if ticks % 6 ~= 0 then return end
            local ws = soft(Pad.findWidgets) or {}
            for i = 1, #ws do
                local w = ws[i]
                local nm = str(w.name)
                if w.visible ~= false then
                    if nm == "ActionRadials" and not M.armGot.radial then
                        M.armGot.radial = true
                        soft(radialSnapshot)
                    elseif nm:find("Dialogue", 1, true) and not M.armGot.dialogue then
                        local n = soft(dialogueSnapshot, w.node)
                        if type(n) == "number" and n > 0 then M.armGot.dialogue = true end
                    end
                end
            end
            -- The wheel is already understood, so the dialogue alone ends the watch. The tick
            -- cap is a backstop: a probe left subscribed forever is a probe that costs the
            -- player frames in every fight after the one it was armed for.
            if M.armGot.dialogue or ticks > 18000 then M.disarm() end
        end)
    end)
    P("armed - open the round menu once, and talk to somebody once")
    return M.armId
end

function M.disarm()
    if M.armId ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(M.armId) end)
        M.armId = nil
        P("disarmed")
    end
end

-- 3d. Where the action really is, and how many pages there really are ----------------------
--
-- The slot record turned out to carry no `Name` at all - only `SlotType`, `SlotIndex`, `CanUse`
-- and a nested `Content`. So the action is one level further in, and the layer's name for the
-- slot was coming from the panel beside the wheel rather than from the slot. This opens
-- `Content` and `ExtenderData`, and counts what `findRadial` counts, so "384 pages" stops being
-- a mystery.

local function openInto(v, cap)
    if type(v) ~= "userdata" then return nil end
    local p = soft(function() return v:GetAllProperties() end)
    if type(p) ~= "table" then return nil end
    local out = {}
    for k, val in pairs(p) do
        local s = str(val)
        if #s > (cap or 120) then s = s:sub(1, cap or 120) .. "…" end
        out[str(k)] = s
    end
    return out
end

function M.content(howMany)
    local ws = soft(Pad.findWidgets) or {}
    local out = {}
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false and str(w.name) == "ActionRadials" then
            local radial = soft(Pad.findRadial, w.node)
            local items = radial ~= nil and (soft(Pad.radialItems, radial) or {}) or {}
            for k = 1, math.min(#items, howMany or 4) do
                local ip = soft(function() return items[k]:GetAllProperties() end)
                local dc = type(ip) == "table" and ip.DataContext or nil
                local rec = type(dc) == "userdata" and soft(function() return dc:GetAllProperties() end) or nil
                local e = { slot = k }
                if type(rec) == "table" then
                    e.slotType = str(rec.SlotType)
                    e.content = openInto(rec.Content, 160)
                    -- ExtenderData is a collection the Script Extender hangs off the slot; if
                    -- the spell id is anywhere, it is here or in Content.
                    e.extender = openInto(rec.ExtenderData, 160)
                    local ed = rec.ExtenderData
                    local n = tonumber(soft(function() return #ed end))
                    if n ~= nil and n > 0 then
                        e.extenderItems = {}
                        for q = 1, math.min(n, 4) do
                            e.extenderItems[q] = openInto(soft(function() return ed[q] end), 160)
                        end
                    end
                end
                out[#out + 1] = e
                P("slot " .. k .. " type=" .. str(e.slotType))
                if e.content then
                    for kk, vv in pairs(e.content) do P("   content." .. kk .. " = " .. vv) end
                end
            end
        end
    end
    save("skill-content.json", { at = soft(Ext.Utils.MonotonicTime), slots = out })
    return out
end

--- Everything `findRadial` would walk past, so the page count can be argued with.
function M.pages()
    local ws = soft(Pad.findWidgets) or {}
    local seen, total, withIndex = {}, 0, 0
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false and str(w.name) == "ActionRadials" then
            local function rec(o, d)
                if o == nil or d > 16 then return end
                local p = soft(function() return o:GetAllProperties() end)
                if type(p) ~= "table" then return end
                if p.IsVisible == false then return end
                local cls = select(1, A.splitToString(A.realType(o)))
                if cls:find("Radial", 1, true) and not cls:find("RadialListItem", 1, true) then
                    total = total + 1
                    local has = p.SelectedIndex ~= nil
                    if has then withIndex = withIndex + 1 end
                    local key = cls .. (has and "  [SelectedIndex]" or "  [no SelectedIndex]")
                    seen[key] = (seen[key] or 0) + 1
                    return
                end
                local ch, cn = A.kids(o)
                for k = 1, cn do rec(ch[k], d + 1) end
            end
            soft(rec, w.node, 0)
        end
    end
    P("nodes matching 'Radial': " .. total .. ", of them with SelectedIndex: " .. withIndex)
    local list = {}
    for k, v in pairs(seen) do list[#list + 1] = v .. " x " .. k P("   " .. v .. " x " .. k) end
    save("skill-pages.json", { total = total, withIndex = withIndex, classes = list })
    return seen
end

--- The list the pages actually live in, and how many of the radials carry anything.
---
--- 384 `ls.Radial` nodes all carry `SelectedIndex`, so counting those cannot be right whatever
--- the test. The structure note says the pages are `ListBoxItem`s under `HotBarList`; this
--- counts them, and separately counts how many radials hold a single slot, so the honest page
--- number can be picked between the two.
function M.hotbar()
    local ws = soft(Pad.findWidgets) or {}
    local r = { lists = {}, radialsWithItems = 0, radialsTotal = 0 }
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false and str(w.name) == "ActionRadials" then
            local function rec(o, d)
                if o == nil or d > 16 then return end
                local p = soft(function() return o:GetAllProperties() end)
                if type(p) ~= "table" or p.IsVisible == false then return end
                local cls = select(1, A.splitToString(A.realType(o)))
                local nm = str(p.Name)

                if cls:find("ListBox", 1, true) and not cls:find("ListBoxItem", 1, true) then
                    local ch, cn = A.kids(o)
                    local items = 0
                    for k = 1, cn do
                        local kc = select(1, A.splitToString(A.realType(ch[k])))
                        if kc:find("ListBoxItem", 1, true) then items = items + 1 end
                    end
                    r.lists[#r.lists + 1] = { class = cls, name = nm, children = cn,
                                              listBoxItems = items,
                                              count = tonumber(str(p.Items and #p.Items or "")) }
                    P("list " .. cls .. " [" .. nm .. "] children=" .. cn .. " items=" .. items)
                end

                if cls:find("Radial", 1, true) and not cls:find("RadialListItem", 1, true) then
                    r.radialsTotal = r.radialsTotal + 1
                    local items = soft(Pad.radialItems, o) or {}
                    if #items > 0 then r.radialsWithItems = r.radialsWithItems + 1 end
                    return
                end
                local ch, cn = A.kids(o)
                for k = 1, cn do rec(ch[k], d + 1) end
            end
            soft(rec, w.node, 0)
        end
    end
    P("radials " .. r.radialsTotal .. ", of them non-empty " .. r.radialsWithItems)
    save("skill-hotbar.json", r)
    return r
end

-- 4. Text appearing while nothing is being said to us -------------------------------------
--
-- The subtitle hunt. Every pass, the text of every widget is collected and compared with the
-- pass before; anything new is recorded with the widget it came from. Dialogue is excluded
-- because that half already works and would drown everything else.

M.seen = {}
M.hits = {}
M.tickId = nil

local function pass()
    local ws = soft(Pad.findWidgets) or {}
    local inDialogue = false
    for i = 1, #ws do
        if ws[i].visible ~= false and str(ws[i].name):find("Dialogue", 1, true) then
            inDialogue = true
        end
    end
    for i = 1, #ws do
        local w = ws[i]
        local nm = str(w.name)
        if not (inDialogue and nm:find("Dialogue", 1, true)) then
            local texts = soft(Pad.textsOf, w.node, nil, 10) or {}
            for k = 1, #texts do
                local t = texts[k]
                local key = nm .. "|" .. t
                -- Long enough to be a sentence somebody said, rather than a number on a badge.
                if not M.seen[key] and #t >= 12 then
                    M.seen[key] = true
                    M.hits[#M.hits + 1] = { at = soft(Ext.Utils.MonotonicTime),
                                            widget = nm, visible = w.visible ~= false, text = t }
                    P(nm .. ": " .. t:sub(1, 160))
                end
            end
        end
    end
end

function M.watch(seconds)
    M.stop()
    M.seen, M.hits = {}, {}
    -- Primed with what is already there, so the first pass does not report the whole HUD as
    -- new. Two passes: the first fills `seen`, and it is thrown away.
    soft(pass)
    M.hits = {}
    local ticks, limit = 0, math.floor((tonumber(seconds) or 60) * 30)
    M.tickId = soft(function()
        return Ext.Events.Tick:Subscribe(function()
            ticks = ticks + 1
            if ticks % 6 ~= 0 then return end
            soft(pass)
            if ticks >= limit then M.stop() end
        end)
    end)
    P("watching for " .. tostring(seconds or 60) .. " s - go and let somebody talk")
    return M.tickId
end

function M.stop()
    if M.tickId ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(M.tickId) end)
        M.tickId = nil
        P("stopped, " .. #M.hits .. " new lines")
        save("skill-watch.json", { at = soft(Ext.Utils.MonotonicTime), hits = M.hits })
    end
    return #M.hits
end

return M
