# The Graph A11y Kernel — an engine-neutral specification

**Status**: Draft 1 (2026-07-17)
**Source implementations**: RTAccess (`RTAccess/UI/Graph/`, C#, ~1,700 lines, BCL-only) and
WrathAccess (upstream). Lineage: Factorio Access `key-graph.lua` / `menu.lua` → Tanglebeep
(ported with permission) → WrathAccess → RTAccess.
**Conformance suite**: `tests/` (~100 behavioral tests over the kernel alone — they compile
`Graph/**` standalone, which is what enforces the kernel/host boundary).

---

## 0. What this is

A specification for building a **screen-reader accessibility layer inside a video game** (or any
application whose native UI toolkit cannot be made accessible) by constructing a **mod-owned
parallel UI tree** over the application's live state. It generalizes the architecture shipped in
two production mods (Pathfinder: Wrath of the Righteous; Warhammer 40,000: Rogue Trader) so it can
be re-implemented in any language, for any engine, over any GUI library.

The spec has three layers:

1. **The kernel** (§3–§6) — pure data structures and algorithms, no engine dependency. Port this
   verbatim.
2. **The host ports** (§2) — the five capabilities the kernel needs from a game. Implement these
   per game.
3. **The policies** (§7–§9) — input mapping, speech, screen lifecycle: normative behavior for the
   navigator you build around the kernel. Follow these; they encode the field-tested UX contract.

Keywords MUST / SHOULD / MAY are used in the RFC-2119 sense.

---

## 1. Design axioms

These are the load-bearing decisions. Violating one produces a category of bug that both source
projects hit and had to engineer back out.

### A1. Parallel tree, not the game's focus system

The accessibility layer OWNS its navigation model. It MUST NOT ride the application's native focus
ring, gamepad navigation, or hover system. Native focus systems are built for sighted spatial
scanning; they skip non-interactive text, follow visual layout rather than reading order, and
change semantics per screen. The parallel tree reads the game's state and presents its own
traversal.

*Corollary*: the game's own UI stays live underneath. Every input path into it must be accounted
for (§8).

### A2. Immediate mode — the tree is rebuilt, never mutated

Every screen declares its nodes **fresh from live application state on every render** (per
operation and per frame). Node contents hold **no view state**: a node's label is a closure that
reads the game's state at speak time; activating a node calls the game's own handler. The only
state that survives a render is the cursor (§3.6).

This kills the universal failure mode of retained-mode accessibility layers: cache invalidation
against a UI you don't own. There is nothing to invalidate.

### A3. Focus persists by identity, not by reference to the tree

Renders are throwaway; focus is reconciled into each new render by a **two-tier identity**
(§3.1): the backing domain object (follows a thing that *moved*), else a structural key (follows
a logical control whose backing object was *rebuilt*), else the nearest survivor in the previous
traversal order. Focus never silently jumps to the top of a screen because the content re-rendered.

### A4. Announce exactly once, from one place

A focus change is spoken **exactly once, no matter what caused it** — a keypress, the screen
moving focus, a content rebuild, the game yanking a VM. This is achieved by a **frame differ**
(§7.2): one code path compares "identity last spoken" against "identity now focused" and speaks
the delta. Hand-written announce calls around focus mutations are FORBIDDEN — every one is a
future double-speak or missed-speak.

### A5. Read the game's state; drive the game's handlers

Actions MUST invoke the application's own method/handler for the equivalent UI interaction — even
when that spawns a dialog you then have to make accessible. Never reimplement an application flow
from primitives. Labels MUST mirror what the application visually shows on the control
("label mirrors the card"); detail that is visually tooltip-only stays behind the tooltip verb.

### A6. Parity — never reveal what a sighted user can't currently see

Fog of war, hidden units, undiscovered content: the layer MUST gate its readouts on the same
visibility rules the sighted presentation uses. Convenience reveals are cheating, and they corrupt
the shared vocabulary between blind and sighted players of the same game.

### A7. Interrupt speech by provenance, not timing

Speech caused by the user's own keypress interrupts what's playing; passive/event speech and
automatic focus changes queue. (A keypress response never clips; background narration never cuts
off what's playing.) The differ path queues; the direct input paths interrupt (§7.4).

### A8. Localize everything the layer itself says

All layer-authored strings go through a localization table. Application content (names, log
lines) is already localized — pass it through, never re-translate.

---

## 2. Host ports

The kernel is pure; everything engine-specific enters through five required ports and four
optional ones. A game is a viable host if you can implement the required five.

### Required

- **P1 — State read.** Read arbitrary application state on demand, cheaply enough to call every
  frame (UI view-models, entity lists, text). In managed engines this is reflection/direct field
  access; in native engines, memory reading or a scripting API.
- **P2 — Action invoke.** Call the application's own UI handlers (click/submit/toggle
  equivalents).
- **P3 — Tick.** A per-frame (or high-frequency) callback on a thread from which P1/P2 are legal.
- **P4 — Key input.** Raw key/chord state independent of the application's input consumption,
  plus a way to **arbitrate**: suppress, per chord per frame, the application's own handling of
  keys the layer claims (§8).
- **P5 — Speech.** `Speak(text, interrupt)` to a screen reader or TTS, where `interrupt=true`
  cuts current speech and `false` queues. (Windows: NVDA controller client / SAPI via a
  Tolk-style bridge; the source projects hand-bind a native `prism.dll`.)

### Optional

- **P6 — Sound.** Play the application's own themed hover/click sounds at the navigator
  chokepoints, so the accessible layer sounds native.
- **P7 — Localization.** String table for the layer's own vocabulary (role words, "n of m",
  "collapsed", "no tooltip").
