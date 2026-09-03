import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用内更新：下载 APK 到缓存目录 → 拉起系统安装器。
/// 每次下载前清掉旧包；App 启动时也调 [cleanupApks] 兜底，装完不会残留。
class ApkInstaller {
  static const _fileName = 'oneray-update.apk';

  static Future<Directory> _dir() async {
    final base = await getTemporaryDirectory();
    final d = Directory(p.join(base.path, 'update'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 下载并拉起安装。[onProgress] 传 0.0~1.0；总大小未知时传 -1。
  static Future<void> downloadAndInstall(
    String apkUrl, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _dir();
    await _wipe(dir);
    final path = p.join(dir.path, _fileName);
    await Dio().download(
      apkUrl,
      path,
      cancelToken: cancelToken,
      onReceiveProgress: (rec, total) => onProgress?.call(total > 0 ? rec / total : -1),
    );

    // 校验：APK 是 zip，开头必须是 "PK\x03\x04"。不是就是下到了错误页 / 传坏了。
    final f = File(path);
    final len = await f.length();
    if (len < 1024 * 1024) {
      throw Exception('下载的文件太小（${len ~/ 1024} KB），可能服务器上的安装包有问题');
    }
    final head = await f.openRead(0, 4).first;
    if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B || head[2] != 0x03 || head[3] != 0x04) {
      throw Exception('下载的文件不是有效的安装包，请检查服务器上的 oneray.apk');
    }

    final res = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
    if (res.type != ResultType.done) {
      throw Exception(res.message);
    }
  }

  /// App 启动时调用 —— 清掉残留的安装包。
  static Future<void> cleanupApks() async {
    try {
      await _wipe(await _dir());
    } catch (_) {}
  }

  static Future<void> _wipe(Directory dir) async {
    for (final f in dir.listSync()) {
      if (f is File && f.path.toLowerCase().endsWith('.apk')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }
}
