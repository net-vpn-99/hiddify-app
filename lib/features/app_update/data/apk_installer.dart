import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用内更新：下载 APK 到外部专用目录 → 校验 sha256（有的话）→ 拉起系统安装器。
/// 每次下载前清旧包；App 启动时清 10 分钟前的残留，装完不会残留、也不会误删进行中的。
class ApkInstaller {
  static const _fileName = 'oneray-update.apk';

  static Future<Directory> _dir() async {
    // 优先外部专用目录（/Android/data/<pkg>/files/update），安装器读这里比 cache 可靠
    final base = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'update'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// [apkUrls] 主 + 备，逐个尝试，直到某个下载并校验通过。
  /// [onProgress] 传 0.0~1.0；总大小未知时传 -1。[sha256Hex] 非空则校验。
  static Future<void> downloadAndInstall(
    List<String> apkUrls, {
    String? sha256Hex,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (apkUrls.isEmpty) throw Exception('没有可用的下载地址');
    final dir = await _dir();
    await _wipe(dir);
    final path = p.join(dir.path, _fileName);
    final f = File(path);

    Object? lastErr;
    for (final url in apkUrls) {
      try {
        await Dio().download(
          url,
          path,
          cancelToken: cancelToken,
          onReceiveProgress: (rec, total) => onProgress?.call(total > 0 ? rec / total : -1),
        );

        final len = await f.length();
        if (len < 1024 * 1024) {
          throw Exception('下载的文件太小（${len ~/ 1024} KB），换源重试');
        }
        final head = await f.openRead(0, 4).first;
        if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B || head[2] != 0x03 || head[3] != 0x04) {
          throw Exception('下载的不是有效安装包，换源重试');
        }
        if (sha256Hex != null && sha256Hex.isNotEmpty) {
          final digest = await sha256.bind(f.openRead()).first;
          if (digest.toString().toLowerCase() != sha256Hex.toLowerCase()) {
            throw Exception('安装包校验不通过（下载被损坏），换源重试');
          }
        }
        lastErr = null;
        break; // 这一个源成功了
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        lastErr = e;
        // 换下一个源
      }
    }
    if (lastErr != null) {
      throw Exception('所有下载源都失败了，请稍后重试或到官网手动下载（$lastErr）');
    }

    final res = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
    if (res.type != ResultType.done) {
      throw Exception('无法拉起安装器：${res.message}。可到官网手动下载安装。');
    }
  }

  /// App 启动时调用 —— 清掉 10 分钟前的残留安装包（不碰进行中的）。
  static Future<void> cleanupApks() async {
    try {
      final dir = await _dir();
      final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
      for (final e in dir.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.apk')) {
          final stat = await e.stat();
          if (stat.modified.isBefore(cutoff)) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
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
