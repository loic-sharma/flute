// Turns raw dumps from the app into compact text for an agent to read.

/// Default cap on printed tree lines.
const int defaultMaxLines = 400;

const int _maxTextLength = 80;

/// Quotes [text] for one line of output, cutting it at 80 characters.
String quote(String text) {
  String oneLine = text.replaceAll('\r\n', r'\n').replaceAll('\n', r'\n').replaceAll('"', r'\"');
  if (oneLine.length > _maxTextLength) {
    oneLine = '${oneLine.substring(0, _maxTextLength - 1)}…';
  }
  return '"$oneLine"';
}

/// A semantics node as dumped by the app.
class SemanticsEntry {
  SemanticsEntry.fromJson(Map<String, Object?> json)
    : id = json['id']! as int,
      role = json['role'] as String? ?? 'none',
      flags = (json['flags'] as List<Object?>? ?? const <Object?>[]).cast<String>(),
      actions = (json['actions'] as List<Object?>? ?? const <Object?>[]).cast<String>(),
      label = json['label'] as String? ?? '',
      value = json['value'] as String? ?? '',
      hint = json['hint'] as String? ?? '',
      tooltip = json['tooltip'] as String? ?? '',
      children = <SemanticsEntry>[
        for (final Object? child in json['children'] as List<Object?>? ?? const <Object?>[])
          SemanticsEntry.fromJson(child! as Map<String, Object?>),
      ];

  final int id;
  final String role;
  final List<String> flags;
  final List<String> actions;
  final String label;
  final String value;
  final String hint;
  final String tooltip;
  final List<SemanticsEntry> children;

  bool get isHidden => flags.contains('hidden');

  bool get isInteractive =>
      _interactiveFlags.any(flags.contains) || _interactiveActions.any(actions.contains);

  /// Whether this node says anything on its own. Nodes that don't are folded
  /// into their parent.
  bool get isMeaningful =>
      label.isNotEmpty ||
      value.isNotEmpty ||
      hint.isNotEmpty ||
      tooltip.isNotEmpty ||
      actions.any((String a) => !_ignoredActions.contains(a)) ||
      flags.any(_roleFlags.containsKey) ||
      flags.contains('scopesRoute');

  /// A short name for what the node is.
  String get displayRole {
    for (final MapEntry<String, String> entry in _roleFlags.entries) {
      if (flags.contains(entry.key)) {
        if (entry.key == 'checkable' && flags.contains('radio')) {
          return 'radio';
        }
        return entry.value;
      }
    }
    if (flags.contains('scopesRoute')) {
      return 'scope';
    }
    if (role != 'none') {
      return role;
    }
    if (actions.any((String a) => !_ignoredActions.contains(a))) {
      return 'group';
    }
    return 'text';
  }

  /// Flags and actions worth showing in brackets.
  List<String> get attributes {
    final String shownRole = displayRole;
    return <String>[
      for (final String flag in flags)
        if (!_hiddenFlags.contains(flag) && _roleFlags[flag] != shownRole) flag,
      for (final String action in actions)
        if (!_ignoredActions.contains(action) && !(action == 'tap' && shownRole == 'textField'))
          action,
    ];
  }

  /// One output line, without indentation.
  String describe({bool isRoot = false}) {
    final String role = isRoot && displayRole == 'text' && label.isEmpty ? 'root' : displayRole;
    final buffer = StringBuffer('- s#$id $role');
    if (label.isNotEmpty) {
      buffer.write(' ${quote(label)}');
    } else if (tooltip.isNotEmpty) {
      buffer.write(' ${quote(tooltip)}');
    }
    if (value.isNotEmpty) {
      buffer.write(' = ${quote(value)}');
    }
    if (hint.isNotEmpty && label.isEmpty) {
      buffer.write(' hint ${quote(hint)}');
    }
    final List<String> attrs = attributes;
    if (attrs.isNotEmpty) {
      buffer.write(' [${attrs.join(', ')}]');
    }
    return buffer.toString();
  }

