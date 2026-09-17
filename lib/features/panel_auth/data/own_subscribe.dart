/// 自家 Xboard 订阅：路径只说明格式，不能证明属于本项目。
/// 改写已有 profile 必须再过账号绑定 ID，或旧数据的「光速 + 已知面板域名」。

import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

const accountProfilePrefKey = 'oneray_account_profile_id';

bool looksLikeOwnPanelSubscribe(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return false;
  if (u.scheme != 'https' && u.scheme != 'http') return false;
  if (!u.path.contains('/api/v1/client/subscribe')) return false;
  final token = u.queryParameters['token']?.trim() ?? '';
  return token.isNotEmpty;
}

bool isKnownPanelHost(String url, {String? extraBase}) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  bool matches(String? raw) {
    final h = Uri.tryParse((raw ?? '').trim())?.host.toLowerCase();
    return h != null && h.isNotEmpty && h == host;
  }

  if (matches(Constants.panelApiBase)) return true;
  for (final u in Constants.panelApiFallbacks) {
    if (matches(u)) return true;
  }
  if (matches(PanelApiBase.current)) return true;
  if (matches(extraBase)) return true;
  for (final u in PanelApiBase.configHosts) {
    if (matches(u)) return true;
  }
  return false;
}

/// 账号登录/注册拿到的订阅：路径 + 已知面板 host。第三方同路径不能绑定。
bool isOwnAccountSubscribeSource(String url) {
  return looksLikeOwnPanelSubscribe(url) && isKnownPanelHost(url);
}

/// 登录导入才会 bind。没有 bind 的旧「光速」记录，仅当 host 是已知面板时才当自家。
bool isOwnAccountProfile(RemoteProfileEntity profile, {String? boundId}) {
  if (boundId != null && boundId.isNotEmpty && profile.id == boundId) return true;
  if (profile.userOverride?.name != '光速') return false;
  return isOwnAccountSubscribeSource(profile.url);
}

String? subscribeTokenOf(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return null;
  final token = u.queryParameters['token']?.trim() ?? '';
  return token.isEmpty ? null : token;
}

String originOf(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty) return '';
  final scheme = u.scheme.isEmpty ? 'https' : u.scheme;
  return '$scheme://${u.host}';
}

Future<String?> boundAccountProfileId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(accountProfilePrefKey);
}

Future<void> bindAccountProfileId(String id) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(accountProfilePrefKey, id);
}

Future<void> unbindAccountProfileIdIf(String id) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getString(accountProfilePrefKey) == id) {
    await prefs.remove(accountProfilePrefKey);
  }
}

/// 用当前探活成功的 API 重建自家订阅 URL。没有订阅 token 时原样返回
/// [originalUrl]（可能是第三方链接），绝不把登录令牌填进去。
String buildOwnSubscribeUrl({
  required String apiBase,
  String? token,
  String? originalUrl,
}) {
  var t = token?.trim() ?? '';
  final extra = <String, String>{};
  if (originalUrl != null && originalUrl.trim().isNotEmpty) {
    final u = Uri.tryParse(originalUrl.trim());
    if (u != null) {
      extra.addAll(u.queryParameters);
      if (t.isEmpty) t = (extra['token'] ?? '').trim();
    }
  }
  extra.remove('token');
  if (t.isEmpty) return originalUrl?.trim() ?? '';
  var base = apiBase.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final q = StringBuffer('token=${Uri.encodeQueryComponent(t)}');
  extra.forEach((k, v) {
    if (k.isEmpty || v.isEmpty) return;
    q.write('&${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}');
  });
  return '$base/api/v1/client/subscribe?$q';
}
