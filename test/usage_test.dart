import 'package:args/args.dart';
import 'package:flutter_flute/src/cli/common.dart';
import 'package:flutter_flute/src/cli/runner.dart';
import 'package:flutter_flute/src/cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';

({String text, int exitCode})? _help(List<String> arguments) =>
    helpFor(buildParser().parse(arguments), hadArguments: arguments.isNotEmpty);

void main() {
  test('flute help lists every visible command', () {
    final String usage = generalUsage();
    for (final CommandSpec spec in commands) {
      expect(usage.contains('  ${spec.name} '), !spec.hidden, reason: spec.name);
    }
  });

  for (final CommandSpec spec in commands.where((CommandSpec c) => !c.hidden)) {
    test('${spec.name} --help describes the command and every option', () {
      final String text = commandUsage(spec);
      expect(text, startsWith('${spec.summary}.'));
      expect(text, contains('flute ${spec.usage.first}'));

      final ArgParser parser = spec.buildParser();
      for (final Option option in parser.options.values) {
        expect(option.help, isNotNull, reason: '--${option.name} has no help text');
        expect(text, contains('--${option.name}'));
      }
      for (final String example in spec.examples) {
        expect(example, startsWith('flute ${spec.name}'));
      }
    });
  }

  for (final CommandSpec spec in commands) {
    test('${spec.name} accepts --verbose and -v', () {
      for (final List<String> arguments in <List<String>>[
        <String>[spec.name, '--verbose'],
        <String>[spec.name, '-v'],
        <String>['--verbose', spec.name],
      ]) {
        final ArgResults top = buildParser().parse(arguments);
        expect(top.command!.flag('verbose') || top.flag('verbose'), isTrue, reason: '$arguments');
      }
      expect(commandUsage(spec), contains('-v, --verbose'));
    });
  }

  test('--timeout help states each command\'s default', () {
    expect(commandUsage(findCommand('run')!), contains('Defaults to 5m.'));
    expect(commandUsage(findCommand('tap')!), contains('Defaults to 10s.'));
  });

  group('helpFor', () {
    test('<command> --help and -h print that command', () {
      expect(_help(<String>['tap', '--help'])!.text, commandUsage(findCommand('tap')!));
      expect(_help(<String>['dump', '-h'])!.text, commandUsage(findCommand('dump')!));
      expect(_help(<String>['tap', '--help'])!.exitCode, ExitCode.success);
    });

    test('--help works with arguments a command would reject', () {
      expect(_help(<String>['fill', 's#5', '--help'])!.text, commandUsage(findCommand('fill')!));
    });

    test('help <command> prints that command', () {
      expect(_help(<String>['help', 'wait'])!.text, commandUsage(findCommand('wait')!));
    });

    test('help, --help and bare flute print the general usage', () {
      expect(_help(<String>['help'])!.text, generalUsage());
      expect(_help(<String>['--help'])!.exitCode, ExitCode.success);
      expect(_help(<String>[])!.exitCode, ExitCode.success);
    });

    test('options without a command are a usage error', () {
      expect(_help(<String>['--session', 'a'])!.exitCode, ExitCode.usage);
    });

    test('help for an unknown command is a usage error', () {
      expect(
        () => _help(<String>['help', 'nope']),
        throwsA(
          isA<FluteException>().having(
            (FluteException e) => e.exitCode,
            'exitCode',
            ExitCode.usage,
          ),
        ),
      );
    });

    test('commands without --help run normally', () {
      expect(_help(<String>['tap', 's#7']), isNull);
    });
  });

  test('wrapText wraps prose and keeps indented lines whole', () {
    final String wrapped = wrapText('${'word ' * 30}\n  flutter pub add --dev flutter_flute', 40);
    final List<String> lines = wrapped.split('\n');
    expect(
      lines.where((String l) => !l.startsWith('  ')).every((String l) => l.length <= 40),
      isTrue,
    );
    expect(lines.last, '  flutter pub add --dev flutter_flute');
  });
}
