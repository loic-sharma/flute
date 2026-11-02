import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// Returns the semantics tree of every view as JSON, unpruned.
///
/// Pruning and formatting happen in the CLI so they can be tested against
/// recorded dumps.
List<Map<String, Object?>> dumpSemanticsTrees() {
  final views = <Map<String, Object?>>[];
  for (final RenderView view in RendererBinding.instance.renderViews) {
    final SemanticsNode? root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) {
      continue;
    }
    views.add(<String, Object?>{
      'viewId': view.flutterView.viewId,
      'root': _describeNode(root, view.flutterView.devicePixelRatio),
    });
  }
  return views;
}

Map<String, Object?> _describeNode(SemanticsNode node, double devicePixelRatio) {
  final SemanticsData data = node.getSemanticsData();
  // Traversal order, the order a screen reader follows. visitChildren would
  // give paint order, which puts an app bar after the body it overlays.
  final children = <Map<String, Object?>>[
    for (final SemanticsNode child in node.debugListChildrenInOrder(
      DebugSemanticsDumpOrder.traversalOrder,
    ))
      // Merged children are already folded into this node's data.
      if (!child.isMergedIntoParent) _describeNode(child, devicePixelRatio),
  ];
  final Rect rect = globalRect(node, devicePixelRatio);
  return <String, Object?>{
    'id': node.id,
    'role': data.role.name,
    'flags': describeFlags(data.flagsCollection),
    'actions': <String>[
      for (final ui.SemanticsAction action in ui.SemanticsAction.values)
        if (data.hasAction(action)) action.name,
    ],
    if (data.label.isNotEmpty) 'label': data.label,
    if (data.value.isNotEmpty) 'value': data.value,
    if (data.hint.isNotEmpty) 'hint': data.hint,
    if (data.tooltip.isNotEmpty) 'tooltip': data.tooltip,
    if (data.identifier.isNotEmpty) 'identifier': data.identifier,
    'rect': <double>[rect.left, rect.top, rect.right, rect.bottom],
    if (children.isNotEmpty) 'children': children,
  };
}

/// The flags that are set on a node, as short names.
List<String> describeFlags(ui.SemanticsFlags flags) {
  return <String>[
    if (flags.isButton) 'button',
    if (flags.isTextField) 'textField',
    if (flags.isLink) 'link',
    if (flags.isHeader) 'header',
    if (flags.isImage) 'image',
    if (flags.isSlider) 'slider',
    if (flags.isKeyboardKey) 'keyboardKey',
    if (flags.scopesRoute) 'scopesRoute',
    if (flags.namesRoute) 'namesRoute',
    if (flags.isHidden) 'hidden',
    if (flags.isObscured) 'obscured',
    if (flags.isMultiline) 'multiline',
    if (flags.isReadOnly) 'readOnly',
    if (flags.isLiveRegion) 'liveRegion',
    if (flags.isInMutuallyExclusiveGroup) 'radio',
    if (flags.hasImplicitScrolling) 'scrollable',
    ...switch (flags.isChecked) {
      ui.CheckedState.none => const <String>[],
      ui.CheckedState.isTrue => const <String>['checkable', 'checked'],
      ui.CheckedState.isFalse => const <String>['checkable'],
      ui.CheckedState.mixed => const <String>['checkable', 'mixed'],
    },
    ..._tristate(flags.isToggled, 'toggleable', 'toggled'),
    ..._tristate(flags.isSelected, null, 'selected'),
    ..._tristate(flags.isFocused, 'focusable', 'focused'),
    ..._tristate(flags.isExpanded, 'expandable', 'expanded'),
    ..._tristate(flags.isEnabled, null, null, falseName: 'disabled'),
    ..._tristate(flags.isRequired, null, 'required'),
  ];
}

List<String> _tristate(ui.Tristate value, String? applicable, String? onName, {String? falseName}) {
  return switch (value) {
    ui.Tristate.none => const <String>[],
    ui.Tristate.isTrue => <String>[?applicable, ?onName],
    ui.Tristate.isFalse => <String>[?applicable, ?falseName],
  };
}

/// The node's rect in global logical pixels.
Rect globalRect(SemanticsNode node, double devicePixelRatio) {
  // Transforms up the chain end in physical pixels: the root node's transform
  // includes the view's device pixel ratio.
  Rect rect = node.rect;
  for (SemanticsNode? n = node; n != null; n = n.parent) {
    final Matrix4? transform = n.transform;
    if (transform != null) {
      rect = MatrixUtils.transformRect(transform, rect);
    }
  }
  return Rect.fromLTRB(
    rect.left / devicePixelRatio,
    rect.top / devicePixelRatio,
    rect.right / devicePixelRatio,
    rect.bottom / devicePixelRatio,
  );
}

/// A semantics node that is live in some view, with the view it belongs to.
class LocatedNode {
  LocatedNode(this.node, this.view);

  final SemanticsNode node;
  final RenderView view;

  Rect get rect => globalRect(node, view.flutterView.devicePixelRatio);
}

/// Finds a live semantics node by id in any view.
LocatedNode? findSemanticsNode(int id) {
  for (final RenderView view in RendererBinding.instance.renderViews) {
    final SemanticsNode? root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) {
      continue;
    }
    final SemanticsNode? found = _find(root, id);
    if (found != null) {
      return LocatedNode(found, view);
    }
  }
  return null;
}

SemanticsNode? _find(SemanticsNode node, int id) {
  if (node.id == id) {
    return node;
  }
  SemanticsNode? found;
  node.visitChildren((SemanticsNode child) {
    found = _find(child, id);
    return found == null;
  });
  return found;
}

/// Finds the render object that owns the semantics node [id] under [view].
RenderObject? findSemanticsOwner(RenderView view, int id) {
  RenderObject? found;
  void visit(RenderObject object) {
    if (found != null) {
      return;
    }
    if (object.debugSemantics?.id == id) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }

  visit(view);
  return found;
}

/// The id of the semantics node that represents [object] in the tree: the
/// node it owns, or the node it is merged into, or the nearest ancestor's.
int? semanticsIdFor(RenderObject object, {bool searchAncestors = true}) {
  for (RenderObject? o = object; o != null; o = searchAncestors ? o.parent : null) {
    SemanticsNode? node = o.debugSemantics;
    if (node != null) {
      while (node!.isMergedIntoParent && node.parent != null) {
        node = node.parent;
      }
      return node.id;
    }
  }
  return null;
}
