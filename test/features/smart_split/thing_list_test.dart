import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/model/public_suffix.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 名单和主域名（跟 Windows split_test.cpp 同名用例一样）。跑法：flutter test test/features/smart_split
void main() {
  final psl = PublicSuffix.parse(File('assets/split/public_suffix_list.dat').readAsStringSync());
  const json = '''
{"version":3,"things":[
 {"id":"wechat","name":"微信","domains":["weixin.qq.com"],"lock":"direct","apps":["weixin","com.tencent.mm"]},
 {"id":"qq","name":"QQ","domains":["qq.com"]},
 {"id":"","name":"没 id","domains":["x.com"]},
 {"id":"steam","name":"Steam","apps":["Steam"],"lock":"split"}],
 "shared":["jsdelivr.net"],
 "must":{"proxy":["akamaihd.net"],"direct":["icbc.com.cn"]}}''';

  test('testMatchSuffix：最长后缀先认', () {
    final l = ThingList.parse(json)!;
    expect(l.match('szminorshort.weixin.qq.com')!.id, 'wechat');
    expect(l.match('im.qq.com')!.id, 'qq');
    expect(l.match('example.org'), isNull);
    expect(l.size, 3);
  });

  test('App 按包名认，大小写不管', () {
    final l = ThingList.parse(json)!;
    expect(l.matchApp('com.tencent.mm')!.id, 'wechat');
    expect(l.matchApp('steam.exe')!.id, 'steam');
  });

  test('testMustDomains', () {
    final l = ThingList.parse(json)!;
    expect(l.mustLock('a248.e.akamaihd.net'), 'proxy');
    expect(l.mustLock('www.icbc.com.cn'), 'direct');
    expect(l.mustLock('btsj6.com'), '');
    expect(l.isShared('cdn.jsdelivr.net'), isTrue);
  });

  test('坏 JSON、没有东西返回 null；新名单少掉一大半不换', () {
    expect(ThingList.parse('{oops'), isNull);
    expect(ThingList.parse('{"things":[]}'), isNull);
    final now = ThingList.parse(json)!;
    expect(ThingList.pickNewer(now, json), isNull); // 版本一样
    expect(ThingList.pickNewer(now, json.replaceFirst('"version":3', '"version":4'))!.version, 4);
  });

  test('testRegistrable', () {
    expect(psl.registrable('imgb.anycip.com'), 'anycip.com');
    expect(psl.registrable('xxx.github.io'), 'xxx.github.io');
    expect(psl.registrable('www.bbc.co.uk'), 'bbc.co.uk');
    expect(psl.registrable('com'), 'com');
  });

  test('App 里带的种子名单读得懂', () {
    expect(ThingList.parse(File('assets/split/things-seed.json').readAsStringSync()), isNotNull);
  });
}