- **P8 — Settings.** Persisted user preferences; the announcer consults a per-control-type,
  per-part-kind verbosity filter (§7.3).
- **P9 — Logging.** A speech transcript and focus trace are the single most valuable debugging
  artifacts this architecture has. Strongly recommended.

---

## 3. Kernel data model

Names below are from the reference implementation; ports may rename, but the semantics are
normative.

### 3.1 ControlId — two-tier identity

The identity of a control, designed so focus can be followed across rebuilds even when the world
shifts.

- `Reference` (optional): the domain object the node was derived from (a view-model, an item, an
  entity). Compared by **reference identity** (pointer equality).
- `StructuralKey` (required): a **value-equatable** key — a string, or a composite such as
  `(pane, row, col)`.

Rules:

- Equality and hashing are defined on `StructuralKey` **alone**, so a ControlId is a stable map
  key. The Reference tier is metadata applied explicitly during reconciliation (§5.2).
- Two controls are "the same" when their References are identical (tier 1 — follows an object
  that MOVED, its structural key having changed) OR their StructuralKeys are equal (tier 2 —
  follows a logical control whose backing object was REBUILT: new instance, same identity).
- Constructors: `Structural(key)`, `Referenced(ref, key)`, `ForObject(ref)` (the object doubles
  as its own structural key).
- Structural keys MUST be stable across rebuilds for as long as the control logically exists.
  Index-based keys are acceptable only when the collection's order is stable.

### 3.2 NodeAnnouncement — one part of a spoken readout

A control's readout is a list of **parts**, each resolved live at speak time:

- `Text`: `() -> string`. Null/empty at speak time = the part stays silent this time.
- `Kind`: an optional well-known string tagging what the part is:
  `label`, `role`, `value`, `selected`, `enabled`, `tooltip`, `position`, `reason`
  (extensible). Kinds drive per-type speak ordering, node-over-type overriding, and the user's
  per-kind verbosity settings.
- `Live`: if true, the part is **watched while its node is focused** — when its resolved text
  changes (an async toggle settling, the game flipping a value), the navigator speaks just that
  part (§7.5). This replaces per-element watcher machinery with one architectural mechanism.

The **first part is the control's label** by convention — search, dedupe, and path-diffing rely
on this.

### 3.3 ControlType — control types as registry values, not classes

A control type ("button", "toggle", "slider") is **data**:

- `Key`: stable settings/registry key.
- `Order`: the announcement kinds in speak order; parts with unknown/absent kinds append after,
  in declaration order.
- `Common`: parts every control of the type shares (the localized role word), resolved per
  compose.

