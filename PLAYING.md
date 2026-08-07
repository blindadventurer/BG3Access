# Playing Baldur's Gate 3 with BG3Access

This is the guide for playing. If you want to know how the layer is built, read
[README.md](README.md) instead.

## Read this part first

**The layer speaks your game's language.** It asks the game which language it is being played
in and says its own words — "walking", "arrived", "2 metres", "a controller is needed" — in
that one. English and Russian are written; every other language falls back to English, which
means an Italian game gives you Italian item names and dialogue inside English connective
words. Nothing is silent in any language.

If you would rather hear a different language than the one you play in, put its two-letter code
— `en` or `ru` — in a file called `lang.txt` next to the mod's other files, in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\A11y\`. That file wins over
whatever the game says.

Text the layer takes from the game — item names, dialogue lines, quest objectives, place names,
menu entries — has always come out in your game's language and still does. It is read through
the game's own localisation, not translated by us.

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
- A voice in your screen reader for the language your game is in. The layer says the game's own
  names and lines as the game wrote them, so a voice that cannot read that language will spell
  them out letter by letter.

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

One of those kinds is **unexplored** — the named places of this level you have never stood
in, nearest first, and it is how a level gets walked without a map: go to the nearest one,
listen on the way, go again. It shrinks as you explore, and what is left after the named places
are gone is the anonymous ground between them ("area").

Another is **landmarks**, and it is the one to reach for when you do not know
where to go. It does not list what is near you — it lists the fixtures of the whole level:
doors, ladders, consoles, levers, keys. Distance and direction, at any range. That is the
list that ends a "where is the thing my quest is about" walk in one press instead of forty.

Every row of it now says **which place it is part of** — "lever, Defiled Temple, 40 m" —
and rows in the same place are kept together, so a hundred fixtures arrive as eight or ten
groups instead of one flat run. What the game itself has pointed you at is marked "quest
target", and only ever for a quest you have actually seen in your journal.

Another kind is **places** — the places of the level by name, with **the fast-travel shrines
you have actually found** among them. They come grouped the way the landmarks do: everything that belongs to the grove
is heard together, then the forest, then the swamp, each group led by its nearest member, so
fifty names arrive as eight places rather than one long run. A place the story is currently
pointing into says **"quest target"**, which is the shortest answer there is to "where should I
go today" — "Emerald Grove, quest target, 98 m", "Goblin Camp, waypoint, two o'clock,
240 m". The one you are standing in says "you are here". Whether you have been somewhere before
is not said here — that is the whole of what **unexplored** is for, and saying it twice would
put the same two words on nearly every row of a fresh level.

The shrines are the game's own record, out of the save: the sixteen of Act 1 do not all appear
at once any more, only the ones this playthrough has switched on — and finding a new one is
said out loud when it happens ("New waypoint: Overgrown Ruins"), which nothing in the
interface announced before.

Names are never hidden. The map's fog cannot be read at all — it is a mask the renderer draws,
carried by no component, no widget and no line of the game's own scripts — so a list that hid
what it knows would be taking away the only thing standing in for a map. Walking to a place works like
walking to anything else: **Alt + Home**, in hops you can hear the end of.

The name of the place is also spoken on its own the moment you walk into one — "Place: Emerald
Grove" — the way the game prints it on screen for everyone else. So "where am I"
usually needs no key at all; when it does, the place you are in is the first row of
**places**, the one that says "you are here".

### Places you cannot walk to in a straight line

A level in this game is not one surface. Interiors are built hundreds of metres away from the
building they belong to — the druids' inner chambers sit eight hundred metres from the grove
whose door leads to them — so a distance and a bearing to one are correct and useless, and
walking that way ends in open ground.

The layer now knows every link between the walkable islands of a level: the doors, hatches,
ladders and rings the game itself uses. A row you cannot reach directly says **"no direct
route"**, and a door that leads off the island you are on says **"crossing"** — that is how a
hatch worth crossing the map for is told from a cupboard.

