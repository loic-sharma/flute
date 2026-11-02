import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'semantics.dart';

/// Returns the element tree as JSON, keeping only widgets created by the
/// app's own code.
///
/// Uses the same test as the inspector's summary tree. Widgets created inside
/// `package:flutter` are folded into their nearest kept ancestor.
List<Map<String, Object?>> dumpWidgetTree() {
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return const <Map<String, Object?>>[];
  }
  return _collect(root, _semanticsIdsByWidget());
}

/// Maps each kept element to the semantics node it is closest to.
///
/// Every semantics node goes to the nearest app-created widget above the
/// render object that owns it, so a `TextField` gets its field's node and a
/// button's `Text` gets the button's merged node. When several nodes land on
/// one element, the topmost wins.
Map<Element, int> _semanticsIdsByWidget() {
  final ids = <Element, int>{};
  void visit(RenderObject object) {
    final int? id = object.debugSemantics == null
        ? null
        : semanticsIdFor(object, searchAncestors: false);
    final Object? creator = object.debugCreator;
    if (id != null && creator is DebugCreator) {
      Element? kept;
      if (debugIsWidgetLocalCreation(creator.element.widget)) {
        kept = creator.element;
      } else {
        creator.element.visitAncestorElements((Element ancestor) {
          if (debugIsWidgetLocalCreation(ancestor.widget)) {
            kept = ancestor;
            return false;
          }
          return true;
        });
      }
      if (kept != null) {
        ids.putIfAbsent(kept!, () => id);
      }
    }
    object.visitChildren(visit);
  }

  for (final RenderView view in RendererBinding.instance.renderViews) {
    visit(view);
  }
  return ids;
}

List<Map<String, Object?>> _collect(Element element, Map<Element, int> ids) {
  final children = <Map<String, Object?>>[];
  element.visitChildren((Element child) => children.addAll(_collect(child, ids)));

  if (!debugIsWidgetLocalCreation(element.widget)) {
    return children;
  }
  return <Map<String, Object?>>[_describe(element, ids[element], children)];
}

Map<String, Object?> _describe(
  Element element,
  int? semanticsId,
  List<Map<String, Object?>> children,
) {
  final Widget widget = element.widget;
  final String? text = textPreview(widget);
  return <String, Object?>{
    'type': widget.runtimeType.toString(),
    if (widget.key != null) 'key': describeKey(widget.key!),
    'text': ?text,
    'id': ?semanticsId,
    if (children.isNotEmpty) 'children': children,
  };
}

/// A short description of a key, without the `[<'...'>]` noise.
String describeKey(Key key) {
  if (key is ValueKey<String>) {
    return key.value;
  }
  if (key is ValueKey) {
    return '${key.value}';
  }
  return key.toString();
}

/// The text a widget shows, for the widgets where that is easy to tell.
String? textPreview(Widget widget) {
  return switch (widget) {
    Text(:final String? data?) => data,
    Text(textSpan: final InlineSpan span) => span.toPlainText(),
    RichText(:final InlineSpan text) => text.toPlainText(),
    EditableText(:final TextEditingController controller) => controller.text,
    _ => null,
  };
}
