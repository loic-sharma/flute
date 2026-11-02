import 'package:flutter_flute/src/cli/common.dart';
import 'package:flutter_flute/src/daemon/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseDuration', () {
    expect(parseDuration('500ms'), const Duration(milliseconds: 500));
    expect(parseDuration('10s'), const Duration(seconds: 10));
    expect(parseDuration('10'), const Duration(seconds: 10));
    expect(parseDuration('1.5s'), const Duration(milliseconds: 1500));
    expect(parseDuration('5m'), const Duration(minutes: 5));
    expect(parseDuration('1h'), const Duration(hours: 1));
    expect(
      () => parseDuration('soon'),
      throwsA(
        isA<FluteException>().having((FluteException e) => e.exitCode, 'exitCode', ExitCode.usage),
      ),
    );
  });

  test('formatDuration round-trips', () {
    for (final text in <String>['250ms', '10s', '5m', '1h']) {
      expect(formatDuration(parseDuration(text)), text);
    }
  });

  test('parseRef', () {
    expect(parseRef('s#7'), 7);
    expect(parseRef('7'), 7);
    expect(() => parseRef('#7'), throwsA(isA<FluteException>()));
    expect(() => parseRef('s#x'), throwsA(isA<FluteException>()));
  });

  test('session names are validated', () {
    expect(SessionPaths('my-app_2').name, 'my-app_2');
    expect(() => SessionPaths('../evil'), throwsA(isA<FluteException>()));
    expect(() => SessionPaths('a b'), throwsA(isA<FluteException>()));
  });

  group('generateEntrypoint', () {
    test('plain main', () {
      final String source = generateEntrypoint(
        importUri: 'package:my_app/main.dart',
        mainSource: 'void main() {\n  runApp(const MyApp());\n}\n',
      );
      expect(source, contains("import 'package:my_app/main.dart' as app;"));
      expect(source, contains('void main(List<String> args) {'));
      expect(source, contains('  enableFlute();\n  app.main();'));
    });

    test('main with args', () {
      final String source = generateEntrypoint(
        importUri: 'package:my_app/main.dart',
        mainSource: 'void main(List<String> args) {}',
      );
      expect(source, contains('app.main(args);'));
    });

    test('async main is awaited', () {
      final String source = generateEntrypoint(
        importUri: '../../integration_test/app.dart',
        mainSource: 'Future<void> main() async {\n  await init();\n}',
      );
      expect(source, contains('Future<void> main(List<String> args) async {'));
      expect(source, contains('await app.main();'));
    });

    test('untyped main', () {
      final String source = generateEntrypoint(
        importUri: 'package:my_app/main.dart',
        mainSource: 'main() => runApp(const MyApp());',
      );
      expect(source, contains('  app.main();'));
    });
  });
}
