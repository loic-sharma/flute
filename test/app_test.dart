import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_driver/flutter_driver.dart' hide find;
import 'package:flutter_flute/src/app/extensions.dart';
import 'package:flutter_flute/src/cli/format.dart';
import 'package:flutter_flute/src/protocol/commands.dart';
import 'package:flutter_test/flutter_test.dart';

class _Factories with DeserializeFinderFactory, CreateFinderFactory, CommandHandlerFactory {}

class _App extends StatelessWidget {
  const _App({required this.onGo});

  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(header: true, child: const Text('Title')),
            Semantics(
              button: true,
              label: 'Go',
              child: GestureDetector(
                key: const ValueKey<String>('go'),
                behavior: HitTestBehavior.opaque,
                onTap: onGo,
                child: const SizedBox(width: 100, height: 40),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<Map<String, dynamic>> _call(
  CommandExtension extension,
  Command command,
  WidgetTester tester,
) async {
  final factories = _Factories();
  final Result result = await extension.call(command, tester, factories, factories);
  return result.toJson();
}

int _idForLabel(Map<String, dynamic> dump, String label) {
  int? found;
  void visit(Map<String, Object?> node) {
    if (node['label'] == label) {
      found = node['id']! as int;
    }
    for (final Object? child in node['children'] as List<Object?>? ?? const <Object?>[]) {
      visit(child! as Map<String, Object?>);
    }
  }

  for (final Object? view in dump['views'] as List<Object?>) {
    visit((view! as Map<String, Object?>)['root']! as Map<String, Object?>);
  }
  return found!;
}

void main() {
  testWidgets('hello reports the protocol version', (WidgetTester tester) async {
    final Map<String, dynamic> hello = await _call(
      FluteHelloExtension(),
      const FluteHello(),
      tester,
    );
    expect(hello['protocol'], fluteProtocolVersion);
  });

  testWidgets('dump semantics returns nodes with global rects', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_App(onGo: () {}));

    final Map<String, dynamic> dump = await _call(
      FluteDumpSemanticsExtension(),
      const FluteDumpSemantics(),
      tester,
    );
    final List<String> lines = formatSemantics(dump, interactive: true);
    expect(lines, hasLength(1));
    expect(lines.single, matches(RegExp(r'^- s#\d+ button "Go" \[tap\]$')));

    // The rect is in global logical pixels and matches the widget.
    final int id = _idForLabel(dump, 'Go');
    final Rect widgetRect = tester.getRect(find.byKey(const ValueKey<String>('go')));
    void check(Map<String, Object?> node) {
      if (node['id'] == id) {
        final rect = (node['rect']! as List<Object?>).cast<double>();
        expect(Rect.fromLTRB(rect[0], rect[1], rect[2], rect[3]), widgetRect);
      }
      for (final Object? child in node['children'] as List<Object?>? ?? const <Object?>[]) {
        check(child! as Map<String, Object?>);
      }
    }

    check(
      ((dump['views'] as List<Object?>).single! as Map<String, Object?>)['root']!
          as Map<String, Object?>,
    );
    handle.dispose();
  });

  testWidgets('tap hits the node with a real pointer event', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    int taps = 0;
    await tester.pumpWidget(_App(onGo: () => taps++));

    final Map<String, dynamic> dump = await _call(
      FluteDumpSemanticsExtension(),
      const FluteDumpSemantics(),
      tester,
    );
    final Map<String, dynamic> result = await _call(
      FluteTapExtension(),
      FluteTap(_idForLabel(dump, 'Go')),
      tester,
    );
    expect(result['error'], isNull);
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('tap on a missing ref says it is gone', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_App(onGo: () {}));
    final Map<String, dynamic> result = await _call(
      FluteTapExtension(),
      const FluteTap(9999),
      tester,
    );
    expect(result['error'], 's#9999 is gone.');
    handle.dispose();
  });

  testWidgets('tap refuses a node something else covers', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    int taps = 0;
    await tester.pumpWidget(
      Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          _App(onGo: () => taps++),
          // A barrier over everything that still lets semantics through.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              excludeFromSemantics: true,
            ),
          ),
        ],
      ),
    );

    final Map<String, dynamic> dump = await _call(
      FluteDumpSemanticsExtension(),
      const FluteDumpSemantics(),
      tester,
    );
    final Map<String, dynamic> result = await _call(
      FluteTapExtension(),
      FluteTap(_idForLabel(dump, 'Go')),
      tester,
    );
    expect(result['error'], startsWith('s#'));
    expect(result['error'], contains('is covered by'));
    expect(taps, 0);
    handle.dispose();
  });

  testWidgets('find returns matches with their semantics refs', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_App(onGo: () {}));

    final Map<String, dynamic> result = await _call(
      FluteFindExtension(),
      FluteFind(ByValueKey('go')),
      tester,
    );
    final matches = (result['matches'] as List<Object?>).cast<Map<String, Object?>>();
    expect(matches, hasLength(1));
    expect(matches.single['type'], 'GestureDetector');
    expect(matches.single['key'], 'go');
    expect(matches.single['id'], isA<int>());
    handle.dispose();
  });

  testWidgets('dump app keeps widgets created by this code', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_App(onGo: () {}));

    final Map<String, dynamic> dump = await _call(
      FluteDumpWidgetsExtension(),
      const FluteDumpWidgets(),
      tester,
    );
    final List<String> lines = formatWidgets(dump);
    expect(lines.first, '- _App');
    expect(lines, contains(matches(RegExp(r'^\s+- Text "Title"$'))));
    expect(lines.where((String l) => l.contains('RichText')), isEmpty);
    handle.dispose();
  });
}
