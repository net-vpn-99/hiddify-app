import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';

/// 10-25 诊断 75AA-1025：连上后关检测连接时，关一个连接会同步跑完它那次请求的 finally（从集合里删掉自己），
/// 正在遍历的集合被改了 → 抛 Concurrent modification，`_confirm` 没走完，首页一直停在「第 5/5 步」。
/// 跑法：flutter test test/features/connection/close_warm_clients_test.dart
void main() {
  test('关的时候自己从集合里删掉也不出错，全部关掉、集合清空', () {
    final clients = <int>{1, 2, 3};
    final closed = <int>[];
    closeAllWarm<int>(clients, (c) {
      closed.add(c);
      clients.remove(c);
    });
    expect(closed..sort(), [1, 2, 3]);
    expect(clients, isEmpty);
  });
}
