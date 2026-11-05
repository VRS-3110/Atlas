# Atlas

A native macOS mind-mapping workspace for researchers. Ideas, questions, evidence, sources,
quotes and tasks are all nodes in one graph, and every window shows the same live data.

Atlas was built in five phases, all now done (version 1.0); [PHASES.md](PHASES.md) records
what each one delivered, how to try it, and the decisions taken along the way.

## Requirements

- macOS 14 Sonoma or later
- The Swift 6 toolchain, from the Xcode Command Line Tools (`xcode-select --install`) or Xcode 16+
- No third-party packages

## Build, run and test

```bash
Scripts/run.sh
```

That builds a debug `build/Atlas.app` and opens it. Other entry points:

| Command | What it does |
| --- | --- |
| `Scripts/build-app.sh release` | Optimised, universal `build/Atlas.app` (Apple silicon and Intel), ad-hoc signed. Drag it to Applications to keep it. Debug builds are for this Mac's processor only. |
| `Scripts/make-dmg.sh` | The release app in a disk image, `build/Atlas-<version>.dmg`, with an Applications shortcut to drag it onto. |
| `Scripts/test.sh` | Runs the unit tests. Extra arguments go to `swift test`, e.g. `Scripts/test.sh --filter Undo`. |
| `open Package.swift` | Opens the package in Xcode, if you have it. |

The release app runs on any Mac with macOS 14 or later, Apple silicon or Intel. It is
signed ad hoc rather than with a Developer ID, and it is not notarised. It opens normally on the Mac that built it. On another Mac,
macOS blocks the first launch: choose Open Anyway in System Settings ▸ Privacy & Security.
Each phase bumped the version; the finished app was 1.0, and 1.1 added the JourneyMan link. `swift Scripts/make-icon.swift`
redraws the app icon.

The scripts work around two quirks of a Command Line Tools-only install. Neither touches
anything outside this folder. An older CLT install can leave a stale `PackageDescription`
interface behind that breaks every `Package.swift`, so the scripts point SwiftPM at a clean
copy in `.build-support/`. They also pass `swift test` the search paths for the Swift
Testing framework. With Xcode selected, both steps are skipped.

## Your data

| What | Where |
| --- | --- |
| Workspace | `~/Library/Application Support/Atlas/Atlas.sqlite` |
| Daily backups (newest 7 kept), and a copy made before each restore | `~/Library/Application Support/Atlas/Backups/` |
| Attached PDFs and files | `~/Library/Application Support/Atlas/Attachments/` |
| Tasks shared with JourneyMan (only when sharing is on) | `~/Documents/JourneyMan/atlas/` |

File ▸ Back Up Workspace… writes a single portable `.atlasbackup` file (JSON, with the
attached files inside); File ▸ Restore from Backup… replaces the workspace with one, after
asking.

How saving works:

- Every change is saved within half a second.
- Atlas also saves immediately when it quits or moves to the background.
- The database uses write-ahead logging with full sync, so a crash or power cut cannot
  corrupt it.
- Records written by a newer version of Atlas, or damaged ones, are left untouched rather
  than dropped.

To try Atlas without touching your real workspace, point it at another file:

```bash
ATLAS_STORE_PATH=/tmp/atlas-test/Atlas.sqlite build/Atlas.app/Contents/MacOS/Atlas
```

## Using the map

Select a node first, then:

