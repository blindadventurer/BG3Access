-- The layer, started by the game.
--
-- Until now every module was typed into the SE console after each launch, and loading a save
-- - which wipes the client Lua state - meant typing them all again. As a mod none of that is
-- needed: the extender runs this file every time it builds the client state, including right
-- after that wipe, so the layer comes back on its own.
--
-- Every module exists in two copies. The packed ones travel inside the pak and are what a
-- plain install uses. The loose ones live in <Script Extender>/A11y/ - that is where
-- tools/push-lua.ps1 writes - and they win when present, so editing a file and reloading
-- stays a one-command loop with no repacking. A loose file that fails to compile is skipped
-- with a warning instead of taking the layer down with it.

local DEV = "A11y/"

-- Load order is a dependency order: a11y-nav and a11y-pad read _G.A11y at load time, so the
-- menu module has to be in place before them.
-- The four *data modules are data, not code: they depend on nothing, everything that reads them
-- checks for nil first, and they are generated rather than written - so they load first and are
-- marked optional. A missing module normally takes the whole layer down with it, which is right
-- for code and wrong for a table: losing the journal index costs the quest pointer, losing the
-- place index costs the place names, losing the ready-check index costs the warning before a
-- point of no return - and losing the layer costs the game.
local ORDER = {
    { name = "a11y-questdata", global = "QuestData", optional = true },
    { name = "a11y-placedata", global = "PlaceData", optional = true },
    { name = "a11y-portaldata", global = "PortalData", optional = true },
    { name = "a11y-rcdata",    global = "ReadyData",  optional = true },
    { name = "a11y-menu",      global = "A11y"      },
    { name = "a11y-nav",       global = "Nav"       },
    { name = "a11y-pad",       global = "Pad"       },
}

local ENV = _ENV

local function P(fmt, ...)
    Ext.Utils.Print("[a11y] " .. string.format(fmt, ...))
end

