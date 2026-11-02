import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_flute/src/daemon/flutter_tool.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for `flutter run --machine` that tests feed lines into.
class FakeProcess implements Process {
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final _StdinRecorder _stdin = _StdinRecorder();

  void event(String name, Map<String, Object?> params) {
    line(
      jsonEncode(<Object?>[
        <String, Object?>{'event': name, 'params': params},
      ]),
    );
  }

  void line(String text) => _stdout.add(utf8.encode('$text\n'));

  void respond(int id, Object? result) {
    line(
      jsonEncode(<Object?>[
        <String, Object?>{'id': id, 'result': result},
      ]),
    );
  }

  Future<void> exitWith(int code) async {
    await _stdout.close();
    await _stderr.close();
    _exitCode.complete(code);
  }

  /// Requests the tool wrote to stdin.
  List<Map<String, Object?>> get requests => _stdin.requests;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 1234;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _StdinRecorder implements IOSink {
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  @override
  void writeln([Object? object = '']) {
    final decoded = jsonDecode('$object') as List<Object?>;
    requests.add(decoded.single! as Map<String, Object?>);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('reads app events and reports start', () async {
    final process = FakeProcess();
    final tool = FlutterTool.fromProcess(process);
    final progress = <String>[];
    tool.onProgress = progress.add;

    process
      ..event('daemon.connected', <String, Object?>{'version': '0.6.1'})
      ..line('Launching lib/main.dart on Windows in debug mode...')
      ..event('app.start', <String, Object?>{'appId': 'abc', 'deviceId': 'windows'})
      ..event('app.progress', <String, Object?>{
        'appId': 'abc',
        'message': 'Building Windows application...',
      })
      ..event('app.debugPort', <String, Object?>{
        'appId': 'abc',
        'wsUri': 'ws://127.0.0.1:1234/x=/ws',
      })
      ..event('app.started', <String, Object?>{'appId': 'abc'});

    await tool.started;
    expect(tool.appId, 'abc');
    expect(tool.deviceId, 'windows');
    expect(tool.wsUri, 'ws://127.0.0.1:1234/x=/ws');
    expect(progress, <String>['Building Windows application...']);
    expect(tool.toolOutput, contains('Launching lib/main.dart on Windows in debug mode...'));
  });

  test('fails start when the tool exits first, keeping its output', () async {
    final process = FakeProcess();
    final tool = FlutterTool.fromProcess(process);
    process
      ..event('daemon.logMessage', <String, Object?>{
        'level': 'error',
        'message': "lib/main.dart:4:28: Error: Expected ';'",
      })
      ..line('Error: Build process failed.');
    await process.exitWith(1);

    await expectLater(tool.started, throwsA(predicate<Object>(isStartFailure)));
    expect(await tool.exitCode, 1);
    expect(
      tool.toolOutput,
      containsAll(<String>[
        "lib/main.dart:4:28: Error: Expected ';'",
        'Error: Build process failed.',
      ]),
    );
  });

  test('hot reload sends app.restart and reports failures', () async {
    final process = FakeProcess();
    final tool = FlutterTool.fromProcess(process);
    process.event('app.start', <String, Object?>{'appId': 'abc', 'deviceId': 'windows'});
    await pumpEventQueue();

    final Future<String?> ok = tool.restart(fullRestart: false);
    await pumpEventQueue();
    expect(process.requests.single['method'], 'app.restart');
    expect((process.requests.single['params']! as Map<String, Object?>)['fullRestart'], false);
    process.respond(process.requests.single['id']! as int, <String, Object?>{
      'code': 0,
      'message': '',
    });
    expect(await ok, isNull);

    final Future<String?> failed = tool.restart(fullRestart: true);
    await pumpEventQueue();
    process.respond(process.requests.last['id']! as int, <String, Object?>{
      'code': 1,
      'message': 'DevFS synchronization failed',
    });
    expect(await failed, 'DevFS synchronization failed');
  });

  test('pending requests fail when the tool exits', () async {
    final process = FakeProcess();
    final tool = FlutterTool.fromProcess(process);
    process.event('app.start', <String, Object?>{'appId': 'abc'});
    await pumpEventQueue();
    final Future<String?> reload = tool.restart(fullRestart: false);
    await process.exitWith(0);
    await expectLater(reload, throwsA(anything));
    expect(tool.hasExited, isTrue);
  });
}
