# flute: an agent-first CLI for driving Flutter apps

Nov 1, 2026 · @Loic

`flute` lets an agent launch a Flutter app, inspect its widget and semantics trees, and act on it with short shell commands. A per-session background daemon keeps the app and its Flutter Driver connection alive between commands. The CLI and the in-app support ship together as one package, `flutter_flute`.

## Architecture

&#91;embedded content: flute architecture · CLI, daemon, flutter tool, app\]

The CLI exits after every command. The daemon keeps the `flutter run` process and the Flutter Driver connection alive between commands, so each command costs one local round trip.

## Goals and non-goals

v1 gives an agent a stateless shell interface to a live Flutter app, modeled on Vercel's `agent-browser`: one short command per action, compact text back.

Goals:

- **One command per action.** `run`, `reload`, `restart`, `dump`, `tap`, `fill`, `find`, `screenshot`, `quit`, each finishing in seconds and printing text sized for an LLM context window.
- **No code changes to the app.** The app only needs `flutter_flute` as a dev dependency. `flute` generates the entrypoint that turns on Flutter Driver.
- **Fast iteration.** Hot reload works, so an agent can edit code, run `flute reload` and look again without relaunching.
- **Parallel apps.** Named sessions (`--session foo`) let one machine drive several apps at once.
- **Desktop and mobile.** Windows, macOS, Linux, Android and iOS, in debug mode.

Non-goals for v1:

- Web. Flutter Driver on web goes through WebDriver, a separate code path.
- Profile and release builds. Reload needs debug mode, and release mode has no VM service.
- A test framework. `flute` drives apps interactively; it does not run test files or report pass/fail.
- Remote devices over the network beyond what `flutter run` already supports.
- A JSON output mode. Output is human-readable text; a `--json` flag can come later.

## Decisions and rationale

These choices were settled before this design was written; the rest of the doc builds on them.

| Decision | Why | Rejected alternative |
| --- | --- | --- |
| `flute run` launches a generated wrapper entrypoint that calls `enableFlute()`, then the app's `main()` | No code changes to the app; it only needs `flutter_flute` as a dev dependency | Users call `enableFlutterDriverExtension()` in their own entrypoint |
| One package, `flutter_flute`, holds both the in-app library and the CLI | One version to install and keep in step; the in-app half needs the Flutter SDK anyway | A separate pure-Dart `flute` CLI package |
| The daemon drives `flutter run --machine` (or `flutter attach --machine`) | Gives hot reload and reports the VM service URI; device support, builds and DDS come from the tool | `flutter drive`: cannot hot reload, and runs the test as a separate host process |
| The daemon uses the host side of `package:flutter_driver` | `FlutterDriver` and its command classes import no Flutter code, which is how `flutter drive` runs tests on the plain `dart` binary | Re-implementing the `ext.flutter.driver` protocol over `package:vm_service` |
| Custom commands live in `flutter_flute` as `CommandExtension`s | Flutter Driver cannot target a semantics node by id or dump a pruned tree | Making do with built-in finders and tapping rect centers from the CLI |
| One daemon per session, over localhost TCP with a token, 30-minute idle timeout | Sessions stay isolated and a crash takes down only one; nothing outlives its use | One daemon for all sessions; named pipes and Unix sockets |
| `flute run` replaces the session's app, even one from another project | An agent can rerun without cleaning up first | Refusing, or warning first |
| `s#<id>` refs are raw `SemanticsNode` ids; stale refs fail with a hint | No snapshot bookkeeping in the daemon | Snapshot-scoped refs, as in `agent-browser` |
| `fill` taps, then uses Flutter Driver's emulated text entry | Works the same on every platform without a soft keyboard | Real keyboard input (deferred; likely later) |
| Output is plain text for agents: `✓ Done`, `✗ <error>`, capped dumps | Keeps the agent's context small | JSON output (may come later as a flag) |
| Screenshots use device capture on Android and iOS, layer capture on desktop | Platform views and native dialogs appear on mobile; `flutter screenshot` does not support desktop devices | Device capture everywhere |
| Frame sync is off; each action does a short `wait idle` first | Default frame sync never returns while an animation loops | Flutter Driver's default frame sync |
| v1 targets desktop and mobile in debug mode only | Reload needs debug mode; release has no VM service; web needs the WebDriver path | Web and profile mode in v1 |

