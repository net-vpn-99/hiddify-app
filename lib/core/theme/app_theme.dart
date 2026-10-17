import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';

class AppTheme {
  AppTheme(this.mode, this.fontFamily);
  final AppThemeMode mode;
  final String fontFamily;

  // 只用来让 Material 算出没被覆盖的边角色；看得见的颜色全部在 _build 里从 OneRayTokens 覆盖。
  static final Color _brandSeed = OneRayTokens.light.acc;

  ThemeData lightTheme(ColorScheme? lightColorScheme) =>
      _build(lightColorScheme ?? ColorScheme.fromSeed(seedColor: _brandSeed), OneRayTokens.light, null);

  ThemeData darkTheme(ColorScheme? darkColorScheme) => _build(
    darkColorScheme ?? ColorScheme.fromSeed(seedColor: _brandSeed, brightness: Brightness.dark),
    OneRayTokens.dark,
    mode.trueBlack ? Colors.black : null,
  );

  /// B「夜航」（10-17 定稿，docs/计划/界面改版-B夜航.md §3.4）：只有一种强调色；
  /// 按钮三种（强调色实心胶囊 / panel 浅底胶囊 / line 描边只给断开取消）；卡片不描边；
  /// 输入框 panel 底不描边、出错一圈 fault。颜色全从 OneRayTokens 取。
  ThemeData _build(ColorScheme seed, OneRayTokens tk, Color? trueBlack) {
    final background = trueBlack ?? tk.bg;
    final scheme = seed.copyWith(
      primary: tk.acc,
      onPrimary: tk.accInk,
      primaryContainer: tk.accSoft,
      onPrimaryContainer: tk.accHover,
      secondary: tk.sub,
      surface: background,
      onSurface: tk.text,
      onSurfaceVariant: tk.sub,
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: tk.card,
      surfaceContainerLow: tk.card,
      surfaceContainer: tk.card,
      surfaceContainerHigh: tk.card,
      surfaceContainerHighest: tk.panel,
      outline: tk.sub,
      outlineVariant: tk.ring,
      error: tk.fault,
      errorContainer: tk.faultSoft,
      onErrorContainer: tk.fault,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: fontFamily,
      appBarTheme: AppBarTheme(backgroundColor: background, surfaceTintColor: Colors.transparent, foregroundColor: tk.text),
      cardTheme: CardThemeData(
        color: tk.card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: tk.card,
        surfaceTintColor: Colors.transparent,
        indicatorColor: tk.accSoft,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? tk.acc : tk.sub),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? tk.acc : tk.sub,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: tk.acc,
          foregroundColor: tk.accInk,
          disabledBackgroundColor: tk.acc.withValues(alpha: 0.48),
          disabledForegroundColor: tk.accInk,
          minimumSize: const Size(64, 52),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      // 次按钮：panel 浅底胶囊。
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: tk.panel,
          foregroundColor: tk.text,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: const Size(64, 48),
          shape: const StadiumBorder(),
        ),
      ),
      // 断开 / 取消：唯一允许描边的按钮。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: tk.text,
          side: BorderSide(color: tk.line),
          minimumSize: const Size(64, 48),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: tk.acc)),
      // 切换标签：panel 底槽 + 选中那格 sheet 底强调色字（以前 Material 默认算出土黄）。
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? tk.sheet : tk.panel),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? tk.acc : tk.sub),
          side: WidgetStatePropertyAll(BorderSide(color: tk.panel, width: 3)),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
          visualDensity: VisualDensity.compact,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(OneRayTokens.paper),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? tk.acc : tk.line),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tk.panel,
        hintStyle: TextStyle(color: tk.dim),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: tk.acc, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: tk.fault),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: tk.fault, width: 1.5),
        ),
        errorStyle: TextStyle(color: tk.fault),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tk.sheet,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: tk.scrim,
        showDragHandle: true,
        dragHandleColor: tk.ring,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tk.sheet,
        surfaceTintColor: Colors.transparent,
        barrierColor: tk.scrim,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      // 提示条：深色模式浅底深字、浅色模式深底白字（§3.4）。
      snackBarTheme: SnackBarThemeData(
        backgroundColor: tk.text,
        contentTextStyle: TextStyle(color: tk.bg),
        actionTextColor: tk.bg,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: tk.panel,
        selectedColor: tk.acc,
        labelStyle: TextStyle(color: tk.sub),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: tk.acc, linearTrackColor: tk.panel),
      dividerTheme: DividerThemeData(color: tk.ring.withValues(alpha: 0.6)),
    );
  }

  CupertinoThemeData cupertinoThemeData(bool sysDark, ColorScheme? lightColorScheme, ColorScheme? darkColorScheme) {
    final bool isDark = switch (mode) {
      AppThemeMode.system => sysDark,
      AppThemeMode.light => false,
      AppThemeMode.dark => true,
      AppThemeMode.black => true,
    };
    final def = CupertinoThemeData(brightness: isDark ? Brightness.dark : Brightness.light);
    // final def = CupertinoThemeData(brightness: Brightness.dark);

    // return def;
    final defaultMaterialTheme = isDark ? darkTheme(darkColorScheme) : lightTheme(lightColorScheme);
    return MaterialBasedCupertinoThemeData(
      materialTheme: defaultMaterialTheme.copyWith(
        cupertinoOverrideTheme: def.copyWith(
          textTheme: CupertinoTextThemeData(
            textStyle: def.textTheme.textStyle.copyWith(fontFamily: fontFamily),
            actionTextStyle: def.textTheme.actionTextStyle.copyWith(fontFamily: fontFamily),
            navActionTextStyle: def.textTheme.navActionTextStyle.copyWith(fontFamily: fontFamily),
            navTitleTextStyle: def.textTheme.navTitleTextStyle.copyWith(fontFamily: fontFamily),
            navLargeTitleTextStyle: def.textTheme.navLargeTitleTextStyle.copyWith(fontFamily: fontFamily),
            pickerTextStyle: def.textTheme.pickerTextStyle.copyWith(fontFamily: fontFamily),
            dateTimePickerTextStyle: def.textTheme.dateTimePickerTextStyle.copyWith(fontFamily: fontFamily),
            tabLabelTextStyle: def.textTheme.tabLabelTextStyle.copyWith(fontFamily: fontFamily),
          ).copyWith(),
          barBackgroundColor: def.barBackgroundColor,
          scaffoldBackgroundColor: def.scaffoldBackgroundColor,
        ),
      ),
    );
  }
}
