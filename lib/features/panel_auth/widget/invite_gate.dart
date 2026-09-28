import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 打开邀请页。免注册的号也能进，奖励记在这个号上。
///
/// 所有入口（「我的」页的「邀请返利」、到期弹窗的第二个按钮）都走这里，别各写各的。
Future<void> openInvite(BuildContext context) {
  return context.pushNamed('invite');
}
