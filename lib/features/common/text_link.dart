import 'package:flutter/material.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';

/// 一行文字链接（「找回密码」「已有账号？去登录」「换一条线路」「以后再说」……）。
/// 跟 Windows `TextLink.qml` 同一个规矩：默认灰字（sub），要强调的才 accent。
/// 弹窗里的「确定 / 取消」是按钮不是链接，照旧用 TextButton（主题里是强调色）。
class TextLink extends StatelessWidget {
  const TextLink(
    this.text, {
    super.key,
    required this.onTap,
    this.accent = false,
    this.icon,
    this.fontSize = 14,
  });

  final String text;
  final VoidCallback? onTap;
  final bool accent;
  final IconData? icon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final style = TextButton.styleFrom(
      foregroundColor: accent ? tk.acc : tk.sub,
      textStyle: TextStyle(fontSize: fontSize),
    );
    final label = Text(text);
    if (icon == null) return TextButton(style: style, onPressed: onTap, child: label);
    return TextButton.icon(style: style, onPressed: onTap, icon: Icon(icon, size: 18), label: label);
  }
}
