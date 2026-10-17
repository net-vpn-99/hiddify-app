import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/common/line_icon.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum QuotaEndedAction { invite, purchase, bind, login }

/// 流量用完 / 会员到期 / 没有套餐：居中弹窗，不是首页顶栏报错。
///
/// 1.1.28 起主按钮统一是**去买套餐**：游客现在不绑邮箱也能下单（GslGuest 1.1.0），
/// 绑定也不再送时长，没理由再把「绑定邮箱」摆在到期用户面前挡路。绑定退回成「我的」页
/// 上的一条提醒（换手机 / 电脑上也能用同一个套餐）。
class QuotaEndedDialog extends ConsumerWidget {
  const QuotaEndedDialog({super.key, required this.account});

  final PanelAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = account.stateSlug;
    final bonus = ref.watch(inviteTextsProvider).valueOrNull?.bonus;
    // 没套餐的人说「还没有套餐」，不说「试用已结束」。
    final freeTrial = slug != 'no_plan' && ref.watch(panelAuthProvider).freeTrial;

    // 10-13 换成引导卡样式（两端统一，Windows QuotaPrompt.qml），只讲重点。
    final (title, body) = freeTrial
        ? ('免费试用已结束', '买个套餐就能接着用，不用先注册。')
        : switch (slug) {
            'traffic_exhausted' => ('本期流量已用完', '续费后马上就能接着用。'),
            'expired' => ('会员已到期', '续费后马上就能接着用。'),
            _ => ('还没有套餐', '选一个套餐就能开始用。'),
          };
    final showInvite = slug != 'no_plan';

    return GuideCard(
      title: title,
      body: body,
      tipTitle: showInvite ? '邀请好友，双方都有奖励' : '',
      tipIcon: LineIconName.gift,
      tipBelow: true,
      tipText: (bonus != null && bonus.isNotEmpty) ? '好友用起来后，你们各得 $bonus。' : '好友用起来后，你们都能再获得体验。',
      actionText: slug == 'no_plan' || freeTrial ? '去买套餐' : '去续费',
      onAction: () => context.pop(QuotaEndedAction.purchase),
      secondaryText: showInvite ? '邀请好友' : '',
      onSecondary: () => context.pop(QuotaEndedAction.invite),
      links: [
        if (freeTrial) GuideLink('以前买过？登录你的账号', () => context.pop(QuotaEndedAction.login)),
        GuideLink('稍后再说', () => context.pop()),
      ],
    );
  }
}

/// 这台设备连账号都还没有（游客没开成：名额满了 / 后台关了 / 这台手机登录过正式账号）。
/// 点连接或点线路时弹它，给两条路：登录，或者去看套餐。
class NeedAccountDialog extends StatelessWidget {
  const NeedAccountDialog({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return GuideCard(
      title: '还差一步就能连',
      body: message ?? '登录已有账号，或者买个套餐就能用。',
      actionText: '登录账号',
      onAction: () => context.pop(QuotaEndedAction.login),
      secondaryText: '看看套餐',
      onSecondary: () => context.pop(QuotaEndedAction.purchase),
      links: [GuideLink('稍后再说', () => context.pop())],
    );
  }
}