## Commands

Every command takes `--session <name>` (default `default`) and `--timeout <duration>` (default `10s`). Commands other than `run` and `attach` fail with a one-line hint if the session has no app.

| Command | What it does | Prints |
| --- | --- | --- |
| `flute run [-d <device>] [-t <target>] [-- <flutter args>]` | Starts the app in a new or reused daemon. Replaces the session's current app if there is one. | Device, app, VM service URI, and the app it replaced, if any |
| `flute attach <vm-service-uri> [-d <device>]` | Connects to an app that is already running and already has the `flutter_flute` extension | Same as `run` |
| `flute quit` | Stops the app (or detaches from an attached app) and shuts down the daemon | `Stopped <app>` |
| `flute reload` | Hot reload | Reload time and any compile errors |
| `flute restart` | Hot restart: reruns main() and resets app state. Reconnects the driver. | Restart time and any compile errors; notes that earlier refs are stale |
| `flute dump app [--depth <n>] [--under <ref>]` | Widget tree, pruned to user-relevant widgets | Indented tree |
| `flute dump semantics [-i \| --interactive]` | Semantics tree with `s#<id>` refs. `-i` prints only interactive nodes (buttons, text fields, toggles, links) as a flat list. | Indented tree |
| `flute screenshot [<path>]` | Saves a PNG of the app: a device capture on Android and iOS, a capture of Flutter's layers on desktop. The default path is in the session's directory. | `✓ Screenshot saved to <path>` |
| `flute tap <ref>` | Taps a semantics node | `✓ Done` |
| `flute fill <ref> <text>` | Taps a text field, then replaces its content | `✓ Done` |
| `flute find <finder> <value> [<action> [<args>]]` | Finds widgets by `text`, `key`, `label`, `type` or `tooltip`, then optionally runs `tap` or `fill` on the match | Matches with refs, or the action's output |
| `flute wait <finder> <value> [--gone]` / `flute wait idle` | Waits until a widget appears or disappears, or until no frames are pending | `Found ...` or a timeout error |
| `flute logs [--tail <n>]` | App output captured by the daemon since launch | Log lines |
| `flute sessions` | Lists live sessions | One line per session |

Example of what an agent sees:

```text
$ flute run -d windows
Started my_app on Windows (debug) in session "default"
VM service: http://127.0.0.1:53817/abc=/

$ flute dump semantics
- s#1 scope
  - s#3 heading "Sign in"
  - s#5 textField "Email" [focusable]
  - s#6 textField "Password" [focusable, obscured]
  - s#7 button "Login" [tap]

$ flute dump semantics -i
- s#5 textField "Email" [focusable]
- s#6 textField "Password" [focusable, obscured]
- s#7 button "Login" [tap]

$ flute fill s#5 "dash@example.com"
✓ Done

$ flute find text "Login" tap
✓ Done

$ flute find text "Doesn't exist" tap
✗ Could not find text 'Doesn't exist'.

$ flute screenshot
✓ Screenshot saved to C:\Users\dash\AppData\Local\flute\sessions\default\screenshots\2026-11-01T10-42-07.png
```

Exit codes: `0` success, `1` the command failed (not found, timeout, app error), `2` usage error, `3` no app is running in the session.

## Package layout

`flutter_flute` is one Flutter package with two halves that never import each other: an in-app library that runs inside the app, and a CLI that runs on the host Dart VM. They share only a small set of command and result classes with no Flutter imports.

