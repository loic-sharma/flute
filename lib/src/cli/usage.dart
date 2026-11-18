// Command definitions and the help text built from them.
import 'package:args/args.dart';

/// One `flute` subcommand: how to call it, what it does, and its options.
class CommandSpec {
  const CommandSpec({
    required this.name,
    required this.usage,
    required this.summary,
    this.details,
    this.examples = const <String>[],
    this.addOptions,
    this.hidden = false,
  });

  final String name;

  /// Usage lines, each without the leading `flute `.
  final List<String> usage;

  /// One line for the command list in `flute help`.
  final String summary;

  /// More about the command and its arguments, for `flute <command> --help`.
  final String? details;

  final List<String> examples;

  /// Adds options beyond the common ones.
  final void Function(ArgParser parser)? addOptions;

  /// Left out of `flute help`; `flute daemon` is internal.
  final bool hidden;

  /// The command's own options first, then the ones every command takes.
  ArgParser buildParser() {
    final parser = ArgParser();
    addOptions?.call(parser);
    addCommonOptions(parser, launches: name == 'run' || name == 'attach');
    return parser;
  }
}

/// Adds the options every command takes. [launches] commands wait longer by
/// default, for first builds.
void addCommonOptions(ArgParser parser, {bool launches = false}) {
  parser
    ..addOption(
      'session',
      valueHelp: 'name',
      help: 'The session to use. Defaults to \$FLUTE_SESSION, or "default".',
    )
    ..addOption(
      'timeout',
      valueHelp: 'duration',
      help:
          'How long to wait before failing, such as 500ms, 10s or 5m.\n'
          'Defaults to ${launches ? '5m' : '10s'}.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help:
          'Print extra detail to stderr, each line starting with "verbose:": the\n'
          'daemon used, each step it takes and how long it took.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print help for this command.');
}

void _addLaunchOptions(ArgParser parser) {
  parser
    ..addOption(
      'device',
      abbr: 'd',
      valueHelp: 'device',
      help: 'Device id, as flutter devices lists it.',
    )
    ..addOption(
      'target',
      abbr: 't',
      valueHelp: 'path',
      help: 'The entrypoint to run. Defaults to lib/main.dart.',
    )
    ..addOption(
      'idle-timeout',
      valueHelp: 'duration',
      help:
          'Stop the app and the daemon after this long without a command.\n'
          'Defaults to \$FLUTE_IDLE_TIMEOUT, or 30m.',
    );
}

const String _refHelp =
    'Refs look like s#7. Get them from flute dump semantics, flute dump app or flute find.';

