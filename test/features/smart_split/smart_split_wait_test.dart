import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/notifier/route_check_notifier.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_controller.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_notifier.dart';
import 'package:hiddify/features/smart_split/widget/smart_split_page.dart';

class _CountActions implements SplitActions {
  int chooses = 0;

  @override
  final Map<String, Uint8List?> icons = {};

  @override
  Future<void> choose(String key, String picked) async => chooses++;

  @override
  Future<void> startCollect() async {}

  @override
  void stopCollect() {}

  @override
  Future<void> resetOne(String key) async {}

  @override
  Future<void> resetAll() async {}

  @override
  Future<void> retrySync(String key) async {}

  @override
  void setDomainIncluded(String key, String domain, {required bool included}) {}
}

SplitRow _site(String host, String now) => SplitRow(
  SplitThing(key: 'site:$host')
    ..kind = 'site'
    ..name = host
    ..host = host
    ..domains = [host]
    ..now = now,
  now: now,
  choice: '',
  excluded: const {},
);

void main() {
  testWidgets('正在改时盖住页面，别的选项点不到', (tester) async {
    final actions = _CountActions();
    await tester.pumpWidget(
      MaterialApp(
        home: SmartSplitView(
          connected: true,
          state: SmartSplitState(
            connected: true,
            collecting: true,
            pickable: [_site('btsj6.com', 'proxy'), _site('dmit.io', 'proxy')],
            applying: const {'site:btsj6.com': 'direct'},
            rowNote: const {'site:btsj6.com': 'reconnecting'},
          ),
          check: const RouteCheckState(status: 'idle'),
          lineName: '',
          actions: actions,
          onRecheck: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('请等一下'), findsOneWidget);
    expect(find.text('正在让这个网站走本地。'), findsWidgets);
    expect(find.text('走光速雷达').hitTestable(), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    expect(actions.chooses, 0);
  });

  testWidgets('没在改的时候不盖住', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SmartSplitView(
          connected: true,
          state: SmartSplitState(connected: true, collecting: true, pickable: [_site('btsj6.com', 'proxy')]),
          check: const RouteCheckState(status: 'idle'),
          lineName: '',
          actions: _CountActions(),
          onRecheck: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('请等一下'), findsNothing);
    expect(find.text('走本地').hitTestable(), findsOneWidget);
  });
}
