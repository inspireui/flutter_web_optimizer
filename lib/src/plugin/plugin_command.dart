import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as path;
import 'template_plugin.dart';

class PluginCommand extends Command<void> {
  PluginCommand() {
    argParser.addOption(
      'path',
      help: 'custom plugin file path',
      mandatory: true,
    );
  }

  @override
  String get description =>
      'auto generate template plugin for flutter web optimizer';

  @override
  String get name => 'plugin';

  String get pluginPath => argResults!['path'];

  @override
  FutureOr<void> run() async {
    String basename = path.basenameWithoutExtension(pluginPath);
    if (!RegExp(r'^.+_plugin$').hasMatch(basename)) {
      basename += '_plugin';
    }
    basename = path.setExtension(basename, '.dart');

    final String fullPluginPath =
        path.join(path.context.current, path.dirname(pluginPath), basename);

    File(fullPluginPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(templatePluginSourceCode);
  }
}
