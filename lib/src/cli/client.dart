import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'common.dart';

/// What the CLI knows about a running daemon from `daemon.json`.
class DaemonInfo {
  DaemonInfo({required this.pid, required this.port, required this.token});

  static DaemonInfo? read(SessionPaths paths) {
    try {
      final json = jsonDecode(paths.daemonJson.readAsStringSync()) as Map<String, Object?>;
      return DaemonInfo(
        pid: json['pid']! as int,
        port: json['port']! as int,
        token: json['token']! as String,
      );
    } on Object {
      return null;
    }
  }

  final int pid;
  final int port;
  final String token;
}

/// A connection to one session's daemon.
class DaemonClient {
  DaemonClient._(this._socket, this._info) {
    _lines = _socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
  }

  final Socket _socket;
  final DaemonInfo _info;
  late final Stream<String> _lines;

  /// Connects to the session's daemon, or returns null if none is running.
  ///
  /// With [trace], says what it found under `--verbose`.
  static Future<DaemonClient?> connect(SessionPaths paths, {bool trace = true}) async {
    final DaemonInfo? info = DaemonInfo.read(paths);
    if (info == null) {
      if (trace) {
        Verbose.log('no daemon: ${paths.daemonJson.path} is missing or unreadable');
      }
      return null;
    }
    try {
      final Socket socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        info.port,
        timeout: const Duration(seconds: 2),
      );
      if (trace) {
        Verbose.log('connected to daemon pid ${info.pid} on 127.0.0.1:${info.port}');
      }
      return DaemonClient._(socket, info);
    } on SocketException catch (e) {
      if (trace) {
        Verbose.log(
          'no daemon: pid ${info.pid} on port ${info.port} does not answer (${e.message})',
        );
      }
      return null;
    }
  }

  /// Sends one request, writes its output to stdout and stderr as it
  /// arrives, and returns its exit code.
  Future<int> request(
    String method,
    Map<String, Object?> params, {
    IOSink? out,
    IOSink? err,
  }) async {
    out ??= stdout;
    err ??= stderr;
    final watch = Stopwatch()..start();
    Verbose.log('sending $method ${jsonEncode(params)}');
    _socket.writeln(
      jsonEncode(<String, Object?>{
        'id': 1,
        'token': _info.token,
        'method': method,
        'params': params,
      }),
    );
    await _socket.flush();
    await for (final String line in _lines) {
      final Map<String, Object?> message;
      try {
        message = jsonDecode(line) as Map<String, Object?>;
      } on FormatException {
        continue;
      }
      if (message.containsKey('exit')) {
        await _socket.close();
        Verbose.log('$method exited ${message['exit']} after ${watch.elapsedMilliseconds}ms');
        return message['exit']! as int;
      }
      final Object? output = message['output'];
      if (output is String) {
        (message['stderr'] == true ? err : out).writeln(output);
      }
    }
    err.writeln('✗ The daemon disconnected.');
    return ExitCode.failure;
  }

  /// Sends a request and collects its output instead of printing it.
  Future<(int, String)> requestText(String method) async {
    final buffer = _BufferSink();
    final int code = await request(method, const <String, Object?>{}, out: buffer, err: buffer);
    return (code, buffer.text.trim());
  }

  void destroy() => _socket.destroy();
}

/// Starts the daemon for a session if it is not running, and connects to it.
///
/// Holds an exclusive lock on `daemon.lock` while it checks and spawns, so two
/// concurrent `flute run` calls cannot start two daemons for one session.
Future<DaemonClient> connectOrSpawn(SessionPaths paths, {required Duration idleTimeout}) async {
  paths.directory.createSync(recursive: true);
  final RandomAccessFile lock = await paths.lock.open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    final DaemonClient? existing = await DaemonClient.connect(paths);
    if (existing != null) {
      return existing;
    }
    try {
      paths.daemonJson.deleteSync();
    } on FileSystemException {
      // Not there.
    }

    // A compiled `flute` executable is its own script.
    final String script = Platform.script.toFilePath();
    final bool compiled = script == Platform.resolvedExecutable;
    final args = <String>[
      if (!compiled) ...await _vmArguments(),
      if (!compiled) script,
      'daemon',
      '--session',
      paths.name,
      '--idle-timeout',
      formatDuration(idleTimeout),
    ];
    Verbose.log('starting daemon: ${Platform.resolvedExecutable} ${args.join(' ')}');
    final watch = Stopwatch()..start();
    await Process.start(
      Platform.resolvedExecutable,
      args,
      mode: ProcessStartMode.detached,
      workingDirectory: paths.directory.path,
    );

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final DaemonClient? client = await DaemonClient.connect(paths, trace: false);
      if (client != null) {
        Verbose.log('daemon answered after ${watch.elapsedMilliseconds}ms');
        return client;
      }
    }
    throw FluteException(
      'The flute daemon did not start within 10s.',
      hint: 'See ${paths.daemonLog.path}',
    );
  } finally {
    await lock.unlock().catchError((Object _) => lock);
    await lock.close();
  }
}

/// VM arguments that make the daemon resolve packages the way this process
/// does.
Future<List<String>> _vmArguments() async {
  final args = <String>[
    for (final String arg in Platform.executableArguments)
      if (!arg.startsWith('--packages')) arg,
  ];
  final Uri? packageConfig = await Isolate.packageConfig;
  if (packageConfig != null && packageConfig.isScheme('file')) {
    args.add('--packages=${packageConfig.toFilePath()}');
  }
  return args;
}

class _BufferSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) => _buffer.write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<void> flush() async {}
}