| Keys | Action |
| --- | --- |
| Tab | Add a child and edit its title |
| Return | Add a sibling below (a child, for a central topic) |
| Space, F2 or double-click | Edit the title; typing any letter starts editing too |
| Return / Esc while editing | Keep the title / cancel (a new empty node disappears) |
| Arrow keys | Move to the nearest node in that direction; ⇧ adds to the selection |
| ⌫ | Delete the node and its branch from this map |
| ⌘. | Collapse or expand the branch |
| ⌃⌘1 – ⌃⌘9 | Set the type: Idea, Question, Hypothesis, Claim, Evidence, Source, Quote, Task, Note |
| ⌘C / ⌘X / ⌘V | Copy, cut or paste branches (pasted as children of a single selected node) |
| ⌘D | Duplicate |
| ⌘] / ⌘[ or ⇧Tab | Indent / outdent |
| ⌥⌘↑ / ⌥⌘↓ | Move up / down among its siblings |
| ⌘L | Connect the other selected nodes to the one clicked last |
| ⌥⌘G / ⇧⌥⌘G | Group the selection in a labelled frame / remove the frame |
| ⌘A | Select every visible node on the map |
| ⌘Z / ⇧⌘Z | Undo / redo, shared by every window |

With a connection selected, Return or Space opens the relation menu and ⌫ deletes it. While
the relation menu is open, 1–6 pick related, supports, contradicts, leads to, part of or
custom. With a group selected, Return or Space renames it and ⌫ removes the frame (the nodes
stay).

Mouse and trackpad:

| Gesture or keys | Action |
| --- | --- |
| Click | Select a node, connection or group title; ⇧-click or ⌘-click adds to the selection |
| Drag a node | Move it with its branch; it snaps to nearby nodes unless you hold ⌘ |
| Drop a node onto another | The middle makes it a child. In Mind Map, Tree and Org Chart, the top or bottom edge (left or right in an org chart) puts it before or after |
| Drag a dot on a node's edge | Connect the node to the one you drop on, then pick the relation |
| Drag empty canvas | Select the nodes in the rectangle; ⇧ or ⌘ adds them to the selection |
| Space-drag, middle-button drag or two-finger scroll | Pan |
| Double-click empty canvas | Add a free-standing node |
| Double-click a connection | Change its relation |
| Drag a group's title | Move the group; double-click the title to rename it |
| Pinch or ⌘-scroll | Zoom around the pointer |
| Smart zoom (two-finger double-tap) | Zoom to 100% at the pointer, or back out to fit |
| Click or drag in the minimap | Move around the map |

In an automatic layout, dragging a node onto empty canvas pins it there; the layout then
arranges its branch around it. Unpin it from its right-click menu, the inspector or
Arrange ▸ Unpin All.

Layouts and views:

| Keys | Action |
| --- | --- |
| ⌥⌘1 – ⌥⌘5 | Free Placement, Mind Map, Tree (Right), Org Chart, Radial |
| ⇧⌘F | Focus mode: dim nodes more than 1–6 hops from the selection (View ▸ Focus Depth) |
| ⇧⌘M | Show or hide the minimap |
| ⌘= / ⌘- / ⌘0 / ⌘9 | Zoom in / out / actual size / fit |

Everywhere else:

| Keys | Action |
| --- | --- |
| ⌘K | Command palette: jump to a node, map, source or section, or run a command |
| ⌘N | New map |
| ⌥⌘N | New window |
| ⇧⌘O | Open the current page in a new window |
| ⌘1 – ⌘6 | Inbox, Today, Week, Sources, Tags, Review |
| ⌥Space (from any app) | Quick capture into the Inbox; ⌘Return saves. Change it in Settings |
| ⌘T | Make the selected nodes tasks, or turn them back |
| ⇧⌘C | Copy a citation for the selected source, quote or citing node |
| ⌘, | Settings: capture shortcut, calendar, planner, workspace location |
| ⌃⌘I | Show or hide the inspector |
| ⌃⌘S | Show or hide the sidebar |

The inspector shows whatever is selected:

- **A node.** Rename it, set its type and colour, add tags, pin it, and write notes in
  Markdown. Linking another node with `[[Its Title]]` lists the link on that node. You can
  also turn the node into a task and see everything that refers to it.
- **A connection.** Its relation, label, line style and arrow.
- **A group.** Its title, colour and nodes.
- **Several nodes.** Align and distribute them.
- **Nothing.** The map's details and its layout.

Resting the pointer on a node for a moment shows a preview card: a source's details and
where it is used, a link, what the node cites, task dates and the start of its notes.

## The other pages

| Page | What it is for |
| --- | --- |
| Inbox | Everything captured and not yet filed. Drag items onto a map, or make them sources or tasks, or archive them. |
| Today | A timeline of the day: drag tasks onto it, move and stretch blocks, see calendar events, start a focus timer. The daily log beside it lists what you touched. |
| Week | Seven days of the same timeline, with a tray of overdue and unscheduled tasks. |
| Sources | The library: sort, filter by tag, year or author, look up DOIs and links, import and export BibTeX, read PDFs and add quotes. |
| Tags | Every tag with its nodes. |
| Review | The week: completed tasks, new sources, unanswered questions and branches left quiet for 14 days. |

Export a map from File ▸ Export Map as PNG, PDF, a Markdown outline or OPML. File ▸ Import
Outline… makes a map from OPML, Markdown or indented text.

## Working with JourneyMan

Atlas can share its tasks with [JourneyMan](https://github.com/VRS-3110/JourneyMan), a time
tracker. Turn it on in Settings ▸ JourneyMan.

- Tasks show up in JourneyMan with a project for each map.
- Done goes both ways.
- Focus time becomes deep work there, and time tracked there shows in the inspector.
- **Open in JourneyMan** and **Open in Atlas** (`atlas://node/<id>`) jump between them.

The apps share a folder on this Mac, `~/Documents/JourneyMan/atlas`, and nothing goes
online. Setup, the sync rules and both file formats are in [JOURNEYMAN.md](JOURNEYMAN.md).

## How it is put together

| Module | Contents | Depends on |
| --- | --- | --- |
| `AtlasLayout` | Pure geometry: the automatic layouts, snapping, align and distribute, connector curves, arrow-key navigation. | Nothing |
| `AtlasCore` | Model and store. | AtlasLayout |
| `Atlas` | SwiftUI and AppKit app. | Both |

`AtlasCore` holds:

- **Model.** Each record is a plain `Codable` struct: `NodeData`, `EdgeData`, `MapData`,
  `PlacementData`, `FrameData` and `DayLogData`.
- **Entities.** Views see each record through an observable `Entity`, so they read
  `node.title` directly.
- **Store.** `Workspace` is one shared store. Every change goes through
  `Workspace.perform`, which makes it one undo step and marks it for saving.
- **Persistence.** SQLite, with each record stored as JSON.
- **Clipboard and search.** Copied branches, outline text in both directions, and the fuzzy
  matching behind the ⌘K palette.
- **Research.** BibTeX, citation keys and formatting, Crossref and web-page metadata,
  capture rules, templates, sources and quotes.
- **Planning.** Scheduling, the daily log, the weekly review, and the JourneyMan link's
  file formats and rules.
- **Export.** Markdown and OPML, outline import, and workspace backup and restore.

The `Atlas` app:

- Draws nodes as native views and connectors in a single `Canvas`, with groups behind them
  and drag feedback, connection handles and the relation menu above.
- Uses an invisible AppKit view to own the keyboard and trackpad gestures over the canvas.
- Keeps each map's interaction state in a `MapController`. Layout targets are recomputed
  when the map changes, and `LayoutAnimator` springs the nodes towards them.

A node can sit on several maps. Its position and parent are stored per map, in
`PlacementData`. Relation edges are global and are drawn on every map that holds both
ends.

## Development aids

Each runs only when its environment variable is set.

- `ATLAS_SNAPSHOT=/path.png` saves a picture of the window shortly after launch. Add
  `ATLAS_SNAPSHOT_QUIT=1` to quit afterwards.
- `ATLAS_SCRIPT=/path.txt` replays keyboard, mouse and menu steps and dumps the map state
  as JSON. It can also export, back up, restore, generate large maps (`generate 1000`) and
  measure frame rates (`fps 4 /path.txt zoom`). The command list is in
  `Sources/Atlas/App/DebugScript.swift`.
- `ATLAS_PASTEBOARD=name` makes copy and paste use a private pasteboard of that name, so
  scripted runs leave your clipboard alone.
