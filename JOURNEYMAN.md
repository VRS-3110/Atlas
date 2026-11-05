# Working with JourneyMan

[JourneyMan](https://github.com/VRS-3110/JourneyMan) is a time tracker and second brain that
runs in the browser. Linked with Atlas:

- Your Atlas tasks show up in JourneyMan, with a project for each map.
- Ticking a task in either app ticks it in both.
- Focus time from Atlas lands in JourneyMan's Time view as deep work.
- Time tracked in JourneyMan shows in Atlas's inspector as **Tracked in JourneyMan**.
- **Open in JourneyMan** (inspector) and **Open in Atlas** (JourneyMan) jump between them.

Nothing goes online. The two apps share one folder on your Mac:
`~/Documents/JourneyMan/atlas`.

## Set it up

1. Atlas ▸ Settings ▸ JourneyMan: turn on **Share tasks with JourneyMan**. Atlas creates the
   folder and writes `tasks.json` into it. macOS may ask whether Atlas can use your
   Documents folder; allow it.
2. JourneyMan (Chrome) ▸ Connections ▸ Atlas: choose **Connect the Atlas folder** and pick
   `Documents/JourneyMan/atlas` (picking `Documents/JourneyMan` works too). Allow it to
   view and edit the folder.
3. The first time you choose **Open in Atlas** in JourneyMan, the browser asks whether to
   open Atlas. Tick "Always allow".

Safari can't keep a folder connected. There, use **Import tasks.json…** and
**Save journeyman.json** in JourneyMan's Connections instead.

## When things sync

- **Atlas** writes `tasks.json` 1.5 seconds after a task changes. It reads `journeyman.json`
  at launch, whenever Atlas comes to the front, and every 30 seconds.
- **JourneyMan** reads `tasks.json` when it opens, when its tab comes back into view, and
  every minute. It writes `journeyman.json` a moment after anything changes.

Changes from JourneyMan arrive as one undo step, **Update from JourneyMan**.

## Who wins

| What | Direction | Rule |
| --- | --- | --- |
| Name, dates, time block, priority, map | Atlas → JourneyMan | A change in Atlas replaces that field in JourneyMan. JourneyMan's own edits stay until that field changes in Atlas. |
| Done | Both ways | The app where it was changed last wins. "Doing" counts as not done. |
| Focus time (Atlas) | Atlas → JourneyMan | The growth since the last read becomes one deep-work entry. |
| Time tracked in JourneyMan | JourneyMan → Atlas | Shown as its own total, so nothing is counted twice. |
| Deleted, cancelled or archived in Atlas | Atlas → JourneyMan | Removed from JourneyMan, or kept and unlinked if it has time logged. |

A task's time block in Atlas sets its day, time and estimate in JourneyMan. Atlas's due date
becomes JourneyMan's deadline.

## The files

Both are JSON. Dates are ISO 8601 in UTC, with or without milliseconds. Each file has a
`format` number. A reader refuses a format newer than it knows.

### `tasks.json` (written by Atlas)

```json
{
  "app": "Atlas", "format": 1, "exportedAt": "2026-11-05T09:00:00.000Z",
  "tasks": [{
    "id": "6F1C2B9E-0A57-4D7B-9E1A-1B2C3D4E5F60",
    "title": "Draft literature review",
    "status": "todo",
    "statusChangedAt": "2026-11-05T08:59:00.000Z",
    "priority": "high",
    "due": "2026-11-09T00:00:00.000Z",
    "scheduledStart": "2026-11-06T09:00:00.000Z",
    "durationMinutes": 90,
    "focusMinutes": 25,
    "map": { "id": "403E683A-8F97-4205-942E-1D97EAEBA87D", "name": "Thesis" },
    "tags": [], "inbox": "none",
    "createdAt": "…", "updatedAt": "…",
    "url": "atlas://node/6F1C2B9E-0A57-4D7B-9E1A-1B2C3D4E5F60"
  }]
}
```

- `status`: `todo`, `doing`, `done` or `cancelled`.
- `priority`: `none`, `low`, `medium` or `high`.
- `map`: the first map the task is on, in sidebar order. It is left out for tasks that live
  only in the planner.
- `inbox`: `none`, or `inbox` for a capture not yet filed. Archived captures are left out.
- Fields with no value are left out.

### `journeyman.json` (written by JourneyMan)

```json
{
  "app": "JourneyMan", "format": 1, "exportedAt": "2026-11-05T09:30:00.000Z",
  "appUrl": "http://localhost:8000/",
  "tasks": [{
    "atlasId": "6F1C2B9E-0A57-4D7B-9E1A-1B2C3D4E5F60",
    "done": true,
    "doneChangedAt": "2026-11-05T09:30:00.000Z",
    "trackedMinutes": 30
  }]
}
```

- `appUrl`: where JourneyMan runs. Atlas builds **Open in JourneyMan** from it
  (`<appUrl>#task/atlas:<id>`). Type an address in Settings to use a different one. The
  JourneyMan Mac app reports `journeyman://localhost/index.html`, which opens the app.
- `trackedMinutes`: time tracked in JourneyMan itself. Focus time that came from Atlas is
  not included.

## Links

- `atlas://node/<id>` opens Atlas and reveals the node: on its map, or in Today, Week or
  the Inbox if it's on no map. The scheme is registered by `Resources/Info.plist`.
- `<JourneyMan address>#task/atlas:<id>` opens the task in JourneyMan.

## Code

| File | What it does |
| --- | --- |
| `Sources/AtlasCore/Planning/JourneyManLink.swift` | The file formats, building `tasks.json`, applying `journeyman.json`, and links. No file access, so it is tested. |
| `Sources/Atlas/App/JourneyManSync.swift` | Reads and writes the folder: on changes, on activation and on a timer. |
| `Tests/AtlasCoreTests/JourneyManLinkTests.swift` | Export, the done rules, time, file reading and links. |

`TaskInfo` gained two fields, both read leniently, so older workspaces open unchanged:

- `statusChangedAt`: when the status last changed.
- `journeyManMinutes`: time tracked in JourneyMan.

`TaskInfo.setStatus(_:at:)` is now the one place a status changes.
