import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../daemon/daemon.dart';
import 'client.dart';
import 'common.dart';

const Duration _defaultTimeout = Duration(seconds: 10);
const Duration _defaultRunTimeout = Duration(minutes: 5);
const Duration _defaultIdleTimeout = Duration(minutes: 30);

const String _usage = '''
flute: drive a running Flutter app from the shell.

Usage: flute <command> [arguments] [--session <name>] [--timeout <duration>]

Commands:
  run [-d <device>] [-t <target>] [-- <flutter args>]
                                   Start the app (replaces the session's app)
  attach <vm-service-uri> [-d <device>]
                                   Connect to a running app that has flutter_flute
  quit                             Stop the app and the session's daemon
  reload                           Hot reload
  restart                          Hot restart; earlier refs become stale
  dump app [--depth <n>] [--under <ref>]
                                   Widget tree, pruned to the app's own widgets
  dump semantics [-i]              Semantics tree with s#<id> refs
  screenshot [<path>]              Save a PNG of the app
  tap <ref>                        Tap a semantics node
  fill <ref> <text>                Tap a text field and replace its content
  find <finder> <value> [tap | fill <text>] [--first]
                                   Find widgets by text, key, label, type or tooltip
  wait <finder> <value> [--gone]   Wait until a widget appears or disappears
  wait idle                        Wait until no frames are pending
  logs [--tail <n>]                App output since launch
  sessions                         List live sessions

Exit codes: 0 success, 1 failure, 2 usage error, 3 no app in the session.''';

ArgParser _commonParser() {
  return ArgParser()
    ..addOption('session', defaultsTo: Platform.environment['FLUTE_SESSION'] ?? 'default')
    ..addOption('timeout')
    ..addFlag('help', abbr: 'h', negatable: false);
}

ArgParser _buildParser() {
  final ArgParser parser = _commonParser();
  final ArgParser dumpParser = _commonParser()
    ..addFlag('interactive', abbr: 'i', negatable: false)
    ..addOption('depth')
    ..addOption('under')
    ..addOption('max-lines');
  parser
    ..addCommand(
      'run',
      _commonParser()
        ..addOption('device', abbr: 'd')
        ..addOption('target', abbr: 't')
        ..addOption('idle-timeout'),
    )
    ..addCommand(
      'attach',
      _commonParser()
        ..addOption('device', abbr: 'd')
        ..addOption('target', abbr: 't')
        ..addOption('idle-timeout'),
    )
    ..addCommand('quit', _commonParser())
    ..addCommand('reload', _commonParser())
    ..addCommand('restart', _commonParser())
    ..addCommand('dump', dumpParser)
    ..addCommand('screenshot', _commonParser())
    ..addCommand('tap', _commonParser())
    ..addCommand('fill', _commonParser())
    ..addCommand('find', _commonParser()..addFlag('first', negatable: false))
    ..addCommand('wait', _commonParser()..addFlag('gone', negatable: false))
    ..addCommand('logs', _commonParser()..addOption('tail'))
    ..addCommand('sessions', _commonParser())
    ..addCommand('help', _commonParser())
    ..addCommand('daemon', _commonParser()..addOption('idle-timeout'));
  return parser;
}

/// Runs the `flute` CLI and returns its exit code.
Future<int> runFlute(List<String> arguments) async {
  try {
    return await _run(arguments);
  } on FluteException catch (e) {
    stderr.writeln('✗ ${e.message}');
    e.details?.forEach(stderr.writeln);
    if (e.hint != null) {
      stderr.writeln(e.hint);
    }
    return e.exitCode;
  } on FormatException catch (e) {
    stderr.writeln('✗ ${e.message}');
    stderr.writeln('Run: flute help');
    return ExitCode.usage;
  }
}