```text
flutter_flute/
  bin/flute.dart              CLI entrypoint (also the daemon, via a hidden `daemon` subcommand)
  lib/flutter_flute.dart      In-app library: enableFlute()
  lib/src/app/                Custom driver commands and their handlers (imports flutter, flutter_driver/driver_extension)
  lib/src/protocol/           Shared Command/Result classes and the protocol version (pure Dart)
  lib/src/cli/                Argument parsing, session lookup, daemon client, output formatting
  lib/src/daemon/             Daemon server, flutter tool process, FlutterDriver connection, idle timer
```

Install the CLI once per machine and add the in-app library to each app:

```bash
flutter pub global activate flutter_flute
flutter pub add --dev flutter_flute
```

The CLI uses the host side of `package:flutter_driver` (`FlutterDriver.connect`, `sendCommand`) directly. That library imports no Flutter code, which is how `flutter drive` runs test files on the plain `dart` binary. The daemon reuses `FlutterDriver` rather than re-implementing the `ext.flutter.driver` wire protocol, and sends `flutter_flute`'s custom commands through `sendCommand`.

**Version skew.** The globally installed CLI and the app's dev dependency can differ. The in-app library answers a \`flute\_hello\` command with its protocol version. The daemon refuses to drive an app with a different major version and prints the `flutter pub add` or `pub global activate` command that fixes it.

## Instrumenting the app

`flute run` launches a generated entrypoint that turns on the driver extension and then calls the app's own `main()`. The app's source is never edited.

For `-t lib/main.dart` in package `my_app`, `flute` writes `.dart_tool/flute/main.dart` in the app's project:

```dart
// GENERATED by flute. Do not edit.
import 'package:flutter_flute/flutter_flute.dart';
import 'package:my_app/main.dart' as app;

void main(List<String> args) {
  enableFlute();
  app.main(); // or app.main(args) when the app's main takes arguments
}
```

Then it runs `flutter run -t .dart_tool/flute/main.dart`. Details:

- **Imports.** Targets under `lib/` are imported with a `package:` URI; other targets (for example `integration_test/app.dart`) use a relative import from `.dart_tool/flute/`.
- **`main` signature.** `flute` reads the target's `main` declaration to pick `main()` or `main(args)`. An `async` main is awaited.
- **Missing dependency.** Before launching, `flute` checks `.dart_tool/package_config.json` for `flutter_flute`. If it is missing, `flute run` fails and prints `flutter pub add --dev flutter_flute`. It never edits `pubspec.yaml`.
- **Hot reload.** The wrapper is part of the reloaded program, so edits to the app's code reload normally. Changes to `main()` itself need `flute restart`, as with `flutter run`.

`enableFlute()` calls `enableFlutterDriverExtension()` with:

- `commands` and `finders`: `flutter_flute`'s custom extensions (see Driver commands).
- `enableTextEntryEmulation: true`, so `fill` works without a real keyboard. This also means the platform keyboard never shows; an agent that needs it can turn emulation off with a later option.
- `silenceErrors: false`, so command failures reach `flute logs`.

Behavior changes inside the app: the driver installs its own binding (`_DriverBinding`), which uses a test binary messenger and skips the zone check. These are the same trade-offs every `flutter drive` test accepts. `flute` documents them rather than working around them.

## Sessions and the daemon

Each session is one daemon process driving at most one app. The CLI is a thin client: it finds the session's daemon, sends one request, prints the reply and exits.