Press **Alt + Home** on one of those and the layer does not walk into the wall: it says how many
doors are on the way and walks you to the first one instead. Take it, press **Alt + Home**
again, and repeat until you are there.

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
it as one: the moment you steer for yourself, it stops steering for you. It keeps working for as
long as the character might still be running, including after the layer has given up on a long
walk and said so — that used to be exactly when it stopped working.

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
  then "and 4 more" — so finding the one corpse that holds a quest item does not mean
  walking to seventeen of them in turn.
- **Things the game itself refuses to name.** The console that ends the prologue and the rune
  that opens a pod both have no name at all in the game's data, so nothing could ever have
  read them out. The layer now calls such a thing what it is — console, lever, ladder, key —
  taken from what the level was built from.
- **Where you are, by name.** The game has a name for every part of every level — Emerald
  Grove, Defiled Temple, Waukeen's Rest — and 268 of them, with their outlines, now travel with
  the layer. It says the name when you walk in, lists them all as a category, and attaches the
  place to everything else it names, so a landmark three hundred metres off is somewhere rather
  than a bearing. The fast-travel shrines come with it: sixteen of them in Act 1, each with the
  name the game gives it instead of "waypoint" sixteen times over.
- **The camera drifting off the character.** BG3 sometimes leaves the view a long way from
  whoever you are steering, and the sound goes with it — the footsteps fade and there is no
  way to tell why. The layer measures the distance and says so when it is far out of its own
  usual range, once, with what to press. It stays quiet in conversations, cutscenes and fights,
  where the view is meant to be somewhere else.
- Dice rolls: what is being attempted, the skill, the number to beat and your bonus before
  you throw; what came up and whether it passed after. **And the bonus section**, which is the
  half of that panel you can still change: what your total is made of, what is on offer to add
  («+1d4»), and when there is nothing left to apply. The d-pad moves through those, and each
  change is read as you make it. The outcome waits until the roll is
  actually settled, because until then you can still spend inspiration on it.
- **Books, notes and letters — all of them, whole.** Opening one used to be silence: the page
  is drawn by a control that lays the text out itself, so the widget holds no words at all and
  no depth of searching would have found any. The whole text is a single property on the model
  behind it — and it is not paginated there, however many pages the game draws it across, so
  you never have to turn one.

  A book announces itself by name and reads its first paragraph: "Book: Thaniel's Divination
  Without Magic, 8 more paragraphs", then the text. **Page Down** takes the next paragraph, **Page Up**
  the previous, each with its number, so you can stop, go back and hear one again. A list
  inside a note is read line by line, and a signature is its own line. It is not read out in
  one breath on purpose: a book is minutes of speech, and there has to be a way back.

  While a book is open it owns the keys — Page Up and Page Down walk its paragraphs and not
  the barrels standing around you.
- Tutorial hints, with the tag markup taken out.
- Combat: whose turn it is, what you are aiming at, and what the game says about the move
  under the cursor.
- The journal objective, and when one finishes and the next appears — **and which section of
  the journal it belongs to**. "Main Quest" and "The Druid Grove" are the game's own words
  for its own quest categories, and hearing which one a task came from is the difference
  between moving the story on and running an errand. The list of quest targets leads with the
  main story for the same reason; it still says where the nearest one is when that is
  something else.
