import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:path_provider/path_provider.dart';

/// 首页那一排常用网站。名单是 `sitesUrl` 下面的 `sites.json`。
///
/// 连上以后拉一次，6 小时内用本地那份。失败就用上次存的；从来没成功过，快捷按钮不显示。
/// 名单内容和上次不一样时，清掉按网站 id 存的图标，避免换图以后一直看旧的。
class SiteLink {
  const SiteLink({required this.id, required this.name, required this.url, this.iconPath});

  final String id;
  final String name;
  final String url;
  final String? iconPath;
}

class SitesCatalog {
  SitesCatalog._();

  static const _ttl = Duration(hours: 6);
  static List<SiteLink> quick = const [];
  static Future<void>? _inflight;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.bytes,
      followRedirects: true,
    ),
  );

  static Future<void> ensureLoaded() {
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  static Future<void> _load() async {
    await RemoteSiteConfig.ensureLoaded();
    final sitesUrl = RemoteSiteConfig.sitesUrl;
    if (sitesUrl == null) {
      quick = const [];
      return;
    }
    Directory? dir;
    try {
      final root = await getApplicationCacheDirectory();
      dir = Directory('${root.path}/sites');
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (_) {
      quick = const [];
      return;
    }

    final jsonFile = File('${dir.path}/sites.json');
    final urlFile = File('${dir.path}/sites.url');
    final cachedUrl = urlFile.existsSync() ? urlFile.readAsStringSync() : '';
    final fresh = jsonFile.existsSync() &&
        cachedUrl == sitesUrl &&
        DateTime.now().difference(jsonFile.lastModifiedSync()) < _ttl;

    List<int>? bytes;
    if (fresh) {
      bytes = jsonFile.readAsBytesSync();
    } else {
      try {
        final got = await _dio.get<List<int>>(_jsonUrl(sitesUrl));
        final body = got.data;
        if (body != null && body.isNotEmpty) {
          final previous = jsonFile.existsSync() ? jsonFile.readAsBytesSync() : const <int>[];
          if (!_sameBytes(previous, body)) _deleteIcons(dir);
          jsonFile.writeAsBytesSync(body, flush: true);
          urlFile.writeAsStringSync(sitesUrl, flush: true);
          bytes = body;
        }
      } catch (_) {}
      bytes ??= jsonFile.existsSync() ? jsonFile.readAsBytesSync() : null;
    }
    if (bytes == null) {
      quick = const [];
      return;
    }

    final parsed = _parse(bytes, dir, sitesUrl);
    quick = await _withIcons(parsed, dir);
  }

  static String _jsonUrl(String sitesUrl) {
    final base = sitesUrl.endsWith('/') ? sitesUrl : '$sitesUrl/';
    return '${base}sites.json';
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static void _deleteIcons(Directory dir) {
    for (final entity in dir.listSync()) {
      if (entity is File && entity.path.endsWith('.png')) entity.deleteSync();
    }
  }

  static List<_PendingLink> _parse(List<int> bytes, Directory dir, String sitesUrl) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final byId = <String, Map>{};
    final items = decoded['items'];
    if (items is List) {
      for (final item in items) {
        if (item is Map && item['id'] is String) byId[item['id'] as String] = item;
      }
    }
    final out = <_PendingLink>[];
    final ids = decoded['quick'];
    if (ids is! List) return out;
    for (final id in ids) {
      if (out.length >= 5) break;
      if (id is! String || !byId.containsKey(id)) continue;
      final item = byId[id]!;
      final url = item['url'];
      if (url is! String) continue;
      final page = Uri.tryParse(url);
      if (page == null || page.scheme != 'https' || page.host.isEmpty) continue;
      final name = item['name'] is String && (item['name'] as String).isNotEmpty ? item['name'] as String : id;
      final relative = item['icon'] is String ? item['icon'] as String : '';
      final iconUrl = _iconUrl(sitesUrl, relative);
      final file = File('${dir.path}/$id.png');
      final ready = iconUrl != null && file.existsSync() && file.lengthSync() > 32;
      out.add(_PendingLink(id: id, name: name, url: url, iconUrl: iconUrl, iconPath: ready ? file.path : null));
    }
    return out;
  }

  static Uri? _iconUrl(String sitesUrl, String relative) {
    if (relative.isEmpty || relative.contains(':') || relative.contains('//') || relative.contains('\\')) {
      return null;
    }
    final base = sitesUrl.endsWith('/') ? sitesUrl : '$sitesUrl/';
    final uri = Uri.parse(base).resolve(relative);
    if (uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  static Future<List<SiteLink>> _withIcons(List<_PendingLink> pending, Directory dir) async {
    final out = <SiteLink>[];
    for (final item in pending) {
      var path = item.iconPath;
      final iconUrl = item.iconUrl;
      if (path == null && iconUrl != null) {
        final file = File('${dir.path}/${item.id}.png');
        try {
          final got = await _dio.get<List<int>>(iconUrl.toString());
          final body = got.data;
          if (body != null && body.length > 32) {
            file.writeAsBytesSync(body, flush: true);
            path = file.path;
          }
        } catch (_) {}
      }
      out.add(SiteLink(id: item.id, name: item.name, url: item.url, iconPath: path));
    }
    return out;
  }
}

class _PendingLink {
  const _PendingLink({
    required this.id,
    required this.name,
    required this.url,
    required this.iconUrl,
    required this.iconPath,
  });

  final String id;
  final String name;
  final String url;
  final Uri? iconUrl;
  final String? iconPath;
}
