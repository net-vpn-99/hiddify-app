import 'dart:convert';
import 'dart:io';

/// 点「开始采集」时关掉浏览器的旧连接：浏览器会复用采集前建好的连接，不关的话刷新网页什么都记不到
/// （VPN 仓库 docs/计划/智能分流-自己改网站.md 三.1.2）。用内核自带的 Clash 接口，不改内核：
/// 内核每次启动把配置写进工作目录 data/current-config.json，里面有接口地址和这次的随机密码。
/// 只关浏览器的、下过不到 1MB 的 TCP 连接（视频、下载不动，跟 Windows kIdleCloseMaxBytes 一样）。

const _idleCloseMaxBytes = 1000 * 1000;

/// 配置里的 experimental.clash_api；没开、读不懂返回 null。
({String base, String secret})? readClashApi(String configJson) {
  try {
    final root = jsonDecode(configJson);
    final exp = root is Map ? root['experimental'] : null;
    final api = exp is Map ? exp['clash_api'] : null;
    if (api is! Map) return null;
    final ctrl = api['external_controller'];
    if (ctrl is! String || ctrl.isEmpty) return null;
    final secret = api['secret'];
    return (base: 'http://$ctrl', secret: secret is String ? secret : '');
  } catch (_) {
    return null;
  }
}

/// GET /connections 的回答里要关的：浏览器的、TCP、上下行合计不到 1MB。processPath 在安卓上是包名
/// （有的带「 (uid)」），按开头比。
List<String> pickBrowserConns(String body, Set<String> browsers) {
  try {
    final list = (jsonDecode(body) as Map)['connections'];
    if (list is! List) return const [];
    final ids = <String>[];
    for (final c in list) {
      if (c is! Map) continue;
      final meta = c['metadata'];
      final path = meta is Map && meta['processPath'] is String ? meta['processPath'] as String : '';
      final pkg = path.split(' ').first;
      final bytes = ((c['upload'] as num?) ?? 0) + ((c['download'] as num?) ?? 0);
      if (meta is Map && meta['network'] == 'tcp' && browsers.contains(pkg) && bytes < _idleCloseMaxBytes) {
        if (c['id'] is String) ids.add(c['id'] as String);
      }
    }
    return ids;
  } catch (_) {
    return const [];
  }
}

/// 关浏览器的旧连接，返回关了几条。哪一步不行都返回 0，采集照常。
Future<int> closeBrowserConns(String currentConfigPath, Set<String> browsers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final file = File(currentConfigPath);
    if (!file.existsSync()) return 0;
    final api = readClashApi(await file.readAsString());
    if (api == null) return 0;
    Future<HttpClientResponse> send(String method, String path) async {
      final req = await client.openUrl(method, Uri.parse('${api.base}$path'));
      if (api.secret.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${api.secret}');
      return req.close().timeout(const Duration(seconds: 2));
    }

    final res = await send('GET', '/connections');
    final ids = pickBrowserConns(await res.transform(utf8.decoder).join(), browsers);
    var closed = 0;
    for (final id in ids) {
      final r = await send('DELETE', '/connections/${Uri.encodeComponent(id)}');
      await r.drain<void>();
      if (r.statusCode < 300) closed++;
    }
    return closed;
  } catch (_) {
    return 0;
  } finally {
    client.close(force: true);
  }
}
