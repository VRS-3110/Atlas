# Build phases

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Data model, persistence, sidebar shell, basic canvas | Done |
| 2 | Full map interactions, layouts, focus mode, ⌘K palette, undo polish | Done |
| 3 | Quick capture, Inbox, sources library, DOI lookup, BibTeX, templates | Done |
| 4 | Tasks, Today and Week, calendar (EventKit), daily log, weekly review | Done |
| 5 | Export, performance, accessibility, polish | Done (version 1.0) |

---

## Phase 1: foundation

### What was built

**Model.** Everything is a node. A node has a type (idea, question, hypothesis, claim,
evidence, source, quote, task or note), tags, a colour and Markdown notes. Source details
(authors, year, DOI and so on) and task details (status, priority, due date) are optional
parts of a node rather than separate records. That way a quote can cite a source, and any
node can become a task without being copied.

The other records:

- **Maps** list the nodes placed on them.
- **Placements** hold a node's position and parent per map, so one node can appear on
  several maps.
- **Relation edges** (supports, contradicts, leads to, part of, related, custom) link any
  two nodes and show on every map that holds both.
- **Frames** and **day logs** are modelled already. They get their UI in phases 2 and 4.

**Store.** A single `Workspace` shared by every window:

- Edits appear everywhere at once. Renaming a node in the inspector updates every map
  showing it.
- Each command is one undo step. Typing and drags merge into a single step.
- Failed edits roll back completely.
- Removing a node from a map deletes it only if it has no other home. Its other homes can
  be another map, the inbox, the sources library or the planner.

**Saving.**

- Edits are saved to SQLite within half a second, and straight away on quit or when Atlas
  goes to the background.
- A dated backup is made each day; the newest seven are kept.
- Records that cannot be read are reported and left untouched in the file.

**Window.** A sidebar with:

- Inbox, Today, Week, Sources, Tags and Review (all placeholders except Tags).
- The map list, with New Map, rename, drag to reorder, delete with confirmation (undoable)
  and Open in New Window.

Any page can open in its own window, and several windows can show the same map. The Tags
page lists every tag with its nodes.

**Map canvas.**

- Nodes are native views; connectors are curves drawn in one canvas, with relation labels.
- New maps and first launches fit the map to the window, and each map remembers its
  viewport.
- Keyboard editing: Tab, Return, Space, typing, arrows, ⌫, ⌘. and Esc.
- Mouse editing: click, ⇧-click, drag and double-click.
- Pan and zoom with the trackpad, the mouse and the zoom buttons.
- Right-click menu on nodes.

**Inspector.**

- For a node: title, type, colour, tags, Markdown notes with preview, task and source
  details.
- References to the node: maps it is on, relation edges, citations and `[[links]]`.
- With nothing selected, it shows the map's details.

**Welcome map.** A first launch shows a short guided map that uses each feature once.

**Tests.** 68 unit tests in `Tests/` (`Scripts/test.sh`) cover:

- Transactions and undo: coalescing, rollback, gesture steps, history limit, observers.
- Every editing operation, including the orphan rules.
- The map tree, including bad data and cycles.
- Queries: references, graph distance, tags and search.
- Model encoding, including records from newer or damaged files.
- Saving, autosave, unreadable rows, restore and backup pruning.
- Geometry and arrow-key navigation.

### How to try it

1. Run `Scripts/run.sh`. The welcome map opens, fitted to the window.
2. Click **Welcome to Atlas** and press Tab. Type a title and press Return. Press Return
   again for a sibling, type, then press Esc. The empty node disappears.
3. Select a node and press Space (or just start typing) to rename it. Esc puts the old
   title back.
4. Use the arrow keys to move around the map. ⇧-arrow and ⇧-click select several nodes.
5. Drag a node: its branch moves with it. Press ⌘Z and it goes back, still selected.
   ⇧⌘Z moves it again.
6. Select **How do I edit a map?** and press ⌘. to collapse it. The badge shows how many
   nodes are hidden; click it to expand.
7. Select a note and press ⌫. The previous sibling becomes selected. ⌘Z brings the note
   back.
