# BG3Access

A screen-reader accessibility layer for **Baldur's Gate 3**, built as Script Extender
Lua: it constructs its own navigable tree over the game's live UI and world state and
speaks it through NVDA/JAWS, instead of trying to make the game's Noesis UI accessible.

The architecture it implements is written down separately in
[graph-a11y-spec.md](graph-a11y-spec.md) — engine-neutral, and derived from two shipped
mods (Pathfinder: WotR, Rogue Trader).

## Layout

| Path | What it is |
| --- | --- |
| `lua/` | The layer itself — **source of truth** for every module |
| `BG3Access/` | Mod tree: `meta.lsx`, `Config.json`, `BootstrapClient/Server.lua` |
| `BG3AccessDiag/` | A separate diagnostic mod (client/server probes) |
| `probes/` | Console probes run by hand during investigation |
| `tools/` | PowerShell: build, install, hot-reload, console I/O, speech |
| `bg3-host-port-research.md` | How the five host ports map onto BG3's engine |
| `experiment-results.md` | Running log of what was tried and what it did |

`lua/a11y-*.lua` are the layer's modules: `pad` (input), `nav` (navigation),
`menu` (screen readers), `model`, `mouse`, plus `nav-server` on the server context.

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

Both scripts assume the game at `G:\SteamLibrary\steamapps\common\Baldurs Gate 3`;
pass `-GameDir` for another install.

## Development loop

```powershell
powershell -File tools\push-lua.ps1                    # push every module + reload
powershell -File tools\push-lua.ps1 -Name a11y-pad     # push one
```

The push copies into the running game's Script Extender folder and asks the live layer to
re-read it — no repack, no restart.

## Dependencies not in this repo

- **LSLib / Divine** → `tools/lslib/`, from https://github.com/Norbyte/lslib/releases.
  Only `build-mod.ps1 -Pak` needs it. Use this build, not the one bundled with Vortex:
  the Vortex one writes an LSPK v16 package and BG3 reads v18, failing silently.

`tools/prism.dll` (the speech bridge that talks to NVDA/JAWS) *is* tracked, since
`tools\speak.ps1` will not run without it.
