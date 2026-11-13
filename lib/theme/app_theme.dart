import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Lazily-built but cached ThemeData. Building Material3 ThemeData isn't
/// cheap (it composes ColorScheme + all the sub-themes + text themes), so
/// computing it on every MaterialApp rebuild is wasted work and a noticeable
/// hitch when the user toggles theme mode.
///
/// Dynamic color (Material You, Android 12+): pass the wallpaper-derived
/// ColorScheme from DynamicColorBuilder via [lightThemeFromScheme] /
/// [darkThemeFromScheme]. The sub-themes are built from the scheme, so a
/// dynamic palette recolors the whole app; when no dynamic scheme is
/// available the built-in forest-green palette below is used instead.
/// Dynamic themes are memoized by scheme value, so toggling theme mode
/// doesn't rebuild them.
class AppTheme {
  static final ThemeData lightTheme = _buildLightTheme();
  static final ThemeData darkTheme = _buildDarkTheme();

  // Built-in fallback palettes (used when dynamic color is unavailable).
  static const ColorScheme _lightColorScheme = ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    primaryContainer: AppColors.primaryLight,
    onPrimaryContainer: AppColors.primary,

    secondary: AppColors.accent,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.accentLight,
    onSecondaryContainer: AppColors.accent,

    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceContainerHighest: Color(0xFFEEF2EF),
    surfaceContainer: Color(0xFFF2F5F2),
    surfaceContainerLow: Color(0xFFF6F8F6),
    surfaceContainerLowest: AppColors.surface,

    outline: AppColors.border,
    outlineVariant: AppColors.divider,
    shadow: Colors.black,

    error: AppColors.error,
    onError: Colors.white,
  );

  static const ColorScheme _darkColorScheme = ColorScheme.dark(
    primary: AppColors.primaryDark, // brighter forest green
    onPrimary: Colors.black,
    primaryContainer: Color(0xFF1F3F2F),
    onPrimaryContainer: AppColors.primaryDark,

    secondary: AppColors.accent,
    onSecondary: Colors.black,
    secondaryContainer: Color(0xFF3B231C),
    onSecondaryContainer: AppColors.accent,

    surface: Color(0xFF1B221C), // cards
    onSurface: Color(0xFFE6ECE7), // primary text
    onSurfaceVariant: Color(0xFFB2BDB4), // secondary text
    surfaceContainerHighest: Color(0xFF252D26), // chips, info panels
    surfaceContainer: Color(0xFF1F2620),
    surfaceContainerLow: Color(0xFF181D18),
    surfaceContainerLowest: Color(0xFF121712), // scaffold

    outline: Color(0xFF3A4239),
    outlineVariant: Color(0xFF2A2F2A),
    shadow: Colors.black,

    error: AppColors.error,
    onError: Colors.white,
  );

  static ColorScheme? _lastLightScheme;
  static ThemeData? _lastLightTheme;
  static ColorScheme? _lastDarkScheme;
  static ThemeData? _lastDarkTheme;

  /// 页面转场基线：Android 用预测性返回（PredictiveBack）转场，返回手势
  /// 会跟手显示上一页预览（Android 14+；更低版本回退到 FadeForwards）；
  /// Apple 平台保持 Cupertino 滑动手感，桌面统一 Zoom。
  /// 此前未配置，三端各走各自默认，体验不一致。
  static const PageTransitionsTheme _pageTransitionsTheme =
      PageTransitionsTheme(
    builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      TargetPlatform.linux: ZoomPageTransitionsBuilder(),
    },
  );

  /// Light theme for a dynamic [scheme]; null falls back to [lightTheme].
  static ThemeData lightThemeFromScheme(ColorScheme? scheme) {
    if (scheme == null) return lightTheme;
    if (scheme == _lastLightScheme && _lastLightTheme != null) {
      return _lastLightTheme!;
    }
    _lastLightScheme = scheme;
    return _lastLightTheme = _buildLightTheme(scheme);
  }

  /// Dark theme for a dynamic [scheme]; null falls back to [darkTheme].
  static ThemeData darkThemeFromScheme(ColorScheme? scheme) {
    if (scheme == null) return darkTheme;
    if (scheme == _lastDarkScheme && _lastDarkTheme != null) {
      return _lastDarkTheme!;
    }
    _lastDarkScheme = scheme;
    return _lastDarkTheme = _buildDarkTheme(scheme);
  }

  // ── Light ─────────────────────────────────────────────────────────
  static ThemeData _buildLightTheme([ColorScheme? scheme]) {
    final cs = scheme ?? _lightColorScheme;
    // Without a dynamic scheme we keep the warm-paper scaffold/app-bar
    // background; a dynamic scheme uses its own surface instead.
    final background =
        scheme == null ? AppColors.background : cs.surface;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: cs.primary,
      scaffoldBackgroundColor: background,
      colorScheme: cs,
      pageTransitionsTheme: _pageTransitionsTheme,

      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 2,
        shadowColor: const Color(0x0D000000),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 24,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: cs.onSurface),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surface,
        indicatorColor: cs.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
          }
          return const TextStyle(
              fontSize: 12, fontWeight: FontWeight.normal);
        }),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        hintStyle: TextStyle(color: cs.onSurfaceVariant),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
      ),

      // 全局兜底子主题（SnackBar / Dialog / BottomSheet）：此前三者的
      // 形状与浮起行为靠各调用点手写（app_snack、22 处 showDialog、
      // 9 处 showModalBottomSheet 各自为政），这里给方案驱动的默认值。
      // 调用点显式传入的参数仍然优先（home 更新提示的定制样式不受影响）。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(16),
          ),
        ),
        showDragHandle: false,
      ),
    );
  }

  // ── Dark ──────────────────────────────────────────────────────────
  static ThemeData _buildDarkTheme([ColorScheme? scheme]) {
    final cs = scheme ?? _darkColorScheme;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: cs.primary,
      scaffoldBackgroundColor: cs.surfaceContainerLowest,
      colorScheme: cs,
      pageTransitionsTheme: _pageTransitionsTheme,

      // Make all default text colors honor onSurface/onSurfaceVariant so
      // widgets that don't explicitly read colorScheme still pick up the
      // right color when the user is in dark mode.
      textTheme: TextTheme().apply(
        bodyColor: cs.onSurface,
        displayColor: cs.onSurface,
      ),

      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: cs.outlineVariant),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
        ),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: cs.surfaceContainerLowest,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 24,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: cs.onSurface),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surface,
        indicatorColor: cs.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
          }
          return const TextStyle(
              fontSize: 12, fontWeight: FontWeight.normal);
        }),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        hintStyle: TextStyle(color: cs.onSurfaceVariant),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
      ),

      // 与亮色主题相同的兜底子主题，见 _buildLightTheme 里的说明。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(16),
          ),
        ),
        showDragHandle: false,
      ),
    );
  }
}
