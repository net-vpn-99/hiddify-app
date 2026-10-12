import 'package:flutter/material.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/deep_linking/my_app_links.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// For temporary storage of the link received from AppLinks.
String newUrlFromAppLink = '';

/// 邀请页 `oneray://invite?code=` 送到首页去记。别当成订阅导入。
String pendingInviteFromLink = '';

/// TG 机器人「打开光速雷达，一键领取」→ 官网 /gift/open/ → `oneray://invite?gift=1`。
/// 首页看到 true 就直接拉起 Telegram 领（链接里带着这个账号，不用用户再发账号编号）。
/// 借 invite 这个 host 是因为老版本只认它：老版本收到会安安静静回首页，不会弹「添加配置」。
final giftFromLink = ValueNotifier<bool>(false);

class RefreshListenable extends ChangeNotifier {
  RefreshListenable(this.ref) {
    ref.listen(myAppLinksProvider, (_, next) {
      if (next.value != null) {
        newUrlFromAppLink = next.value!;
        notifyListeners();
      }
    });
    ref.listen(Preferences.introCompleted, (_, _) => notifyListeners());
  }
  final Ref ref;
}
