# BG3Access

A screen-reader accessibility layer for **Baldur's Gate 3**, built as Script Extender
Lua: it constructs its own navigable tree over the game's live UI and world state and
speaks it through NVDA/JAWS, instead of trying to make the game's Noesis UI accessible.

The architecture it implements is written down separately in
[graph-a11y-spec.md](graph-a11y-spec.md) — engine-neutral, and derived from two shipped
mods (Pathfinder: WotR, Rogue Trader).

## Playing it

Download
**[BG3Access-Setup.exe](https://github.com/blindadventurer/BG3Access/releases/latest/download/BG3Access-Setup.exe)**,
double-click it, answer Yes once. It is not signed, so SmartScreen asks for *More info* →
*Run anyway* first — the line below avoids that dialog and does the same thing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/blindadventurer/BG3Access/main/tools/bootstrap.ps1 | iex"
```

Or download the latest release, unpack it, and run `install.bat` — the same thing with the
downloading done by hand. Either way the installer offers to fetch the
**[Script Extender](https://github.com/Norbyte/bg3se/releases)**, without which the game starts
perfectly and runs no mod code at all.

**[PLAYING.md](PLAYING.md)** is the guide: what you need, the keys, and what to do when it
is silent. Two things worth knowing before you start — the layer **speaks the language the game
is being played in** (English and Russian are written; everything else falls back to English),
and it needs a **game controller** plugged in.

The rest of this file is about the source.

## Layout

| Path | What it is |
| --- | --- |
| `lua/` | The layer itself — **source of truth** for every module |
| `BG3Access/` | Mod tree: `meta.lsx`, `Config.json`, `BootstrapClient/Server.lua` |
| `BG3AccessDiag/` | A separate diagnostic mod (client/server probes) |
| `probes/` | Console probes run by hand during investigation |
| `tools/` | PowerShell: build, package, install, hot-reload, console I/O, speech |
| `install.bat`, `uninstall.bat`, `status.bat` | What a player runs — wrappers over `tools/install.ps1` and friends |
| `PLAYING.md` | The player's guide: requirements, keys, troubleshooting |
| `bg3-host-port-research.md` | How the five host ports map onto BG3's engine |
| `experiment-results.md` | Running log of what was tried and what it did |

`lua/a11y-*.lua` are the layer's modules: `pad` (input), `nav` (navigation),
`menu` (screen readers), `model`, `mouse`, plus `nav-server` on the server context.

## Languages

Every sentence the layer speaks is written in English in the source, inside `T"..."`, and
translated on the way out by `lua/a11y-lang.lua`. The language is the game's own
(`GlobalSwitches.Language`), overridable by a two-letter code in
`<Script Extender>/A11y/lang.txt`. A string with no translation is said in English, so a
half-finished language is a layer that speaks a mixture rather than one that goes quiet.

| Path | What it is |
| --- | --- |
| `lua/a11y-lang.lua` | The mechanism: which language, plural rules, and the game's own strings the layer has to recognise |
| `lua/a11y-ru.lua` | English → Russian. Adding a language means copying this file |
| `tools/check-lang.ps1` | What has drifted: English with no translation, translations for English that is gone, format strings whose placeholders no longer match |

`a11y-lang.lua` also holds the handles for the strings the layer matches **against** the game —
the options row that carries the control scheme, the buttons under a dialogue box, the camp
supply label. Those were hard-coded in Russian until 0.5.0, which is why the control-scheme
repair silently did nothing on any copy of the game that was not Russian. A handle resolves to
whatever the player is looking at, in all fifteen of the game's languages.

## Install

Patch 8 does not accept a mod from outside its own manager — a `.pak` in
`%LOCALAPPDATA%\...\Mods\` is never listed, and a `modsettings.lsx` entry is stripped on
the next launch. So installing means **grafting**: the layer's `ScriptExtender` folder is
placed inside a module the game already loads (`GustavX`), where the Script Extender
finds it anyway. `graft-mod.ps1` adds only new paths — nothing of the game is replaced,
and `-Uninstall` takes them away again.

```powershell
powershell -File tools\build-mod.ps1        # stage lua\ into the mod tree, then graft
powershell -File tools\mod-status.ps1       # after restarting the game: did it take?
```

Every script takes `-GameDir`, and defaults it to whatever `tools/find-game.ps1` finds —
Steam's `libraryfolders.vdf`, then GOG's registry entry, then the usual paths, each
candidate proved by `bin\bg3.exe` rather than by the folder name. `tools/install.ps1` is
the same graft with the checks a stranger's machine needs around it (is the game there, is
the Script Extender there, does anything answer when we try to speak) and is what
`install.bat` runs.

Two of those checks now fix what they find, because for the players this is for a diagnosis is
not a fix:

- `tools/install-extender.ps1` downloads BG3SE from Norbyte's own releases and puts `DWrite.dll`
  into `bin`. It asks first, names the project, the release, the file and the hash, and records
  what it installed so `uninstall.ps1 -WithExtender` can take back exactly that. The file's
  header argues with the earlier decision not to do this at all; it is worth reading before
  changing it back.
- `tools/bootstrap.ps1` is the one-liner above: fetch the current release, unpack it into
  `%LOCALAPPDATA%\Programs\BG3Access`, run the installer. It is fetched from `main` by URL, so
  what is on `main` is what strangers run — it is not covered by the release ZIP being pinned.
- `tools/package-installer.ps1` builds `BG3Access-Setup.exe` out of the release ZIP and
  `tools/sfx-setup.bat`, using IExpress, which is already on every Windows. Its header records
  the three ways an IExpress package silently installs nothing; all three were found by
  building one. The asset name carries no version on purpose, so
  `/releases/latest/download/BG3Access-Setup.exe` is a link that keeps working.

On a machine that has never run a PowerShell script, `powershell -File ...` fails outright:
the default execution policy is Restricted. That is what the `.bat` wrappers are for — they
pass `-ExecutionPolicy Bypass`.

## Development loop

```powershell
powershell -File tools\push-lua.ps1                    # push every module + reload
powershell -File tools\push-lua.ps1 -Name a11y-pad     # push one
```

The push copies into the running game's Script Extender folder and asks the live layer to
re-read it — no repack, no restart.

## Running native plugins alongside this

Nothing here needs it, and it is written down because getting it wrong takes the layer with it.

Native BG3 plugins are DLLs injected into the game process. The usual loader for them,
kassent's Native Mod Loader, is a `DWrite.dll` proxy — and so is the Script Extender this layer
depends on. Two of those in `bin\` is the known conflict: one of them does not load, and the
workarounds all end with the extender half-broken.

[Yet Another BG3 Native Mod Loader](https://github.com/MolotovCherry/Yet-Another-BG3-Mod-Loader)
does not proxy anything — it injects from outside — so it and the extender coexist. Measured on
this machine, 2026-08-06: game up, loader in the process (`Running Loader by Cherry v0.1.0`),
`boot.json` reporting `state=running` with all six of our modules loaded. No conflict.

- Tools (`bg3_injector.exe`, `bg3_watcher.exe`, `loader.dll`) → `<game>\bin\NativeModLoader\`.
  From that folder the game root is found on its own, but `install_root` in the config is
  written as the default Steam path and needs correcting on a machine like this one where the
  game is on another drive.
- Plugins and config → `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Plugins\`, **not**
  `bin\NativeMods\`. `config.toml` and a `logs\` folder appear there on first run.
- The injector is one-shot: start the game, then run it. The watcher is the same thing left
  running in the background. The autostart variant edits the registry; this machine does not
  use it.

**This is a door to native plugins only.** Ordinary `.pak` mods are a different problem, and
Patch 8 still refuses the ones that come from outside — which is why this layer is grafted into
a module the game already loads rather than shipped as a pak.

## Dependencies not in this repo

- **LSLib / Divine** → `tools/lslib/`, from https://github.com/Norbyte/lslib/releases.
  Only `build-mod.ps1 -Pak` needs it. Use this build, not the one bundled with Vortex:
  the Vortex one writes an LSPK v16 package and BG3 reads v18, failing silently.

`tools/prism.dll` (the speech bridge that talks to NVDA/JAWS) *is* tracked, since
`tools\speak.ps1` will not run without it.

## License

MIT — see [LICENSE](LICENSE). `tools/prism.dll` is third-party and carries its own terms.
