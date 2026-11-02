import 'package:flutter_flute/src/cli/format.dart';
import 'package:flutter_test/flutter_test.dart';

/// A dump recorded from the example app's sign-in page, trimmed.
Map<String, Object?> signInDump() => <String, Object?>{
  'views': <Object?>[
    <String, Object?>{
      'viewId': 0,
      'root': <String, Object?>{
        'id': 0,
        'role': 'none',
        'flags': <String>[],
        'actions': <String>[],
        'rect': <double>[0, 0, 1264, 681],
        'children': <Object?>[
          <String, Object?>{
            'id': 1,
            'role': 'none',
            'flags': <String>[],
            'actions': <String>[],
            'rect': <double>[0, 0, 1264, 681],
            'children': <Object?>[
              <String, Object?>{
                'id': 3,
                'role': 'none',
                'flags': <String>['scopesRoute'],
                'actions': <String>[],
                'rect': <double>[0, 0, 1264, 681],
                'children': <Object?>[
                  <String, Object?>{
                    'id': 4,
                    'role': 'none',
                    'flags': <String>['header'],
                    'actions': <String>[],
                    'label': 'Sign in',
                    'rect': <double>[580, 200, 684, 232],
                  },
                  <String, Object?>{
                    'id': 5,
                    'role': 'none',
                    'flags': <String>['textField', 'focusable'],
                    'actions': <String>['tap', 'focus', 'setText', 'setSelection'],
                    'label': 'Email',
                    'value': 'dash@example.com',
                    'rect': <double>[472, 240, 792, 288],
                  },
                  <String, Object?>{
                    'id': 6,
                    'role': 'none',
                    'flags': <String>['textField', 'obscured', 'focusable'],
                    'actions': <String>['tap', 'focus'],
                    'label': 'Password',
                    'rect': <double>[472, 296, 792, 344],
                  },
                  <String, Object?>{
                    'id': 9,
                    'role': 'none',
                    'flags': <String>['hidden'],
                    'actions': <String>[],
                    'label': 'Offstage',
                    'rect': <double>[0, 0, 0, 0],
                  },
                  <String, Object?>{
                    'id': 7,
                    'role': 'none',
                    'flags': <String>['button', 'focusable'],
                    'actions': <String>['tap', 'focus', 'showOnScreen'],
                    'label': 'Login',
                    'rect': <double>[472, 368, 792, 408],
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  ],
};

void main() {
  group('formatSemantics', () {
    test('prints a pruned tree with refs', () {
      expect(formatSemantics(signInDump()), <String>[
        '- s#0 root',
        '  - s#3 scope',
        '    - s#4 heading "Sign in"',
        '    - s#5 textField "Email" = "dash@example.com" [focusable]',
        '    - s#6 textField "Password" [obscured, focusable]',
        '    - s#7 button "Login" [focusable, tap]',
      ]);
    });

    test('-i prints only interactive nodes, flat', () {
      expect(formatSemantics(signInDump(), interactive: true), <String>[
        '- s#5 textField "Email" = "dash@example.com" [focusable]',
        '- s#6 textField "Password" [obscured, focusable]',
        '- s#7 button "Login" [focusable, tap]',
      ]);
    });

    test('--under prints one subtree', () {
      expect(formatSemantics(signInDump(), under: 7), <String>[
        '- s#7 button "Login" [focusable, tap]',
      ]);
      expect(formatSemantics(signInDump(), under: 42), isEmpty);
    });

    test('--depth caps printed levels', () {
      expect(formatSemantics(signInDump(), depth: 2), <String>['- s#0 root', '  - s#3 scope']);
    });

    test('caps output and says how much is left', () {
      expect(formatSemantics(signInDump(), maxLines: 2), <String>[
        '- s#0 root',
        '  - s#3 scope',
        '… 4 more nodes; use --depth, --under or --max-lines',
      ]);
      expect(formatSemantics(signInDump(), maxLines: 0), hasLength(6));
    });

    test('labels views when there are several', () {
      final Map<String, Object?> dump = signInDump();
      final views = dump['views']! as List<Object?>;
      views.add(<String, Object?>{
        'viewId': 1,
        'root': <String, Object?>{
          'id': 100,
          'flags': <String>[],
          'actions': <String>[],
          'label': 'Second',
        },
      });
      final List<String> lines = formatSemantics(dump);
      expect(lines.first, 'View 0:');
      expect(lines, contains('View 1:'));
      expect(lines.last, '  - s#100 text "Second"');
    });
  });

  test('shownSemanticsIds matches the printed nodes', () {
    expect(shownSemanticsIds(signInDump()), <int>{3, 4, 5, 6, 7});
  });

  group('formatWidgets', () {
    final dump = <String, Object?>{
      'roots': <Object?>[
        <String, Object?>{
          'type': 'MyApp',
          'id': 1,
          'children': <Object?>[
            <String, Object?>{'type': 'TextField', 'key': 'email', 'id': 5},
            <String, Object?>{
              'type': 'ElevatedButton',
              'id': 7,
              'children': <Object?>[
                <String, Object?>{'type': 'Text', 'text': 'Login'},
              ],
            },
          ],
        },
      ],
    };

    test('prints refs that the semantics dump shows', () {
      expect(formatWidgets(dump, knownIds: <int>{5, 7}), <String>[
        '- MyApp',
        '  - s#5 TextField (key: email)',
        '  - s#7 ElevatedButton',
        '    - Text "Login"',
      ]);
    });

    test('--under starts at the widget with that ref', () {
      expect(formatWidgets(dump, under: 7), <String>['- s#7 ElevatedButton', '  - Text "Login"']);
    });
  });

  test('quote cuts long text and escapes newlines', () {
    expect(quote('a\nb "c"'), r'"a\nb \"c\""');
    final String long = quote('x' * 200);
    expect(long.length, 82);
    expect(long, endsWith('…"'));
  });

  test('findErrorBanner finds the first banner', () {
    final lines = <String>[
      'flutter: hello',
      '══╡ EXCEPTION CAUGHT BY GESTURE ╞═══',
      for (int i = 0; i < 20; i++) 'line $i',
    ];
    expect(findErrorBanner(lines), hasLength(10));
    expect(findErrorBanner(lines)!.first, contains('EXCEPTION CAUGHT BY GESTURE'));
    expect(findErrorBanner(<String>['all good']), isNull);
  });
}
