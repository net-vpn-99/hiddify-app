import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「你现在的网络」：国内 / 国外出口实测（两端同一套规则，见 VPN 仓库
/// docs/你现在的网络-国内国外IP自检-手册.md）。
///
/// 用户担心「QQ 会不会显示美国登录」。与其解释，不如实测：分别请求一个国内、一个国外
/// 的查 IP 网址，各自看到的出口就是 QQ / 谷歌看到的。
///
/// ⚠️ 安卓上 app 自己的请求不一定进 VPN 隧道，所以这两个请求都用 httpClient 的
/// `proxyOnly: true` —— 走 sing-box 本地 mixed 端口，进去后照样按分流规则判国内 / 国外。
/// 另起一个不带代理的 Dio 会两行都测出中国 IP，结论是错的。
class RouteCheckState {
  const RouteCheckState({
    this.status = 'idle',
    this.domesticLine = '',
    this.foreignLine = '',
    this.warning = '',
    this.domesticSummary = '',
    this.foreignSummary = '',
  });

  /// idle / running / done
  final String status;
  final String domesticLine;
  final String foreignLine;
  final String warning;

  /// 纠错留言里写的简短结果
  final String domesticSummary;
  final String foreignSummary;
}

final routeCheckProvider = NotifierProvider<RouteCheckNotifier, RouteCheckState>(RouteCheckNotifier.new);

class _Egress {
  _Egress({required this.ok, this.ip = '', this.cc = '', this.region = '', this.isp = ''});
  final bool ok;
  final String ip;
  final String cc; // 国外那侧：两位国家代码；国内那侧：CN 或空
  final String region;
  final String isp;
}

class RouteCheckNotifier extends Notifier<RouteCheckState> {
  int _serial = 0;

  // 国内网址必须是分流规则一定判成「国内」的域名（B 站：UTF-8、带运营商；腾讯兜底，无运营商）。
  static const _domesticUrls = [
    'https://api.bilibili.com/x/web-interface/zone',
    'https://r.inews.qq.com/api/ip2city',
  ];
  static const _foreignUrls = [
    'https://api.ip.sb/geoip',
    'https://ipinfo.io/json',
    'https://www.cloudflare.com/cdn-cgi/trace',
  ];

  @override
  RouteCheckState build() {
    // 第一次测通（首页从「连接中」变「已连接」）→ 测一次；断开 → 清空。
    // 测通 → 测一次；真的断开（「已确认」被清掉）→ 清空。不直接看连接状态：切到桌面
    // 再回来时状态流会重放一下「断开」，看它的话结果会被白白清掉又重测。
    ref.listen(stabilityProvider.select((s) => s.confirmed), (prev, next) {
      if (next && prev != true) {
        unawaited(check());
      } else if (!next && prev == true) {
        _reset();
      }
    });
    // 已连着换线路（内核里直接切出站，不重连）→ 国外那行要跟着变。
    ref.listen(Preferences.lastNodeName, (prev, next) {
      if (prev != next && ref.read(stabilityProvider).confirmed) unawaited(check());
    });
    return const RouteCheckState();
  }

  void _reset() {
    _serial++;
    state = const RouteCheckState();
  }