8. Double-click empty canvas to add a free-standing node.
9. Pan with a two-finger scroll or by dragging the background. Pinch to zoom, or use ⌘=,
   ⌘-, ⌘0 (100%) and ⌘9 (fit). A two-finger double-tap toggles between 100% and fit.
10. With a node selected, change its title in the inspector and watch the map update.
    Change its type (⌃⌘1–⌃⌘9) and colour. Add tags, then open the Tags page (⌘5).
11. In a node's notes, write `[[Everything is a node]]`. Select that node: the inspector
    lists the link.
12. Press ⌘N for a new map. Right-click it in the sidebar to rename it or open it in a new
    window. Drag maps to reorder them. Delete a map and press ⌘Z to restore it.
13. Open the same map in two windows (⇧⌘O) and edit in one: the other follows.
14. Quit and reopen. Everything is back, each map at its last zoom and position.
15. Check `~/Library/Application Support/Atlas/Backups/` for today's backup.

### Verified so far

- The 68 unit tests pass.
- Scripted sessions in the built app covered the following, through real keyboard and mouse
  events:
  - adding children and siblings
  - typing titles, and Return and Esc while editing
  - ⌘Z and ⇧⌘Z, with the selection following
  - click and ⇧-click
  - dragging a node and undoing the drag
  - double-clicking a node and empty canvas
  - clicking the background
  - ⌘. to collapse
  - ⌘0 and ⌘9 from the View menu
- A forced kill 0.6 s after an edit lost nothing.
- The scripts checked the logic behind scrolling and pinching, but not a physical
  trackpad.
- The steps for multiple windows, the sidebar menus and inspector editing (items 10–13 in
  the list above) have not been tried in the running app yet.

### Decisions and assumptions

1. **SQLite instead of SwiftData.** This Mac has the Command Line Tools but not Xcode, and
   SwiftData's `@Model` macro needs a compiler plugin that only ships with Xcode. Atlas
   therefore stores records in SQLite (part of macOS) behind one observable store. It keeps
   the guarantees asked of SwiftData: autosave, no data loss, crash safety and backups.
   - Undo, cross-window updates and saving all go through one code path.
   - The package opens in Xcode unchanged.
   - Moving to SwiftData later would only replace `Persistence/`.
2. **A Swift package, not an Xcode project.** `Scripts/build-app.sh` assembles and ad-hoc
   signs `Atlas.app`. The app is not sandboxed.
3. **Sources and tasks are node facets** rather than separate records. That keeps one graph
   and lets the planner, the sources library and maps show the same object.
4. **Undo is shared by every window**, like the data. While a title is being edited, ⌘Z
   undoes the typing first.
5. **Positions are free-form in Phase 1.** New nodes go below their siblings, balancing the
   two sides of a central topic. Automatic layouts (mind map, tree, org chart, radial)
   arrive in Phase 2; each map already stores its layout style.
6. **Deleting on a map is safe.** It never destroys a source, a task, an inbox item or a
   node shown on another map.
7. **Calendar access** will be read-only (Phase 4). The usage description is already in
   `Info.plist`.

### Not in Phase 1

- Drawing relation edges by hand: they display, but the connect tool comes in Phase 2.
- Automatic layouts, focus mode, the ⌘K palette and frames UI (Phase 2).
- Quick capture, the Inbox, the sources library and BibTeX (Phase 3).
- Today, Week, the calendar, the daily log and the review (Phase 4).
- Export (Phase 5).

Sidebar entries for later phases show which phase brings them.

---

## Phase 2: map interactions

### What was built

**Layouts.** Each map has a layout, set from the Arrange menu (⌥⌘1–⌥⌘5), the ⌘K palette or
the map inspector:

- **Free Placement**: nodes stay where you put them.
- **Mind Map**: branches on both sides of the central topic.
- **Tree (Right)**: every branch grows to the right.
- **Org Chart**: branches grow downwards, one row per level.
- **Radial**: one ring per level around the central topic, each branch in its own slice.

How the automatic layouts behave:

- They are worked out from the tree and the node sizes every time, so they never overwrite
  stored positions.
- Nodes spring to their new places. Reduce Motion turns the animation off.
- Central topics keep their place.
- A **pinned** node stays where you put it. Its branch is arranged around it, and it does
  not push its siblings around.
- Switching to Free Placement keeps every node where the layout had it, as one undo step.

