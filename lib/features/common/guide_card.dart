import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';

/// 通用引导卡（10-13 运营定，两端统一；Windows 是 qml/overlays/GuideCard.qml）。
/// 所有告知类提示都用这个样子，跟邮件同一种感觉：白色大圆角卡片、居中粗标题、一句话、图例、
/// 「图标 + 小标题 + 一句话」小贴士、金色整行按钮、最下面一行「还是不行？联系客服」。
/// 只写帮他把问题解决掉的话，背景知识不写；客户端查实了是哪种情况才弹。
Future<void> showGuideCard(
  BuildContext context, {
  required String title,
  String body = '',
  Widget? illustration,
  String tipTitle = '',
  String tipText = '',
  String actionText = '知道了',
  bool showContact = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final t = PurchaseTokens.of(ctx);
      return Dialog(
        backgroundColor: t.raised,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.text, fontSize: 19, fontWeight: FontWeight.w600),
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.secondary, fontSize: 14, height: 1.55),
                  ),
                ],
                if (illustration != null) ...[
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: t.background, borderRadius: BorderRadius.circular(14)),
                    child: illustration,
                  ),
                ],
                if (tipTitle.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: t.selected, shape: BoxShape.circle),
                        child: Text('?', style: TextStyle(color: t.warning, fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tipTitle, style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(tipText, style: TextStyle(color: t.secondary, fontSize: 13, height: 1.45)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: t.primary,
                      foregroundColor: t.onPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(actionText),
                  ),
                ),
                if (showContact)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: t.secondary, minimumSize: const Size(48, 40)),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      context.pushNamed('supportChat');
                    },
                    child: Text.rich(
                      TextSpan(
                        text: '还是不行？',
                        style: TextStyle(color: t.secondary, fontSize: 12),
                        children: [
                          TextSpan(
                            text: '联系客服',
                            style: TextStyle(color: t.warning, decoration: TextDecoration.underline),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 「你的网络连不上我们的线路」：服务器 ✓ / 线路 ✕ 两行示意。
Future<void> showNetBlockedGuide(BuildContext context, int tried) {
  final t = PurchaseTokens.of(context);
  Widget row(String label, bool ok) {
    final c = ok ? t.remaining : t.empty;
    return Row(
      children: [
        Text('你的手机', style: TextStyle(color: t.text, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 2, color: c)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(ok ? '✓' : '✕', style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Expanded(child: Container(height: 2, color: c)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: t.text, fontSize: 12)),
      ],
    );
  }

  return showGuideCard(
    context,
    title: '你的网络连不上我们的线路',
    body: '光速雷达的服务器能连上，但 $tried 条线路都没有回应。是你现在用的网络挡住了线路，换线路也没用。',
    illustration: Column(
      children: [
        row('光速雷达的服务器', true),
        const SizedBox(height: 10),
        row('线路（试了 $tried 条）', false),
      ],
    ),
    tipTitle: '换个网络试试',
    tipText: 'Wi-Fi 和手机流量换一个，再点「重新连接」。',
  );
}