Future<int> _run(List<String> arguments) async {
  final ArgResults top = _buildParser().parse(arguments);
  final ArgResults? command = top.command;
  if (command == null || command.name == 'help' || top.flag('help') || command.flag('help')) {
    stdout.writeln(_usage);
    return command == null && !top.flag('help') && arguments.isNotEmpty
        ? ExitCode.usage
        : ExitCode.success;
  }

  // Options may come before or after the command name.
  String option(String name) => command.wasParsed(name) ? command.option(name)! : top.option(name)!;
  String? optionalOption(String name) => command.wasParsed(name)
      ? command.option(name)
      : (top.wasParsed(name) ? top.option(name) : null);

  final paths = SessionPaths(option('session'));
  final String name = command.name!;
  final List<String> rest = command.rest;
  final String? timeoutText = optionalOption('timeout');
  final Duration timeout = timeoutText != null
      ? parseDuration(timeoutText)
      : (name == 'run' || name == 'attach' ? _defaultRunTimeout : _defaultTimeout);
  final params = <String, Object?>{'timeout': timeout.inMilliseconds};

  switch (name) {
    case 'daemon':
      final String? idle = command.option('idle-timeout');
      await runDaemon(paths.name, idle == null ? _defaultIdleTimeout : parseDuration(idle));
      // The daemon exits the process when it shuts down.
      await Future<void>.delayed(const Duration(days: 365 * 100));
      return ExitCode.success;

    case 'run':
    case 'attach':
      final String? idle =
          command.option('idle-timeout') ?? Platform.environment['FLUTE_IDLE_TIMEOUT'];
      final Duration idleTimeout = idle == null ? _defaultIdleTimeout : parseDuration(idle);
      params['cwd'] = Directory.current.path;
      params['idleTimeout'] = idleTimeout.inMilliseconds;
      if (command.option('device') case final String device) {
        params['device'] = device;
      }
      if (command.option('target') case final String target) {
        params['target'] = target;
      }
      if (name == 'run') {
        params['flutterArgs'] = rest;
      } else {
        _expectArgs(rest, 1, 'attach <vm-service-uri>');
        params['uri'] = rest.single;
      }
      final DaemonClient client = await connectOrSpawn(paths, idleTimeout: idleTimeout);
      return client.request(name, params);

    case 'quit':
    case 'reload':
    case 'restart':
      _expectArgs(rest, 0, name);
      return _send(paths, name, params);

    case 'dump':
      _expectArgs(rest, 1, 'dump app | dump semantics');
      final String what = rest.single;
      if (what != 'app' && what != 'semantics') {
        throw FluteException(
          'Unknown dump "$what".',
          hint: 'Use: flute dump app, or flute dump semantics',
          exitCode: ExitCode.usage,
        );
      }
      if (command.flag('interactive')) {
        if (what != 'semantics') {
          throw FluteException('-i only applies to dump semantics.', exitCode: ExitCode.usage);
        }
        params['interactive'] = true;
      }
      if (command.option('depth') case final String depth) {
        params['depth'] = _parseInt(depth, '--depth');
      }
      if (command.option('under') case final String under) {
        params['under'] = parseRef(under);
      }
      if (command.option('max-lines') case final String maxLines) {
        params['maxLines'] = _parseInt(maxLines, '--max-lines');
      }
      return _send(paths, what == 'app' ? 'dump_app' : 'dump_semantics', params);

    case 'screenshot':
      if (rest.length > 1) {
        _expectArgs(rest, 1, 'screenshot [<path>]');
      }
      if (rest.isNotEmpty) {
        params['path'] = File(rest.single).absolute.path;
      }
      return _send(paths, 'screenshot', params);

    case 'tap':
      _expectArgs(rest, 1, 'tap <ref>');
      params['ref'] = parseRef(rest.single);
      return _send(paths, 'tap', params);

    case 'fill':
      _expectArgs(rest, 2, 'fill <ref> <text>');
      params['ref'] = parseRef(rest[0]);
      params['text'] = rest[1];
      return _send(paths, 'fill', params);

    case 'find':
      if (rest.length < 2) {
        _expectArgs(rest, 2, 'find <finder> <value> [tap | fill <text>]');
      }
      params['finder'] = rest[0];
      params['value'] = rest[1];
      if (rest.length > 2) {
        params['action'] = rest[2];
        params['args'] = rest.sublist(3);
      }
      params['first'] = command.flag('first');
      return _send(paths, 'find', params);

    case 'wait':
      if (rest.length == 1 && rest.single == 'idle') {
        return _send(paths, 'wait_idle', params);
      }
      _expectArgs(rest, 2, 'wait <finder> <value> [--gone], or wait idle');
      params['finder'] = rest[0];
      params['value'] = rest[1];
      params['gone'] = command.flag('gone');
      return _send(paths, 'wait', params);

    case 'logs':
      _expectArgs(rest, 0, 'logs [--tail <n>]');
      final String? tail = command.option('tail');
      return _logs(paths, tail == null ? null : _parseInt(tail, '--tail'));

    case 'sessions':
      _expectArgs(rest, 0, 'sessions');
      return _sessions();
  }
  throw FluteException(
    'Unknown command "$name".',
    hint: 'Run: flute help',
    exitCode: ExitCode.usage,
  );
}

