import 'package:flutter/material.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';

/// 卡片：card 底，不描边、不加阴影，靠底色深浅分层（B 夜航 §3.4）。「我的」页的账号卡、方块、行组都用它。
class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: OneRayTokens.of(context).card,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 图标垫一块强调色浅底的圆角小方块。B 夜航只有一种强调色，所以所有入口同一个颜色。
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tk.accSoft, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(icon, size: size * 0.55, color: tk.acc),
    );
  }
}
