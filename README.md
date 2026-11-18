# flute

The Flutter testing tool. It lets an agent launch a Flutter app, inspect it,
and interact with it.

```text
$ flute run -d windows
Started my_app on Windows (debug) in session "default"
VM service: http://127.0.0.1:53817/abc=/

$ flute dump semantics -i
- s#5 textField "Email" [focusable]
- s#6 textField "Password" [obscured, focusable]
- s#7 button "Login" [focusable, tap]

$ flute fill s#5 "dash@example.com"
✓ Done

$ flute find text "Login" tap
✓ Done

$ flute screenshot
✓ Screenshot saved to C:\Users\dash\AppData\Local\flute\sessions\default\screenshots\2026-11-01T10-42-07.png
```

## Setup

> [!NOTE]
> The package is not on pub.dev yet. Until it is, activate it from a checkout
> with `flutter pub global activate --source path <checkout>` and add it with
> `flutter pub add --dev 'flutter_flute:{"path":"<checkout>"}'`.

Install the CLI once per machine, and add the in-app library to each app as a
dev dependency:

```bash
flutter pub global activate flutter_flute
```

```bash
flutter pub add --dev flutter_flute
```

## Commands

| Command | What it does |
| --- | --- |
| `flute run [-d <device>] [-t <target>] [-- <flutter args>]` | Starts the app. Replaces the session's current app. |
| `flute attach <vm-service-uri> [-d <device>]` | Connects to a running app that already includes `flutter_flute`. |
| `flute quit` | Stops the app (or detaches) and shuts down the daemon. |
| `flute reload` / `flute restart` | Hot reload / hot restart. A restart makes earlier refs stale. |
| `flute dump app [--depth <n>] [--under <ref>]` | Widget tree, pruned to the app's own widgets. |
| `flute dump semantics [-i]` | Semantics tree with `s#<id>` refs; `-i` lists interactive nodes only. |
| `flute screenshot [<path>]` | Saves a PNG of the app. |
| `flute tap <ref>` | Taps a semantics node with a real pointer event. |
| `flute fill <ref> <text>` | Taps a text field and replaces its content. |
| `flute find <finder> <value> [tap \| fill <text>] [--first]` | Finds widgets by `text`, `key`, `label`, `type` or `tooltip`. |
| `flute wait <finder> <value> [--gone]` / `flute wait idle` | Waits for a widget to appear or disappear, or for no pending frames. |
| `flute logs [--tail <n>]` | App output since launch. |
| `flute sessions` | Lists live sessions. |

Every command takes `--session <name>` (default `default`, or
`FLUTE_SESSION`) and `--timeout <duration>` (default `10s`; `5m` for `run` and
`attach`). `-v`/`--verbose` adds detail on stderr, each line starting with
`verbose:`: which daemon was used or started, each Flutter Driver command with
its timing, and the `flutter` tool's own output during `run` and reloads.
`flute <command> --help` describes a command and its options.

Dumps stop at 400 lines; `--max-lines 0` removes the cap. Integer keys are
written `key int:42`.

Exit codes: `0` success, `1` the command failed, `2` usage error, `3` no app is
running in the session.
