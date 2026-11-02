import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli/common.dart';

/// Finds the `flutter` executable: `FLUTTER_ROOT/bin/flutter` when that is
/// set, otherwise the one on `PATH`.
String flutterExecutable() {
  final String name = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final String candidate = p.join(root, 'bin', name);
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    if (dir.isEmpty) {
      continue;
    }
    final String candidate = p.join(dir, name);
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  throw FluteException(
    'Could not find the flutter tool.',
    hint: 'Put flutter on PATH or set FLUTTER_ROOT.',
  );
}

/// Starts a `flutter` subcommand. Batch files on Windows need a shell.
Future<Process> startFlutter(List<String> args, {required String workingDirectory}) {
  return Process.start(
    flutterExecutable(),
    args,
    workingDirectory: workingDirectory,
    runInShell: Platform.isWindows,
  );
}

/// Kills a process and, on Windows, the processes it started (the shell runs
/// `flutter.bat`, which runs Dart).
Future<void> killTree(Process process) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', <String>['/PID', '${process.pid}', '/T', '/F']);
  } else {
    process.kill(ProcessSignal.sigkill);
  }
}

/// A `flutter run --machine` or `flutter attach --machine` child process.
///
/// Reads the JSON-RPC events it prints, and sends it `app.*` requests.
class FlutterTool {
  FlutterTool._(this._process, {required this.attached}) {
    // A start failure is reported through [started]; don't let it count as
    // unhandled when nobody is waiting yet.
    _started.future.ignore();
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStdout, onDone: _stdoutDone.complete);
    _process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onStderr);
    _process.exitCode.then((int code) async {
      await _stdoutDone.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      _exited = true;
      for (final Completer<Object?> pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(FluteException('The flutter tool exited (code $code).'));
        }
      }
      if (!_started.isCompleted) {
        _started.completeError(_StartFailure(code));
      }
      _exitCode.complete(code);
    });
  }

  /// Runs `flutter run --machine` (or attach) with [args].
  static Future<FlutterTool> start(
    List<String> args, {
    required String workingDirectory,
    required bool attached,
  }) async {
    final Process process = await startFlutter(args, workingDirectory: workingDirectory);
    return FlutterTool._(process, attached: attached);
  }

  /// Wraps a process that is already running. Used by tests.
  factory FlutterTool.fromProcess(Process process, {bool attached = false}) =>
      FlutterTool._(process, attached: attached);

  final Process _process;

  /// Whether this tool attached to an app it did not launch.
  final bool attached;

  final Completer<void> _stdoutDone = Completer<void>();
  final Completer<void> _started = Completer<void>();
  final Completer<int> _exitCode = Completer<int>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 1;
  bool _exited = false;

  String? appId;
  String? deviceId;
  String? wsUri;

  /// Output of the tool that is not app output: plain lines and
  /// `daemon.logMessage` events. Kept to report build failures.
  final List<String> toolOutput = <String>[];

  /// Called with each progress message during a build.
  void Function(String message)? onProgress;

  /// Called with every other line, for the daemon log.
  void Function(String line)? onToolLog;

  /// Completes when the app's first frame is up; fails if the tool exits
  /// first.
  Future<void> get started => _started.future;

  Future<int> get exitCode => _exitCode.future;

  bool get hasExited => _exited;

  int get pid => _process.pid;

  void _onStdout(String line) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('[{') && trimmed.endsWith('}]')) {
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        _toolLine(line);
        return;
      }
      for (final Object? message in decoded! as List<Object?>) {
        _onMessage(message! as Map<String, Object?>);
      }
      return;
    }
    _toolLine(line);
  }

  void _onStderr(String line) => _toolLine(line);

  void _toolLine(String line) {
    toolOutput.add(line);
    if (toolOutput.length > 500) {
      toolOutput.removeRange(0, toolOutput.length - 500);
    }
    onToolLog?.call(line);
  }

  void _onMessage(Map<String, Object?> message) {
    final Object? id = message['id'];
    if (id is int && !message.containsKey('event')) {
      final Completer<Object?>? pending = _pending.remove(id);
      if (pending == null) {
        return;
      }
      if (message.containsKey('error')) {
        pending.completeError(FluteException('${message['error']}'));
      } else {
        pending.complete(message['result']);
      }
      return;
    }

    final String? event = message['event'] as String?;
    final Map<String, Object?> params = (message['params'] as Map<String, Object?>?) ?? const {};
    switch (event) {
      case 'app.start':
        appId = params['appId'] as String?;
        deviceId = params['deviceId'] as String?;
      case 'app.debugPort':
        wsUri = params['wsUri'] as String?;
      case 'app.started':
        if (!_started.isCompleted) {
          _started.complete();
        }
      case 'app.log' || 'daemon.logMessage':
        // App output reaches the daemon through the VM service instead: how
        // the tool forwards it differs by platform and version, and on
        // desktop it is block-buffered. Keep these for build failures.
        final String text = (params['log'] ?? params['message']) as String? ?? '';
        for (final String line in const LineSplitter().convert(text)) {
          _toolLine(line);
        }
        if (params['level'] == 'error' && !_started.isCompleted) {
          onProgress?.call(text);
        }
      case 'app.progress':
        final String? text = params['message'] as String?;
        if (text != null &&
            text.isNotEmpty &&
            params['finished'] != true &&
            !_started.isCompleted) {
          onProgress?.call(text);
        }
      default:
        onToolLog?.call(jsonEncode(message));
    }
  }

  /// Sends a request on the tool's stdin and waits for its result.
  Future<Object?> request(String method, Map<String, Object?> params) {
    if (_exited) {
      throw FluteException('The flutter tool has exited.');
    }
    final int id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _process.stdin.writeln(
      jsonEncode(<Object?>[
        <String, Object?>{'id': id, 'method': method, 'params': params},
      ]),
    );
    return completer.future;
  }

  /// Hot reload, or hot restart with [fullRestart].
  ///
  /// Returns the tool's message on failure, null on success.
  Future<String?> restart({required bool fullRestart}) async {
    final Object? result = await request('app.restart', <String, Object?>{
      'appId': appId,
      'fullRestart': fullRestart,
      'pause': false,
      'reason': 'flute',
    });
    if (result is Map<String, Object?> && result['code'] != 0) {
      final Object? message = result['message'];
      return message is String && message.isNotEmpty ? message : 'Reload failed.';
    }
    return null;
  }

  /// Stops a launched app or detaches from an attached one, then waits up
  /// to 10 s for the tool to exit before killing it.
  Future<void> stop() async {
    if (!_exited && appId != null) {
      try {
        await request(attached ? 'app.detach' : 'app.stop', <String, Object?>{
          'appId': appId,
        }).timeout(const Duration(seconds: 10));
      } on Object {
        // Fall through to the kill below.
      }
    }
    try {
      await exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await killTree(_process);
    }
  }

  /// Kills the tool without asking the app to stop.
  Future<void> kill() => killTree(_process);
}

/// The tool exited before the app's first frame.
class _StartFailure implements Exception {
  _StartFailure(this.exitCode);

  final int exitCode;

  @override
  String toString() => 'The flutter tool exited (code $exitCode) before the app started.';
}

/// Whether [error] means the tool exited before the app started.
bool isStartFailure(Object error) => error is _StartFailure;
