import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/data/box_log_parser.dart';
import 'package:hiddify/features/smart_split/data/clash_conns.dart';
import 'package:hiddify/features/smart_split/data/collector.dart';

/// 采集读 box.log；脱敏格式样例保留连接号、重复出站行和 DNS 行，网址使用保留测试域。
/// 跑法：flutter test test/features/smart_split
void main() {
  final sample = File('test/fixtures/split/box-sample.txt').readAsStringSync();

  test('testPairPackageAndHost：同一个连接号拼上包名和网址，出站行重复的只算一次', () {
    final conns = parseBoxLog(sample);
    final edge = conns.where((c) => c.pkg == 'com.microsoft.emmx').map((c) => c.host).toList();
    expect(edge, ['www.example.test', 'm.example.test', 'img.example.test']);
  });

  test('testDirectVsProxy', () {
    final conns = parseBoxLog(sample);
    expect(conns.firstWhere((c) => c.host == 'location.example.test').outbound, 'direct');
    expect(conns.firstWhere((c) => c.host == 'www.example.test').outbound, 'proxy');
  });

  test('testIgnoreLinesWithoutId：DNS 那几行、没有连接号的行不出连接', () {
    final conns = parseBoxLog(sample);
    expect(conns.length, 4);
    expect(conns.every((c) => c.id.isNotEmpty), isTrue);
  });

  test('包名行和出站行分两次读到也拼得上', () {
    final p = BoxLogParser();
    expect(p.feed('INFO [7 1ms] router: found package name: com.android.chrome\n'), isEmpty);
    final c = p.feed('INFO [7 9ms] outbound/direct[direct §hide§]: outbound connection to a.example.com:443\n');
    expect(c.single.pkg, 'com.android.chrome');
    expect(c.single.host, 'a.example.com');
  });

  group('Collector', () {
    late Directory dir;
    late File log;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('split');
      log = File('${dir.path}/box.log');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    String conn(int id, String host) =>
        'INFO [$id 1ms] router: found package name: com.android.chrome\n'
        'INFO [$id 9ms] outbound/vless[x]: outbound connection to $host:443\n';

    test('testStartIgnoresOld：开始之前已经在文件里的不算', () {
      log.writeAsStringSync(conn(1, 'old.example.com'));
      final c = Collector(log)..start();
      log.writeAsStringSync(conn(2, 'new.example.com'), mode: FileMode.append);
      expect(c.poll().map((x) => x.host), ['new.example.com']);
    });

    test('testTruncateKeepsRecords：重连清空 box.log，已采到的留着，之后的接着记', () {
      log.writeAsStringSync('');
      final c = Collector(log)..start();
      log.writeAsStringSync(conn(1, 'a.com') + conn(2, 'b.com') + conn(3, 'c.com'), mode: FileMode.append);
      expect(c.poll().length, 3);
      log.writeAsStringSync(conn(4, 'd.com'));
      expect(c.poll().map((x) => x.host), ['a.com', 'b.com', 'c.com', 'd.com']);
    });

    test('半行先不读，写完了再读', () {
      log.writeAsStringSync('');
      final c = Collector(log)..start();
      final line = conn(5, 'half.example.com');
      log.writeAsStringSync(line.substring(0, line.length - 10), mode: FileMode.append);
      expect(c.poll(), isEmpty);
      log.writeAsStringSync(line.substring(line.length - 10), mode: FileMode.append);
      expect(c.poll().single.host, 'half.example.com');
    });

    test('stop 以后清空，文件不存在也不出错', () {
      final c = Collector(File('${dir.path}/nope.log'))..start();
      expect(c.poll(), isEmpty);
      c.stop();
      expect(c.poll(), isEmpty);
    });
  });

  test('testCloseConnsPicksBrowserIdle：只挑浏览器的、下得少的 TCP', () {
    final body = jsonEncode({
      'connections': [
        {'id': 'a', 'metadata': {'network': 'tcp', 'processPath': 'com.android.chrome'}, 'upload': 100, 'download': 2000},
        {'id': 'b', 'metadata': {'network': 'tcp', 'processPath': 'com.android.chrome'}, 'upload': 0, 'download': 5000000},
        {'id': 'c', 'metadata': {'network': 'udp', 'processPath': 'com.android.chrome'}, 'upload': 0, 'download': 10},
        {'id': 'd', 'metadata': {'network': 'tcp', 'processPath': 'com.tencent.mm'}, 'upload': 0, 'download': 10},
        {'id': 'e', 'metadata': {'network': 'tcp', 'processPath': 'com.microsoft.emmx (10123)'}, 'upload': 0, 'download': 10},
      ],
    });
    expect(pickBrowserConns(body, {'com.android.chrome', 'com.microsoft.emmx'}), ['a', 'e']);
    expect(pickBrowserConns('not json', {'com.android.chrome'}), isEmpty);
  });

  test('从内核配置读出接口地址和密码', () {
    final api = readClashApi(jsonEncode({
      'experimental': {
        'clash_api': {'external_controller': '127.0.0.1:27756', 'secret': 's3'},
      },
    }));
    expect(api!.base, 'http://127.0.0.1:27756');
    expect(api.secret, 's3');
    expect(readClashApi('{}'), isNull);
    expect(readClashApi('oops'), isNull);
  });

  test('testCloseConnsNoConfig：配置文件不存在关 0 条', () async {
    expect(await closeBrowserConns('${Directory.systemTemp.path}/no-such-config.json', {'com.android.chrome'}), 0);
  });
}
