import 'package:flutter_driver/driver_extension.dart';

import 'extensions.dart';

/// Turns on the Flutter Driver extension with `flute`'s custom commands.
///
/// Call this before `runApp`. It installs Flutter Driver's binding, which
/// uses a test binary messenger and emulates text entry, so the platform
/// keyboard never shows.
void enableFlute() {
  enableFlutterDriverExtension(
    silenceErrors: false,
    enableTextEntryEmulation: true,
    commands: <CommandExtension>[
      FluteHelloExtension(),
      FluteDumpSemanticsExtension(),
      FluteDumpWidgetsExtension(),
      FluteTapExtension(),
      FluteFindExtension(),
      FluteWaitIdleExtension(),
      FluteWaitRasterizedExtension(),
    ],
  );
}