local function soft(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

-- Which table the modules hand each other over through.
--
-- They pass A11y/Nav/Pad to one another as `_G.X`, and inside a mod `_G` is not always the
-- real global table - the extender gives each mod its own environment and builds may or may
-- not let a write through to the globals underneath. So probe it once: write, read back, and
-- if the write did not stick, use the mod environment itself and pin `_G` to it. Either way
-- every module ends up reading and writing the same table.
local function pickGlobals()
    local g = rawget(ENV, "_G") or _G
    local ok = pcall(function() g.A11Y_PROBE = true end)
    if ok and rawget(g, "A11Y_PROBE") == true then
        g.A11Y_PROBE = nil
        return g
    end
    return ENV
end

local G = pickGlobals()
rawset(ENV, "_G", G)

-- The extender's `load` is not Lua's: the second argument is the environment table, where
-- stock Lua takes a chunk name. Passing a name there fails with "bad argument #2 to 'load'
-- (table expected, got string)" and every module falls through to the packed copy.
local function fromLoose(name)
    local src = soft(Ext.IO.LoadFile, DEV .. name .. ".lua")
    if type(src) ~= "string" or #src == 0 then return nil end
    local ok, chunk, err = pcall(load, src, ENV)
    if not ok or chunk == nil then
        Ext.Utils.PrintWarning("[a11y] loose " .. name .. " will not compile (" ..
            tostring(err or chunk) .. ") - falling back to the packed copy")
        return nil
    end
    local ran, mod = pcall(chunk)
    if not ran then
        Ext.Utils.PrintWarning("[a11y] loose " .. name .. " failed while loading (" ..
            tostring(mod) .. ") - falling back to the packed copy")
        return nil
    end
    return mod
end

local function fromPack(name)
    local ok, mod = pcall(Ext.Require, "A11y/" .. name .. ".lua")
    if not ok then
        Ext.Utils.PrintError("[a11y] packed " .. name .. " failed: " .. tostring(mod))
        return nil
    end
    return mod
end

-- A note left on disk for whoever asks from outside whether the mod came up.
--
-- The extender's console is the only other place this shows, and reading it means a window
-- that has to exist and be scraped; a small JSON file next to the speech bridge answers
-- "did it load, from where, and is the game listing the mod" with a single Get-Content.
local function report(state, extra)
    local out = {
        state = state,
        modules = extra and extra.modules or nil,
        error = extra and extra.error or nil,
        controllerMode = soft(function() return Ext.Utils.GetGlobalSwitches().ControllerMode end),
        extender = soft(Ext.Utils.Version),
        game = soft(Ext.Utils.GameVersion),
        listed = false,
    }
    local order = soft(Ext.Mod.GetLoadOrder)
    if type(order) == "table" then
        out.loadOrder = #order
        for _, uuid in ipairs(order) do
            local m = soft(Ext.Mod.GetMod, uuid)
            local name = m and m.Info and m.Info.Name
            if name == "BG3Access" then out.listed = true end
        end
    end
    soft(Ext.IO.SaveFile, DEV .. "boot.json", soft(Ext.Json.Stringify, out) or
        ('{"state":"' .. state .. '"}'))
end

local sources = nil

local function loadAll()
    local found = {}
    for _, m in ipairs(ORDER) do
        local mod, where = fromLoose(m.name), "loose"
        if mod == nil then mod, where = fromPack(m.name), "packed" end
        if mod == nil and m.optional then
            Ext.Utils.PrintWarning("[a11y] " .. m.name .. " did not load - going on without it")
            G[m.global] = nil
            found[#found + 1] = m.global .. ":missing"
        elseif mod == nil then
            Ext.Utils.PrintError("[a11y] " .. m.name ..
                " did not load at all - the layer stays down")
            report("modules-failed", { modules = found, error = m.name })
            return false
        else
            G[m.global] = mod
            found[#found + 1] = m.global .. ":" .. where
        end
    end
    sources = found
    P("modules %s", table.concat(found, " "))
    return true
end

local function stopLayer()
    if G.Pad ~= nil and G.Pad.stop ~= nil then pcall(G.Pad.stop) end
end

local function startLayer()
    if G.Pad == nil or G.Pad.start == nil then return false end
    local ok, err = pcall(G.Pad.start)
    if not ok then
        Ext.Utils.PrintError("[a11y] Pad.start failed: " .. tostring(err))
        report("start-failed", { modules = sources, error = tostring(err) })
        return false
    end
    P("layer running")
    report("running", { modules = sources })
    -- Said out loud on purpose: after a save load the client state is rebuilt and everything
    -- here runs again, and hearing one short line is how the player knows the layer survived.
    --
    -- Queued rather than interrupting. This fires during the loading screen, and the loading
    -- screen carries the game's own tip - the one piece of writing there, and the layer used to
    -- cut it in half to say a line about itself.
    if G.A11y ~= nil and G.A11y.say ~= nil then pcall(G.A11y.say, "Доступность включена", false) end
    return true
end

-- Loaded here, started a tick later.
--
-- The two halves cannot swap places. `Ext.Require` only works while the extender is running
-- this file - deferred to a Tick handler it fails with "called without a mod, but the current
-- mod UUID is not known", and the packed copies become unreachable. Starting, on the other
-- hand, wants the client to exist: this file runs while the state is still being built, with
-- no UI root and no input manager yet, and one tick is enough for both.
local loaded = loadAll()

local kick
kick = Ext.Events.Tick:Subscribe(function()
    if kick ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(kick) end)
        kick = nil
    end
    if loaded then startLayer() end
end)

-- Console handle: `A11yBoot.reload()` re-reads the loose files and restarts the layer, which
-- is the whole hot-reload loop once tools/push-lua.ps1 has copied a file in. Loose files only
-- - by the time the console is typing, the packed fallback is out of reach for the same
-- reason the loading above happens at file scope.
G.A11yBoot = {
    reload = function()
        stopLayer()
        if not loadAll() then return false end
        return startLayer()
    end,
    start = startLayer,
    stop  = stopLayer,
    globals = G,

    -- The dev-only modules (a11y-mouse, a11y-model) are not part of the layer and are loaded
    -- on demand. They take their dependencies out of `_G`, which inside a mod is this table
    -- and not the console's global table - so `Ms = load(...)()` typed at the console builds
    -- a second, half-wired copy that cannot see A11y or Pad. This puts them where the rest of
    -- the layer lives: Mods.BG3Access.A11yBoot.loadDev("a11y-mouse", "Ms").
    loadDev = function(name, global)
        local mod = fromLoose(name)
        if mod == nil then return false end
        G[global] = mod
        P("dev module %s -> %s", name, global)
        return true
    end,
}