/// Every subcommand, in the order `flute help` lists them.
final List<CommandSpec> commands = <CommandSpec>[
  CommandSpec(
    name: 'run',
    usage: <String>['run [-d <device>] [-t <target>] [-- <flutter args>]'],
    summary: "Start the app (replaces the session's app)",
    details:
        'Builds and launches the app in the current project with flutter run, in debug mode. '
        'Arguments after -- go to flutter run. If the session already has an app, it is stopped first.\n\n'
        'The project must depend on flutter_flute. If it does not, run:\n'
        '  flutter pub add --dev flutter_flute',
    examples: <String>['flute run -d windows', 'flute run -d emulator-5554 -- --flavor dev'],
    addOptions: _addLaunchOptions,
  ),
  CommandSpec(
    name: 'attach',
    usage: <String>['attach <vm-service-uri> [-d <device>] [-t <target>]'],
    summary: 'Connect to a running app that has flutter_flute',
    details:
        'Attaches with flutter attach, so reload and restart keep working. The app must already '
        'include flutter_flute, for example because flute run started it in another session. '
        'flute quit detaches without stopping the app.',
    examples: <String>['flute attach http://127.0.0.1:53817/abc=/ -d windows --session other'],
    addOptions: _addLaunchOptions,
  ),
  const CommandSpec(
    name: 'quit',
    usage: <String>['quit'],
    summary: "Stop the app and the session's daemon",
    details:
        'Stops an app the session launched, or detaches from one it attached to. '
        'Logs and screenshots stay in the session directory.',
  ),
  const CommandSpec(
    name: 'reload',
    usage: <String>['reload'],
    summary: 'Hot reload',
    details:
        'Prints the reload time, or the compiler errors if the reload fails. '
        'After a failed reload the app keeps running the old code.',
  ),
  const CommandSpec(
    name: 'restart',
    usage: <String>['restart'],
    summary: 'Hot restart; earlier refs become stale',
    details:
        'Reruns main() and resets app state. Refs from before the restart no longer work; '
        'run flute dump semantics again.',
  ),
  CommandSpec(
    name: 'dump',
    usage: <String>[
      'dump semantics [-i] [--depth <n>] [--under <ref>]',
      'dump app [--depth <n>] [--under <ref>]',
    ],
    summary: 'Print the semantics tree, or the app\'s widget tree',
    details:
        'dump semantics prints the semantics tree in the order a screen reader reads it, '
        'one node per line with its s#<id> ref, role, label, value and flags. '
        'Nodes that say nothing on their own are folded into their parent.\n\n'
        'dump app prints the widget tree, keeping only widgets created by the app\'s own code. '
        'A widget carries an s# ref when it has a semantics node.\n\n'
        'Output stops at 400 lines unless --max-lines says otherwise.',
    examples: <String>['flute dump semantics -i', 'flute dump app --under s#12 --depth 3'],
    addOptions: (ArgParser parser) => parser
      ..addFlag(
        'interactive',
        abbr: 'i',
        negatable: false,
        help: 'Print only interactive nodes, as a flat list. dump semantics only.',
      )
      ..addOption('depth', valueHelp: 'n', help: 'Print at most this many levels.')
      ..addOption('under', valueHelp: 'ref', help: 'Print only the subtree under this ref.')
      ..addOption(
        'max-lines',
        valueHelp: 'n',
        help: 'Stop after this many lines. 0 prints everything. Defaults to 400.',
      ),
  ),
  const CommandSpec(
    name: 'screenshot',
    usage: <String>['screenshot [<path>]'],
    summary: 'Save a PNG of the app',
    details:
        'Without a path, saves to the session\'s screenshots directory and prints where. '
        'Android and iOS use a device capture; desktop captures Flutter\'s layers, '
        'so platform views come out blank there.',
    examples: <String>['flute screenshot', 'flute screenshot out/login.png'],
  ),
  const CommandSpec(
    name: 'tap',
    usage: <String>['tap <ref>'],
    summary: 'Tap a semantics node',
    details:
        'Taps the center of the node with a real pointer event. An offscreen node is scrolled '
        'into view first. If another widget covers the node, tap fails and names it rather than '
        'tapping the wrong thing.\n\n$_refHelp',
    examples: <String>['flute tap s#7'],
  ),
  const CommandSpec(
    name: 'fill',
    usage: <String>['fill <ref> <text>'],
    summary: 'Tap a text field and replace its content',
    details:
        'Taps the field, waits for it to take focus, then replaces its whole value with <text>. '
        'Quote text that has spaces.\n\n$_refHelp',
    examples: <String>['flute fill s#5 "dash@example.com"'],
  ),
  CommandSpec(
    name: 'find',
    usage: <String>['find <finder> <value> [tap | fill <text>] [--first]'],
    summary: 'Find widgets by text, key, label, type or tooltip',
    details:
        'Finders: text (a Text widget\'s exact string), key (a ValueKey; write int:42 for an '
        'integer key), label (a semantics label), type (a widget type name) and tooltip.\n\n'
        'Without an action, prints each match with its ref. With tap or fill, acts on the match; '
        'several matches fail unless --first is given.',
    examples: <String>[
      'flute find text "Login" tap',
      'flute find key email fill "dash@example.com"',
      'flute find type ElevatedButton',
    ],
    addOptions: (ArgParser parser) => parser.addFlag(
      'first',
      negatable: false,
      help: 'With tap or fill, act on the first of several matches.',
    ),
  ),
  CommandSpec(
    name: 'wait',
    usage: <String>['wait <finder> <value> [--gone]', 'wait idle'],
    summary: 'Wait for a widget to appear or disappear, or for the app to go idle',
    details:
        'Takes the same finders as flute find. Fails with exit code 1 if --timeout passes first; '
        'the app keeps running.\n\n'
        'wait idle waits until no frame is pending and no animation runs. '
        'A looping animation keeps the app busy, so wait idle times out while one runs.',
    examples: <String>[
      'flute wait text "Welcome"',
      'flute wait key spinner --gone',
      'flute wait idle',
    ],
    addOptions: (ArgParser parser) =>
        parser.addFlag('gone', negatable: false, help: 'Wait until the widget disappears instead.'),
  ),
  CommandSpec(
    name: 'logs',
    usage: <String>['logs [--tail <n>]'],
    summary: 'Print app output since launch',
    details:
        'Includes print output and uncaught Flutter errors. '
        'Still works after the app exits, until the next flute run.',
    examples: <String>['flute logs --tail 50'],
    addOptions: (ArgParser parser) =>
        parser.addOption('tail', valueHelp: 'n', help: 'Print only the last <n> lines.'),
  ),
  const CommandSpec(
    name: 'sessions',
    usage: <String>['sessions'],
    summary: 'List live sessions',
    details: 'Prints one line per session that has a running daemon: its name, app and device.',
  ),
  const CommandSpec(
    name: 'help',
    usage: <String>['help [<command>]'],
    summary: 'Print help for flute or one command',
  ),
  CommandSpec(
    name: 'daemon',
    usage: <String>['daemon'],
    summary: 'Run the session daemon (internal)',
    hidden: true,
    addOptions: (ArgParser parser) => parser.addOption('idle-timeout'),
  ),
];

