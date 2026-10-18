import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 线条小图标（10-13，给引导卡和公告用；Windows 同一套线条：qml/components/LineIcon.qml，两边一起改）。
/// 自己画的 24×24 描边图形，不用第三方图标包；每张卡按内容选图标，别再用一个问号什么都表达不了。
enum LineIconName { info, gift, message, wifi, shield, users, logout, download, search, bell, lock, gauge }

const _paths = <LineIconName, String>{
  LineIconName.info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  LineIconName.gift:
      '<rect x="3.5" y="8" width="17" height="4" rx="1"/><path d="M5 12v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7M12 8v12M12 8c-1.5-3-5-3.5-5-1.5S10 8 12 8zM12 8c1.5-3 5-3.5 5-1.5S14 8 12 8z"/>',
  LineIconName.message:
      '<path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4 3.5V16H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"/><path d="M8 9.5h8M8 12.5h5"/>',
  LineIconName.wifi:
      '<path d="M3.5 9.5a12 12 0 0 1 17 0M6.5 12.8a7.5 7.5 0 0 1 11 0M9.5 16a3 3 0 0 1 5 0"/><path d="M12 19h.01"/>',
  LineIconName.shield: '<path d="M12 3l7 3v5c0 4.5-3 8-7 10c-4-2-7-5.5-7-10V6z"/><path d="M9 12l2 2 4-4"/>',
  LineIconName.users:
      '<circle cx="9" cy="8" r="3.5"/><path d="M3.5 20v-1a5 5 0 0 1 5-5h1a5 5 0 0 1 5 5v1"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a5 5 0 0 1 3 4.5V20"/>',
  LineIconName.logout:
      '<path d="M14 8V6a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1v-2"/><path d="M10 12h10M17 9l3 3-3 3"/>',
  LineIconName.download: '<path d="M12 4v11M8 11l4 4 4-4M5 19h14"/>',
  LineIconName.search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/>',
  LineIconName.bell: '<path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/>',
  // 线路列表改版（10-18）：精品锁着、测速按钮
  LineIconName.lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  LineIconName.gauge: '<path d="M4 18a8 8 0 1 1 16 0"/><path d="M12 18l4-6"/>',
};

class LineIcon extends StatelessWidget {
  const LineIcon(this.name, {super.key, required this.color, this.size = 18});

  final LineIconName name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    // 描边用黑色画，再整体染成 color（深浅色主题都跟着走）。
    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" '
        'stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">${_paths[name]}</svg>';
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
