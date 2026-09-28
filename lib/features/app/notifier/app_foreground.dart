import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 最近一次生命周期是不是 resumed。
/// inactive / paused / hidden 都算不在前台：切出去用别的 App 时不能据此判线路不通。
final appForegroundProvider = StateProvider<bool>((ref) => true);
