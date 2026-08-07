-- What the layer says, and in which language it says it.
--
-- Two different problems live here, and they are only neighbours because both are about
-- language.
--
-- **The layer's own words.** Every sentence the layer speaks is written in English in the
-- source and translated on the way out. `T"Nothing nearby"` is a table lookup: with the game
-- in English it returns its argument unchanged and costs one failed index, and with the game
-- in Russian it returns "Рядом никого". A missing translation falls through to the English,
-- so a half-finished language is a layer that speaks a mixture rather than a layer that is
-- silent - which is the right failure for something a blind player is relying on.
--
-- **The game's own words.** In a few places the layer has to recognise a string the *game*
-- produced: the caption of the options row that holds the control scheme, the button under a
-- dialogue box, the label above the camp supplies. Those were written down in Russian, which
-- meant every one of them silently stopped working on an English game - and the control
-- scheme one takes the whole keyboard half of the layer with it. They are recorded here as
-- **localisation handles** wherever a handle exists: `Ext.Loca.GetTranslatedString` turns a
-- handle into the string the player is actually looking at, in whichever of the game's
-- fifteen languages that is, so the match is right in all of them and not just in two.
--
-- Adding a language means adding one file, `a11y-<code>.lua`, holding nothing but the
-- English -> that-language map (copy `a11y-ru.lua` and translate the values), then naming it
-- in `M.SOURCES` below and in the load order in BootstrapClient. Anything left untranslated
-- keeps saying the English.

local M = {}
M.BUILD = "lang 2026-08-07"