**State directory.** Sessions are per user, not per project: `%LOCALAPPDATA%\flute\sessions\<name>\` on Windows, `~/.flute/sessions/<name>/` elsewhere. Each holds:

| File | Contents |
| --- | --- |
| `daemon.json` | Daemon PID, localhost port, auth token, protocol version, start time |
| `app.json` | Project path, device, target, launch or attach mode, VM service URI, app ID |
| `daemon.log` | Daemon diagnostics |
| `app.log` | App output, for `flute logs` (rotated at 5 MB) |
| `screenshots/` | Default screenshot location |

**Finding or starting the daemon.** For every command, the CLI:

1. Reads `daemon.json`. If it exists and the PID is alive, connects to the port and sends a `ping` carrying the token.
2. If there is no file, the process is dead, or the ping fails: for `run` and `attach`, spawns `flute daemon --session <name>` detached, and waits up to 10 s for it to write `daemon.json`. For other commands, exits with code `3` and `No app in session "<name>". Start one with: flute run`.
3. Sends the request and streams the reply to stdout.

A lock file (`daemon.lock`, held with an exclusive file lock) stops two concurrent `flute run` calls from spawning two daemons for one session.

**Transport.** Newline-delimited JSON over a TCP socket bound to `127.0.0.1` on a random port. Each request is `{"id", "token", "method", "params"}`; the reply is a stream of `{"id", "output"}` lines ending with `{"id", "exit"}`. The token is a random 128-bit value in `daemon.json`, readable only by the user, so other local users cannot drive the app. The daemon handles one request at a time per session and queues the rest.

**Replacing on `run`.** `flute run` in a session that already has an app stops that app (or detaches, if it was attached), then launches the new one in the same daemon. The output starts with `Replaced <old app> on <old device>`.

**Lifetime.** The daemon exits when:

- `flute quit` is called.
- The app exits or crashes. The daemon writes the exit code to `exit.json` first. The next command prints `App exited (code <n>)` and the last 20 lines of `app.log` instead of the generic no-app message.
- No command arrives for the idle timeout: 30 minutes by default, set with `flute run --idle-timeout <duration>` or `FLUTE_IDLE_TIMEOUT`. On timeout the daemon stops the app it launched, or only disconnects from an attached app.

On exit the daemon deletes `daemon.json` and `app.json` but keeps the logs and screenshots.

## Launch, attach and reload

The daemon never builds or installs apps itself. It runs the `flutter` tool in machine mode as a child process and gets device support, builds, DDS and hot reload from it.

**Launch.** For `flute run`, the daemon:

1. Writes the wrapper entrypoint (see Instrumenting the app).
2. Starts `flutter run --machine -d <device> -t .dart_tool/flute/main.dart <extra args>` with the app's project as the working directory. The `flutter` used is the one on `PATH`, or `FLUTTER_ROOT/bin/flutter` when that is set.
3. Reads JSON-RPC events from the child's stdout: `app.start` gives the `appId`, `app.debugPort` gives the VM service `wsUri` (already behind DDS, so other tools can share it), `app.started` means the first frame is up, and `app.log` lines go to `app.log`. `app.progress` messages are streamed to the CLI so the agent sees build progress during long first builds.
4. Calls `FlutterDriver.connect(dartVmServiceUrl: wsUri)`, which finds the root isolate, resumes it if paused, and waits for the `ext.flutter.driver` extension. A missing extension after 30 s fails `run` with a pointer to `flute logs`.
5. Sends `flute_hello` to check the protocol version, turns on semantics with `SetSemantics(true)`, then replies to the CLI.

If the build fails, `flutter run` exits before `app.started`. `flute run` prints the tool's error output and exits `1`; the daemon exits too.

**Attach.** `flute attach <uri>` runs `flutter attach --machine --debug-url <uri> [-d <device>] [-t <target>]` in the current project, then follows steps 3 to 5. Using `flutter attach` rather than a bare VM service connection keeps `flute reload` working. The attached app must already include `flutter_flute`, for example because it was started from a wrapper entrypoint, or `connect` times out with the same message as above.

**Reload.** The daemon writes `{"id":n,"method":"app.restart","params":{"appId":...,"fullRestart":false}}` to the child's stdin and waits for the result:

- Hot reload keeps the same isolate, so the `FlutterDriver` connection stays valid. Semantics refs may change if the reload changed the UI.
- Hot restart (`flute restart`) replaces the root isolate. The daemon drops its `FlutterDriver`, connects again (step 4), and turns semantics back on. All refs from before the restart are stale.
- A compile error comes back as a failed restart; `flute reload` prints the compiler's messages and exits `1`. The app keeps running the old code.

**Stop.** `quit`, replacement and idle timeout send `app.stop` for launched apps and `app.detach` for attached ones, wait up to 10 s for the child to exit, then kill it.

## Driver commands

Each CLI command maps to built-in Flutter Driver commands where they fit and to `flutter_flute` custom commands (registered as `CommandExtension`s) where they do not. Raw data comes back from the app; all formatting happens in the CLI.

| CLI command | Sent to the app | Kind |
| --- | --- | --- |
| `run`, `attach` (handshake) | `flute_hello` → protocol version, app name; then `SetSemantics(true)` | Custom + built-in |
| `dump semantics` | `flute_dump_semantics` | Custom |
| `dump app` | `flute_dump_widgets` | Custom |
| `tap <ref>` | `flute_tap(ref)` | Custom |
| `fill <ref> <text>` | `flute_tap(ref)`, wait for focus, then `EnterText(text)` | Custom + built-in |
| `find <finder> <value>` | `flute_find(finder)` with a built-in `SerializableFinder` | Custom |
| `wait <finder> <value>` | `WaitFor` / `WaitForAbsent` | Built-in |
| `wait idle` | `WaitForCondition` on no pending frame and no transient callbacks | Built-in |
| `screenshot` | Android and iOS: `wait idle`, then `flutter screenshot -d <device> -o <path>` (device capture). Desktop: `wait idle`, then `ScreenshotCommand` | flutter tool or built-in |

**Semantics refs.** `s#<id>` is the raw `SemanticsNode.id`. `flute_dump_semantics` walks every view's semantics owner and returns, per node: id, role and flags, label, value, hint, supported actions, rect in global logical pixels, and children. Nodes that are hidden or have no label, value or actions are folded into their parent to keep the tree short. With `-i` (`--interactive`), only interactive nodes are printed, as a flat list: nodes flagged as a button, text field, checkbox, switch, slider or link, or with a tap, long-press, focus or text-editing action. A ref the app no longer has fails with `✗ s#7 is gone. Run: flute dump semantics`.

