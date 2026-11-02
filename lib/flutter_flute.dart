/// In-app support for the `flute` CLI.
///
/// Apps do not call this directly: `flute run` generates an entrypoint that
/// calls [enableFlute] before the app's own `main()`.
library;

export 'src/app/enable.dart' show enableFlute;
