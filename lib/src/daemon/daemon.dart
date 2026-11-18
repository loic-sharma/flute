import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_driver/flutter_driver.dart';
// ScreenshotCommand is not exported. FlutterDriver.screenshot() sends it after
// a fixed 2 s sleep; flute waits for a rasterized frame instead.
// ignore: implementation_imports
import 'package:flutter_driver/src/common/screenshot.dart' show ScreenshotCommand;
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vms;

import '../cli/common.dart';
import '../cli/format.dart';
import '../protocol/commands.dart';
import 'flutter_tool.dart';
import 'project.dart';

/// Where a command's output goes: the CLI's stdout or stderr.
abstract class Reply {
  void out(String line);
  void err(String line);
}

/// The app a session is driving.
class _App {
  _App({
    required this.project,
    required this.tool,
    required this.deviceId,
    required this.target,
    required this.wsUri,
  });

  final FlutterProject project;
  final FlutterTool tool;
  final String deviceId;
  final String target;
  final String wsUri;
  late FlutterDriver driver;
  String platform = 'unknown';

  bool get attached => tool.attached;
  bool get isMobile => platform == 'android' || platform == 'iOS';

  String get deviceName => switch (deviceId) {
    'windows' => 'Windows',
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => deviceId,
  };

  /// The VM service URI in its http form, as `flutter run` prints it.
  String get vmServiceUri {
    final Uri uri = Uri.parse(wsUri);
    String path = uri.path;
    if (path.endsWith('/ws')) {
      path = path.substring(0, path.length - 2);
    }
    return uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http', path: path).toString();
  }
}

/// The per-session background process.
///
/// Keeps the `flutter` tool and the Flutter Driver connection alive between
/// CLI commands, and runs one command at a time.
class Daemon {
  Daemon(this.paths, {required this.idleTimeout});

  final SessionPaths paths;
  Duration idleTimeout;

  late final ServerSocket _server;
  late final String _token;
  _App? _app;
  Timer? _idleTimer;
  Future<void> _queue = Future<void>.value();
  bool _stopping = false;
  bool _shuttingDown = false;

  /// The request being handled, and whether it asked for `--verbose`.
  /// Requests run one at a time, so there is at most one.
  Reply? _current;
  bool _verbose = false;

  /// Sends [message] to the CLI on stderr if the current request is verbose.
  void _trace(String message) {
    if (_verbose) {
      _current?.err('$verbosePrefix$message');
    }
  }

  /// Recent app output, for error banners.
  final List<String> _recentAppLines = <String>[];
  int _appLinesSeen = 0;

  /// Timestamp of the newest app output event, to skip replays.
  int _outputHighWater = 0;

