import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../daemon/daemon.dart';
import 'client.dart';
import 'common.dart';
import 'usage.dart';

const Duration _defaultTimeout = Duration(seconds: 10);
const Duration _defaultRunTimeout = Duration(minutes: 5);
const Duration _defaultIdleTimeout = Duration(minutes: 30);

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
    // Bad options, such as an unknown flag or a missing option value.
    stderr.writeln('✗ ${e.message}');
    final String? name = arguments.where((String a) => findCommand(a) != null).firstOrNull;
    stderr.writeln(name == null || name == 'help' ? 'Run: flute help' : 'Run: flute $name --help');
    return ExitCode.usage;
  }
}

/// Returns the help text for [arguments] if they ask for help, else null.
///
/// Throws a usage [FluteException] for `flute help <unknown>`.
({String text, int exitCode})? helpFor(ArgResults top, {required bool hadArguments}) {
  final ArgResults? command = top.command;
  if (command == null) {
    // Bare `flute` is a usage error; `flute --help` is not.
    return (
      text: generalUsage(),
      exitCode: top.flag('help') || !hadArguments ? ExitCode.success : ExitCode.usage,
    );
  }
  if (command.name == 'help') {
    if (command.rest.isEmpty) {
      return (text: generalUsage(), exitCode: ExitCode.success);
    }
    final CommandSpec? spec = findCommand(command.rest.first);
    if (spec == null || command.rest.length > 1) {
      throw FluteException(
        'Unknown command "${command.rest.join(' ')}".',
        hint: 'Run: flute help',
        exitCode: ExitCode.usage,
      );
    }
    return (text: commandUsage(spec), exitCode: ExitCode.success);
  }
  if (command.flag('help')) {
    return (text: commandUsage(findCommand(command.name!)!), exitCode: ExitCode.success);
  }
  if (top.flag('help')) {
    // `flute --help tap` reads as help for tap.
    return (text: commandUsage(findCommand(command.name!)!), exitCode: ExitCode.success);
  }
  return null;
}

Future<int> _run(List<String> arguments) async {
  final ArgResults top = buildParser().parse(arguments);
  final ({String text, int exitCode})? help = helpFor(top, hadArguments: arguments.isNotEmpty);
  if (help != null) {
    (help.exitCode == ExitCode.success ? stdout : stderr).writeln(help.text);
    return help.exitCode;
  }
  final ArgResults command = top.command!;

  // Options may come before or after the command name.
  String? optionalOption(String name) => command.wasParsed(name)
      ? command.option(name)
      : (top.wasParsed(name) ? top.option(name) : null);

  final paths = SessionPaths(
    optionalOption('session') ?? Platform.environment['FLUTE_SESSION'] ?? 'default',
  );
  final String name = command.name!;
  final List<String> rest = command.rest;
  final String? timeoutText = optionalOption('timeout');
  final Duration timeout = timeoutText != null
      ? parseDuration(timeoutText)
      : (name == 'run' || name == 'attach' ? _defaultRunTimeout : _defaultTimeout);
  Verbose.enabled = command.flag('verbose') || top.flag('verbose');
  final params = <String, Object?>{
    'timeout': timeout.inMilliseconds,
    if (Verbose.enabled) 'verbose': true,
  };
  if (name != 'sessions') {
    // `sessions` looks at all of them; this line would only mislead.
    Verbose.log(
      'session "${paths.name}" in ${paths.directory.path}, timeout ${formatDuration(timeout)}',
    );
  }

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
    throw FluteException(
      'Usage: flute $usage',
      hint: 'Run: flute ${usage.split(' ').first} --help',
      exitCode: ExitCode.usage,
    );
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
  Verbose.log(
    paths.exitJson.existsSync()
        ? 'no daemon; ${paths.exitJson.path} records how the last app exited'
        : 'no daemon and no ${paths.exitJson.path}',
  );
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
      final List<String> fileLines = const LineSplitter().convert(file.readAsStringSync());
      Verbose.log('read ${fileLines.length} lines from ${file.path}');
      lines.addAll(fileLines);
    }
  }
  if (!paths.appLog.existsSync()) {
    Verbose.log('no ${paths.appLog.path} yet');
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
  Verbose.log('looking for sessions in ${root.path}');
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
      final DaemonClient? client = await DaemonClient.connect(paths, trace: false);
      if (client == null) {
        Verbose.log('$name: no live daemon');
        continue;
      }
      final (int code, String status) = await client.requestText('status');
      Verbose.log('$name: status exited $code');
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