  Future<void> check() async {
    final connected = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;
    final serial = ++_serial;
    state = const RouteCheckState(status: 'running');

    final results = await Future.wait([_first(_domesticUrls, true), _first(_foreignUrls, false)]);
    if (serial != _serial) return;
    final d = results[0];
    final f = results[1];

    final lineName = ref.read(Preferences.lastNodeName);
    final firstLine = ref.read(lineSetProvider).valueOrNull?.lines.firstOrNull?.name ?? '';
    final where = lineName.isNotEmpty ? lineName : firstLine;

    String domesticLine;
    String domesticSummary;
    final domesticCn = d.ok && d.cc == 'CN';
    if (!d.ok) {
      domesticLine = '暂时测不出来';
      domesticSummary = '未测';
    } else if (domesticCn) {
      final place = [d.region, d.isp].where((s) => s.isNotEmpty).join(' ');
      domesticLine = '本地网络 · $place';
      domesticSummary = place;
    } else {
      final place = d.region.isEmpty ? '国外' : d.region;
      domesticLine = '没有走本地网络 · $place';
      domesticSummary = place;
    }

    String foreignLine;
    final foreignCn = f.ok && f.cc == 'CN';
    if (!f.ok) {
      foreignLine = '暂时测不出来';
    } else if (foreignCn) {
      foreignLine = '没有走光速雷达 · 中国';
    } else {
      foreignLine = '光速雷达 · ${where.isEmpty ? f.cc : where}';
    }

    String warning = '';
    if (d.ok && !domesticCn) {
      warning = '国内网站也被带到了国外，可能有其他 VPN / 加速器在接管网络';
    } else if (foreignCn) {
      warning = '国外网站没有走光速雷达，请换一条线路或联系客服';
    }

    state = RouteCheckState(
      status: 'done',
      // IP 单独放第二行（窄屏上不会被折成两半），中间两段打码。
      domesticLine: d.ok ? '$domesticLine\n${_mask(d.ip)}' : domesticLine,
      foreignLine: f.ok ? '$foreignLine\n${_mask(f.ip)}' : foreignLine,
      warning: warning,
      domesticSummary: domesticSummary,
      foreignSummary: f.ok ? f.cc : '未测',
    );
  }

  /// 按顺序试，前一个失败才试下一个；每个 5 秒。
  Future<_Egress> _first(List<String> urls, bool domestic) async {
    final client = ref.read(httpClientProvider);
    for (final url in urls) {
      final cancel = CancelToken();
      final timer = Timer(const Duration(seconds: 5), () => cancel.cancel('timeout'));
      try {
        final res = await client.get<dynamic>(url, cancelToken: cancel, proxyOnly: true);
        final r = domestic ? _parseDomestic(url, res.data) : _parseForeign(url, res.data);
        if (r.ok) return r;
      } catch (_) {
        // 换下一个
      } finally {
        timer.cancel();
      }
    }
    return _Egress(ok: false);
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final v = jsonDecode(data);
        if (v is Map<String, dynamic>) return v;
      } catch (_) {}
    }
    return const {};
  }

  static String _shortRegion(String s) =>
      s.replaceAll(RegExp(r'(壮族|回族|维吾尔|藏族)?(自治区|特别行政区|省|市)$'), '').trim();

  static _Egress _parseDomestic(String url, dynamic data) {
    final root = _asMap(data);
    final m = url.contains('bilibili') ? _asMap(root['data']) : root;
    final ip = (url.contains('bilibili') ? m['addr'] : m['ip'])?.toString() ?? '';
    final country = m['country']?.toString() ?? '';
    final cn = country == '中国';
    return _Egress(
      ok: ip.isNotEmpty,
      ip: ip,
      cc: cn ? 'CN' : '',
      region: cn ? _shortRegion(m['province']?.toString() ?? '') : country,
      isp: m['isp']?.toString() ?? '',
    );
  }

  static _Egress _parseForeign(String url, dynamic data) {
    String ip = '';
    String cc = '';
    if (url.contains('cdn-cgi/trace')) {
      for (final line in (data?.toString() ?? '').split('\n')) {
        if (line.startsWith('ip=')) ip = line.substring(3).trim();
        if (line.startsWith('loc=')) cc = line.substring(4).trim();
      }
    } else {
      final m = _asMap(data);
      ip = m['ip']?.toString() ?? '';
      cc = (m['country_code'] ?? m['country'])?.toString() ?? '';
    }
    cc = cc.toUpperCase();
    return _Egress(ok: ip.isNotEmpty && cc.isNotEmpty, ip: ip, cc: cc);
  }

  static String _mask(String ip) {
    final v4 = ip.split('.');
    if (v4.length == 4) return '${v4.first}.*.*.${v4.last}';
    final v6 = ip.split(':').where((s) => s.isNotEmpty).toList();
    if (v6.length >= 2) return '${v6.first}:…:${v6.last}';
    return ip;
  }
}
