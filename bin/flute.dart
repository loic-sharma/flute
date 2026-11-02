import 'dart:io';

import 'package:flutter_flute/src/cli/runner.dart';

Future<void> main(List<String> arguments) async {
  final int code = await runFlute(arguments);
  await Future.wait<void>(<Future<void>>[stdout.flush(), stderr.flush()]);
  exit(code);
}
