import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/data/split_diag.dart';

void main() {
  test('规则文件不在', () {
    expect(splitDiag(), '规则文件不在。内核用的还是上一次的。');
  });

  test('写了走本地，重新打开后图片网址仍走光速雷达', () {
    final text = splitDiag(
      routeJson: '{"user_direct":["btsj6.com","anycip.com"],"user_proxy":[]}',
      boxLog: 'INFO [1 9ms] outbound/direct[direct]: outbound connection to www.btsj6.com:443\n'
          'INFO [2 9ms] outbound/vless[美国 洛杉矶 07]: outbound connection to imgb.anycip.com:443\n',
    );
    expect(text, contains('走本地：btsj6.com、anycip.com'));
    expect(text, contains('内核没有报读失败'));
    expect(text, contains('www.btsj6.com 走了本地。'));
    expect(text, contains('imgb.anycip.com 仍走光速雷达。'));
    expect(text, isNot(contains('example.com')));
  });

  test('域名被藏起来：日志里没有改过的网址，只有 cloudflare-ech', () {
    final text = splitDiag(
      routeJson: '{"user_direct":["anycip.com"]}',
      boxLog: 'INFO [3 9ms] outbound/vless[x]: outbound connection to cloudflare-ech.com:443\n'
          'INFO [4 9ms] outbound/vless[x]: outbound connection to 104.16.1.2:443\n',
    );
    expect(text, contains('一条都没出现'));
    expect(text, contains('cloudflare-ech.com'));
    expect(text, contains('只有 IP'));
    expect(text, isNot(contains('104.16.1.2')));
  });

  test('内核报了没读成', () {
    final text = splitDiag(
      routeJson: '{"user_direct":["btsj6.com"]}',
      stderr: '[gsl-route] skip gsl-route.json: unexpected end of JSON\n',
    );
    expect(text, contains('内核没读成'));
    expect(text, contains('还没有连接日志'));
  });

  test('一个网址都没写进去', () {
    expect(splitDiag(routeJson: '{"user_direct":[],"user_proxy":[]}'), contains('一个网址都没写进规则'));
  });
}