**Tapping.** `flute_tap` looks the node up by id and taps the center of its rect with a real pointer event, through the driver's `WidgetController`, so gesture detectors, ink splashes and focus behave as they do for a user. Before tapping it checks:

1. The node is offscreen → it sends `SemanticsAction.showOnScreen` and waits for the scroll to settle.
2. A hit test at the center does not reach the node's render object (something covers it) → it fails with the name of the covering widget, rather than tapping the wrong thing.

**Filling.** `fill` taps the field, waits up to the timeout for a text input connection, then sends `EnterText`. With text entry emulation on, `EnterText` replaces the whole field value, so `fill` always replaces rather than appends.

**Finding.** `flute_find` evaluates a built-in finder (`ByText`, `ByValueKey`, `BySemanticsLabel`, `ByType`, `ByTooltipMessage`) and returns each match's widget type, text, rect and the id of the nearest semantics node that owns it. `find` prints the matches with their `s#` refs. With an action (`tap`, `fill`), it requires exactly one match: zero fails with `✗ Could not find text 'Login'.`; several fail with the list of matches unless `--first` is given. The action then goes through the same `flute_tap` path. `ByValueKey` covers `String` and `int` keys only, as in Flutter Driver.

**Widget tree.** `flute_dump_widgets` walks the element tree from the root and keeps only widgets created in the app's own code, using `debugIsWidgetLocalCreation` (the same test the inspector's summary tree uses; debug builds track widget creation by default). For each kept widget it returns type, key, a short text preview and, when the widget's render object owns a semantics node, that node's id. Each printed line therefore carries an `s#` ref where one exists, so the agent can go from `dump app` straight to `tap`. `--depth` caps the depth and `--under <ref>` prints only the subtree under a semantics node.

