import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:path/path.dart' as path;

import '../common/logger.dart';
import '../common/model.dart';
import 'dart_agency_build.dart';
import 'dart_deferred_library_loader.js.dart';
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
      ..addOption(
        'target',
        help: 'Build target'
      );
  }

  @override
  String get description =>
      'solve web page loading slow and browser cache problem';

  @override
  String get name => 'optimize';

  /// 资源路径，一般是cdn地址
  String get _assetBase => argResults!['asset-base'] ?? '';

  /// Web构建产物路径
  String get _webOutput {
    final String? webOutput = argResults!['web-output'];
    if (webOutput?.isNotEmpty ?? false) {
      return path.join(path.context.current, webOutput!);
    }
    return path.join(path.context.current, 'build/web');
  }

  /// plugin 文件路径，支持处理资源上传cdn等操作
  String get _plugin {
    final String? pluginFile = argResults!['plugin'];
    if (pluginFile?.isNotEmpty ?? false) {
      return path.join(path.context.current, pluginFile!);
    }
    return '';
  }

  /// isolate通信，发送信息
  SendPort? _sendPort;

  /// isolate通信，接收信息
  ReceivePort? _receivePort;

  /// isolate消息
  Stream<IsolateMessageProtocol>? _message;

  /// 哈希化后的main.dart.js && main.dart.xxx.part文件
  final Map<String, String> _jsManifest = <String, String>{};

  /// 需要上传的文件
  List<String> _toUploadFiles = <String>[];

  @override
  FutureOr<void> run() async {
    Logger.info('start web optimize inspireui');

    await _initIsolate(argResults!.arguments);

    final Directory outputDir = Directory(_webOutput);
    if (!outputDir.existsSync()) {
      // 构建产物目录不存在，直接退出
      Logger.error('web artifacts output dir is not exist');
      exit(2);
    }

    final File mainDartJsFile = outputDir
        .listSync()
        .whereType<File>()
        .singleWhere(
            (File entity) => path.basename(entity.path) == 'main.dart.js');
    await _splitMainDartJS(mainDartJsFile);

    _hashScripts();

    await _cdnAssets();

    _replaceFlutterJS();

    _injectToHtml();

    _disposeIsolate();

    Logger.info('end web optimize');
  }

  /// 解析命令行参数
  // void _parseShellArgs(List<String> arguments) {
  //   final ArgParser argParser = ArgParser()
  //     ..addOption(
  //       'asset-base',
  //       help: 'asset base url，end with /，eq：http://127.0.0.1:8080/',
  //       mandatory: true,
  //     )
  //     ..addOption(
  //       'web-output',
  //       help: 'web artifacts output dir，'
  //           'only support relative path，root path is [path.context.current]，'
  //           'eq：build/web',
  //     )
  //     ..addOption(
  //       'plugin',
  //       help: 'plugin file path，'
  //           'only support relative path，root path is [path.context.current]，'
  //           'eq：flutter_web_optimize_plugin.dart',
  //     );
  //   final ArgResults argResults =
  //       completion.tryArgsCompletion(arguments, argParser);
  //   _assetBase = argResults['asset-base'];
  //   final String? webOutput = argResults['web-output'];
  //   if (webOutput?.isNotEmpty ?? false) {
  //     _webOutput = path.join(path.context.current, webOutput!);
  //   }
  //   final String? pluginFile = argResults['plugin'];
  //   if (pluginFile?.isNotEmpty ?? false) {
  //     _plugin = path.join(path.context.current, pluginFile!);
  //   }
  // }

  /// 解析 flutter_web_optimizer.yaml 文件
  // void _parseYaml() {
  //   final String contents =
  //       File('${path.current}/flutter_web_optimizer.yaml').readAsStringSync();
  //   final dynamic doc = loadYaml(contents);
  //   if (doc is! Map) {
  //     return;
  //   }
  //   _assetBase = doc['asset_base'] ?? '';
  //   if (_assetBase.isEmpty) {
  //     throw Exception(
  //         '[flutter_web_optimizer.yaml]: asset_base_url args not be null!!!');
  //   }
  //   if (doc['cdn_upload'] is! Map<dynamic, dynamic>) {
  //     return;
  //   }
  //   if (doc['cdn_upload']['custom_upload_file_name'] is! String) {
  //     return;
  //   }
  //   _plugin = doc['cdn_upload']['custom_upload_file_name'] ?? '';
  // }

  /// 初始化isolate通信
  Future<void> _initIsolate(List<String> args) {
    final Completer<void> completer = Completer<void>();
    if (_plugin.isEmpty) {
      completer.complete();
    }
    final StreamController<IsolateMessageProtocol> controller =
        StreamController<IsolateMessageProtocol>.broadcast();
    _message = controller.stream;

    _receivePort ??= ReceivePort();
    _receivePort!.listen((dynamic message) {
      Logger.info('server isolate get message: $message');
      if (message is Map<String, Object>) {
        controller.add(IsolateMessageProtocol.fromMap(message));
      }
      if (message is SendPort) {
        _sendPort = message;
        completer.complete();
      }
    });

    Isolate.spawnUri(Uri.file(_plugin), args, _receivePort!.sendPort);
    return completer.future;
  }

  /// 释放isolate通信
  void _disposeIsolate() {
    _receivePort?.close();
  }

  /// 拆分 main.dart.js
  Future<void> _splitMainDartJS(File file) async {
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

    const int totalChunk = 6;
    final Uint8List bytes = file.readAsBytesSync();
    int chunkSize = (bytes.length / totalChunk).ceil();
    final List<Future<bool>> futures = List<Future<bool>>.generate(
      totalChunk,
      (int index) {
        return writeSingleFile(
          file: file,
          filename: 'main.dart_$index.js',
          startIndex: index * chunkSize,
          endIndex: (index + 1) * chunkSize,
        );
      },
    );

    await Future.wait(futures);

    /// 分片完成后删除 main.dart.js
    file.deleteSync();
  }

  /// md5文件
  String _md5File(File file, {String? md5}) {
    final Uint8List bytes = file.readAsBytesSync();
    // 截取8位即可
    final md5Hash = md5 ?? crypto.md5.convert(bytes).toString().substring(0, 8);

    // 文件名使用hash值
    final basename = path.basenameWithoutExtension(file.path);
    final extension = path.extension(file.path);
    return '$md5Hash-$basename$extension';
  }

  void _hashScripts() {
    var md5 = crypto.md5
        .convert([
          Random().nextInt(1000),
          Random().nextInt(1000),
          Random().nextInt(1000),
          Random().nextInt(1000)
        ])
        .toString()
        .substring(0, 8);
    Logger.info('hash script $md5');
    Directory(_webOutput)
        .listSync()
        .whereType<File>()
        .where(
            (File file) => RegExp(r'main\.dart(.*)\.js$').hasMatch(file.path))
        .forEach((File file) {
      _toUploadFiles.add(file.path);
      final String key = path.relative(file.path, from: _webOutput);
      final String filename = _md5File(file, md5: md5);
      file.renameSync(path.join(path.dirname(file.path), filename));
      if (key.startsWith('main.dart_')) {
        _jsManifest[path.basename(file.path)] = filename;
      }
    });

    /// rewrite to main script
    for (var mainItem in _jsManifest.keys.toList()) {
      final File file = File('$_webOutput/${_jsManifest[mainItem]}');
      if (file.existsSync()) {
        String contents = file.readAsStringSync();
        contents = contents.replaceAll(
            RegExp(r'main.dart.js'), '$md5-main.dart.js');
        file.writeAsString(contents);
      } else {
        Logger.info(file.path);
      }
    }
    Logger.info('hash script done');
  }

  /// 资源cdn化
  Future<void> _cdnAssets() async {
    final Completer<void> completer = Completer<void>();
    if (_plugin.isEmpty) {
      completer.complete();
    }
    _message?.listen((IsolateMessageProtocol protocol) {
      if (protocol.isResponse &&
          protocol.action == IsolateMessageAction.cdnAssets) {
        completer.complete();
      }
    });
    _sendPort?.send(IsolateMessageProtocol.request(
      IsolateMessageAction.cdnAssets,
      _toUploadFiles,
    ).toMap());
    return completer.future;
  }

  /// 替换 flutter.js
  void _replaceFlutterJS() {
    File('$_webOutput/flutter.js').writeAsStringSync(flutterJSSourceCode);
  }

  /// 向 index.html 注入
  void _injectToHtml() {
    final String? target = argResults?['target'];
    final bool isAgency = target == 'agency';
    final File file = File('$_webOutput/index.html');
    String contents = file.readAsStringSync();
    final File flutterJsFile = File('$_webOutput/flutter.js');
    final String filename = _md5File(flutterJsFile);
    flutterJsFile
        .renameSync(path.join(path.dirname(flutterJsFile.path), filename));
    contents = contents.replaceAll(
      RegExp(r'<script src="flutter.js" defer></script>'),
      '<script src="$filename" defer></script>',
    );
    final Document document = parse(contents);
    final String dartDeferredLibraryLoader = dartDeferredLibraryLoaderSourceCode
        .replaceAll(
            RegExp('var assetBase = null;'), 'var assetBase = "$_assetBase";')
        .replaceAll(
          RegExp('var jsManifest = null;'),
          'var jsManifest = ${jsonEncode(_jsManifest)};',
        );
    final List<Element> scripts = document.getElementsByTagName('script');
    bool isInjected = false;
    for (int i = 0; i < scripts.length; i++) {
      final Element element = scripts[i];
      if (element.text.contains(RegExp(r'var serviceWorkerVersion'))) {
        element.text = '${element.text}\n$dartDeferredLibraryLoader';
        if (isAgency) {
          element.text = '${element.text}\n$dartAgencyBuild';
        }
        isInjected = true;
        break;
      }
    }
    if (!isInjected) {
      final Element? headElement = document.head;
      if (headElement != null) {
        final Element script = Element.tag('script');
        script.text = '\n$dartDeferredLibraryLoader';
        if (isAgency) {
          script.text = '${script.text}\n$dartAgencyBuild';
        }

        if (scripts.length > 1) {
          final Element firstScript = scripts.first;
          headElement.insertBefore(script, firstScript);
          headElement.insertBefore(Text('\n'), firstScript);
        } else {
          headElement.append(script);
          headElement.append(Text('\n'));
        }
      }
    }
    file.writeAsStringSync(document.outerHtml);
  }
}