  static const Map<String, String> _roleFlags = <String, String>{
    'textField': 'textField',
    'button': 'button',
    'link': 'link',
    'header': 'heading',
    'slider': 'slider',
    'checkable': 'checkbox',
    'toggleable': 'switch',
    'image': 'image',
    'keyboardKey': 'key',
  };

  static const Set<String> _hiddenFlags = <String>{
    'scopesRoute',
    'namesRoute',
    'radio',
    'checkable',
    'toggleable',
    'scrollable',
  };

  static const Set<String> _interactiveFlags = <String>{
    'button',
    'textField',
    'checkable',
    'toggleable',
    'slider',
    'link',
  };

  static const Set<String> _interactiveActions = <String>{'tap', 'longPress', 'focus', 'setText'};

  static const Set<String> _ignoredActions = <String>{
    'showOnScreen',
    'didGainAccessibilityFocus',
    'didLoseAccessibilityFocus',
    'moveCursorForwardByCharacter',
    'moveCursorBackwardByCharacter',
    'moveCursorForwardByWord',
    'moveCursorBackwardByWord',
    'setSelection',
    'setText',
    'copy',
    'cut',
    'paste',
    'focus',
    'customAction',
  };
}

/// A node of the pruned tree that will be printed.
class _Line {
  _Line(this.depth, this.text);

  final int depth;
  final String text;
}

/// Formats a `flute_dump_semantics` result.
///
/// [under] limits output to the subtree under that node id; [depth] caps the
/// printed depth.
List<String> formatSemantics(
  Map<String, Object?> dump, {
  bool interactive = false,
  int? depth,
  int? under,
  int maxLines = defaultMaxLines,
}) {
  final views = <(int, SemanticsEntry)>[
    for (final Map<String, Object?> view
        in (dump['views']! as List<Object?>).cast<Map<String, Object?>>())
      (view['viewId']! as int, SemanticsEntry.fromJson(view['root']! as Map<String, Object?>)),
  ];

  final lines = <_Line>[];
  for (final (int viewId, SemanticsEntry root) in views) {
    SemanticsEntry? start = root;
    if (under != null) {
      start = _findEntry(root, under);
      if (start == null) {
        continue;
      }
    }
    if (views.length > 1) {
      lines.add(_Line(0, 'View $viewId:'));
    }
    final int base = views.length > 1 ? 1 : 0;
    if (interactive) {
      _collectInteractive(start, base, lines);
    } else {
      _collectTree(start, base, 0, depth, lines, isRoot: true);
    }
  }
  if (under != null && lines.isEmpty) {
    return <String>[];
  }
  return _render(lines, maxLines, 'nodes');
}

/// The ids `flute dump semantics` prints, other than each view's root.
///
/// `dump app` only shows refs from this set, so every ref it prints can be
/// found in the semantics dump too.
Set<int> shownSemanticsIds(Map<String, Object?> dump) {
  final ids = <int>{};
  void visit(SemanticsEntry node) {
    if (!node.isHidden && node.isMeaningful) {
      ids.add(node.id);
    }
    node.children.forEach(visit);
  }

  for (final Map<String, Object?> view
      in (dump['views']! as List<Object?>).cast<Map<String, Object?>>()) {
    SemanticsEntry.fromJson(view['root']! as Map<String, Object?>).children.forEach(visit);
  }
  return ids;
}

SemanticsEntry? _findEntry(SemanticsEntry node, int id) {
  if (node.id == id) {
    return node;
  }
  for (final SemanticsEntry child in node.children) {
    final SemanticsEntry? found = _findEntry(child, id);
    if (found != null) {
      return found;
    }
  }
  return null;
}