A node's own part **overrides** a common part of the same kind. Deriving type identity from
implementation classes (the legacy approach in both source projects) forced artificial class
hierarchies; don't repeat it.

### 3.4 NodeVtable — behaviors as data

All of a control's behaviors, as optional slots. A null slot means "doesn't have this behavior"
and the navigator speaks its "nothing there" feedback instead:

- `Announcements` (required, ≥1 part): the spoken focus readout.
- `ControlType` (optional): see §3.3.
- `OnActivate` — primary activation (Enter; the left-click equivalent).
- `OnSecondary` — secondary activation (the right-click equivalent).
- `OnActivateShift` / `OnActivateCtrl` — modified activations (the shift-drag / ctrl-drag
  equivalents, e.g. stack splitting).
- `OnTooltip` — read/open the control's detail (Space / F1). The action owns the whole behavior
  so the kernel stays application-agnostic.
- `OnAdjust(sign, large)` — horizontal value adjust (sliders). **When set, Left/Right do not
  navigate.**
- `StateText`: `() -> string` — the control's state line, spoken immediately (interrupting) after
  an activation/adjust that changes state. This is the *synchronous* feedback path (survives
  rapid key repeats); *asynchronous* changes ride Live parts instead.
- `SearchText` / `ExcludeFromSearch` — type-ahead matching text (default: the label).
- `HoverSound` / `ClickSound` / `ActivateSound` (optional, host-typed but stored opaque —
  keeping the kernel dependency-free): themed sounds played at navigator chokepoints.
- `OnExpand` / `OnCollapse` — optional overrides for how an expandable group's state changes
  (default: the kernel mutates the persistent expansion set).
- `SpeaksOwnExpansion` / `SpeaksOwnPosition` — set when the node's own parts already include
  that information, so the announcer doesn't append it twice.

### 3.5 GraphNode, edges, and the render

- `GraphNode`: `Id`, `Vtable`, four directional `Transitions` (Up/Right/Down/Left, each an edge
  to a `ControlId` destination with an optional spoken transition label — a "lane change" line),
  plus structural metadata:
  - `Parent` — the node's structural parent *within this render*, or null. The parent chain IS
    the presentation hierarchy the announcer diffs (§7.2). A parent may be **non-focusable pure
    structure** (a labeled panel — never navigable, exists only on chains) or a real control
    (a tree group header).
  - `Focusable` — false for pure-structure parents.
  - `Expandable` / `Expanded` — tree group headers; `Expanded` is stamped at build time from the
    persistent expansion set (or an explicit value).
  - `StopKey` — the Tab-stop this node belongs to (§4.3).
  - `RegionKey` — optional sub-stop region for coarse jumps.
  - `PositionIndex` / `PositionCount` — auto-stamped "n of m" among the siblings arrows actually
    reach (§4.6); 0 = none.
- `GraphRender`: one built snapshot — `Nodes` (map by ControlId), `Order` (declaration order —
  drives stop/region cycling and search scan order), `StartKey` (where focus starts absent any
  prior position). Rebuilt per operation and thrown away.
- Tab-stop cycling and region jumps are **operations over node metadata, not edges** — they carry
  per-stop remembered positions, which a static edge cannot express.

### 3.6 GraphState — the only persistent thing

The cursor that survives between renders. One per live screen:

- `CurKey` — the focused control's id (carrying its Reference for tier-1 recovery).
- `KeyOrder` — the total traversal order computed from the previous render (for
  nearest-survivor recovery).
- `NextSuggestedMove` — a one-shot "focus here next render if present" request (consumed either
  way).
- `StopMemory` — remembered position per Tab-stop (where Tab lands when cycling back in).
- `Expanded` — the set of expanded group ids. **Screens hold no tree state of their own.**

---

## 4. The builder

`GraphBuilder` turns a screen's declarations into a `GraphRender`. Two construction styles,
freely mixable in one build:

### 4.1 Menu mode