  /// Starts listening and writes `daemon.json`.
  Future<void> start() async {
    paths.directory.createSync(recursive: true);
    driverLog = (String source, String message) => log('$source: $message');

    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    _token = List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();

    paths.daemonJson.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'pid': pid,
        'port': _server.port,
        'token': _token,
        'protocol': fluteProtocolVersion,
        'started': DateTime.now().toIso8601String(),
      }),
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['600', paths.daemonJson.path]);
    }
    log('Daemon started on port ${_server.port} (pid $pid)');

    _server.listen(_onConnection);
    _resetIdleTimer();
  }

  void log(String message) {
    try {
      paths.daemonLog.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // Logging must never take the daemon down.
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      log('Idle for ${formatDuration(idleTimeout)}; shutting down.');
      _queue = _queue.then((_) => shutdown());
    });
  }

  void _onConnection(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) => _onRequest(socket, line),
          onError: (Object error) => log('Connection error: $error'),
          cancelOnError: true,
        );
  }

  void _onRequest(Socket socket, String line) {
    final Map<String, Object?> request;
    try {
      request = jsonDecode(line) as Map<String, Object?>;
    } on FormatException {
      return;
    }
    final Object? id = request['id'];
    final reply = _SocketReply(socket, id);
    if (request['token'] != _token) {
      reply.err('✗ Bad session token.');
      reply.exit(ExitCode.failure);
      return;
    }
    final String method = request['method'] as String? ?? '';
    final Map<String, Object?> params = (request['params'] as Map<String, Object?>?) ?? const {};

    // Answer status checks right away, even while a command runs.
    if (method == 'ping') {
      reply.exit(ExitCode.success);
      return;
    }
    if (method == 'status') {
      final _App? app = _app;
      reply.out(
        app == null
            ? 'no app'
            : '${app.project.name} on ${app.deviceName}${app.attached ? ' (attached)' : ''}',
      );
      reply.exit(ExitCode.success);
      return;
    }

    _queue = _queue.then((_) async {
      if (_shuttingDown) {
        reply.err('✗ The session is shutting down.');
        reply.exit(ExitCode.noApp);
        return;
      }
      _idleTimer?.cancel();
      _current = reply;
      _verbose = params['verbose'] == true;
      final int code;
      try {
        code = await _run(method, params, reply);
      } finally {
        _current = null;
        _verbose = false;
      }
      reply.exit(code);
      await socket.flush().catchError((Object _) {});
      if (method == 'quit' || (_app == null && !_shuttingDown && method != 'ping')) {
        // No app left to drive: quit, a failed run, or the app exited.
        await shutdown();
        return;
      }
      _resetIdleTimer();
    });
  }

  Future<int> _run(String method, Map<String, Object?> params, Reply reply) async {
    final Duration timeout = Duration(milliseconds: (params['timeout'] as int?) ?? 10000);
    final int appLinesBefore = _appLinesSeen;
    try {
      final int code = await _dispatch(method, params, reply, timeout);
      _reportAppError(appLinesBefore, reply);
      return code;
    } on FluteException catch (e) {
      reply.err('✗ ${e.message}');
      for (final String line in e.details ?? const <String>[]) {
        reply.err(line);
      }
      if (e.hint != null) {
        reply.err(e.hint!);
      }
      _reportAppError(appLinesBefore, reply);
      return e.exitCode;
    } on TimeoutException {
      reply.err('✗ Timed out after ${formatDuration(timeout)}.');
      _reportAppError(appLinesBefore, reply);
      return ExitCode.failure;
    } catch (e, stack) {
      log('Unexpected error in $method: $e\n$stack');
      reply.err('✗ ${_firstLine('$e')}');
      reply.err('See ${paths.daemonLog.path}');
      return ExitCode.failure;
    }
  }

  /// Appends the app's error banner if one appeared during the command.
  void _reportAppError(int appLinesBefore, Reply reply) {
    final int newLines = _appLinesSeen - appLinesBefore;
    if (newLines <= 0) {
      return;
    }
    final List<String> recent = _recentAppLines.sublist(max(0, _recentAppLines.length - newLines));
    final List<String>? banner = findErrorBanner(recent);
    if (banner != null) {
      reply.err('App reported an error:');
      banner.forEach(reply.err);
    }
  }

  Future<int> _dispatch(String method, Map<String, Object?> params, Reply reply, Duration timeout) {
    if (method == 'run') {
      return _launch(params, reply, timeout);
    }
    if (method == 'attach') {
      return _attach(params, reply, timeout);
    }
    final _App? app = _app;
    if (app == null) {
      throw FluteException(
        'No app in session "${paths.name}".',
        hint: 'Start one with: flute run',
        exitCode: ExitCode.noApp,
      );
    }
    return switch (method) {
      'quit' => _quit(app, reply),
      'reload' => _reload(app, reply, timeout, fullRestart: false),
      'restart' => _reload(app, reply, timeout, fullRestart: true),
      'dump_semantics' => _dumpSemantics(app, params, reply, timeout),
      'dump_app' => _dumpApp(app, params, reply, timeout),
      'screenshot' => _screenshot(app, params, reply, timeout),
      'tap' => _tap(app, params, reply, timeout),
      'fill' => _fill(app, params, reply, timeout),
      'find' => _find(app, params, reply, timeout),
      'wait' => _wait(app, params, reply, timeout),
      'wait_idle' => _waitIdleCommand(app, reply, timeout),
      _ => throw FluteException('Unknown method "$method".', exitCode: ExitCode.usage),
    };
  }

  // ---------------------------------------------------------------------------
  // Launch, attach and stop

  Future<int> _launch(Map<String, Object?> params, Reply reply, Duration timeout) async {
    final FlutterProject project = FlutterProject.find(params['cwd']! as String);
    project.checkDependency();
    final String target = params['target'] as String? ?? p.join('lib', 'main.dart');
    if (params['idleTimeout'] case final int ms) {
      idleTimeout = Duration(milliseconds: ms);
    }

    final String? replaced = await _replaceApp();
    if (replaced != null) {
      reply.out(replaced);
    }
    _startNewAppLog();

    final String entrypoint = project.writeEntrypoint(target);
    _trace('project ${project.name} in ${project.directory}; wrote $entrypoint for $target');
    final String? device = params['device'] as String?;
    final List<String> extra = (params['flutterArgs'] as List<Object?>? ?? const <Object?>[])
        .cast<String>();
    final args = <String>[
      'run',
      '--machine',
      if (device != null) ...<String>['-d', device],
      '-t',
      entrypoint,
      ...extra,
    ];
    _trace('starting ${flutterExecutable()} ${args.join(' ')}');
    final tool = await FlutterTool.start(
      args,
      workingDirectory: project.directory,
      attached: false,
    );
    return _connectTool(project, tool, target, reply, timeout, verb: 'Started');
  }

  Future<int> _attach(Map<String, Object?> params, Reply reply, Duration timeout) async {
    final FlutterProject project = FlutterProject.find(params['cwd']! as String);
    final String uri = params['uri']! as String;
    final String? device = params['device'] as String?;
    final String? target = params['target'] as String?;

    final String? replaced = await _replaceApp();
    if (replaced != null) {
      reply.out(replaced);
    }
    _startNewAppLog();

    final args = <String>[
      'attach',
      '--machine',
      '--debug-url',
      uri,
      if (device != null) ...<String>['-d', device],
      if (target != null) ...<String>['-t', target],
    ];
    _trace('starting ${flutterExecutable()} ${args.join(' ')} in ${project.directory}');
    final tool = await FlutterTool.start(args, workingDirectory: project.directory, attached: true);
    return _connectTool(
      project,
      tool,
      target ?? p.join('lib', 'main.dart'),
      reply,
      timeout,
      verb: 'Attached to',
    );
  }

  Future<int> _connectTool(
    FlutterProject project,
    FlutterTool tool,
    String target,
    Reply reply,
    Duration timeout, {
    required String verb,
  }) async {
    tool
      ..onProgress = reply.out
      ..onToolLog = (String line) {
        log('flutter: $line');
        // Full build and reload output, for verbose run, reload and restart.
        _trace('flutter: $line');
      };

    try {
      await tool.started.timeout(timeout);
    } on TimeoutException {
      await tool.kill();
      throw FluteException(
        'The app did not start within ${formatDuration(timeout)}.',
        hint: 'Run: flute logs',
      );
    } catch (e) {
      if (!isStartFailure(e)) {
        rethrow;
      }
      // Skip pub's output before the launch; keep the last 30 lines after it.
      final List<String> output = tool.toolOutput;
      final int launch = output.lastIndexWhere((String l) => l.startsWith('Launching '));
      final List<String> relevant = output
          .skip(launch < 0 ? 0 : launch + 1)
          .where((String l) => l.trim().isNotEmpty)
          .toList();
      throw FluteException(
        verb == 'Started' ? 'Build or launch failed.' : 'Attach failed.',
        details: relevant.sublist(max(0, relevant.length - 30)),
      );
    }

    final String? wsUri = tool.wsUri;
    if (wsUri == null) {
      await tool.stop();
      throw FluteException('The flutter tool did not report a VM service URI.');
    }
    final app = _App(
      project: project,
      tool: tool,
      deviceId: tool.deviceId ?? 'unknown',
      target: target,
      wsUri: wsUri,
    );
    try {
      await _connectDriver(app);
    } catch (_) {
      await tool.stop();
      rethrow;
    }
    _app = app;
    tool.exitCode.then((int code) => _onToolExit(app, code));

    paths.appJson.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'project': project.directory,
        'name': project.name,
        'device': app.deviceId,
        'platform': app.platform,
        'target': target,
        'mode': app.attached ? 'attach' : 'launch',
        'vmServiceUri': app.vmServiceUri,
        'appId': tool.appId,
      }),
    );

    reply.out('$verb ${project.name} on ${app.deviceName} (debug) in session "${paths.name}"');
    reply.out('VM service: ${app.vmServiceUri}');
    return ExitCode.success;
  }

  /// Connects Flutter Driver, checks the protocol version, and sets up the
  /// session's defaults.
  Future<void> _connectDriver(_App app) async {
    _trace('connecting Flutter Driver to ${app.wsUri}');
    final watch = Stopwatch()..start();
    final Future<FlutterDriver> connecting = FlutterDriver.connect(
      dartVmServiceUrl: app.wsUri,
      logCommunicationToFile: false,
    );
    try {
      app.driver = await connecting.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      connecting.then((FlutterDriver d) => d.close()).ignore();
      throw FluteException(
        'The app did not enable the flute extension within 30s.',
        hint: 'Is the app built with flutter_flute? Run: flute logs',
      );
    }
    _trace('driver connected in ${watch.elapsedMilliseconds}ms');

    final Map<String, dynamic> hello = await _send(
      app,
      const FluteHello(),
      const Duration(seconds: 10),
    );
    final int theirs = hello['protocol'] as int;
    if (theirs != fluteProtocolVersion) {
      await app.driver.close();
      throw FluteException(
        'The app uses flutter_flute protocol $theirs; this CLI speaks $fluteProtocolVersion.',
        hint: theirs < fluteProtocolVersion
            ? 'Run: flutter pub upgrade flutter_flute'
            : 'Run: flutter pub global activate flutter_flute',
      );
    }
    app.platform = hello['platform'] as String? ?? 'unknown';
    await _listenToAppOutput(app);
    await _setPubRoot(app);
    await _send(app, const SetSemantics(true), const Duration(seconds: 10));
    await _send(app, const SetFrameSync(false), const Duration(seconds: 10));
  }

  /// Captures the app's output from the VM service's Stdout and Stderr
  /// streams. The engine mirrors `print` there on every platform, unbuffered.
  ///
  /// Output printed before the driver connects is not captured.
  Future<void> _listenToAppOutput(_App app) async {
    final vms.VmService client = app.driver.serviceClient;
    final partial = <String, String>{};
    // DDS replays recent output to each new subscriber. That catches output
    // printed before the first connection, but after a hot restart's
    // reconnect it would repeat what is already logged.
    final int cutoff = _outputHighWater;
    bool isNew(vms.Event event) {
      final int timestamp = event.timestamp ?? 0;
      if (timestamp != 0 && timestamp <= cutoff) {
        return false;
      }
      _outputHighWater = max(_outputHighWater, timestamp);
      return true;
    }

    void onEvent(vms.Event event, String stream) {
      final String? bytes = event.bytes;
      if (bytes == null || !isNew(event)) {
        return;
      }
      final String text =
          (partial[stream] ?? '') + utf8.decode(base64.decode(bytes), allowMalformed: true);
      final List<String> lines = text.split('\n');
      partial[stream] = lines.removeLast();
      for (final String line in lines) {
        _onAppLog(line.endsWith('\r') ? line.substring(0, line.length - 1) : line);
      }
    }

    client.onStdoutEvent.listen((vms.Event e) => onEvent(e, vms.EventStreams.kStdout));
    client.onStderrEvent.listen((vms.Event e) => onEvent(e, vms.EventStreams.kStderr));
    // `flutter run --machine` turns on the inspector's structured errors, so
    // uncaught Flutter errors arrive as events instead of being printed.
    client.onExtensionEvent.listen((vms.Event e) {
      if (e.extensionKind != 'Flutter.Error' || !isNew(e)) {
        return;
      }
      final Object? text = e.extensionData?.data['renderedErrorText'];
      if (text is String) {
        const LineSplitter().convert(text).forEach(_onAppLog);
      }
    });
    for (final String stream in <String>[
      vms.EventStreams.kStdout,
      vms.EventStreams.kStderr,
      vms.EventStreams.kExtension,
    ]) {
      try {
        await client.streamListen(stream);
      } on vms.RPCError catch (e) {
        // Already listening (code 103) after a reconnect is fine.
        if (e.code != 103) {
          log('Could not listen to $stream: $e');
        }
      }
    }
  }

  /// Tells the inspector which directory holds the app's own code, as
  /// DevTools does. Without it, every widget outside `package:flutter`
  /// counts as the app's, including packages such as `material_ui`.
  Future<void> _setPubRoot(_App app) async {
    final String root = Uri.directory(app.project.directory).toString();
    // Creation locations may spell the drive letter either way.
    final String lowerDrive = root.replaceFirstMapped(
      RegExp(r'^file:///([A-Z]):'),
      (Match m) => 'file:///${m[1]!.toLowerCase()}:',
    );
    try {
      await app.driver.serviceClient.callServiceExtension(
        'ext.flutter.inspector.addPubRootDirectories',
        isolateId: app.driver.appIsolate.id,
        args: <String, Object?>{'arg0': root, if (lowerDrive != root) 'arg1': lowerDrive},
      );
    } on Object catch (e) {
      log('Could not set the inspector pub root: $e');
    }
  }

  /// Stops the session's current app, if any, and describes what it replaced.
  Future<String?> _replaceApp() async {
    final _App? old = _app;
    if (old == null) {
      return null;
    }
    await _stopApp(old);
    return 'Replaced ${old.project.name} on ${old.deviceName}';
  }

  Future<void> _stopApp(_App app) async {
    _stopping = true;
    try {
      await app.driver.close().timeout(const Duration(seconds: 5)).catchError((Object _) {});
      await app.tool.stop();
    } finally {
      _stopping = false;
      if (identical(_app, app)) {
        _app = null;
      }
    }
  }

  void _onToolExit(_App app, int code) {
    if (_stopping || _shuttingDown || !identical(_app, app)) {
      return;
    }
    log('App exited (code $code)');
    paths.exitJson.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'code': code,
        'name': app.project.name,
        'at': DateTime.now().toIso8601String(),
      }),
    );
    _app = null;
    // Exit once any running command has replied.
    _queue = _queue.then((_) => shutdown());
  }

  Future<int> _quit(_App app, Reply reply) async {
    await _stopApp(app);
    reply.out(app.attached ? 'Detached from ${app.project.name}' : 'Stopped ${app.project.name}');
    return ExitCode.success;
  }

  /// Stops the app, removes the session's live files and exits.
  Future<void> shutdown() async {
    if (_shuttingDown) {
      return;
    }
    _shuttingDown = true;
    _idleTimer?.cancel();
    final _App? app = _app;
    if (app != null) {
      await _stopApp(app);
    }
    paths.daemonJson.deleteIfExists();
    paths.appJson.deleteIfExists();
    log('Daemon stopped');
    await _server.close();
    exit(0);
  }

  // ---------------------------------------------------------------------------
  // App output

  /// `app.log` holds output since the current app's launch.
  void _startNewAppLog() {
    paths.exitJson.deleteIfExists();
    paths.appLog.deleteIfExists();
    File('${paths.appLog.path}.1').deleteIfExists();
    _recentAppLines.clear();
    _outputHighWater = 0;
  }

  void _onAppLog(String line) {
    _appLinesSeen++;
    _recentAppLines.add(line);
    if (_recentAppLines.length > 200) {
      _recentAppLines.removeAt(0);
    }
    final File log = paths.appLog;
    try {
      if (log.existsSync() && log.lengthSync() > 5 * 1024 * 1024) {
        log.renameSync('${log.path}.1');
      }
      log.writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException catch (e) {
      this.log('Could not write app.log: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Reload

  Future<int> _reload(_App app, Reply reply, Duration timeout, {required bool fullRestart}) async {
    final int linesBefore = _appLinesSeen;
    final int toolLinesBefore = app.tool.toolOutput.length;
    final watch = Stopwatch()..start();
    final String? failure = await app.tool.restart(fullRestart: fullRestart).timeout(timeout);
    if (failure != null) {
      final int newAppLines = _appLinesSeen - linesBefore;
      throw FluteException(
        fullRestart
            ? 'Hot restart failed: ${_firstLine(failure)}'
            : 'Hot reload failed: ${_firstLine(failure)}',
        details: <String>[
          ...app.tool.toolOutput.skip(min(toolLinesBefore, app.tool.toolOutput.length)),
          ..._recentAppLines.sublist(max(0, _recentAppLines.length - newAppLines)),
        ].where((String l) => l.trim().isNotEmpty).take(40).toList(),
        hint: 'The app is still running the old code.',
      );
    }
    if (fullRestart) {
      await app.driver.close().catchError((Object _) {});
      await _reconnectAfterRestart(app, timeout);
      reply.out('✓ Restarted in ${watch.elapsedMilliseconds}ms. Earlier s# refs are stale.');
    } else {
      reply.out('✓ Reloaded in ${watch.elapsedMilliseconds}ms');
    }
    return ExitCode.success;
  }

  /// A hot restart replaces the root isolate; connect to the new one.
  Future<void> _reconnectAfterRestart(_App app, Duration timeout) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        await _connectDriver(app);
        return;
      } on Object catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw FluteException('Could not reconnect after hot restart: ${_firstLine('$lastError')}');
  }

  // ---------------------------------------------------------------------------
  // Driver commands

  /// Sends [command] and returns its result, turning app-side failures into
  /// [FluteException]s.
  Future<Map<String, dynamic>> _send(_App app, Command command, Duration timeout) async {
    final Map<String, String> args = command.serialize()..remove('command');
    _trace('→ ${command.kind}${args.isEmpty ? '' : ' ${jsonEncode(args)}'}');
    final watch = Stopwatch()..start();
    final Map<String, dynamic> result;
    try {
      result = await app.driver.sendCommand(command).timeout(timeout + const Duration(seconds: 1));
    } on DriverError catch (e) {
      _trace(
        '← ${command.kind} failed after ${watch.elapsedMilliseconds}ms: ${_firstLine(e.message)}',
      );
      throw _driverFailure(app, e);
    } on TimeoutException {
      _trace('← ${command.kind} timed out after ${watch.elapsedMilliseconds}ms');
      rethrow;
    }
    // Results can be whole trees; report their size, not their contents.
    _trace(
      '← ${command.kind} in ${watch.elapsedMilliseconds}ms, ${jsonEncode(result).length} bytes',
    );
    final Object? error = result['error'];
    if (error is String) {
      throw FluteException(
        error,
        hint: error.contains('is gone') ? 'Run: flute dump semantics' : null,
      );
    }
    return result;
  }

  FluteException _driverFailure(_App app, DriverError e) {
    if (app.tool.hasExited) {
      return FluteException('The app exited.', hint: 'Run: flute logs', exitCode: ExitCode.noApp);
    }
    final String message = e.message;
    if (message.contains('Timeout while executing')) {
      return FluteException('Timed out in the app.');
    }
    const String marker = 'while executing ';
    final int at = message.indexOf(marker);
    if (at >= 0) {
      final String rest = message.substring(at + marker.length);
      final int colon = rest.indexOf(': ');
      return FluteException(
        'App error: ${_firstLine(colon >= 0 ? rest.substring(colon + 2) : rest)}',
        hint: 'Run: flute logs',
      );
    }
    log('Driver error: $message ${e.originalError}');
    return FluteException(_firstLine(message), hint: 'Run: flute logs');
  }

  /// Waits until no frame is pending, up to [budget]. Returns false if the
  /// app was still busy.
  Future<bool> _waitIdle(_App app, Duration budget) async {
    // flute_wait_idle rather than WaitForCondition: a timed-out driver
    // command prints a stack trace into the app's output, and with a looping
    // animation every action would time out.
    try {
      final Map<String, dynamic> result = await _send(
        app,
        FluteWaitIdle(budget),
        budget + const Duration(seconds: 1),
      );
      final bool idle = result['idle'] == true;
      _trace(idle ? 'app is idle' : 'app still busy after ${formatDuration(budget)}; going ahead');
      return idle;
    } on FluteException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static const Duration _actionIdleBudget = Duration(seconds: 2);

  Future<int> _waitIdleCommand(_App app, Reply reply, Duration timeout) async {
    if (!await _waitIdle(app, timeout)) {
      throw FluteException('The app was still busy after ${formatDuration(timeout)}.');
    }
    reply.out('✓ Idle');
    return ExitCode.success;
  }

  Future<int> _dumpSemantics(
    _App app,
    Map<String, Object?> params,
    Reply reply,
    Duration timeout,
  ) async {
    final Map<String, dynamic> dump = await _send(app, const FluteDumpSemantics(), timeout);
    final int? under = params['under'] as int?;
    final List<String> lines = formatSemantics(
      dump,
      interactive: params['interactive'] == true,
      depth: params['depth'] as int?,
      under: under,
      maxLines: params['maxLines'] as int? ?? defaultMaxLines,
    );
    if (under != null && lines.isEmpty) {
      throw FluteException('s#$under is gone.', hint: 'Run: flute dump semantics');
    }
    if (lines.isEmpty) {
      reply.out(params['interactive'] == true ? 'No interactive nodes.' : 'No semantics nodes.');
    }
    lines.forEach(reply.out);
    return ExitCode.success;
  }

  Future<int> _dumpApp(_App app, Map<String, Object?> params, Reply reply, Duration timeout) async {
    final Map<String, dynamic> dump = await _send(app, const FluteDumpWidgets(), timeout);
    final Map<String, dynamic> semantics = await _send(app, const FluteDumpSemantics(), timeout);
    final int? under = params['under'] as int?;
    final List<String> lines = formatWidgets(
      dump,
      depth: params['depth'] as int?,
      under: under,
      maxLines: params['maxLines'] as int? ?? defaultMaxLines,
      knownIds: shownSemanticsIds(semantics),
    );
    if (under != null && lines.isEmpty) {
      throw FluteException('No widget owns s#$under.', hint: 'Run: flute dump app');
    }
    if (lines.isEmpty) {
      reply.out('No app widgets found.');
    }
    lines.forEach(reply.out);
    return ExitCode.success;
  }

  Future<int> _tap(_App app, Map<String, Object?> params, Reply reply, Duration timeout) async {
    await _waitIdle(app, _actionIdleBudget);
    await _send(app, FluteTap(params['ref']! as int, timeout: timeout), timeout);
    reply.out('✓ Done');
    return ExitCode.success;
  }

  Future<int> _fill(_App app, Map<String, Object?> params, Reply reply, Duration timeout) async {
    await _waitIdle(app, _actionIdleBudget);
    await _fillRef(app, params['ref']! as int, params['text']! as String, timeout);
    reply.out('✓ Done');
    return ExitCode.success;
  }

  Future<void> _fillRef(_App app, int ref, String text, Duration timeout) async {
    await _send(app, FluteTap(ref, waitForTextInput: true, timeout: timeout), timeout);
    await _send(app, EnterText(text, timeout: timeout), timeout);
  }

  Future<int> _find(_App app, Map<String, Object?> params, Reply reply, Duration timeout) async {
    final String kind = params['finder']! as String;
    final String value = params['value']! as String;
    final SerializableFinder finder = _finder(kind, value);
    final String described = _describeFinder(kind, value);
    final String? action = params['action'] as String?;
    if (action != null) {
      await _waitIdle(app, _actionIdleBudget);
    }

    final Map<String, dynamic> result = await _send(
      app,
      FluteFind(finder, timeout: timeout),
      timeout,
    );
    final List<Map<String, Object?>> matches = <Map<String, Object?>>[
      for (final Object? match in result['matches'] as List<Object?>)
        match! as Map<String, Object?>,
    ];
    if (matches.isEmpty) {
      throw FluteException('Could not find $described.');
    }

    if (action == null) {
      matches.map((Map<String, Object?> m) => describeWidget(m)).forEach(reply.out);
      reply.out('${matches.length} ${matches.length == 1 ? 'match' : 'matches'}');
      return ExitCode.success;
    }

    if (matches.length > 1 && params['first'] != true) {
      throw FluteException(
        'Found ${matches.length} widgets for $described; $action needs exactly one.',
        details: matches.map((Map<String, Object?> m) => describeWidget(m)).toList(),
        hint: 'Use a ref from this list, or pass --first.',
      );
    }
    final Object? id = matches.first['id'];
    if (id is! int) {
      throw FluteException('The match for $described has no semantics node to $action.');
    }
    switch (action) {
      case 'tap':
        await _send(app, FluteTap(id, timeout: timeout), timeout);
      case 'fill':
        final List<Object?> args = params['args'] as List<Object?>? ?? const <Object?>[];
        if (args.isEmpty) {
          throw FluteException('fill needs the text to enter.', exitCode: ExitCode.usage);
        }
        await _fillRef(app, id, args.first! as String, timeout);
      default:
        throw FluteException(
          'Unknown action "$action".',
          hint: 'Use tap or fill.',
          exitCode: ExitCode.usage,
        );
    }
    reply.out('✓ Done');
    return ExitCode.success;
  }

  Future<int> _wait(_App app, Map<String, Object?> params, Reply reply, Duration timeout) async {
    final String kind = params['finder']! as String;
    final String value = params['value']! as String;
    final SerializableFinder finder = _finder(kind, value);
    final String described = _describeFinder(kind, value);
    final bool gone = params['gone'] == true;
    try {
      await _send(
        app,
        gone ? WaitForAbsent(finder, timeout: timeout) : WaitFor(finder, timeout: timeout),
        timeout,
      );
    } on FluteException catch (e) {
      if (e.message == 'Timed out in the app.') {
        throw FluteException(
          'Timed out after ${formatDuration(timeout)} waiting for $described${gone ? ' to disappear' : ''}.',
        );
      }
      rethrow;
    } on TimeoutException {
      throw FluteException(
        'Timed out after ${formatDuration(timeout)} waiting for $described${gone ? ' to disappear' : ''}.',
      );
    }
    reply.out(gone ? '✓ Gone: $described' : '✓ Found $described');
    return ExitCode.success;
  }

  Future<int> _screenshot(
    _App app,
    Map<String, Object?> params,
    Reply reply,
    Duration timeout,
  ) async {
    final String path = p.absolute(
      params['path'] as String? ?? p.join(paths.screenshots.path, '${_timestamp()}.png'),
    );
    Directory(p.dirname(path)).createSync(recursive: true);
    await _waitIdle(app, _actionIdleBudget);

    if (app.isMobile) {
      _trace('device capture: flutter screenshot -d ${app.deviceId} -o $path');
      final ProcessResult result = await Process.run(
        flutterExecutable(),
        <String>['screenshot', '-d', app.deviceId, '-o', path],
        workingDirectory: app.project.directory,
        runInShell: Platform.isWindows,
      ).timeout(timeout);
      if (result.exitCode != 0) {
        throw FluteException(
          'flutter screenshot failed.',
          details: '${result.stdout}\n${result.stderr}'
              .split('\n')
              .where((String l) => l.trim().isNotEmpty)
              .toList(),
        );
      }
    } else {
      // Make sure the last frame reached the screen, not just the UI thread.
      try {
        await _send(
          app,
          const FluteWaitRasterized(timeout: Duration(seconds: 2)),
          const Duration(seconds: 2),
        );
      } on FluteException catch (e) {
        log('wait_rasterized failed (${e.message}); falling back to a 2s delay');
        _trace('no rasterized frame reported (${e.message}); waiting 2s instead');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final Map<String, dynamic> result = await _send(
        app,
        ScreenshotCommand(timeout: timeout),
        timeout,
      );
      File(path).writeAsBytesSync(base64.decode(result['data']! as String));
    }
    reply.out('✓ Screenshot saved to $path');
    return ExitCode.success;
  }
}

SerializableFinder _finder(String kind, String value) {
  return switch (kind) {
    'text' => ByText(value),
    'key' =>
      value.startsWith('int:') ? ByValueKey(int.parse(value.substring(4))) : ByValueKey(value),
    'label' => BySemanticsLabel(value),
    'type' => ByType(value),
    'tooltip' => ByTooltipMessage(value),
    _ => throw FluteException(
      'Unknown finder "$kind".',
      hint: 'Use text, key, label, type or tooltip.',
      exitCode: ExitCode.usage,
    ),
  };
}

String _describeFinder(String kind, String value) => "$kind '$value'";

String _timestamp() {
  final String iso = DateTime.now().toIso8601String();
  return iso.substring(0, 19).replaceAll(':', '-');
}

String _firstLine(String text) {
  final String trimmed = text.trim();
  final int newline = trimmed.indexOf('\n');
  return newline < 0 ? trimmed : trimmed.substring(0, newline);
}

extension on File {
  void deleteIfExists() {
    try {
      if (existsSync()) {
        deleteSync();
      }
    } on FileSystemException {
      // Best effort.
    }
  }
}

class _SocketReply implements Reply {
  _SocketReply(this._socket, this._id);

  final Socket _socket;
  final Object? _id;

  void _send(Map<String, Object?> message) {
    try {
      _socket.writeln(jsonEncode(message));
    } on Object {
      // The CLI went away; keep going so the daemon stays consistent.
    }
  }

  @override
  void out(String line) => _send(<String, Object?>{'id': _id, 'output': line});

  @override
  void err(String line) => _send(<String, Object?>{'id': _id, 'output': line, 'stderr': true});

  void exit(int code) => _send(<String, Object?>{'id': _id, 'exit': code});
}

/// Entry point for `flute daemon`.
Future<void> runDaemon(String session, Duration idleTimeout) async {
  final paths = SessionPaths(session);
  final daemon = Daemon(paths, idleTimeout: idleTimeout);
  await runZonedGuarded(daemon.start, (Object error, StackTrace stack) {
    daemon.log('Uncaught error: $error\n$stack');
  });
}
