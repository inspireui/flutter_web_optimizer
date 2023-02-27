import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;

import '../../flutter_web_optimizer.dart';
import '../common/logger.dart';
import '../common/model.dart';
import 'flutter.js.dart';

class OptimizeCommand extends Command<void> {
  OptimizeCommand() {
    argParser
      ..addOption(
        'asset-base',
        help: 'asset base url，end with /，eq：http://127.0.0.1:8080/',
        mandatory: true,
      )
      ..addOption(
        'web-output',
        help: 'web artifacts output dir，'
            'only support relative path，root path is [path.context.current]，'
            'eq：build/web',
      )
      ..addOption(
        'plugin',
        help: 'plugin file path，'
            'only support relative path，root path is [path.context.current]，'
            'eq：flutter_web_optimize_plugin.dart',
      )
      ..addFlag(
        'enable-pwa',
        help: 'enable PWA service worker',
        defaultsTo: true,
      );
  }

  @override
  String get description =>
      'solve web page loading slow and browser cache problem';

  @override
  String get name => 'optimize';

  /// 资源路径，一般是cdn地址
  late String _assetBase;

  /// Web构建产物路径
  late String _webOutput;

  /// plugin 文件路径，支持处理资源上传cdn等操作
  late String _plugin;

  /// isolate通信，发送信息
  SendPort? _sendPort;

  /// isolate通信，接收信息
  ReceivePort? _receivePort;

  /// isolate消息
  Stream<IsolateMessageProtocol>? _message;

  // 需要hash的文件
  final Map<String, String> _hashFiles = <String, String>{};

  // 哈希化后的文件清单
  final Map<String, String> _hashFileManifest = <String, String>{};

  @override
  FutureOr<void> run() async {
    Logger.info('start web optimize inspireui');

    await _parseArgs();

    await _initIsolate();

    final Directory outputDir = Directory(_webOutput);
    if (!outputDir.existsSync()) {
      // 构建产物目录不存在，直接退出
      Logger.error('web artifacts output dir is not exist');
      exit(2);
    }

    await _splitMainDartJS(outputDir);

    _replaceFlutterJS();

    _hashMainDartJs();

    _removeFonts();

    Logger.info('end web optimizes');
  }

  Future<void> _parseArgs() async {
    /// 资源路径，一般是cdn地址
    _assetBase = argResults!['asset-base'] ?? '';

    /// Web构建产物路径
    final String? webOutput = argResults!['web-output'];
    if (webOutput?.isNotEmpty ?? false) {
      _webOutput = path.join(path.context.current, webOutput!);
    } else {
      _webOutput = path.join(path.context.current, 'build', 'web');
    }

    /// plugin 文件路径，支持处理资源上传cdn等操作
    final String? plugin = argResults!['plugin'];
    if (plugin?.isEmpty ?? true) {
      _plugin = '';
      return;
    }
    if (path.extension(plugin!).isNotEmpty) {
      /// Uri
      _plugin = path.join(path.context.current, plugin);
    } else {
      /// Not Uri
      final PackageConfig? packageConfig =
          await findPackageConfig(Directory.current);
      if (packageConfig == null) {
        _plugin = '';
        return;
      }
      try {
        final Package package = packageConfig.packages
            .singleWhere((Package element) => element.name == plugin);
        _plugin = path.join(package.packageUriRoot.toFilePath(), plugin);
        _plugin = path.setExtension(_plugin, '.dart');
      } catch (_) {
        _plugin = '';
      }
    }
    if (!File(_plugin).existsSync()) {
      throw Exception('plugin args is invalid!!!');
    }
  }

  /// 初始化isolate通信
  Future<void> _initIsolate() {
    if (_plugin.isEmpty) {
      return Future<void>.value();
    }

    final Completer<void> completer = Completer<void>();
    final StreamController<IsolateMessageProtocol> controller =
        StreamController<IsolateMessageProtocol>.broadcast();
    _message = controller.stream;

    _receivePort ??= ReceivePort();
    _receivePort!.listen((dynamic message) {
      if (message is SendPort) {
        _sendPort = message;
        completer.complete();
      }

      if (message is Map<String, Object>) {
        Logger.info('server isolate get message: $message');
        controller.add(IsolateMessageProtocol.fromMap(message));
      }
    });

    Isolate.spawnUri(
      Uri.file(_plugin),
      argResults!.arguments,
      _receivePort!.sendPort,
    );
    return completer.future;
  }

  /// 释放isolate通信
  void _disposeIsolate() {
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _message = null;
  }