Rows of controls, wired automatically: Left/Right within a row; Up/Down between **consecutive
rows of the same Tab-stop**. Items added outside an explicit row become single-item rows (a plain
vertical menu). Rows sharing a non-null **row key** with an adjacent row get **column-preserving**
vertical navigation (Up/Down keeps the column position when it exists in the target row; otherwise
vertical lands on the row's first item).

### 4.2 Raw mode

`AddNode(id, vtable)` + `Connect(from, dir, to, label?)` for arbitrary topologies (grids, computed
adjacency). Edges referencing undeclared nodes are silently dropped at build. An edge may carry a
spoken transition label.

### 4.3 Tab-stops and regions

`BeginStop(key?)` starts a new Tab-stop; nodes added from here belong to it. Stop keys MUST be
stable across rebuilds (they key the remembered positions); a null key auto-assigns by index,
which is stable when the screen builds stops in a fixed order. **Arrows never cross a stop**; Tab
cycles stops in first-appearance order. `SetRegion(key)` tags following nodes with a region
(Ctrl+arrow jump target) within the current stop.

Convention (field-tested): **new multi-zone screens use one stop per zone** — Tab cycles zones —
rather than one giant stop partitioned by regions.

### 4.4 The parent stack: contexts and groups

- `PushContext(label, role?)` pushes one **non-focusable** level of presentation hierarchy
  ("Difficulty settings, list") onto nodes added until `PopContext()`. Announced only when focus
  enters the subtree from outside. Its synthetic id is label-pathed so cross-render chain diffs
  match up.
- `BeginGroup(id, vtable, expanded?)` pushes a **focusable, expandable** group header (a tree
  section). Children declared before `EndGroup()` emit **only while the group is expanded**; a
  collapsed ancestor suppresses the whole subtree (the declaration stack stays balanced
  regardless, so screens can declare unconditionally). Expansion state comes from: the explicit
  argument, else the persistent `Expanded` set, else a default.
- Nesting recurses arbitrarily.

### 4.5 Mode-boundary stitching

Where one stop mixes menu rows with raw content (filter controls above a grid), the two wiring
systems don't see each other. The builder MUST stitch the seam at each mode boundary (in
declaration order, same stop): the menu row's cells gain Down edges into the first raw node still
missing an Up edge (and it gains the Up back); the reverse at raw→menu boundaries. Only **missing**
edges are filled — raw content's own wiring is never overridden. Additionally, interleaved raw
content BREAKS the menu rows' vertical chaining (otherwise menu edges would skip over the raw
block, leaving it an unreachable island).

### 4.6 Position stamping

The builder auto-stamps "n of m" positions: a multi-item row's members within their row; a
single-item-row node among the siblings sharing its `(parent, stop)` — i.e., the vertical list
level that arrows actually traverse. Raw/grid nodes get none. Positions announce only when m > 1.
A parent may suppress child positions (log-like streams where "37 of 200" is noise).

### 4.7 Build-time validation

Duplicate ControlIds are an error. A node without at least one announcement part is an error.
Unclosed rows are an error. A build that declared nothing returns null — the caller treats the
screen as "closed/empty" and leaves focus state intact for the next good render.

---

## 5. The engine

`KeyGraph` executes operations against a render callback and a `GraphState`. **Every operation
re-renders first** (`Rerender` → build fresh → `Reconcile`), so it always acts on current reality.
The kernel **never speaks** — every operation returns what happened (`MoveResult { Moved, From,
To, TransitionLabel }`) and the navigator composes speech.

### 5.1 The down-right total order

Traversal order for recovery and scanning, computed per render:

```
order = []; seen = {}; downFringe = [StartKey]
for k in downFringe (growing):
    while k not in seen:
        seen.add(k); order.append(k)
        if node(k) has Down edge: downFringe.append(down.dest)
        if node(k) has Right edge: k = right.dest else break
append every declared node not yet seen, in declaration order   # later Tab-stops
```

Visits a planar UI in reading order; the append step keeps the order **total** (stops have no
cross-stop edges).

### 5.2 Focus reconciliation

On every rebuild, move the cursor to a valid control:

```
if NextSuggestedMove set: if present in render, focus it; consume either way
resolved = null
if CurKey != null:
    tier 1: any node whose Id.Reference IS CurKey.Reference        # object moved
    tier 2: the node at CurKey's StructuralKey                     # object rebuilt
    fallback: from CurKey's index in the PREVIOUS KeyOrder, walk BACKWARD
              to the nearest key that still exists in this render  # nearest survivor
if resolved == null:                                               # first render / all gone
    resolved = the SELECTED member of the start node's stop, else the start node
CurKey = resolved; remember it in StopMemory; KeyOrder = ComputeOrder(render)
```

"Selected member" = the first node in the stop carrying a non-empty `selected`-kind part — so
initial focus lands on the checked radio/current tab, not the top of a long list.

### 5.3 Operations

All return `MoveResult` (or a typed tree result); "not moved" (at an edge / empty graph) returns
`To == From`.

- `Move(dir)` — one step along an edge.
- `MoveToEdge(dir)` — repeat until stuck (Home/End within a row or column).
- `MoveStop(±1, wrap)` — cycle Tab-stops in declaration order, landing on the stop's
  **remembered position, else its selected member, else its first node**. Without wrap, at the
  ends the result is not-moved (the caller may blur instead — §7.6).
- `MoveRegion(±1)` — jump between regions within the current stop, landing on the region's first
  node.
- `Focus(id)` / `FocusByReference(obj)` — programmatic focus (the latter is the tier-1 sync used
  when the game itself moves selection).
- Tree operations (Right/Left semantics for expandable groups):
  - `TreeRight`: on a collapsed group → expand; if expansion yields no children → auto-recollapse
    and report `EmptyGroup` (never leave a silently-empty expanded node). On an expanded group →
    descend to its first child. Elsewhere inside a tree → `Leaf` (consume; nothing to descend).
  - `TreeLeft`: on an expanded group → collapse (focus stays on the header by identity). Elsewhere
    → ascend to the nearest focusable ancestor.
  - `MoveToSiblingEdge(first)` — first/last node sharing the focused node's parent (Home/End at
    the current tree depth).
- Behavior invokers: `Activate`, `Secondary`, `ActivateShift`, `ActivateCtrl`, `Tooltip`,
  `TryAdjust(sign, large)` — run the focused node's vtable slot; false = it has none (caller
  announces the fallback).

---

## 6. The announcer

### 6.1 Effective announcements

A node's effective parts = the control type's common parts (role word) merged with the node's own
— a node part **overrides** a common part of the same kind — sorted by the type's kind order with
a **stable** sort (unknown/kindless parts keep declaration order, after the ordered kinds), then
filtered by the user's per-type/per-kind settings (P8). This single list feeds both readouts and
the live watch.

### 6.2 Path diffing — the core speech algorithm

The spoken line for a focus change from `from` to `to`:

```
toPath   = ancestors of to (outermost first) + to itself     # via Parent pointers
fromPath = same for from (empty when from == null)
i = length of common prefix, comparing NODE IDENTITY (Id equality) level by level
if i >= len(toPath):        # ascended, or same node
    speak just to's own readout
else:
    speak toPath[i..] outermost-first, each level's readout,
    SKIPPING a level whose label merely duplicates the next level down
    (label == next's label, or next's readout begins "label,")
prepend the crossed edge's transition label, if any
join with ", "
```

Consequences (all load-bearing):

- Entering a group reads its levels outermost-first, then the landing control:
  "Difficulty settings, list, Normal, radio button, selected".
- Sibling moves share the whole prefix and read just the control.
- Descending from a group header onto its own child re-announces **nothing but the child** — the
  group is on the child's chain AND is the from-node, so the prefix swallows it.
- The dedupe rule kills "a 'Game difficulty' section wrapping the 'Game difficulty' control"
  double-reads.

### 6.3 A node's own readout (leaf text)

Effective parts resolved live, non-empty ones joined with ", " — plus, for an expandable group
that doesn't speak its own expansion, the localized expanded/collapsed state word — plus the
auto-stamped "n of m" position (unless the node carries its own position part, or the user's
position toggle is off). Wording for positions and expansion state is pluggable/localized (P7).

---

## 7. The navigator (host-side policies)

The navigator wires input to kernel operations and owns all speech. The reference implementation
is ~700 lines. Its policies are normative:

### 7.1 The standard key model

