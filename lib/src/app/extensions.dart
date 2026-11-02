import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_driver/flutter_driver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../protocol/commands.dart';
import 'semantics.dart';
import 'widgets.dart';

class FluteHelloExtension extends CommandExtension {
  @override
  String get commandKind => FluteHello.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteHello.deserialize(params);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    return FluteResult(<String, dynamic>{
      'protocol': fluteProtocolVersion,
      'version': flutePackageVersion,
      'platform': defaultTargetPlatform.name,
    });
  }
}

class FluteDumpSemanticsExtension extends CommandExtension {
  @override
  String get commandKind => FluteDumpSemantics.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteDumpSemantics.deserialize(params);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    return FluteResult(<String, dynamic>{'views': dumpSemanticsTrees()});
  }
}

class FluteDumpWidgetsExtension extends CommandExtension {
  @override
  String get commandKind => FluteDumpWidgets.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteDumpWidgets.deserialize(params);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    return FluteResult(<String, dynamic>{'roots': dumpWidgetTree()});
  }
}

class FluteTapExtension extends CommandExtension {
  @override
  String get commandKind => FluteTap.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteTap.deserialize(params);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    final tap = command as FluteTap;
    LocatedNode? located = findSemanticsNode(tap.id);
    if (located == null) {
      return FluteResult.error('s#${tap.id} is gone.');
    }

    // Scroll the node into view first if its center is offscreen.
    final Size viewSize = located.view.size;
    if (!(Offset.zero & viewSize).contains(located.rect.center)) {
      findSemanticsOwner(located.view, tap.id)?.showOnScreen();
      await _settle();
      located = findSemanticsNode(tap.id);
      if (located == null) {
        return FluteResult.error('s#${tap.id} is gone after scrolling it into view.');
      }
      if (!(Offset.zero & viewSize).contains(located.rect.center)) {
        return FluteResult.error('s#${tap.id} is offscreen and could not be scrolled into view.');
      }
    }

    final Offset center = located.rect.center;
    final String? covered = _coveringWidget(located, center);
    if (covered != null) {
      return FluteResult.error('s#${tap.id} is covered by $covered.');
    }

    await prober.tapAt(center);

    if (tap.waitForTextInput && !await _waitForTextField(tap.timeout)) {
      return FluteResult.error('s#${tap.id} did not focus a text field.');
    }
    return const FluteResult(<String, dynamic>{});
  }
}

/// Returns a description of the widget that would receive a tap at [center]
/// instead of the node's own render object, or null if the tap reaches it.
String? _coveringWidget(LocatedNode located, Offset center) {
  final RenderObject? owner = findSemanticsOwner(located.view, located.node.id);
  if (owner == null) {
    return null;
  }
  final result = HitTestResult();
  RendererBinding.instance.hitTestInView(result, center, located.view.flutterView.viewId);
  final List<HitTestEntry> path = result.path.toList();
  if (path.isEmpty) {
    return null;
  }
  for (final HitTestEntry entry in path) {
    if (identical(entry.target, owner)) {
      return null;
    }
  }

  // If the hit landed on an ancestor of the owner, nothing covers the node;
  // that spot just isn't hit-testable, and the tap goes where a user's would.
  final Object deepest = path.first.target;
  if (deepest is RenderObject) {
    for (RenderObject? o = owner.parent; o != null; o = o.parent) {
      if (identical(o, deepest)) {
        return null;
      }
    }
    return _describeRenderObject(deepest);
  }
  return deepest.runtimeType.toString();
}

String _describeRenderObject(RenderObject object) {
  // Prefer the nearest widget the app created; fall back to the creator.
  final Object? creator = object.debugCreator;
  if (creator is DebugCreator) {
    Widget? local;
    creator.element.visitAncestorElements((Element ancestor) {
      if (debugIsWidgetLocalCreation(ancestor.widget)) {
        local = ancestor.widget;
        return false;
      }
      return true;
    });
    final Widget direct = creator.element.widget;
    if (debugIsWidgetLocalCreation(direct)) {
      return direct.runtimeType.toString();
    }
    if (local != null) {
      return '${local.runtimeType} (${direct.runtimeType})';
    }
    return direct.runtimeType.toString();
  }
  return object.runtimeType.toString();
}

/// Pumps frames until none are scheduled, for up to two seconds.
Future<void> _settle() async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  do {
    await SchedulerBinding.instance.endOfFrame;
  } while (SchedulerBinding.instance.hasScheduledFrame && DateTime.now().isBefore(deadline));
}

Future<bool> _waitForTextField(Duration? timeout) async {
  final deadline = DateTime.now().add(timeout ?? const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (_hasFocusedTextField()) {
      // Let the field open its input connection.
      await SchedulerBinding.instance.endOfFrame;
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

bool _hasFocusedTextField() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  return context != null && context.findAncestorStateOfType<EditableTextState>() != null;
}

class FluteFindExtension extends CommandExtension {
  @override
  String get commandKind => FluteFind.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteFind.deserialize(params, finderFactory);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    final find = command as FluteFind;
    final Finder finder = finderFactory.createFinder(find.finder);
    final matches = <Map<String, Object?>>[];
    for (final Element element in finder.evaluate()) {
      final RenderObject? renderObject = element.renderObject;
      Rect? rect;
      if (renderObject is RenderBox && renderObject.hasSize && renderObject.attached) {
        rect = MatrixUtils.transformRect(
          renderObject.getTransformTo(null),
          Offset.zero & renderObject.size,
        );
      }
      matches.add(<String, Object?>{
        'type': element.widget.runtimeType.toString(),
        'text': ?textPreview(element.widget),
        if (element.widget.key != null) 'key': describeKey(element.widget.key!),
        if (rect != null) 'rect': <double>[rect.left, rect.top, rect.right, rect.bottom],
        'id': ?(renderObject == null ? null : semanticsIdFor(renderObject)),
      });
    }
    return FluteResult(<String, dynamic>{'matches': matches});
  }
}

class FluteWaitIdleExtension extends CommandExtension {
  @override
  String get commandKind => FluteWaitIdle.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteWaitIdle.deserialize(params);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    final deadline = DateTime.now().add((command as FluteWaitIdle).budget);
    final SchedulerBinding scheduler = SchedulerBinding.instance;
    while (scheduler.hasScheduledFrame || scheduler.transientCallbackCount > 0) {
      if (DateTime.now().isAfter(deadline)) {
        return const FluteResult(<String, dynamic>{'idle': false});
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return const FluteResult(<String, dynamic>{'idle': true});
  }
}

class FluteWaitRasterizedExtension extends CommandExtension {
  @override
  String get commandKind => FluteWaitRasterized.commandKind;

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) => FluteWaitRasterized.deserialize(params);

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    // Force a new frame and wait for the engine to report its timing. Frames
    // rasterize in order, so once this one is reported, every earlier frame
    // is on screen.
    final reported = Completer<void>();
    void onTimings(List<ui.FrameTiming> timings) {
      if (!reported.isCompleted) {
        reported.complete();
      }
    }

    SchedulerBinding.instance.addTimingsCallback(onTimings);
    try {
      SchedulerBinding.instance.scheduleForcedFrame();
      await SchedulerBinding.instance.endOfFrame;
      await reported.future.timeout(command.timeout ?? const Duration(seconds: 2));
    } on TimeoutException {
      return FluteResult.error('No rasterized frame was reported.');
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
    }
    return const FluteResult(<String, dynamic>{});
  }
}
