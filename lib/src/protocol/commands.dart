// Commands and results shared by the in-app library and the daemon.
//
// This library must stay pure Dart: the daemon imports it on the host VM.
import 'package:flutter_driver/flutter_driver.dart';

/// Bumped on any breaking change to the commands below. The daemon refuses to
/// drive an app whose major version differs.
const int fluteProtocolVersion = 1;

/// The `flutter_flute` package version, reported by `flute_hello`.
const String flutePackageVersion = '0.1.0';

/// Asks the app for its protocol version.
class FluteHello extends Command {
  const FluteHello({super.timeout});

  FluteHello.deserialize(super.json) : super.deserialize();

  static const String commandKind = 'flute_hello';

  @override
  String get kind => commandKind;

  @override
  bool get requiresRootWidgetAttached => false;
}

/// Asks the app for the full semantics tree of every view.
class FluteDumpSemantics extends Command {
  const FluteDumpSemantics({super.timeout});

  FluteDumpSemantics.deserialize(super.json) : super.deserialize();

  static const String commandKind = 'flute_dump_semantics';

  @override
  String get kind => commandKind;
}

/// Asks the app for its element tree, pruned to widgets created by the app.
class FluteDumpWidgets extends Command {
  const FluteDumpWidgets({super.timeout});

  FluteDumpWidgets.deserialize(super.json) : super.deserialize();

  static const String commandKind = 'flute_dump_widgets';

  @override
  String get kind => commandKind;
}

/// Taps the center of a semantics node with a real pointer event.
///
/// With [waitForTextInput], the command waits after the tap until an editable
/// text field has focus, so `EnterText` can follow.
class FluteTap extends Command {
  const FluteTap(this.id, {this.waitForTextInput = false, super.timeout});

  FluteTap.deserialize(super.json)
    : id = int.parse(json['id']!),
      waitForTextInput = json['waitForTextInput'] == 'true',
      super.deserialize();

  static const String commandKind = 'flute_tap';

  final int id;
  final bool waitForTextInput;

  @override
  String get kind => commandKind;

  @override
  Map<String, String> serialize() =>
      super.serialize()
        ..addAll(<String, String>{'id': '$id', 'waitForTextInput': '$waitForTextInput'});
}

/// Evaluates a built-in finder and describes each match.
class FluteFind extends CommandWithTarget {
  FluteFind(super.finder, {super.timeout});

  FluteFind.deserialize(super.json, super.finderFactory) : super.deserialize();

  static const String commandKind = 'flute_find';

  @override
  String get kind => commandKind;
}

/// Waits up to [budget] until no frame is scheduled and no animation is
/// running. Reports `{"idle": false}` rather than failing when the app stays
/// busy, as it does while an animation loops.
class FluteWaitIdle extends Command {
  const FluteWaitIdle(this.budget);

  FluteWaitIdle.deserialize(super.json)
    : budget = Duration(milliseconds: int.parse(json['budget']!)),
      super.deserialize();

  static const String commandKind = 'flute_wait_idle';

  final Duration budget;

  @override
  String get kind => commandKind;

  @override
  Map<String, String> serialize() => super.serialize()..['budget'] = '${budget.inMilliseconds}';
}

/// Waits until the engine reports a frame as rasterized.
class FluteWaitRasterized extends Command {
  const FluteWaitRasterized({super.timeout});

  FluteWaitRasterized.deserialize(super.json) : super.deserialize();

  static const String commandKind = 'flute_wait_rasterized';

  @override
  String get kind => commandKind;
}

/// A JSON result. Expected failures set `error` instead of throwing, so the
/// CLI can print them without a stack trace.
class FluteResult extends Result {
  const FluteResult(this.data);

  FluteResult.error(String message) : data = <String, dynamic>{'error': message};

  final Map<String, dynamic> data;

  @override
  Map<String, dynamic> toJson() => data;
}