- **The context menu** — the one on **X**, where "Lockpick" lives along with everything else an
  object will allow. It reads the whole list the moment it opens ("Actions: Use,
  Lockpick, Move here") and then each row as you move onto it. Worth reaching for on anything that
  looks locked, stuck or interesting: the ordinary A press only ever does the obvious thing.
- **The question the game asks before a step that cannot be taken back.** Larian call it a
  ready check, and it is the only warning there is before an act closes behind you: the modal
  that says you may not be able to return, the one that warns the region ahead is
  hard for a party of this level, and the one at the end of a day that says somebody in camp
  still wants to talk. About fifteen of them carry every point of no return in the game. The
  layer reads them out, in the game's own words, and **never answers them for you.**
- **Levelling up**, which is the screen where a wrong choice is permanent and until now the
  least readable one in the game. Half of it was always spoken — the headings, the paragraph,
  the character sheet down the right-hand side — and the half that mattered was silent: what
  you are actually choosing between. A spell on offer is an icon and nothing else. There is no
  caption anywhere in the row, in the template or in the panel, so the cursor moved over a grid
  of thirty of them and the layer had nothing to say.

  Now each one says its name, what it costs, how far it reaches, whether it is an attack or a
  save, what damage it does and which school it belongs to — "Burning Hands, action, level
  1 slot, range 5 m, Dexterity saving throw, 3d6 fire damage, evocation, 1 of 17" — and
  **Delete** gives the game's own description of it at length. An unfilled slot says "empty"
  rather than nothing, so you can hear how many choices are still yours to make.

  **Page Up and Page Down survey the whole thing** without moving the cursor: the step you are
  on, how many of its slots are filled, then every choice numbered the way the cursor counts
  them, then the character sheet. Spells you cannot take — usually because you already know
  them — are listed too, marked "unavailable"; the cursor cannot reach those, so this is the
  only way to hear them.

  The screen is a sequence rather than a set of tabs: finishing one selection puts the next in
  front of you with no key pressed and nothing said. Each new step is now announced with how
  much of it is left ("Spells, chosen 0 of 2"), and when the last choice is made the layer
  says so — that is the moment the button at the bottom starts working, and nothing else tells
  you. **End** answers the same question at any time: what is still undecided, then the sheet.
- **The character panel** — the one the quick menu opens, and the same problem as levelling up
  for the same reason. Its grid is **1422 records and not one string**: an inventory cell is a
  slot number and a game object, and every word about the item is on the object rather than on
  the screen. So the cursor moved across a bag and said nothing.

  Now a cell says its name, how many there are, whether it is worn, new or stolen, how rare it
  is and what kind of thing it is — "Potion of Healing, ×2, potion", "Spiked Shield, equipped,
  shield". **Delete** adds what it weighs, what it is worth, its armour class or reach, and the
  game's own description of it.

  **The paperdoll reads, empty slots included** — "chest, Simple Robe, equipped", "helmet,
  empty". Fourteen slots in the order a person dresses. Nothing else in the game tells you that
  you have been walking around with no boots on.

  A party member's bag was announced as a **save group** until now: it is built from the
  same control as the save-game list, and the layer could not tell them apart. It says
  "Gale, inventory, expanded, health 25 of 28, armour class 11, weight 8.3 of 150" instead.

  **Page Up and Page Down** walk the whole panel: which tab, who it is showing, what is on
  them, every equipment slot, then every bag in full with its owner named and its rows
  numbered. **End** answers "what is on me and what am I wearing" on its own.

  **Statuses** come from the character rather than from the panel — the interface keeps them in
  a collection that cannot be opened, and the game's own entity hands them over plainly.
- **What the buttons do, and where you are.** Two questions this panel makes hard for somebody
  who cannot see it, and both are now answered out loud.

  Every row says what **A** would do to it — "Leather Armour, chest, A - equip",
  "Potion of Healing, ×2, potion, A - drink", "helmet, empty, A - select". That is not a guess: the
  panel keeps a row of hints along the bottom, one per action, and shows only the ones that
  apply to whatever the cursor is on. The layer reads the caption the game itself put there.
  **Page Up / Page Down** and **Delete** list all of them, so "what can I even press here" has
  an answer at any moment.

  And it says **which side of the panel you are on** the moment you cross — "Equipment" when
  the cursor moves onto the body, "Bag: Gale" when it moves into somebody's bag. Nothing in
  the rows themselves distinguishes the two: a breastplate reads the same worn or carried, and
  the game marks the boundary with a gap on screen and nothing else.
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