**Canvas.**

- Panning and zooming are animated.
- A layout switch that moves nodes out of view zooms to fit.
- The **minimap** in the corner shows the whole map and the visible part. Click or drag in
  it to move around; ⇧⌘M hides it.
- Dragging empty canvas draws a selection rectangle. ⇧ or ⌘ adds to the selection.
- Pan with Space-drag, a middle-button drag or a two-finger scroll.

**Moving nodes.**

- **Snapping.** A dragged node snaps to the edges and centre lines of nearby nodes, and
  pink guides show the match. Hold ⌘ to place it freely.
- **Dropping onto a node.** Drop on the middle of a node to make the branch its child; the
  node lights up first.
  - In Mind Map, Tree and Org Chart, the top or bottom of a node (left or right in an org
    chart) puts the branch before or after it instead. A line shows where it will go.
- **Dropping on empty canvas.**
  - In an automatic layout, the branch is pinned where you let go.
  - Letting go close to where the layout already has it cancels the move.
  - In a mind map, dragging a main branch across the central topic moves it to that side.
- **Keys.** ⌘] indents and ⌘[ (or ⇧Tab) outdents. ⌥⌘↑ and ⌥⌘↓ move a node among its
  siblings.

**Connections.**

- **Making them.**
  - Point at a node to show four handles, then drag a handle onto another node. The target
    lights up while you drag.
  - ⌘L connects every other selected node to the one clicked last.
- **The relation menu.**
  - It opens straight after connecting, offering related, supports, contradicts, leads to,
    part of and custom. Digits 1–6 pick one.
  - Connecting and picking the relation are one undo step.
- **Editing them.**
  - Click a connection to select it. The inspector then shows its relation, label, line
    style and arrow.
  - Return, Space or a double-click reopens the relation menu; ⌫ deletes the connection.
- **How they look.**
  - Connections of the selected or hovered nodes stand out.
  - A label that cannot fit between two close nodes moves beside its line.

**Align and distribute.** Select several nodes, then use Arrange ▸ Align or Arrange ▸
Distribute, or the inspector's Arrange buttons. Align works on the left, centre, right, top,
middle or bottom; distribute spaces nodes horizontally or vertically. In an automatic
layout, the moved nodes are pinned.

**Groups.**

- ⌥⌘G draws a labelled frame around the selected branches and starts naming it.
- The frame follows its nodes, so it never needs resizing.
- Its title tab selects the group, drags it, or (with a double-click) renames it.
- The inspector sets its colour. ⇧⌥⌘G removes the frame and keeps the nodes.

**Focus mode** (⇧⌘F) dims everything more than N hops from the selection. Hops follow both
tree links and connections. N runs from 1 to 6 (default 2), set with View ▸ Focus Depth or
the stepper in the banner.

**⌘K palette.**

- Type a few letters to jump to any node, map, source or sidebar section, or to run a
  command: layouts, align, group, focus, zoom, undo and more.
- With nothing typed, it lists recently edited nodes first.
- ↑ and ↓ choose, Return runs, Esc closes.

**Clipboard.**

- ⌘C, ⌘X, ⌘V and ⌘D copy, cut, paste and duplicate whole branches. Types and notes come
  along, and so do connections within the copied branches.
- Copies also reach the clipboard as an indented outline of titles.
- Indented text, lists or Markdown headings copied from another app paste as new branches.

**Undo.** Every command is one step. That includes:

- drags, layout switches, align and distribute;
- connecting with its relation;
- grouping with its name;
- pasting.

Undo and redo select what they changed.

**Upgrading.** Maps made in Phase 1 open in Free Placement, so nothing moves on first
launch.

**Tests.** 107 unit tests, 39 of them new, cover:

- Every layout style:
  - anchors and pins
  - mind map sides and radial rings
  - determinism
  - 1,000 nodes in milliseconds
- Snapping, align and distribute.
- Store operations:
  - layout switches and pins
  - branch moves, including refusing a move into itself
  - indent and outdent
  - frames
  - connecting and picking a relation as one step
- Copy, paste and outline text in both directions.
- Fuzzy matching for the palette.
- The one-time move of Phase 1 maps to Free Placement.
- Where relation labels go.

### How to try it

1. Run `Scripts/run.sh`. Your maps open exactly as before, in Free Placement.
2. Press ⌥⌘2 (Mind Map) and watch the nodes spring into place. Try ⌥⌘3, ⌥⌘4 and ⌥⌘5, then
   press ⌘Z to step back through them.
3. In Mind Map, drag a node onto the middle of another node: it becomes a child. In Tree
   (Right), drop it on the top or bottom edge of a node instead: it goes before or after
   that node.
4. Drag a node to empty canvas: it stays there, with a pin badge. Switch layouts and it
   stays put. Right-click it and choose Unpin, or use Arrange ▸ Unpin All.
5. In Mind Map, drag a main branch across the central topic: it moves to the other side.
6. Press ⌥⌘1 (Free Placement). Drag a node close to another so their edges almost line up:
   pink guides appear and it snaps. Hold ⌘ while dragging to place it freely.
7. Drag across empty canvas to select several nodes. Hold Space and drag, or drag with the
   middle mouse button, to pan.
8. Point at a node and drag one of the dots on its edges onto another node. When the menu
   appears, press 2 (Supports). Then press ⌘Z once: the connection goes.
9. Click one node, ⌘-click another and press ⌘L. Click the new connection, press Return and
   pick another relation, then press ⌫ to delete it.
10. Select three nodes. Use Arrange ▸ Align ▸ Left, then Arrange ▸ Distribute ▸ Vertically.
11. Select two nodes and press ⌥⌘G. Type a name and press Return.
    - Drag the frame by its title.
    - Double-click the title to rename it.
    - Change its colour in the inspector.
    - Press ⇧⌥⌘G to ungroup.
    - Group again and press ⌘Z: the frame and its name go together.
12. Select a node and press ⇧⌘F: nodes more than two hops away dim. Use the stepper in the
    banner to change the depth, then press Done.
13. Press ⌘K, type part of a node's title and press Return: Atlas goes to it, even on
    another map. Type "tree" to find the layout command.
14. Copy a branch with ⌘C, select another node and press ⌘V: the copy becomes its child.
    - Paste into TextEdit to see the outline.
    - Copy an indented list from TextEdit and paste it onto the map.
15. Try ⌘D to duplicate, ⌘] and ⌘[ to indent and outdent, and ⌥⌘↑ and ⌥⌘↓ to reorder.
16. Click or drag in the minimap to move around, and press ⇧⌘M to hide it.
17. Quit and reopen. Layouts, pins, groups and connections are all back.

### Verified so far

- The 107 unit tests pass.
- Scripted sessions in the built app used scratch workspaces and a private clipboard. They
  checked the following through real keyboard and mouse events:
  - all five layouts, switching between them, and undoing a switch
  - drop as child, drop before, and drop onto a node in Free Placement
  - pinning by dragging to empty canvas
  - marquee selection, and panning with Space-drag (with no edit when Space is let go)
  - connecting from a handle and picking the relation with a digit, as one undo step
  - ⌘L, and selecting, retyping, deleting and double-clicking a connection
  - copy and paste of branches and of outline text
  - duplicate, indent, outdent and move up
  - grouping and naming as one undo step, dragging a group by its title, and ungrouping
  - focus mode at one and two hops
  - the ⌘K search and jump, ⌥⌘3 and a minimap click
  - the new menus, read back item by item with their shortcuts
- Some checks drove the map controller directly rather than real input:
  - align and distribute
  - snapping in Free Placement (a node landed exactly on a neighbour's edge)
  - group drags, which are named "Move Group"
- Not yet tried in the running app:
  - middle-button panning and a physical trackpad
  - the inspector's Arrange, Layout and frame colour controls
  - switching sides in a mind map by dragging
  - Reduce Motion
  - very large maps beyond the layout timing test

### Decisions and assumptions

1. **Phase 1 maps open in Free Placement.**
   - Phase 1 saved hand positions for every map but labelled them all "mind map".
   - Laying them out automatically on upgrade would have moved everything.
   - A one-time step marks them Free Placement instead. Pick a layout to rearrange one.
2. **Automatic layouts are calculated, not saved.**
   - Stored positions matter only for Free Placement, pinned nodes and central topics.
   - Switching to Free Placement saves the current arrangement, so nothing jumps.
3. **Moving a node in an automatic layout pins it**, rather than letting it spring back.
   Letting go within 20 points of its layout position counts as cancelling. Pins are hidden
   and have no effect in Free Placement, but are kept for when you switch back.
4. **Drop zones.**
   - The middle of a node takes a child.
   - In Mind Map and Tree, the top or bottom 30% inserts a sibling. In Org Chart it is the
     left or right 25%.
   - Free Placement and Radial take only child drops, because there sibling order is not a
     visible line. So do central topics.
5. **Dragging empty canvas selects; it no longer pans.**
   - A selection rectangle matters once align, distribute and group exist.
   - Panning moved to Space-drag, a middle-button drag and two-finger scrolling.
6. **Groups are frames that follow their nodes**, not free-standing rectangles. They never
   need resizing and cannot drift away from what they label. A new group is called "Group"
   until you name it.
7. **⌘L connects towards the node clicked last.** Select the evidence, then the claim, then
   press ⌘L, and the connections run from the evidence to the claim.
8. **Relation digits follow the menu order:**
   1. related
   2. supports
   3. contradicts
   4. leads to
   5. part of
   6. custom

   Closing the menu without choosing keeps "related".
9. **Snapping** reaches 6 screen points at any zoom, and holding ⌘ turns it off.
10. **Focus depth** counts tree links and connections in either direction. Atlas remembers
    the depth you last used.
11. **The palette hides commands that do not apply** to the current selection, rather than
    listing them greyed out.
12. **Copies carry two formats**: a private Atlas one that keeps everything, and a plain
    outline that other apps understand.
13. **Scripted checks never touch your clipboard.** `ATLAS_PASTEBOARD` gives them a private
    pasteboard.

### Not in Phase 2

- Quick capture, the Inbox, the sources library, DOI lookup, BibTeX and templates (Phase 3).
- Today, Week, the calendar, the daily log and the review (Phase 4).
- Export, performance work on very large maps, a full accessibility pass and polish
  (Phase 5).

---

## Phase 3: research capture and sources

### What was built

**Quick capture.**

- ⌥Space opens a small capture panel from any app, without bringing Atlas forward.
  ⌘Return files the text in the Inbox; Esc closes it.
- The shortcut can be changed or turned off in Settings (⌥Space, ⌃⌥Space, ⇧⌘Space, ⌥⌘C).
- File ▸ Quick Capture… and the ⌘K palette open the same panel.
- The Inbox page has its own capture field at the top.

**What a capture becomes.** Atlas reads the text:

- The first line is the title; the rest becomes notes. `#tags` anywhere become tags.
- A lone link or DOI becomes a source, and Atlas fetches its details (see below).
- A line ending in `?` becomes a question.
- `[] `, `- [ ] ` or `todo:` at the start makes a task.
- `> ` at the start, or text in quotation marks, makes a quote.
- Anything else is a note.

**Dragging things in.** Drop onto a map (as a child of the node under the pointer, or
free-standing), onto the Inbox, or onto Sources:

- Links from Safari become sources with the page's details.
- PDFs from Finder or Preview become sources with the PDF attached. Atlas looks for a DOI
  on the first two pages and fetches the paper's details; otherwise it uses the PDF's own
  title and author.
- Selected text becomes a quote. Images and other files are attached to a new note.
- `.bib` files dropped on Sources are imported.

**Looking up details.**

- DOIs are looked up with Crossref (`api.crossref.org`): title, authors, year, journal,
  volume, issue, pages, publisher, ISBN and link.
- Web pages are read for scholarly `citation_*` tags, then Dublin Core, Open Graph and
  finally the page title.
- Lookups only fill empty fields, so nothing you typed is overwritten. A placeholder title
  (the bare link or file name) is replaced.
- Sources ▸ Add ▸ Add by DOI or Link… looks a source up before adding it. Fetch Details in
  the inspector retries one.

**BibTeX.**

- Import reads `@article`, `@book`, `@inproceedings` and the other common types, with
  `@string` macros, `#` joins, month names and LaTeX accents (`{\"o}` → ö). A damaged entry
  is skipped without swallowing the next one.
- Imported sources merge with existing ones that share a DOI or citation key, so importing
  the same file twice adds nothing.
- Export writes the selected sources, or all of them, with fields Atlas does not model
  (e.g. `note`, `annote`) kept from the import.
- Citation keys are made like `darwin1859origin`: first author's family name, year, first
  significant title word. Clashes get `a`, `b`, … A key you typed is never changed.

**Quotes and citing.**

- A quote links to its source and a page. Add one from the source's inspector, or select
  text in the PDF pane and click Add Quote; the page label comes with it.
- Any node can cite sources (inspector ▸ Cites), each with a page.
- ⇧⌘C (Node ▸ Copy Citation) copies, for a source, its reference; for a quote, the quote
  with an in-text citation and the reference; for anything else, what it cites. The style
  is APA-like.

**Sources library** (⌘4).

- A sortable table: title, authors, year, journal or publisher, key, and how often it is
  used. Filter by tag, year or author, and search titles, authors and keys.
- The inspector shows where each source is used: maps, citing nodes and quotes.
- Double-click (or Open PDF) opens the attached PDF in a pane beside the table.

**Research templates.** File ▸ New Map from Template, or Node ▸ Insert Template under the
selected node:

- Research Question → two hypotheses, each with Evidence For and Evidence Against → Open
  Questions.
- Literature Review: three themes and Gaps in the Literature. Sources selected when you
  insert it go under Unsorted Sources; Sources ▸ right-click ▸ New Literature Review from
  Selection does the same.
- Argument Map: a claim with two premises and an objection with its rebuttal.

**Inbox triage** (⌘1). Drag items onto a map, or use the toolbar: Add to Map, Make Source
(fetching details), Make Task, Archive. Archived items stay searchable under Archived.

### How to try it

1. Switch to another app, press ⌥Space, type `Is the sample biased? #methods`, press
   ⌘Return. Open the Inbox: a question tagged `methods`.
2. Capture `10.1038/nature14539`. Within a few seconds (with a network connection) the
   placeholder becomes the paper's title, authors, year and journal, with a citation key.
3. Drag a paper's PDF from Finder onto a map. A source node appears with the PDF attached;
   double-click it in Sources to read it, select a sentence and click Add Quote.
4. Import a `.bib` file from Zotero (Sources ▸ Add ▸ Import BibTeX…), then import it again:
   the second time reports everything as already present.
5. Select a quote on a map and press ⇧⌘C; paste into a text editor.
6. File ▸ New Map from Template ▸ Research Question.

### Verified

- Unit tests: BibTeX parsing and writing, LaTeX accents, author names, citation keys,
  citation formatting, Crossref and web-page metadata (with a fake network), capture rules,
  templates, Inbox triage, merging imports and source usage.
- In the running app (scripted, on a scratch workspace): captures landing in the Inbox
  with the right types and tags, the Sources table and inspector, inserting a template,
  the hover card on a source.
- Not checked automatically: the global ⌥Space shortcut from another app, drags from
  Safari and Preview, and live Crossref lookups. They need a person at the keyboard and the
  network.

### Decisions and assumptions

1. **Quick capture never steals focus.** The panel floats over the current app, so you can
   capture a thought while reading and carry on.
2. **Lookups identify Atlas but send no personal details.** Crossref asks clients to
   identify themselves; Atlas sends "Atlas/1.0 (macOS research app)" and no email address.
3. **Sources are nodes.** A source can sit on maps, have notes and tags, and be a task,
   like anything else.
4. **Citation style is APA-like and fixed.** A style picker (Chicago, MLA, CSL files) can
   come later; BibTeX export covers reference managers.
5. **Attached files are copied** into the workspace's `Attachments` folder, so moving or
   deleting the original does not break a source.

---

## Phase 4: planning

### What was built

**Tasks with a live link.**

- ⌘T makes the selected nodes tasks, or turns them back. The node stays where it is: the
  task *is* the node, so renaming it anywhere renames the task.
- The node shows a status circle, which fills when done, and a strike-through.

**Today** (⌘2).

- A vertical timeline of the day in 15-minute steps. Drag tasks onto it from the backlog,
  the Inbox, a map in another window, or the Week tray.
- Drag a block to move it; drag its bottom edge to change its length. Overlapping blocks
  share the width.
- Calendar events appear beside your tasks, read-only, after you allow calendar access.
  All-day events and tasks due that day sit in a strip at the top.
- The backlog lists overdue and unscheduled tasks, most urgent first, and has a New Task
  field.

**Week** (⌘3). Seven columns with the same timeline. Drag blocks between days to
reschedule. A tray holds overdue and unscheduled tasks.

**Daily log.** Each day gets a log automatically. It lists every node you created, edited
or moved that day, and has space for notes. It appears beside Today.

**Weekly review** (⌘6).

- Tasks completed, sources added, open questions with no answer, and branches untouched for
  14 days or more.
- A question counts as answered when it has the `answered` tag, or a linked claim or
  evidence (a child, or a connection). Mark Answered adds the tag.
- Mark Reviewed on a stale branch counts as touching it today.

**Deep-work timer.** The timer button on a Today block starts a focus timer, shown in the
toolbar. Stopping it (or starting another, or quitting) adds the time to the task. The
review totals the week's focus time.

### How to try it

1. On a map, select a node and press ⌘T. Open Today: it is in the backlog.
2. Drag it onto 10:00. Drag the block's bottom edge down to make it an hour.
3. Open Week and drag the block to tomorrow.
4. Click the timer on a Today block, wait a minute, click stop. The inspector shows the
   focus time.
5. Edit a few nodes, then look at Today's daily log: they are listed.
6. Open Review.

### Verified

- Unit tests: scheduling and rescheduling, durations, completion dates, overdue and
  unscheduled lists, the daily log (including undo removing a log it created), focus time,
  the review's sections, and how overlapping blocks share lanes.
- In the running app (scripted): tasks scheduled onto Today and shown with their times, the
  daily log listing touched nodes, Week and its tray, the review's tiles and sections.
- Not checked automatically: the calendar permission prompt and real events (macOS asks you
  in person), and dragging blocks with a real mouse.

### Decisions and assumptions

1. **Calendar access is read-only.** Atlas never writes to your calendars. Turn events off
   in Settings ▸ Planner.
2. **Logging is part of the edit.** Each edit adds its nodes to today's log in the same undo
   step, so undoing an edit also takes it out of the log.
3. **Stale means the whole branch is quiet**, not just its first node. "Quiet for" is set
   in Settings (14 days by default).
4. **Blocks snap to 15 minutes** and are at least 5 minutes long.
5. **The day starts at 07:00** on the timeline (Settings ▸ Planner); early in the morning
   it starts just before the current hour instead.

---

## Phase 5: export, performance, accessibility and polish

### What was built

**Map export** (File ▸ Export Map):

- **PNG**: the map as laid out (collapsed branches stay collapsed), at twice screen
  resolution, capped at 16,384 pixels a side.
- **PDF**: a single vector page that scales cleanly.
- **Markdown outline**: the map name as a heading, nested bullets with types, task boxes,
  tags, links, in-text citations and notes as quotes, then a Connections list.
- **OPML**: for OmniOutliner, Bike, Logseq and MindNode, with notes, types, tags, links and
  task states.

Images and PDFs always use the light appearance, so they print and share well, and leave
out selection, focus dimming, the grid and the minimap.

**Import Outline…** (File menu) turns an OPML, Markdown or indented text file into a new
map, with notes. A Markdown export reads back into the same tree.

**Workspace backup and restore** (File menu):

- **Back Up Workspace…** writes one `.atlasbackup` file: every map, node, connection,
  group, task and daily log, plus the attached PDFs.
- **Restore from Backup…** shows what the backup holds and asks before replacing anything.
  It first copies the current workspace to `Backups/Before-Restore-<date>.sqlite`.
- A backup from a newer Atlas is refused. Records this version cannot read are skipped and
  reported.

**Performance on large maps.**

- Maps over 250 nodes draw only the node views in or near the window. The set changes only
  when the view leaves that area, so most frames just move one layer.
- Zoomed out below 35% on such a map, nodes are drawn as shapes in one canvas; titles are
  too small to read there anyway. Clicking still selects, and double-clicking zooms to a
  node.
- The minimap redraws only its view rectangle as you pan.

**Accessibility.**

- VoiceOver reads each node's type, title, task status, tags, notes, sources, and where it
  sits ("level 2, 1 of 3, under Welcome to Atlas"). Actions: Edit Title, Add Child,
  Collapse or Expand.
- With VoiceOver on, every node stays a real view on large maps, so nothing is skipped.
- Planner blocks have actions in place of dragging: Mark Done, Move 15 Minutes Later or
  Earlier, Make 15 Minutes Longer or Shorter, Unschedule, Show Node. Backlog rows have
  Schedule Today. The same items are in the right-click menus.
- Everything works from the keyboard: arrow keys on maps, ⌘1–⌘6 for pages, ⌘K for any node
  or command, and standard list and table navigation elsewhere.
- Reduce Motion turns off the layout animation (Phase 2).

**Polish.**

- Hover previews: resting the pointer on a node shows a card with a source's authors,
  journal, DOI and where it is used; a link's address; what a node cites; task dates; the
  start of its notes and its tags.
- An app icon.
- The Sources page keeps its column headers in view and no longer pushes the sidebar
  closed. The Week page's day headers no longer take half the page.
- Version 1.0 (build 4).

### Performance measured

Frames per second while panning continuously (and zooming, where noted) for four seconds,
on this Mac (60 Hz display), measured with a display link by the scripted harness
(`fps` step). Atlas was running in the background throughout. "Before" is the debug build
without the Phase 5 changes, "After" the optimised build with them; the debug build with
them was within a few frames of the "After" figures for 500 nodes.

| Map | View | Before | After |
| --- | --- | --- | --- |
| 500 nodes | actual size, pan and zoom | 56 | **60** |
| 500 nodes | whole map in view, pan | 55.5 | **57.5** |
| 1,000 nodes | actual size, pan and zoom | 4–15 | **33** |
| 1,000 nodes | whole map in view, pan | 2.6–4 | **47** |
| 1,000 nodes | whole map in view, pan and zoom | 9 | **49** |

At 1,000 nodes the main thread is idle about 84% of the time. What remains is SwiftUI
compositing, not Atlas's own work. The 500-node target is met.

### How to try it

1. On the Welcome map, File ▸ Export Map ▸ PDF…, and open the file in Preview.
2. Export ▸ Markdown Outline…, then File ▸ Import Outline… with that file: a copy of the
   map appears.
3. File ▸ Back Up Workspace…. Make a change, then File ▸ Restore from Backup… with that
   file. The change is gone, and `Backups/` holds a Before-Restore copy.
4. Rest the pointer on On the Origin of Species for a moment.
5. Turn on VoiceOver (⌘F5), click a node and move with the arrow keys.

### Verified

- Unit tests (144 in 22 suites, all passing): the Markdown and OPML exports, reading them
  back, importing outlines, backup round trips (records and attachments, into a different
  non-empty workspace), safety copies, and refusing bad, newer or unsafe backups.
- In the running app (scripted): PNG, PDF, Markdown and OPML exports of a 10-node and a
  500-node map, backing up and restoring a 500-node workspace, frame rates above, the
  overview drawing, hover cards below a node, and the fixed Sources and Week layouts.
- Not checked automatically: VoiceOver speech and the file panels. Both need a person at
  the Mac.

### Decisions and assumptions

1. **Exports follow the screen layout.** Collapsed branches stay collapsed in images. The
   text exports include everything, because they carry the content.
2. **Backups are JSON with embedded files**, not a copy of the SQLite file, so they are
   portable, readable and safe to keep anywhere. The daily SQLite copies continue
   alongside.
3. **Restore replaces, it does not merge.** Merging two workspaces raises conflicts with no
   obvious answer; a safety copy makes a mistaken restore recoverable.
4. **Dynamic Type.** macOS has no system-wide Dynamic Type. Pages use the system's text
   styles, so they follow the sidebar and accessibility text settings where macOS applies
   them. Map nodes keep fixed sizes because the layout depends on them; zoom (⌘=) enlarges
   them instead.
5. **The thresholds** (250 nodes, 35% zoom) were picked so ordinary maps look and behave
   exactly as before.

### Still open

- Notarisation needs your Apple Developer ID; the app is signed ad hoc.
- Citation styles beyond APA-like.
- Exporting several maps at once, and PDF pages split for printing large maps.
