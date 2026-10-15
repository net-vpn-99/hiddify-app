import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';

class AppTheme {
  AppTheme(this.mode, this.fontFamily);
  final AppThemeMode mode;
  final String fontFamily;

  // OneRay / 光速 brand seed (warm gold "beam"). Was Hiddify's 0xFF293CA0 blue.
  static const Color _brandSeed = Color(0xFFF0BD35);

  ThemeData lightTheme(ColorScheme? lightColorScheme) =>
      _build(lightColorScheme ?? ColorScheme.fromSeed(seedColor: _brandSeed), PurchaseTokens.light, null);

  ThemeData darkTheme(ColorScheme? darkColorScheme) => _build(
    darkColorScheme ?? ColorScheme.fromSeed(seedColor: _brandSeed, brightness: Brightness.dark),
    PurchaseTokens.dark,
    mode.trueBlack ? Colors.black : null,
  );

  /// 全 App 统一成「我的」页那套（GoMami 式，运营 10-15）：暖浅灰底、白卡、橙色主按钮、
  /// 底栏白底橙色选中。颜色全从 PurchaseTokens 取，Material 从种子算出来的米色 / 橄榄棕不用。
  ThemeData _build(ColorScheme seed, PurchaseTokens tk, Color? trueBlack) {
    final background = trueBlack ?? tk.background;
    final scheme = seed.copyWith(
      primary: tk.primary,
      onPrimary: tk.onPrimary,
      primaryContainer: tk.selected,
      onPrimaryContainer: tk.primaryHover,
      secondary: tk.secondary,
      surface: background,
      onSurface: tk.text,
      onSurfaceVariant: tk.secondary,
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: tk.raised,
      surfaceContainerLow: tk.raised,
      surfaceContainer: tk.raised,
      surfaceContainerHigh: tk.surface,
      surfaceContainerHighest: tk.fill,
      outline: tk.secondary,
      outlineVariant: tk.border,
      error: tk.empty,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: fontFamily,
      appBarTheme: AppBarTheme(backgroundColor: background, surfaceTintColor: Colors.transparent, foregroundColor: tk.text),
      cardTheme: CardThemeData(
        color: tk.raised,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: tk.raised,
        surfaceTintColor: Colors.transparent,
        indicatorColor: tk.selected,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? tk.primary : tk.secondary),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? tk.primary : tk.secondary,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(backgroundColor: tk.primary, foregroundColor: tk.onPrimary),
      ),
      dividerTheme: DividerThemeData(color: tk.border.withValues(alpha: 0.6)),
      extensions: const <ThemeExtension<dynamic>>{ConnectionButtonTheme.light},
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