- Arrows — edge navigation. On Left/Right, a focused adjustable control (slider) **adjusts
  instead of navigating**. At an edge, Left/Right get **tree semantics** (expand/collapse/
  descend/ascend) when the focused node is in a tree.
- Tab / Shift+Tab — cycle Tab-stops (zones).
- Home / End — jump to the edge (in a tree: first/last sibling at the current depth).
- Ctrl+arrows — region jumps; consume only when the focused node is in a region (else bubble).
- Enter — `OnActivate`; Shift+Enter / Ctrl+Enter — the modified activations; a secondary key
  (reference uses Backspace) — `OnSecondary`.
- A tooltip verb (Space and/or F1) — `OnTooltip`, else speak a localized "no tooltip".
- Escape — the screen's Back action.
- Printable characters — type-ahead search (§7.7).

### 7.2 The frame differ (announce-once)

Each frame (P3), after the screen manager settles (§9): rebuild + reconcile; apply any pending
focus request; then **if the focused identity differs from the identity last spoken, speak the
path-diffed line and update the memory**. This single path replaces per-callsite announce
decisions. Landings that arrive via the differ are **queued** (they follow the screen name or the
keypress feedback that caused them); landings on the direct input paths (arrows, Tab, search) are
**interrupting** and update the differ memory so the differ stays silent (A7).

### 7.3 Consume/bubble contract

An input handler returns whether it consumed the chord; the arbitration layer (P4) suppresses the
application's handling only for consumed chords. Normative rules:

- **Nothing focused → don't consume** activation/tooltip/secondary chords: the application keeps
  its own Enter/Space verbs while the layer's cursor is unseated (critical on screens that
  overlay a live world).
- Arrows at a hard edge: consume inside trees; MAY bubble from plain lists on screens that start
  unfocused (so exploration arrows fall through).