**Screenshots.** On Android and iOS the daemon runs `flutter screenshot -d <device> -o <path>`. On desktop it sends `ScreenshotCommand` itself rather than calling `FlutterDriver.screenshot()`, which sleeps a fixed 2 s first because the raster thread may not have finished the last frame; its own comments call that racy. `wait idle` only shows the UI thread is done, so the desktop path also needs a raster-finished signal. Proposed: a `flute_wait_rasterized` custom command that waits for the next `FrameTiming` reported through `SchedulerBinding.addTimingsCallback`. This needs a prototype; until it works, keep the 2 s delay.

## Output, waiting and errors

**Output rules.** Every command prints plain text written for an agent to read, not for a parser:

- Success prints `✓ Done`, or `✓` and a short result where the command has one (`✓ Screenshot saved to <path>`). This keeps the agent's context small; it runs `dump semantics` when it needs to check the effect.
- Trees are indented two spaces per level, one node per line: `- s#<id> <role> "<label>" [<flags and actions>]`. Labels and values over 80 characters are cut with `…`.
- Dumps stop at 400 lines by default and end with `… 1,250 more nodes; use --depth, --under or --max-lines`. `--max-lines 0` removes the cap.
- Errors go to stderr as one line starting with `✗` that says what failed, such as `✗ Could not find text 'Login'.`, then, where useful, one line saying what to try next: `Run: flute dump semantics`.
- No color, spinners or progress bars unless stdout is a terminal. Build progress during `run` prints as plain lines.

**Waiting.** Flutter Driver's default frame sync makes each command wait until the app has no pending frames, which never happens while an animation loops (a spinner, a blinking caret in some widgets). `flute` therefore:

- Turns frame sync off for the session (`SetFrameSync(false)`) and waits explicitly instead: each action first runs `wait idle` with a short budget (2 s). If the app is still busy, the action goes ahead anyway rather than failing.
- Bounds every command by `--timeout` (default 10 s; `run` defaults to 5 minutes for first builds). A timeout prints what the command was waiting for and exits `1`; the app keeps running.
- Offers `flute wait text "Welcome"`, `flute wait key spinner --gone` and `flute wait idle` for when the agent needs to wait on purpose.

**App errors.** The daemon watches `app.log` for Flutter error banners (`══╡ EXCEPTION CAUGHT BY …`). When one appears during a command, that command's output ends with `App reported an error:` and the first 10 lines of it, so the agent sees a crash its tap caused without running `flute logs`.

## Platforms, compatibility and testing

v1 supports every non-web target `flutter run` supports, in debug mode only. The daemon runs on the host, so only the host matters for `flute` itself; device differences are handled by the `flutter` tool.

| Target | v1 | Notes |
| --- | --- | --- |
| Windows, macOS, Linux desktop | Yes | Simplest case; the app runs on the host |
| Android device or emulator | Yes | VM service is forwarded by `flutter run` |
| iOS simulator | Yes |  |
| iOS device | Yes | Slower first launch; needs signing set up as for `flutter run` |
| Web | No | Needs the WebDriver path; planned after v1 |
| Profile or release builds | No | No hot reload; release has no VM service |

**Flutter versions.** `flutter_flute` declares the same minimum Flutter SDK as `flutter_driver` on the stable channel at release, and is tested against current stable and beta.

**Host shells.** The CLI must behave the same in PowerShell, cmd, bash and zsh. Paths in output are absolute and native to the host. Arguments with spaces (`flute fill s#5 "hi there"`) rely on normal shell quoting only.

**Testing plan:**

- Unit tests for argument parsing, output formatting and tree pruning, using recorded semantics and widget dumps.
- In-app tests for each custom command with `flutter test` and a `WidgetTester`, calling the `CommandExtension` handlers directly.
- Daemon tests with a fake `flutter` process that replays recorded `--machine` output, covering launch, build failure, reload with compile error, hot restart reconnect, app crash and idle timeout.
- End-to-end tests on CI that run a sample app on Linux desktop and an Android emulator through the full command list.