void _collectTree(
  SemanticsEntry node,
  int indent,
  int level,
  int? maxDepth,
  List<_Line> lines, {
  bool isRoot = false,
}) {
  final bool shown = isRoot || (!node.isHidden && node.isMeaningful);
  int childIndent = indent;
  int childLevel = level;
  if (shown) {
    if (maxDepth != null && level >= maxDepth) {
      return;
    }
    lines.add(_Line(indent, node.describe(isRoot: isRoot)));
    childIndent = indent + 1;
    childLevel = level + 1;
  }
  for (final SemanticsEntry child in node.children) {
    _collectTree(child, childIndent, childLevel, maxDepth, lines);
  }
}

void _collectInteractive(SemanticsEntry node, int indent, List<_Line> lines) {
  if (!node.isHidden && node.isInteractive) {
    lines.add(_Line(indent, node.describe()));
  }
  for (final SemanticsEntry child in node.children) {
    _collectInteractive(child, indent, lines);
  }
}

List<String> _render(List<_Line> lines, int maxLines, String noun) {
  final bool capped = maxLines > 0 && lines.length > maxLines;
  final Iterable<_Line> shown = capped ? lines.take(maxLines) : lines;
  return <String>[
    for (final _Line line in shown) '${'  ' * line.depth}${line.text}',
    if (capped)
      '… ${_thousands(lines.length - maxLines)} more $noun; use --depth, --under or --max-lines',
  ];
}

String _thousands(int n) {
  final String digits = '$n';
  final buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// One line describing a widget from `flute_dump_widgets` or `flute_find`.
///
/// With [knownIds], only refs in that set are shown.
String describeWidget(Map<String, Object?> widget, {Set<int>? knownIds}) {
  final buffer = StringBuffer('- ');
  final Object? id = widget['id'];
  if (id != null && (knownIds == null || knownIds.contains(id))) {
    buffer.write('s#$id ');
  }
  buffer.write(widget['type']);
  final Object? text = widget['text'];
  if (text is String && text.isNotEmpty) {
    buffer.write(' ${quote(text)}');
  }
  final Object? key = widget['key'];
  if (key != null) {
    buffer.write(' (key: $key)');
  }
  return buffer.toString();
}

/// Formats a `flute_dump_widgets` result.
List<String> formatWidgets(
  Map<String, Object?> dump, {
  int? depth,
  int? under,
  int maxLines = defaultMaxLines,
  Set<int>? knownIds,
}) {
  var roots = <Map<String, Object?>>[
    for (final Object? root in dump['roots']! as List<Object?>) root! as Map<String, Object?>,
  ];
  if (under != null) {
    final Map<String, Object?>? found = _findWidget(roots, under);
    if (found == null) {
      return <String>[];
    }
    roots = <Map<String, Object?>>[found];
  }
  final lines = <_Line>[];
  void visit(Map<String, Object?> widget, int level) {
    if (depth != null && level >= depth) {
      return;
    }
    lines.add(_Line(level, describeWidget(widget, knownIds: knownIds)));
    for (final Object? child in widget['children'] as List<Object?>? ?? const <Object?>[]) {
      visit(child! as Map<String, Object?>, level + 1);
    }
  }

  for (final Map<String, Object?> root in roots) {
    visit(root, 0);
  }
  return _render(lines, maxLines, 'widgets');
}

Map<String, Object?>? _findWidget(List<Map<String, Object?>> widgets, int id) {
  for (final Map<String, Object?> widget in widgets) {
    if (widget['id'] == id) {
      return widget;
    }
    final Map<String, Object?>? found = _findWidget(<Map<String, Object?>>[
      for (final Object? child in widget['children'] as List<Object?>? ?? const <Object?>[])
        child! as Map<String, Object?>,
    ], id);
    if (found != null) {
      return found;
    }
  }
  return null;
}

/// Extracts the error banner Flutter prints for an uncaught exception, if
/// [lines] contain one, cut to [maxLines] lines.
List<String>? findErrorBanner(List<String> lines, {int maxLines = 10}) {
  final int start = lines.indexWhere((String line) => line.contains('╡ EXCEPTION CAUGHT BY'));
  if (start < 0) {
    return null;
  }
  return lines.skip(start).take(maxLines).toList();
}
