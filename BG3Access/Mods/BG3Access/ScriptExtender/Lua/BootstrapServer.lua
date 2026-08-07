-- The server half of the layer.
--
-- Walking to a thing is Osiris work (CharacterMoveTo), and Osiris lives only on the server,
-- so the client asks over the A11yNav channel and this side moves the character. There is no
-- reader here and nothing to speak: it listens, and that is all.
--
-- Loose copy wins over the packed one, same as on the client - see BootstrapClient.lua.

local DEV = "A11y/"
local NAME = "a11y-nav-server"

-- The words this side invents - "lever", "hatch", the name a nameless object is given - are
-- English in the source and said in the game's language, so the language module and its
-- translation tables are loaded here too. Both are optional: without them the server's few
-- words come out in English and nothing else is different.
local EXTRA = {
    { name = "a11y-lang", global = "Lang" },
    { name = "a11y-ru",   global = "LangRU" },
}

local ENV = _ENV

local function soft(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local G = rawget(ENV, "_G") or ENV
rawset(ENV, "_G", G)

local function fromLoose(name)
    local src = soft(Ext.IO.LoadFile, DEV .. name .. ".lua")
    if type(src) ~= "string" or #src == 0 then return nil end
    -- Second argument is the environment table, not a chunk name - see BootstrapClient.lua.
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

local function loadOne(name)
    local mod = fromLoose(name)
    if mod ~= nil then return mod, "loose" end
    local ok, packed = pcall(Ext.Require, "A11y/" .. name .. ".lua")
    if ok then return packed, "packed" end
    return nil, "missing"
end

-- Language first: a11y-nav-server reads _G.Lang at load time.
for _, m in ipairs(EXTRA) do
    local got = loadOne(m.name)
    G[m.global] = got
    if got == nil then
        Ext.Utils.PrintWarning("[a11y] " .. m.name .. " did not load - going on without it")
    end
end

local mod, where = loadOne(NAME)

if mod == nil then
    Ext.Utils.PrintError("[a11y] " .. NAME .. " did not load - walking to objects is off")
    return
end

G.NavSrv = mod
local ok, err = pcall(mod.listen)
Ext.Utils.Print("[a11y] nav server " .. where .. ", listening: " .. tostring(ok and true or err))