/// Looks up a command by name.
CommandSpec? findCommand(String name) {
  for (final CommandSpec spec in commands) {
    if (spec.name == name) {
      return spec;
    }
  }
  return null;
}

/// The parser for the whole CLI.
ArgParser buildParser() {
  final parser = ArgParser();
  addCommonOptions(parser);
  for (final CommandSpec spec in commands) {
    parser.addCommand(spec.name, spec.buildParser());
  }
  return parser;
}

/// Text for `flute help` and `flute --help`.
String generalUsage() {
  final buffer = StringBuffer()
    ..writeln('flute: drive a running Flutter app from the shell.')
    ..writeln()
    ..writeln('Usage: flute <command> [arguments] [--session <name>] [--timeout <duration>]')
    ..writeln()
    ..writeln('Commands:');
  final List<CommandSpec> shown = commands.where((CommandSpec c) => !c.hidden).toList();
  final int width = shown
      .map((CommandSpec c) => c.name.length)
      .reduce((int a, int b) => a > b ? a : b);
  for (final CommandSpec spec in shown) {
    buffer.writeln('  ${spec.name.padRight(width)}   ${spec.summary}');
  }
  buffer
    ..writeln()
    ..writeln('Run "flute <command> --help" for a command\'s arguments and options.')
    ..writeln()
    ..write('Exit codes: 0 success, 1 failure, 2 usage error, 3 no app in the session.');
  return buffer.toString();
}

/// Wraps [text] at spaces so no line is longer than [width] where possible.
///
/// Lines that start with two spaces, such as commands to copy, are kept whole.
String wrapText(String text, int width) {
  return text
      .split('\n')
      .map((String line) => line.startsWith('  ') ? line : _wrapLine(line, width))
      .join('\n');
}

String _wrapLine(String text, int width) {
  final lines = <String>[];
  var line = StringBuffer();
  for (final String word in text.split(' ')) {
    if (line.isNotEmpty && line.length + 1 + word.length > width) {
      lines.add(line.toString());
      line = StringBuffer();
    }
    if (line.isNotEmpty) {
      line.write(' ');
    }
    line.write(word);
  }
  lines.add(line.toString());
  return lines.join('\n');
}

/// Text for `flute <command> --help` and `flute help <command>`.
String commandUsage(CommandSpec spec) {
  final buffer = StringBuffer()
    ..writeln('${spec.summary}.')
    ..writeln()
    ..writeln(spec.usage.length == 1 ? 'Usage: flute ${spec.usage.single}' : 'Usage:');
  if (spec.usage.length > 1) {
    for (final String line in spec.usage) {
      buffer.writeln('  flute $line');
    }
  }
  if (spec.details != null) {
    for (final String paragraph in spec.details!.split('\n\n')) {
      buffer
        ..writeln()
        ..writeln(wrapText(paragraph, 80));
    }
  }
  buffer
    ..writeln()
    ..writeln('Options:')
    ..writeln(spec.buildParser().usage);
  if (spec.examples.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Examples:');
    for (final String example in spec.examples) {
      buffer.writeln('  $example');
    }
  }
  return buffer.toString().trimRight();
}
