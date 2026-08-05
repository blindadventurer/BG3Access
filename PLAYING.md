# Playing Baldur's Gate 3 with BG3Access

This is the guide for playing. If you want to know how the layer is built, read
[README.md](README.md) instead.

## Read this part first

**The layer speaks Russian.** Its own words — "walking", "arrived", "2 metres", "a controller
is needed" — are Russian sentences. Text it takes from the game (item names, dialogue lines,
menu entries) comes out in whatever language your game is set to. So on an English install you
will hear English names inside Russian connective words. There is no English voice yet; that
is a translation job nobody has done, not a missing feature.

**You need a game controller.** Not to play with — you can keep the keyboard — but because the
layer reads the game's *controller* interface, the one BG3 raises when it sees a pad. Without a
controller plugged in there is nothing for it to read, and it will say so.

**This is early software.** It reads the menu, conversations, the world around you, combat and
most panels. It does not read everything, and when it meets something it cannot read it says
that rather than pretending. See [What it does not do](#what-it-does-not-do) below.

## What you need

- Windows.
- **Baldur's Gate 3**, Patch 8. Steam and GOG both work.
- **BG3 Script Extender** — <https://github.com/Norbyte/bg3se/releases>. Nothing in this mod
  runs without it, and **the installer offers to fetch it for you**: it names the project, the
  release and the file, asks once, and Enter is yes. Install it yourself first if you would
  rather; the installer will find it and leave it alone.
- **A game controller** — an Xbox pad, or anything Windows recognises as one.
- **NVDA or JAWS**, running before you start the game. If neither is there, speech falls back
  to SAPI, which will talk but says everything in one flat stream.
- A Russian voice in your screen reader, or you will hear the layer's own words spelled out
  letter by letter.

## Installing

### Download one file and click it

**[BG3Access-Setup.exe](https://github.com/blindadventurer/BG3Access/releases/latest/download/BG3Access-Setup.exe)**
— download it, double-click it, answer **Yes** to the one question it asks, and wait about half
a minute. It says out loud when it is done, and the window closes itself.

Windows will get in the way once, because the file is not signed by anyone it recognises. You
get **"Windows protected your PC"**, and the only button showing is *Don't run*. The one you
want is behind the **More info** link: click that, then **Run anyway**. It is one dialog, it
happens once, and the two ways below avoid it entirely — but nothing in the mod can remove it
short of a code-signing certificate, which costs money it does not have.

### Or one line, with no warning to click through

Press **Windows+R**, paste this, press Enter:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/blindadventurer/BG3Access/main/tools/bootstrap.ps1 | iex"
```

A window opens and does the rest: it downloads the latest release into
`%LOCALAPPDATA%\Programs\BG3Access`, unpacks it, and runs the installer. There is **one
question** — whether it may download the Script Extender — and Enter answers it. Nothing else
is asked.

### Or the ordinary way

1. Download the release ZIP and unpack it anywhere — Downloads is fine. Do not unpack it into
   the game folder.
2. Run **`install.bat`**.
3. Read (or listen to) what it prints. It says out loud whether it worked.

### All three do the same thing

The installer finds the game by itself, offers to fetch the Script Extender if it is not
already there, copies the layer in, sets up the piece that turns the game's speech into your
screen reader's speech, and puts a shortcut on your Desktop that starts the game **without the
launcher** — Larian's launcher window has no accessibility information in it at all, and this
is the simplest way past it. Steam still has to be running for that shortcut to work.

**Start the game however you like — Steam, the shortcut, anything.** The half of the mod that
lives outside the game (it turns what the game writes into what your screen reader says) is
watched by Windows itself: a scheduled task called *BG3Access Speech* looks once a minute,
whatever happened to the last one, and starts it again if it is gone. The Desktop shortcut
still checks before it launches the game, so it is the quickest way in, but nothing depends on
it any more.

This is what the mod going quiet used to look like, and it is worth recognising: the game says
its opening line, or does not, and everything after that is silence. Nothing on screen is
wrong. `status.bat` answers it in one line — `speech companion` and `watchdog` are the two
lines to read.

The only difference is who asks about the Script Extender: the ZIP and the one-liner ask in the
window, `BG3Access-Setup.exe` asks in its opening dialog and then does not stop again.

Nothing depends on where the unpacked folder is. The layer is copied into the game folder, and
the speech companion into `%LOCALAPPDATA%\BG3Access`, so moving or deleting the unpacked folder
cannot break either. Keep it anyway: `status.bat` and `uninstall.bat` live there — the exe and
the one-liner put them in `%LOCALAPPDATA%\Programs\BG3Access` — and there is no other copy.

Two things that can go wrong once and look permanent:

- **The game folder is read-only.** If the game sits under `Program Files`, the Script Extender
  cannot be written there by an ordinary program. Right-click `install.bat` and choose **Run as
  administrator**.
- **An antivirus removes `DWrite.dll`.** The Script Extender is a DLL that loads itself into the
  game, which is also what some unpleasant things do, and scanners occasionally take it on that
  resemblance alone. Allow it and run `install.bat` again. The installer prints the SHA-256 of
  exactly what it downloaded, so what got quarantined can be identified.

If the game is somewhere the installer cannot find, open a Command Prompt in the unpacked
folder and give it the path:

```bash
install.bat -GameDir "D:\Games\Baldurs Gate 3"
```

That is the folder that contains `bin\bg3.exe`.

### The first launch

Start the game, plug in the controller, and wait for the main menu. When the layer comes up it
says one short line. From there the pad moves through the menu and the layer reads it.

If nothing is spoken, run **`status.bat`**. It prints one line for each thing that can be wrong
on its own — including whether it can see a controller at all — and the failing one names its
own fix.

## The keys

The pad plays the game. The keyboard drives the layer, and the two never overlap: every key
below is caught before the game sees it, and every key not listed reaches the game untouched.
They work in controller mode, where the game's own keyboard bindings are dead.

Four keys mean one thing out in the world and another on an open panel, because the question
behind them is the same and only its subject changes.

**Page Up** and **Page Down** — step back and forward through the list. In the world that is
the things standing around you; on a panel it is the lines of the panel.

**Alt + Page Up / Page Down** — the previous or next *kind* of thing: people, containers,
doors, items. This is how a room gets built up in your head without sitting through thirty
barrels first.

One of those kinds is **ориентиры**, and it is the one to reach for when you do not know
where to go. It does not list what is near you — it lists the fixtures of the whole level:
doors, ladders, consoles, levers, keys. Distance and direction, at any range. That is the
list that ends a "where is the thing my quest is about" walk in one press instead of forty.

**Home** — how the walk is going: how far is left, and whether that number is going down.
On a panel it goes to the top of the list.

**Alt + Home** — walk to whatever is selected in the list.

**End** — where the story wants you: the current objective, what it concerns, and the walk
there. On a panel it reads the summary — on a character sheet, what all the choices so far add
up to.

**Delete** — how far the scanner looks. Press it to widen or narrow the circle around you.
On a panel it reads the details of the selected thing: on the settings screen, the name of
the setting and the game's whole explanation of it.

**Alt + Delete** — walk to the target the game itself has selected. In a fight that is a
different thing from the scanner's selection, which is why it has its own key.

**Insert** — read what is worth reading right now. In a fight, the fight. On a panel, the panel
in full. Out in the world, the last line again.

**Pause** — where you are: the screen, the section of it, the control under the cursor.

**Alt + Pause** — stop walking.

**The left stick** — also stops walking. Pushing the stick is the reflex, and the layer treats
it as one: the moment you steer for yourself, it stops steering for you.

There is deliberately no key that reads out everything around you. Thirty entries of barrels
and reeds is not a picture of a room; it is a wall you have to sit through, with the one entry
that mattered somewhere in the middle. The list is walked a step at a time and filtered by
category instead.

## What it reads

- The main menu, and character creation.
- The settings screen: which section you are in, the setting, its value, how far down the
  list you are — and the game's own explanation of what the setting does, which it shows for
  whichever one the cursor is on. That last part is read with the setting. Move on and it is
  cut off mid-sentence, which is the point; **Delete** reads it again from the start.
- Conversations: who is speaking, the line, and the answers as you move between them.
- The world around you, by category and by distance, and walking to any of it with progress
  reported on the way. A body or a box says what is in it as you step past — three names,
  then "и ещё" and a count — so finding the one corpse that holds a quest item does not mean
  walking to seventeen of them in turn.
- **Things the game itself refuses to name.** The console that ends the prologue and the rune
  that opens a pod both have no name at all in the game's data, so nothing could ever have
  read them out. The layer now calls such a thing what it is — пульт, рычаг, лестница, ключ —
  taken from what the level was built from.
- Dice rolls: what is being attempted, the skill, the number to beat and your bonus before
  you throw; what came up and whether it passed after. The outcome waits until the roll is
  actually settled, because until then you can still spend inspiration on it.
- Tutorial hints, with the tag markup taken out.
- Combat: whose turn it is, what you are aiming at, and what the game says about the move
  under the cursor.
- The journal objective, and when one finishes and the next appears.
- Panels the controller interface opens: the character sheet, the inventory, the radial menus,
  the confirmation boxes.

## What it does not do

- **English speech.** See the top of this page.
- **The launcher.** Use the Desktop shortcut the installer makes.
- **The map**, as a map. You get objectives and distances, not a picture of the terrain.
- **Mouse-only parts of the interface.** The layer reads the controller interface; anything
  BG3 only exposes to a mouse is not there to be read.
- **Multiplayer** — untested. It may work; nobody has tried it with a screen reader.

## If something is wrong

Run **`status.bat`** and send what it prints, at
<https://github.com/blindadventurer/BG3Access/issues>. Those lines answer almost every
"it is silent" question before anyone has to ask you anything.

The most common three:

- **`controller` says none found.** BG3 raises the interface the layer reads only when it sees a
  pad, so without one everything else can be perfect and the game will still say nothing. Plug
  one in and start the game again. If you have a controller connected and this still says none
  found, say so in the issue — the check does not recognise every pad, and that is worth fixing.
- **`script extender` says missing.** The game runs, and no mod code runs with it. Run
  `install.bat` again and say yes when it offers to fetch it.
- **`speech companion` says not running.** The game is talking to a file and nothing is
  reading it. Wait a minute and run `status.bat` again: the watchdog should have put it back
  by itself, and if it did, the line above this one — `watchdog` — is the one to send. Starting
  the game from the Desktop shortcut brings it back immediately, and `install.bat` is safe to
  re-run at any time; it no longer stops a companion that is working.
- **`watchdog` says not installed.** Then nothing is checking, and the companion is one killed
  process away from an evening of silence. `install.bat` registers it. It needs no
  administrator rights; if it still fails to register, that message is worth an issue.

A transcript of everything the layer has said is the most useful thing to attach when the
complaint is "it read the wrong thing" — and one is being written already, by the speech
companion, without anyone starting it:

```bash
notepad %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech-companion.log
```

That is the one to send, because it covers what already happened. The other transcript tool
starts recording when you run it and so has nothing to say about the session that went wrong:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tools\speech-log.ps1
```

## Removing it

Run **`uninstall.bat`**. It takes back every file it added, stops the speech companion and
removes the scheduled task that watches it, removes the Desktop shortcut, and restores the
Script Extender settings file it changed. One file is
deliberately kept: `explored.json`, the record of where you have already been, so that
reinstalling later does not start you over.

The Script Extender is left alone, on the chance you have other mods using it — even when the
installer is the thing that put it there. To take that away as well:

```bash
uninstall.bat -WithExtender
```

which removes it only if this installer downloaded it, and says so either way.

Nothing here touches your saves, and nothing replaces a file the game shipped with.
