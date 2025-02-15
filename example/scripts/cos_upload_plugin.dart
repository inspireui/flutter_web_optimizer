import 'dart:isolate';

import 'package:flutter_web_optimizer/flutter_web_optimizer.dart';
import 'package:tencent_cos_plus/tencent_cos_plus.dart';
import 'package:path/path.dart' as path;

/// [arguments] shell args from flutter pub run flutter_web_optimizer optimize
/// eq: flutter pub run flutter_web_optimizer optimize --asset-base http://192.168.101.93:9091/app/ --plugin scripts/cos_upload_plugin.dart
Future<void> main(List<String> arguments, SendPort sendPort) async {
  // do not delete
  ReceivePort receivePort = ReceivePort();
  // do not delete
  sendPort.send(receivePort.sendPort);
  // do not delete
  receivePort.listen((dynamic message) {
    print('client isolate get message: $message');
    if (message is Map<String, Object>) {
      final IsolateMessageProtocol protocol =
          IsolateMessageProtocol.fromMap(message);
      // you can write you business code here
      if (protocol.action == IsolateMessageAction.cdnAssets) {
        _uploadCOS(
          arguments: arguments,
          sendPort: sendPort,
          uploadFiles: protocol.data as List<String>,
        );
      }
    }
  });
}

/// 上传cos
Future<void> _uploadCOS({
  required List<String> arguments,
  required SendPort sendPort,
  required List<String> uploadFiles,
}) async {
  COSApiFactory.initialize(
    config: COSConfig(
      appId: 'xxx',
      secretId: 'xxx',
      secretKey: 'xxx',
    ),
    bucketName: 'xxx',
    region: 'xxx',
  );

  // asset-base
  final String assetBase = arguments[1];

  /// web-output
  final String webOutput = '${path.current}/build/web';

  // cdn的前缀路径
  final Uri uri = Uri.parse(assetBase);
  // 去掉末尾的 /
  final String cdnPrefixPath = uri.path.substring(1);

  // 查询历史版本
  final COSListBucketResult buckets = await COSApiFactory.objectApi.listObjects(
    listObjectHeader: COSListObjectHeader()..prefix = cdnPrefixPath,
  );

  if (buckets.contents?.isNotEmpty ?? false) {
    // 删除历史版本
    final List<COSObject> objects =
        buckets.contents!.map<COSObject>((COSContents content) {
      print('to delete file: ${content.key}');
      return COSObject(key: content.key ?? '');
    }).toList();
    final COSDelete delete = COSDelete(quiet: false, objects: objects);
    await COSApiFactory.objectApi.deleteMultipleObjects(delete: delete);
  }

  // 上传当前版本至cos
  final List<Future<dynamic>> tasks =
      uploadFiles.map<Future<dynamic>>((String filePath) {
    String objectKey = path.relative(filePath, from: webOutput);
    objectKey = '$cdnPrefixPath$objectKey';
    print('to upload file: $objectKey');
    return COSApiFactory.objectApi.putFileObject(
      objectKey: objectKey,
      filePath: filePath,
    );
  }).toList();
  await Future.wait(tasks);

  final IsolateMessageProtocol response =
      IsolateMessageProtocol.response(IsolateMessageAction.cdnAssets);
  sendPort.send(response.toMap());

  // Directory(webOutput)
  //     .listSync(recursive: true)
  //     .whereType<File>()
  //     .forEach((File file) {
  //   final String partPath =
  //       path.relative(file.path, from: webOutput);
  //   final String filePath =
  //       path.join('${Directory.current.path}/build/cdn', partPath);
  //   File(filePath).createSync(recursive: true);
  //   file.copySync(filePath);
  // });
}
