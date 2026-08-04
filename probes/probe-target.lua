-- What a thing is called underneath the translation.
--
-- The nautiloid fight settled that matching an objective to an object by display name cannot
-- work: the task says "Доберитесь до передатчика" and not one of the 116 things within 300 m
-- carries that word. But a display name is the last layer on an object, not the first - the
-- template it was made from has a name the level designer wrote, in English, and that one is
-- stable across every language the game ships.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-target", "TG")
--     Mods.BG3Access.TG.usable(120)
--     Mods.BG3Access.TG.components(120)   -- when the template is not where it was expected

local A, Nav = _G.A11y, _G.Nav
local T = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- The template name, tried in every place it is known to hide.
---
--- Client and server carry different components for the same object, and the extender has
--- moved these fields between builds, so this asks for all of them and reports the first that
--- answers rather than assuming one.
local PATHS = {
    function(e) return e.ServerItem.Template.Name end,
    function(e) return e.ServerItem.Template.TemplateName end,
    function(e) return e.ServerCharacter.Template.Name end,
    function(e) return e.GameObjectVisual.RootTemplateId end,
    function(e) return e.Data.RootTemplate end,
    function(e) return e.Visual.Visual.VisualResource.Template end,
    function(e) return e.OriginalTemplate.TemplateId end,
    function(e) return e.ClientItem.Template.Name end,
    function(e) return e.ClientCharacter.Template.Name end,
}

local function templateOf(e)
    for i = 1, #PATHS do
        local v = soft(PATHS[i], e)
        if type(v) == "string" and v ~= "" then return v, i end
    end
    return nil, nil
end
T.templateOf = templateOf

--- Everything worth walking to, with the name the designer gave it.
function T.usable(radius)
    local list = soft(Nav.scan, radius or 120, true)
    if list == nil then Ext.Utils.Print("[target] no scan") return nil end
    local out = {}
    for i = 1, #list do
        local it = list[i]
        local e = it.entity
        local uuid = soft(function() return e.Uuid.EntityUuid end)
        local tpl, via = templateOf(e)
        out[#out + 1] = string.format("%3d | %-26s | %-14s | %-42s | via=%s | %s",
            math.floor(it.dist or 0), str(it.name), str(it.kind), tostring(tpl),
            tostring(via), tostring(uuid))
    end
    Ext.IO.SaveFile("A11y/target_usable.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[target] " .. #out .. " entries -> target_usable.txt")
    return #out
end

--- Which components a nearby object actually has, when no template path answered.
function T.components(radius)
    local list = soft(Nav.scan, radius or 120, true)
    if list == nil then return nil end
    local out, seenKind = {}, {}
    for i = 1, #list do
        local it = list[i]
        local k = str(it.kind)
        -- One sample per kind is enough to learn the shape; a hundred stools teach nothing.
        if not seenKind[k] then
            seenKind[k] = true
            out[#out + 1] = "== " .. str(it.name) .. " (" .. k .. ", " ..
                            math.floor(it.dist or 0) .. " m)"
            local comps = soft(function() return it.entity:GetAllComponentNames() end)
            if type(comps) ~= "table" then
                comps = soft(function() return Ext.Entity.GetAllComponentNames(it.entity) end)
            end
            if type(comps) == "table" then
                table.sort(comps)
                for _, c in ipairs(comps) do out[#out + 1] = "   " .. tostring(c) end
            else
                out[#out + 1] = "   <no component list available>"
            end
        end
    end
    Ext.IO.SaveFile("A11y/target_components.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[target] components -> target_components.txt")
    return #out
end

Ext.Utils.Print("[target] ready: TG.usable(r) / TG.components(r)")
return T