## Open questions and milestones

Open questions:

- [x] **Sessions across projects.** Sessions are per user, so `flute run` in project B replaces project A's `default` app. Decided: `run` replaces the running app without a warning, as in any other session.
- [x] **Screenshot coverage.** `ScreenshotCommand` captures Flutter's layer tree, so platform views (web views, maps) and native dialogs come out blank. Decided: device capture on Android and iOS, so those show up there. Desktop keeps the layer-tree capture, because `flutter screenshot` does not support desktop devices and OS window capture fails when the window is covered.
- [x] **Real keyboard.** Text entry emulation means the soft keyboard never appears on mobile, which hides layout bugs it would cause. Decided: not in v1. An opt-out such as `flute run --real-keyboard` will likely come later.
- [ ] **Merged semantics nodes.** Under `MergeSemantics`, the node's rect can cover several widgets. Is tapping the center always right, or should `tap` prefer `SemanticsAction.tap` for merged nodes?
- [ ] **Wrapper location.** Running `flutter run -t .dart_tool/flute/main.dart` needs checking against build\_runner, flavors and plugins that read the target path.
- [ ] **More gestures.** Scroll, long press, drag, keyboard keys and system back are left out of v1. Which ones do agents need first?
- [ ] **Repository.** `flutter_flute` is a separate package, but its repository and directory are not chosen yet.

Milestones, each shippable on its own:

1. **Daemon core:** sessions, `run`, `quit`, `reload`, `logs` and `sessions` on Windows, macOS and Linux desktop.
2. **Acting on the UI:** `dump semantics`, `tap`, `fill` and `screenshot`.
3. **Finding and waiting:** `find`, `wait`, `dump app` and `attach`.
4. **Release:** Android and iOS, end-to-end CI, docs, publish `flutter_flute` to pub.dev.

## References

Flutter source files that this design relies on, in the flutter/flutter repository:

| File | What to look at |
| --- | --- |
| `packages/flutter_tools/lib/src/drive/drive_service.dart` | How `flutter drive` launches the app (`device.startApp`, 3 attempts), starts DDS, and passes `VM_SERVICE_URL` to the test process |
| `packages/flutter_tools/lib/src/commands/drive.dart` | `startPausedDefault => true`, test file lookup in `test_driver/`, `--use-existing-app`, `--keep-app-running` |
| `packages/flutter_driver/lib/src/driver/vmservice_driver.dart` | `FlutterDriver.connect`: find the root isolate, resume it leniently, wait for `ext.flutter.driver`, health check. `sendCommand` and its `{isError, response}` handling |
| `packages/flutter_driver/lib/src/driver/driver.dart` | `screenshot()` and its fixed 2 s delay; the public driver API |
| `packages/flutter_driver/lib/src/extension/extension.dart` | `enableFlutterDriverExtension`, `_DriverBinding`, `FlutterDriverExtension.call`, `CommandExtension` and `FinderExtension` |
| `packages/flutter_driver/lib/src/common/` | Command and finder classes and their `serialize()`; pure Dart, usable from the CLI |
| `packages/flutter_tools/lib/src/commands/daemon.dart` | `--machine` protocol: `app.restart` (`fullRestart`), `app.stop`, `app.detach`, and the `app.debugPort` event's `wsUri` |
| `packages/flutter_tools/lib/src/commands/attach.dart` | `--debug-url` for `flute attach` |
| `supportsScreenshot` in `android/android_device.dart`, `ios/devices.dart`, `ios/simulators.dart`, `device.dart` | Which devices `flutter screenshot` supports: Android, iOS simulator, iOS device (depends on Xcode version), custom devices; not desktop or web |
| `packages/flutter/lib/src/widgets/widget_inspector.dart` | `debugIsWidgetLocalCreation`, used to prune `dump app` |