- A screen MAY claim a chord outright as the application's contextual verb before focus gating
  (e.g. Space = the game's own pause/collect-all binding).

### 7.4 Synchronous state feedback

After `Activate`/`Adjust`, if the (possibly re-resolved) focused node declares `StateText`, speak
it **interrupting**, and rebaseline the live watch so the same change isn't spoken twice. This is
what makes rapid key-repeat on a slider or toggle read correctly.

### 7.5 The live watch

While a node stays focused, watch its Live parts: on a value change, speak just that part
(queued). Rebaseline silently whenever focus lands on a new identity — the focus announcement
already spoke the initial state.

### 7.6 Focus states and blur

A screen MAY start **unfocused** (an exploration overlay): no cursor until Tab seats one; Tab past
the last stop blurs back to unfocused and speaks the screen's unfocused announcement. Blur clears
the cursor and differ memory. `HasFocus` (cursor seated?) is the single predicate the rest of the
layer consults (chord claiming, exploration gates).

### 7.7 Type-ahead search

Scope = the focused node's Tab-stop, in declaration order, minus `ExcludeFromSearch` nodes. Match
against `SearchText` (default: the label) **stripped of rich-text markup**. Results navigate with
Up/Down (with OS-style key repeat), Home/End jump to first/last result, Escape clears. Search MUST
stand down entirely while any real text field is live (the layer's own text entry or the
application's), and clears when focus moves off the last result or the screen changes.

### 7.8 Build isolation

A screen's Build reads live application state that can be torn down mid-transition. A throw inside
Build MUST NOT escape the frame tick (it would repeat every frame and mute the layer). Swallow it,
log **once per (screen, exception type)** — not per message, which varying data would defeat —
and render nothing this frame; focus state survives, so the next good render reconciles back.

---

## 8. Input arbitration (the four paths)

A parallel tree over a live application means multiple input paths can react to one keypress. All
four must be handled:

1. **The layer's own poller** (P4) — the intended path.
2. **The application's global keymap** — suppress per-chord, per-frame, only for chords the layer
   claims this frame (a blanket mute breaks the application's contextual verbs). Where the
   application's keymap is user-configurable through its own settings path, prefer **relocating**
   colliding bindings over suppressing them (its hint text then auto-updates).
3. **The UI toolkit's own focus/submit path** (Unity's EventSystem, and equivalents) — the
   application's views stay live beneath the overlay and can react to Submit/click on a selected
   widget. Chord suppression does not reach this path. **Ownership-gate at the application's
   action method** (a "mine now" flag checked inside the patched handler) or keep the toolkit's
   selection cleared while the layer owns focus.
4. **Modal exclusivity** — while a layer-owned modal is focused, the layer owns the whole
   keyboard (mute everything of the application's), so a stray application hotkey can't fire
   under it.

Raw-capture screens (a key-binding dialog) declare `CapturesRawInput`: the layer stands down and
lets the application read the combo.

Never bind keys your users' screen reader eats before the application sees them (NVDA: Insert,
CapsLock). "Free in the application's keymap" ≠ usable.

---

## 9. Screens and the manager

- A **screen** = an `IsActive()` predicate over application state + a `Layer` (stacking order) +
  `Build(builder)` + lifecycle hooks (`OnPush/OnFocus/OnUnfocus/OnPop/OnUpdate`) + policy flags
  (`StartUnfocused`, `Exclusive`, `CapturesRawInput`, `KeepStateOnPop`, `InitialFocusStop`,
  `ScreenName`).
- The **manager** runs per tick: poll every registered screen's `IsActive()` (exception-isolated),
  diff the active set against the persistent stack (pop screens that went inactive with their
  child subtrees; push newly-active ones), then attach the navigator to the **deepest active
  screen** of the top entry. Poll-and-diff — not event subscription — is what makes the stack
  robust to the application recreating its UI objects at will.
- **Per-screen cursor state**: each live screen keeps its own `GraphState`. A screen *covered* by
  a higher layer keeps its state and restores exactly where the user was when focus returns
  (the differ memory resets on attach, so the restored landing announces itself). A *popped*
  screen's state is dropped — reopening starts fresh — unless it opts out (`KeepStateOnPop`:
  screens whose popping isn't really closing, or where resuming your place is the point).
- On focus change, the manager speaks the screen's name (queued), then the differ announces the
  landing — standardized first-focus, uniform across eager and lazy-building screens.

---

## 10. Porting guide

### 10.1 What ports verbatim vs what you rewrite

- **Verbatim** (the kernel, §3–§6): ~1,700 lines. Data model, builder, engine, announcer, plus
  the conformance tests.
- **Per-host, shaped by this spec** (§7–§9): navigator, arbitration, screen manager, speech/sound
  bridges. Roughly 1–2k lines.
- **Per-game, the real cost**: the screen recipes — one `Build` + drive-paths per screen (the
  reference implementation registers ~45), plus event narration (game-log tap), world/exploration
  layers if applicable. This is 80–90% of any project's code. The spec saves you the architecture
  mistakes, not this labor.

### 10.2 Host viability checklist

For a candidate game, verify you can:

1. read UI state every frame (P1) — and enumerate what backs each visual screen;
2. call its UI handlers (P2);
3. run code on a tick where 1–2 are legal (P3);
4. see raw keys AND suppress the game's handling per chord (P4) — including toolkit-level paths
   (§8.3);
5. reach a screen reader (P5);
6. iterate fast (a REPL/dev-server into the live game transformed both source projects'
   velocity).

### 10.3 Ecosystem notes

- **.NET/Mono games** (Unity Mono, SMAPI, tModLoader, RimWorld): the reference kernel drops in
  as-is; Harmony provides P2/P4 patching.
- **Unity IL2CPP**: same, via BepInEx/MelonLoader interop.
- **Unreal**: UE4SS gives Lua + UObject reflection (P1/P2) and a tick; port the kernel to Lua.
- **Godot**: scene-tree access covers P1/P2; GDScript or C# port.
- **Native/no modding API**: P1/P2 via hooking frameworks (Frida/Detours) — the paradigm holds
  but every screen read is reverse-engineering work; budget accordingly.

### 10.4 Conformance

A port is conformant when it passes translations of the kernel test suite (builder wiring,
reconciliation tiers, order computation, tree semantics, announcer path-diff/dedupe/ordering)
and honors the normative policies of §7–§9. The axioms of §1 are the review checklist for
everything above the kernel.
