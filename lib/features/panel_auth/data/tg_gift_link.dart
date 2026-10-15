import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 关注 TG 频道再领一天：装了 Telegram 直接拉起机器人（链接带着账号）；拉不起来就开官网中转页，那里有下载入口。
Future<void> openTgGift(Map<String, dynamic> gift) async {
  final tg = gift['tg'] as String? ?? '';
  final page = gift['page'] as String? ?? '';
  var ok = false;
  if (tg.isNotEmpty) {
    try {
      ok = await launchUrl(Uri.parse(tg), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && page.isNotEmpty) await UriUtils.tryLaunch(Uri.parse(page));
}

/// 这个链接是不是我们的 TG 频道（后台 support_telegram_group）。公告里「关注 TG 频道」按钮、
/// 首页「TG 频道」都指它；还能领「关注送 1 天」时，点它走 [openTgGift]（带着账号去领）。
bool isOurTgChannel(String url) {
  final ch = RemoteSiteConfig.telegramGroupUri;
  final u = Uri.tryParse(url);
  if (ch == null || u == null) return false;
  String norm(String p) => p.endsWith('/') ? p.substring(0, p.length - 1) : p;
  return u.host.toLowerCase() == ch.host.toLowerCase() && norm(u.path).toLowerCase() == norm(ch.path).toLowerCase();
}
