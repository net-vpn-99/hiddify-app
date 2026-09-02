import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

typedef DiagResult = ({String? code, String? error});

/// 收集诊断报告（版本 / 系统 / 关键设置 / box.log / app.log）→ zlib 压缩 → 上传到
/// Xboard 插件 `POST /api/v1/guest/gsl_diag/upload`，返回 4 位诊断码给用户报给客服。
/// 服务端解压走 gzuncompress 的 raw-zlib 分支，所以这里用 ZLibCodec 即可。
Future<DiagResult> uploadDiagnostics(WidgetRef ref) async {
  try {
    final report = await _collect(ref);
    final gz = ZLibCodec(level: 9).encode(utf8.encode(report));
    final b64 = base64.encode(gz);

    final appInfo = ref.read(appInfoProvider).requireValue;
    final email = ref.read(panelAuthProvider).email ?? '';
    final state = _stateLabel(ref);

    final dio = Dio(BaseOptions(
      baseUrl: Constants.panelApiBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (_) => true,
      headers: {'User-Agent': 'OneRay-Android-Diag'},
    ));
    final res = await dio.post<dynamic>(
      '/api/v1/guest/gsl_diag/upload',
      data: FormData.fromMap({
        'report_gz': b64,
        'version': appInfo.version,
        'os': _osLine(),
        'state': state,
        if (email.isNotEmpty) 'email': email,
      }),
    );

    final body = res.data;
    String? code;
    if (body is Map) {
      final data = body['data'];
      code = (data is Map ? data['code'] : null) as String? ?? body['code'] as String?;
    }
    if (code != null && code.isNotEmpty) return (code: code, error: null);

    final msg = (body is Map && body['message'] is String) ? body['message'] as String : '上传失败，请稍后再试';
    return (code: null, error: msg);
  } on DioException {
    return (code: null, error: '无法连接服务器，请检查网络');
  } catch (e) {
    return (code: null, error: '出错了：$e');
  }
}

String _osLine() => '${Platform.operatingSystem} / ${Platform.operatingSystemVersion}';

String _stateLabel(WidgetRef ref) {
  final s = ref.read(connectionNotifierProvider).valueOrNull;
  if (s == null) return 'unknown';
  if (s.isConnected) return 'connected';
  if (s.isDisconnected) return 'disconnected';
  return s.runtimeType.toString().toLowerCase();
}

Future<String> _collect(WidgetRef ref) async {
  final appInfo = ref.read(appInfoProvider).requireValue;
  final b = StringBuffer();
  b.writeln('===== 光速 诊断报告 =====');
  b.writeln('时间: ${DateTime.now().toIso8601String()}');
  b.writeln('版本: ${appInfo.version} (${appInfo.release.name})');
  b.writeln('系统: ${_osLine()}');
  b.writeln('账号: ${ref.read(panelAuthProvider).email ?? "未登录"}');
  b.writeln('连接: ${_stateLabel(ref)}');
  b.writeln();
  b.writeln('--- 关键设置 ---');
  try {
    b.writeln('region=${ref.read(ConfigOptions.region).name}');
    b.writeln('remote_dns=${ref.read(ConfigOptions.remoteDnsAddress)}');
    b.writeln('direct_dns=${ref.read(ConfigOptions.directDnsAddress)}');
    b.writeln('resolve_destination=${ref.read(ConfigOptions.resolveDestination)}');
    b.writeln('enable_fake_dns=${ref.read(ConfigOptions.enableFakeDns)}');
    b.writeln('ipv6_mode=${ref.read(ConfigOptions.ipv6Mode).key}');
    b.writeln('tun_implementation=${ref.read(ConfigOptions.tunImplementation).name}');
    b.writeln('mtu=${ref.read(ConfigOptions.mtu)}');
    b.writeln('bypass_lan=${ref.read(ConfigOptions.bypassLan)}');
  } catch (e) {
    b.writeln('(读取设置出错: $e)');
  }
  b.writeln();

  final dir = ref.read(appDirectoriesProvider).requireValue.workingDir;
  b.writeln('--- box.log (尾部) ---');
  b.writeln(await _tailFile(p.join(dir.path, 'box.log'), 600, 200 * 1024));
  b.writeln();
  b.writeln('--- app.log (尾部) ---');
  b.writeln(await _tailFile(p.join(dir.path, 'app.log'), 300, 100 * 1024));
  return b.toString();
}

Future<String> _tailFile(String path, int maxLines, int maxBytes) async {
  try {
    final f = File(path);
    if (!f.existsSync()) return '(无)';
    final len = await f.length();
    final start = len > maxBytes ? len - maxBytes : 0;
    final raw = await f.openRead(start).transform(utf8.decoder).join();
    final lines = raw.split('\n');
    final tail = lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
    return tail.join('\n');
  } catch (e) {
    return '(读取失败: $e)';
  }
}