void _expectArgs(List<String> rest, int count, String usage) {
  if (rest.length != count) {
    throw FluteException('Usage: flute $usage', exitCode: ExitCode.usage);
  }
}

int _parseInt(String text, String option) {
  final int? value = int.tryParse(text);
  if (value == null || value < 0) {
    throw FluteException('$option needs a whole number, not "$text".', exitCode: ExitCode.usage);
  }
  return value;
}

/// Sends a request to a running session, or explains why there is no app.
Future<int> _send(SessionPaths paths, String method, Map<String, Object?> params) async {
  final DaemonClient? client = await DaemonClient.connect(paths);
  if (client == null) {
    return _reportNoApp(paths);
  }
  return client.request(method, params);
}

int _reportNoApp(SessionPaths paths) {
  if (paths.exitJson.existsSync()) {
    try {
      final json = jsonDecode(paths.exitJson.readAsStringSync()) as Map<String, Object?>;
      stderr.writeln('✗ App exited (code ${json['code']}).');
      final List<String> lines = _readLog(paths);
      final Iterable<String> last = lines.skip(lines.length > 20 ? lines.length - 20 : 0);
      if (last.isNotEmpty) {
        stderr.writeln('Last lines of app output:');
        last.forEach(stderr.writeln);
      }
      stderr.writeln('Start it again with: flute run');
      return ExitCode.noApp;
    } on FormatException {
      // Fall through to the generic message.
    }
  }
  stderr.writeln('✗ No app in session "${paths.name}". Start one with: flute run');
  return ExitCode.noApp;
}

List<String> _readLog(SessionPaths paths) {
  final lines = <String>[];
  for (final file in <File>[File('${paths.appLog.path}.1'), paths.appLog]) {
    if (file.existsSync()) {
      lines.addAll(const LineSplitter().convert(file.readAsStringSync()));
    }
  }
  return lines;
}

int _logs(SessionPaths paths, int? tail) {
  final List<String> lines = _readLog(paths);
  if (lines.isEmpty) {
    if (!paths.appLog.existsSync() && !paths.daemonJson.existsSync()) {
      stderr.writeln('✗ No app output in session "${paths.name}". Start an app with: flute run');
      return ExitCode.noApp;
    }
    stdout.writeln('No app output yet.');
    return ExitCode.success;
  }
  final int skip = tail != null && lines.length > tail ? lines.length - tail : 0;
  lines.skip(skip).forEach(stdout.writeln);
  return ExitCode.success;
}

Future<int> _sessions() async {
  final Directory root = SessionPaths.root;
  final live = <String>[];
  if (root.existsSync()) {
    final List<Directory> dirs = root.listSync().whereType<Directory>().toList()
      ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    for (final dir in dirs) {
      final String name = dir.uri.pathSegments.where((String s) => s.isNotEmpty).last;
      final SessionPaths paths;
      try {
        paths = SessionPaths(name);
      } on FluteException {
        continue;
      }
      final DaemonClient? client = await DaemonClient.connect(paths);
      if (client == null) {
        continue;
      }
      final (int code, String status) = await client.requestText('status');
      if (code == ExitCode.success) {
        live.add('$name: $status');
      }
    }
  }
  if (live.isEmpty) {
    stdout.writeln('No live sessions.');
  } else {
    live.forEach(stdout.writeln);
  }
  return ExitCode.success;
}