local function soft(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

-- language ----------------------------------------------------------------------

M.DEFAULT = "en"

-- `GlobalSwitches.Language` is the game's own name for what it is being played in - measured
-- as the string "Russian" on this machine (§С7). The names below are Larian's folder names
-- under Data/Localization, which is what that field carries.
local CODES = {
    English = "en", Russian = "ru", German = "de", French = "fr", Italian = "it",
    Spanish = "es", LatamSpanish = "es", Polish = "pl", Portuguese = "pt",
    BrazilianPortuguese = "pt", Turkish = "tr", Ukrainian = "uk", Chinese = "zh",
    ChineseTraditional = "zh", Japanese = "ja", Korean = "ko",
}

-- Which global each translation table arrives in. BootstrapClient loads them as optional
-- modules, exactly like the data indexes: losing a translation costs the language, not the
-- layer.
M.SOURCES = { ru = "LangRU" }

M.language = nil        -- what the game reported, verbatim
M.lang = M.DEFAULT      -- the code we speak in
M.forced = nil          -- set by hand, and it wins

--- The language the game is being played in, or the one written into A11y/lang.txt.
---
--- The file override is not a debugging aid. A player whose game is in one language and who
--- listens in another is an ordinary case - a Russian-speaking player on an English copy, or
--- a tester who wants to hear what a translation does - and a one-word file is the only
--- setting this layer has that a screen reader user can edit without the game running.
function M.detect()
    local hand = soft(Ext.IO.LoadFile, "A11y/lang.txt")
    if type(hand) == "string" then
        hand = hand:gsub("%s", ""):lower()
        if hand ~= "" then
            M.forced = hand
            M.lang = hand
            return M.lang
        end
    end
    local gs = soft(Ext.Utils.GetGlobalSwitches)
    local name = gs ~= nil and soft(function() return tostring(gs.Language) end) or nil
    M.language = name
    M.lang = (name ~= nil and CODES[name]) or M.DEFAULT
    return M.lang
end

--- Speak in this language from now on. `Lang.set("en")` at the console is how a Russian
--- player checks what a tester is hearing.
function M.set(code)
    M.forced = code
    M.lang = code or M.DEFAULT
    return M.lang
end

local function table_for(code)
    local g = M.SOURCES[code]
    if g == nil then return nil end
    local mod = rawget(_G, g)
    if type(mod) ~= "table" then return nil end
    return mod.s, mod.plural
end

-- the layer's own words ---------------------------------------------------------

--- One sentence of the layer's, in the player's language.
---
--- English in, the same English out when that is what is wanted - so the cost of the whole
--- mechanism on an English game is one lookup that finds nothing.
function M.t(s)
    if M.lang == "en" or type(s) ~= "string" then return s end
    local tab = table_for(M.lang)
    if tab == nil then return s end
    local v = tab[s]
    if type(v) == "string" then return v end
    return s
end

--- A number and the thing it counts.
---
--- English needs two forms and Russian three, and a screen reader saying "3 вариантов" on
--- every single utterance is the sort of thing that grates until the layer is switched off.
--- The word is always given in English; the table for the language decides what happens to
--- it.
function M.plural(n, word)
    if M.lang ~= "en" then
        local _, forms = table_for(M.lang)
        local f = forms ~= nil and forms[word] or nil
        if f ~= nil then
            -- The Slavic three-form rule. It is the same for Russian and Ukrainian, and any
            -- language whose table is keyed this way gets it.
            local a, b = n % 10, n % 100
            if a == 1 and b ~= 11 then return n .. " " .. f[1] end
            if a >= 2 and a <= 4 and (b < 12 or b > 14) then return n .. " " .. f[2] end
            return n .. " " .. f[3]
        end
        local one = M.t(word)
        if one ~= word then return n .. " " .. one end
    end
    if n == 1 then return n .. " " .. word end
    local irregular = M.PLURAL_EN[word]
    return n .. " " .. (irregular or (word .. "s"))
end

-- Everything the layer counts is a regular noun today; the table is here so that the first
-- one that is not does not have to be special-cased at its call site.
M.PLURAL_EN = {}

-- the game's own words -----------------------------------------------------------

--- Localisation handle -> the string the player is looking at.
local function loca(h)
    local t = soft(function() return Ext.Loca.GetTranslatedString(h) end)
    if type(t) == "string" and t ~= "" and t ~= h then return t end
    return nil
end
M.loca = loca

-- Strings the layer has to recognise coming *out* of the game.
--
-- `h` is a list of localisation handles, and it is the good case: the handle is the same in
-- every language, so the layer matches whatever the player sees. Several are listed where
-- the game has several strings that read the same in one language and differ in another
-- ("Продолжить" is Continue, Resume and Proceed), because these are used as sets to test
-- membership and a spare entry costs nothing.
--
-- `en`/`ru` are the fallback for the two places the game formats a string in code rather
-- than storing it, so there is no handle to point at.
--
-- The handles were read out of Data/Localization/{English,Russian}.pak on 2026-08-07 by
-- looking up the Russian strings this file used to hard-code.
M.GAME = {
    -- The options row that holds the control scheme, and the three values it offers. This is
    -- the load-bearing one: the layer puts the game back into controller mode by driving that
    -- row, and with the caption written in Russian it could not find the row at all on an
    -- English game.
    inputModeRow    = { h = { "h8fd300d1gebfdg4ccfg8f56g4a47bc3e434e" } },
    schemeAuto      = { h = { "habe6b14fge373g4d19g86c6g2f48faa77fed_0" }, en = { "Automatic" }, ru = { "Авто" } },
    schemeKeyboard  = { h = { "habe6b14fge373g4d19g86c6g2f48faa77fed_1" }, en = { "Keyboard only" }, ru = { "Клавиатура" } },
    schemeController= { h = { "habe6b14fge373g4d19g86c6g2f48faa77fed_2",
                              "h8477d7d0gd300g4038g900cg9fba6ea3f776" },
                        en = { "Controller only", "Controller" }, ru = { "Контроллер" } },

    -- The buttons under the dialogue box. The strict reading takes the line from
    -- `TextBodyContainer` and never sees these; this set is what keeps the broad fallback from
    -- welding "Continue" onto the end of every line the way it used to.
    dialogueButtons = { h = { "h560d086ag3144g4595g9129ge69f0383a226",   -- Continue
                              "h45db0d8cg465fg4c1dg8c21gc894286fa41e",   -- Continue
                              "hc1e4c45fg54e3g49c1ga0aeg88d0eed38ae6",   -- Continue
                              "h4fbbc7e3ge45ag4c5bga315ga0155b914856",   -- Resume
                              "hbd442b28g8fc5g4d34g9127g9ec0e917b9e7",   -- Proceed
                              "h566118f2g4237g40e5gbd6agfa6a91271470",   -- Skip
                              "hb69d777fge906g4ba6g876dg302f3160eeb8",   -- Skip
                              "ha8eafa85gec0eg4c43g9c5cg75c4d31ffddf",   -- Choose
                              "h04f38549g65b8g4b72g834eg87ee8863fdc5",   -- Select
                              "hd0c08193ga7f2g4a7eg8225g63748c7b3096",   -- Select
                              "he9e4a39fg8a5dg4ac5gacffgaea214260c69",   -- Dialogue History
                              "h300e48e5g689dg4133gbf34gd245a53eac06",   -- Stop Listening
                              "hfce3e682g151ag47b8g83a2ge40e0ac6594a",   -- Next
                              "h7513bcfbg14a8g4f1fgb54bgce0a03eb840f",   -- Next
                              "h1c1625b0gb1dcg4544gb7f3ga805c2bdb198" } },-- Next

    -- The roll panel's own button, which is not one of the modifiers the player came to hear.
    rollDice        = { h = { "h7bb9bbfbg5fc0g4728g9947g9a9e6c862e93" } },

    -- A tutorial hint carries its category and its dismiss button among its lines, and
    -- neither is the hint.
    tutorialNoise   = { h = { "he162765ega290g4934ga287g65430dcac222",   -- General Tutorial
                              "head66e6bg788dg4defg8488ga6b39108a91a",   -- Finish
                              "hd17fc873gbda6g4283gb940gd9317b144143" } },-- Done

    -- The label over the camp supply counter, which is a heading rather than a fact.
    supplies        = { h = { "h7708bf73ge1fcg40a0gbc51g5128c57ef782",
                              "he7ca760dg408bg4ea8gaebag6c549dd8b4e8",
                              "h766168e9g0dc0g4a96gb328g75ce30288397",
                              "h3de62923gbda0g42a1g8e55g7f98ceb3b95f",
                              "h0320a4c0g8539g4bc1g9c6bgb2f33eb48140",
                              "hde0eec15g0cacg4afcg8eefgb925961f6be0",
                              "h3cef439fg92cdg4b5bgb3fdg5fd5db63d33a" } },

    -- What that much food buys, which is the one line of the camp panel worth hearing whole.
    -- A root rather than a handle: the panel writes a sentence around the words, so what is
    -- wanted is the part of "Enough for a Long Rest" that stays put, matched in lower case.
    longRest        = { en = { "rest" }, ru = { "отдых" } },
}

local resolved = {}

local function build(key)
    local spec = M.GAME[key]
    if spec == nil then return {}, {} end
    local list, set = {}, {}
    local function add(s)
        if type(s) == "string" and s ~= "" and not set[s] then
            set[s] = true
            list[#list + 1] = s
        end
    end
    for _, h in ipairs(spec.h or {}) do add(loca(h)) end
    for _, s in ipairs(spec[M.lang] or {}) do add(s) end
    -- The English is kept as a last resort in every language: a handle that fails to resolve
    -- leaves nothing at all to match on, and matching the English is better than matching
    -- nothing.
    if M.lang ~= "en" then for _, s in ipairs(spec.en or {}) do add(s) end end
    return list, set
end

--- The game's own string for something the layer has to recognise. The first one, for the
--- places that want a single caption to search for.
function M.g(key)
    local r = resolved[key]
    if r == nil then r = { build(key) } resolved[key] = r end
    return r[1][1]
end

--- All of them, as a set, for the places that ask "is this one of those".
function M.gset(key)
    local r = resolved[key]
    if r == nil then r = { build(key) } resolved[key] = r end
    return r[2]
end

--- Forget what the handles resolved to. Only needed after `set()`, and only because the
--- fallbacks are per-language.
function M.reset() resolved = {} end

-- what a language writes differently ---------------------------------------------

--- The names of the months, for turning a save's "31/7/2026" into something a voice reads.
---
--- Nil for a language we have no list for, and the caller leaves the date alone - which is
--- also what happens for every language but Russian, because the order of the numbers in that
--- string is the game's and we have only ever seen it written day-first. Reading "3/7" as the
--- third of July when the copy that wrote it meant the seventh of March would be a confident
--- lie, and the raw string is not bad to listen to.
M.MONTHS = {
    ru = { "января", "февраля", "марта", "апреля", "мая", "июня",
           "июля", "августа", "сентября", "октября", "ноября", "декабря" },
}

function M.months() return M.MONTHS[M.lang] end

--- What separates a number from its fraction. A screen reader reads "11.2" in Russian as
--- "eleven point two" in the middle of a Russian sentence; with the comma it reads as a number.
M.DECIMAL = { ru = "," }

function M.decimal() return M.DECIMAL[M.lang] or "." end

--- The letter between the two numbers of a die. Russian writes 2к6 where English writes 2d6,
--- and a screen reader saying "two dee six" to a Russian player is one of the few places the
--- layer would be speaking a foreign language into the middle of its own sentence.
M.DICE = { ru = "к" }

function M.dice() return M.DICE[M.lang] end

--- Things worth walking to, recognised by the name the game gives them.
---
--- Stems rather than words, stored without their first letter, because names arrive
--- capitalised and Lua's `lower()` does not touch anything outside ASCII. A language with no
--- list here loses the landmark category and nothing else; everything the game itself marks
--- on the map is still found, since that comes from the journal index and carries no words at
--- all.
M.LANDMARKS = {
    ru = {
        "вер",      -- дверь
        "орот",     -- ворота
        "юк",       -- люк
        "естниц",   -- лестница
        "ход",      -- вход, выход, проход
        "унду",     -- сундук
        "щик",      -- ящик
        "лтар",     -- алтарь
        "руг древн", -- круг древних знаков
        "уины",     -- руины
        "клеп",     -- склеп
        "ашня",     -- башня
        "ычаг",     -- рычаг
        "айник",    -- тайник
        "ортал",    -- портал
        "остер", "остёр",  -- костер
        "агерь",    -- лагерь
        "юк в",     -- люк в подвал
    },
    en = {
        "oor",      -- door
        "ate",      -- gate
        "atch",     -- hatch
        "adder",    -- ladder
        "tairs",    -- stairs
        "ntrance",  -- entrance
        "xit",      -- exit
        "hest",     -- chest
        "rate",     -- crate
        "arrel",    -- barrel
        "ltar",     -- altar
        "uins",     -- ruins
        "rypt",     -- crypt
        "omb",      -- tomb
        "ower",     -- tower
        "ever",     -- lever
        "utton",    -- button
        "ache",     -- cache
        "ortal",    -- portal
        "ampfire",  -- campfire
        "amp",      -- camp
        "ell",      -- well
        "hrine",    -- shrine
    },
}

function M.landmarks() return M.LANDMARKS[M.lang] end

-- The tail a stem may carry before it stops being the same word. In Russian that is a case
-- ending - two Cyrillic letters, four bytes, enough for "двери" and not for "рюкзак". English
-- inflects less and the stems are longer, so one byte of plural is all that is wanted, and a
-- longer tail would let "doorway" answer for "door".
M.STEM_TAIL = { ru = 4, en = 2 }

function M.stemTail() return M.STEM_TAIL[M.lang] or 2 end

M.detect()

return M