  /// 拆分 main.dart.js
  Future<void> _splitMainDartJS(Directory outputDir) async {
    // 写入单个文件
    Future<bool> writeSingleFile({
      required File file,
      required String filename,
      required int startIndex,
      required endIndex,
    }) {
      final Completer<bool> completer = Completer();
      final File f = File(path.join(file.parent.path, filename));
      if (f.existsSync()) {
        f.deleteSync();
      }
      final RandomAccessFile raf = f.openSync(mode: FileMode.write);
      final Stream<List<int>> inputStream = file.openRead(startIndex, endIndex);
      inputStream.listen(
        (List<int> data) {
          raf.writeFromSync(data);
        },
        onDone: () {
          raf.flushSync();
          raf.closeSync();
          completer.complete(true);
        },
        onError: (dynamic data) {
          raf.flushSync();
          raf.closeSync();
          completer.complete(false);
        },
      );
      return completer.future;
    }

    final File file = outputDir.listSync().whereType<File>().singleWhere(
        (File entity) => path.basename(entity.path) == 'main.dart.js');

    /// 针对xhr加载动态js文件，插入『@ sourceURL』标记，方便调试
    file
        .openSync(mode: FileMode.append)
        .writeStringSync('\n\n//@ sourceURL=main.dart.js\n');
    const int totalChunk = 6;
    final Uint8List bytes = file.readAsBytesSync();
    final int chunkSize = (bytes.length / totalChunk).ceil();
    final List<Future<bool>> futures = List<Future<bool>>.generate(
      totalChunk,
      (int index) {
        _hashFiles['main.dart_$index.js'] = 'main.dart_$index.js';
        return writeSingleFile(
          file: file,
          filename: 'main.dart_$index.js',
          startIndex: index * chunkSize,
          endIndex: (index + 1) * chunkSize,
        );
      },
    );

    await Future.wait(futures);
    file.deleteSync();
  }

  /// 替换 flutter.js
  void _replaceFlutterJS() {
    final File file = File('$_webOutput/flutter.js');
    if (!file.existsSync()) {
      file.createSync();
    }
    file.writeAsStringSync(flutterJSSourceCode);
  }

  /// md5文件
  String _md5File(File file) {
    final Uint8List bytes = file.readAsBytesSync();
    // 截取8位即可
    final String md5Hash = crypto.md5.convert(bytes).toString().substring(0, 8);

    // 文件名使用hash值
    final String basename = path.basenameWithoutExtension(file.path);
    final String extension = path.extension(file.path);
    final String filename = '$basename.$md5Hash$extension';
    return filename;
  }

  /// 资源hash化
  void _hashMainDartJs() {
    var files = <String, String>{};
    String flutterJS = '';

    void hashJsFileName() {
      Directory(_webOutput)
          .listSync()
          .whereType<File>() // 文件类型
          .where((File file) {
        final RegExp regExp = RegExp(
            r'(main\.dart(.*)\.js)|(favicon.png)|(flutter.js)|(manifest.json)');
        final String filename = path.basename(file.path);
        return regExp.hasMatch(filename);
      }).forEach((File file) {
        final String filename = _md5File(file);
        if (path.basename(file.path) == 'flutter.js') {
          flutterJS = filename;
        }
        if (_hashFiles[path.basename(file.path)] != null) {
          _hashFiles[path.basename(file.path)] = filename;
        }
        files[file.path] = path.join(path.dirname(file.path), filename);
      });
    }

    void replaceDataJSFile() {
      files.forEach((String key, String value) {
        var file = File(key);
        String contents = file.readAsStringSync();
        files.forEach((String key, String value) {
          var oldName = path.basename(key);
          var newName = path.basename(value);
          contents = contents.replaceAll(RegExp(oldName), newName);
        });
        file.writeAsStringSync(contents);
      });
    }

    void addIndexHtmlAsset() {
      const JsonEncoder jsonEncoder = JsonEncoder.withIndent('  ');
      final String flutterWebOptimizer = flutterWebOptimizerSourceCode
          .replaceAll(
            RegExp('var assetBase = null;'),
            'var assetBase = "$_assetBase";',
          )
          .replaceAll(
            RegExp('var mainjsManifest = null;'),
            'var mainjsManifest = ${jsonEncoder.convert(_hashFiles)};',
          );
      final File file = File('$_webOutput/index.html');
      String contents = file.readAsStringSync();

      contents = contents.replaceAll(
        RegExp(r'<script src="flutter.js" defer></script>'),
        '''
<script src="$flutterJS" defer></script>
<script>
        $flutterWebOptimizer
      </script>''',
      );
      file.writeAsStringSync(contents);
    }

    void updateIndexHtml() {
      final File file = File('$_webOutput/index.html');
      String contents = file.readAsStringSync();
      files.forEach((String key, String value) {
        var oldName = path.basename(key);
        var newName = path.basename(value);
        if (oldName == 'flutter.js') {
          newName = 'flutter.js';
        }
        contents = contents.replaceAll(RegExp(oldName), newName);
      });
      file.writeAsStringSync(contents);
    }

    hashJsFileName();
    replaceDataJSFile();
    updateIndexHtml();
    addIndexHtmlAsset();
    // 重命名文件
    files.forEach((String key, String value) {
      var file = File(key);
      print('${path.basename(file.path)} become ${path.basename(value)}');
      file.renameSync(value);
    });
  }

  void _removeFonts() {
    final File file = File('$_webOutput/assets/FontManifest.json');
    if (!file.existsSync()) {
      file.createSync();
    }
    file.writeAsStringSync('[]');
  }
}
