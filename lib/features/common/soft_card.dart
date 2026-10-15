import 'package:flutter/material.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';

/// 白卡：不描边，只有很淡的阴影（参照 GoMami 会员中心）。「我的」页的账号卡、方块、行组都用它。
class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tk = PurchaseTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tk.raised,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06), blurRadius: 14, offset: const Offset(0, 1)),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 图标垫一块同色系的浅色圆角小方块（GoMami 那种绿 / 蓝 / 紫 / 橙），一眼分得清是哪一项。
class IconTile extends StatelessWidget {
  const IconTile(this.icon, this.color, {super.key, this.size = 40});

  final IconData icon;
  final Color color;
  final double size;

  // 几个固定颜色，各入口按用途挑，别每处自己调色。
  static const gold = Color(0xFFD9A21B);
  static const orange = Color(0xFFEE7B3B);
  static const blue = Color(0xFF3F88E0);
  static const purple = Color(0xFF9466D6);
  static const green = Color(0xFF34A06C);
  static const slate = Color(0xFF6E7B8C);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.22 : 0.13),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, size: size * 0.55, color: dark ? Color.lerp(color, Colors.white, 0.25) : color),
    );
  }
}
