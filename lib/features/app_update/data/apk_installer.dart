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
