# flute

`flute` lets an agent launch a Flutter app, inspect its widget and semantics
trees, and act on it with short shell commands. A per-session background
daemon keeps the app and its Flutter Driver connection alive between commands.

The CLI and the in-app support ship together as one package, `flutter_flute`.

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

Install the CLI once per machine, and add the in-app library to each app as a
dev dependency:

```bash
flutter pub global activate flutter_flute
```

```bash
flutter pub add --dev flutter_flute
```

The package is not on pub.dev yet. Until it is, activate it from a checkout
with `flutter pub global activate --source path <checkout>` and add it with
`flutter pub add --dev 'flutter_flute:{"path":"<checkout>"}'`.

The app's code does not change. `flute run` writes an entrypoint to
`.dart_tool/flute/main.dart` that calls `enableFlute()` and then the app's own
`main()`, and runs `flutter run` on it.

## Commands

Every command takes `--session <name>` (default `default`, or
`FLUTE_SESSION`) and `--timeout <duration>` (default `10s`; `5m` for `run` and
`attach`). `-v`/`--verbose` adds detail on stderr, each line starting with
`verbose:`: which daemon was used or started, each Flutter Driver command with
its timing, and the `flutter` tool's own output during `run` and reloads.
`flute <command> --help` describes a command and its options.

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

Dumps stop at 400 lines; `--max-lines 0` removes the cap. Integer keys are
written `key int:42`.

Exit codes: `0` success, `1` the command failed, `2` usage error, `3` no app is
running in the session.

## How it works

- **CLI** (`lib/src/cli/`): parses arguments, finds or starts the session's
  daemon, sends one request and streams the reply. It exits after every command.
- **Daemon** (`lib/src/daemon/`): one process per session, started as
  `flute daemon`. It runs `flutter run --machine` (or `flutter attach --machine`)
  as a child for builds, devices and hot reload. It drives the app through the
  host side of `package:flutter_driver`, and talks to the CLI with
  newline-delimited JSON over `127.0.0.1` and a random token. It exits on
  `flute quit`, when the app exits, or after 30 idle minutes
  (`--idle-timeout` or `FLUTE_IDLE_TIMEOUT`).
- **In-app** (`lib/src/app/`): `enableFlute()` turns on the Flutter Driver
  extension with custom commands: `flute_hello`, `flute_dump_semantics`,
  `flute_dump_widgets`, `flute_tap`, `flute_find`, `flute_wait_idle` and
  `flute_wait_rasterized`.
- **Protocol** (`lib/src/protocol/`): the commands shared by both sides. Pure
  Dart.

Session state lives in `%LOCALAPPDATA%\flute\sessions\<name>\` on Windows and
`~/.flute/sessions/<name>/` elsewhere, or under `FLUTE_HOME` when set.

### Where the build differs from the design doc

- **App output** comes from the VM service's Stdout, Stderr and `Flutter.Error`
  events, not from the tool's `app.log` events. Current versions of the tool
  print app output as `daemon.logMessage` lines, Windows desktop output is
  block-buffered, and `flutter run --machine` turns on structured errors, so
  uncaught errors never reach stdout at all.
- **Idle waits** use a custom `flute_wait_idle` command instead of
  `WaitForCondition`. A timed-out driver command prints a stack trace into the
  app's output, and with a looping animation every action would time out.
- **`dump app` refs** come from the nearest app widget above each semantics
  node's render object. Only refs that `dump semantics` also prints are shown.
- **Inspector pub root**: the daemon tells the inspector the project's
  directory, as DevTools does. Without that, widgets from packages such as
  `material_ui` count as the app's own.
- **Desktop screenshots** wait for `flute_wait_rasterized` instead of a fixed
  2 s. If no frame timing is reported, flute falls back to the 2 s delay.

### Not covered yet

- Android and iOS are implemented, but not yet tested on a device. That
  includes `flutter screenshot` for device capture.
- `find` cannot reach widgets that a lazy list has not built yet. Scrolling is
  one of the gestures left out of v1.
- Each command costs a Dart VM startup: about 1 s from a snapshot (as
  `pub global activate` makes) and about 2.5 s when run from source.
  `dart compile exe bin/flute.dart` makes this much smaller.

## Development

```bash
flutter test
```

```bash
cd example && dart run flutter_flute:flute run -d windows
```

`example/` is a small app with a sign-in form, a home page with a looping
spinner, and a button that throws, used for end-to-end checks. Set
`FLUTE_HOME` to keep test sessions apart from real ones.
