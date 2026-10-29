import 'dart:convert';
import 'dart:io';
import 'package:hiddify/features/profile/data/profile_recommendation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/model/subscription_recommendation.dart';
import 'package:hiddify/features/proxy/model/transport_group.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';

String group(String id) =>
    '$gslGroupPrefix${base64Url.encode(utf8.encode(jsonEncode({
      'id': id,
      'name': '日本 东京 01',
      'revision': 1,
      'endpoints': [
        {'id': '${id}_tcp', 'kind': 'tcp', 'host': '$id.invalid', 'port': 25443, 'available': true, 'tag': '${gslEndpointPrefix}${id}_tcp:abc§hide§'},
        {'id': '${id}_udp', 'kind': 'udp', 'host': '$id.invalid', 'port': 24443, 'available': true, 'tag': '${gslEndpointPrefix}${id}_udp:def§hide§'},
      ],
    }))).replaceAll('=', '')}';
String converted() => jsonEncode({
  'outbounds': [
    {'type': 'selector', 'tag': group('ln_a')},
    {'type': 'selector', 'tag': group('ln_b')},
    {'type': 'vless', 'tag': 'Legacy § 1', 'server': 'legacy.invalid', 'server_port': 443},
  ],
  'route': {'final': 'proxy'},
});
String envelope(Object? decision) => jsonEncode({
  'schema': 1,
  'subscription': 'opaque-fixture',
  'gsl_transports': {'schema': 1, 'groups': [], 'recommendation': decision},
});
Map<String, dynamic> selected({String host = 'ln_b.invalid', String? id = 'ln_b'}) => {
  'schema': 1,
  'status': 'selected',
  'logical_id': id,
  'endpoint': {'host': host, 'port': id == null ? 443 : 24443},
  'reason': 'available',
};
void main() {
  if(Platform.environment['LB_GO_FIXTURE'] != null) {
    test('real unchanged Go conversion binds policy and retains normal logical list',() async {
      final root=Platform.environment['LB_GO_FIXTURE']!;
      final original=await File('$root/go-envelope.json').readAsString();
      final converted=await File('$root/go-converted.json').readAsString();
      final saved=withConvertedRecommendation(original,converted);
      expect(SubscriptionRecommendation.read(saved).known,isTrue);
      expect(SubscriptionRecommendation.read(saved).selected,isFalse);
      expect(parseSubscriptionLines(saved).single.routeId,'ln_tokyo');
      await File('$root/go-marked.json').writeAsString(saved);
      final value=jsonDecode(original) as Map<String,dynamic>;
      value['gsl_transports']['recommendation']={'schema':1,'status':'selected','logical_id':'ln_tokyo','endpoint':{'host':'node.example','port':24443}};
      final selected=SubscriptionRecommendation.read(withConvertedRecommendation(jsonEncode(value),converted));
      expect(selected.selected,isTrue);expect(selected.logicalId,'ln_tokyo');
    });
  }

  test('failed conversion cannot replace an existing profile or lose its none marker', () async {
    final dir = await Directory.systemTemp.createTemp('gsl-recommendation-');
    final input = '${dir.path}/input.json';
    final output = '${dir.path}/profile.json';
    await File(input).writeAsString(envelope({'schema': 1, 'status': 'none'}));
    await File(output).writeAsString('old-profile');
    try {
      await expectLater(
        convertProfileWithRecommendation(input, output, (staging) async {
          await File(staging).writeAsString(converted());
          throw StateError('conversion failed');
        }),
        throwsStateError,
      );
      expect(await File(output).readAsString(), 'old-profile');
      await convertProfileWithRecommendation(input, output, (staging) async {
        await File(staging).writeAsString(converted());
        return 7;
      });
      expect(SubscriptionRecommendation.read(await File(output).readAsString()).known, isTrue);
    } finally {
      for (final f in await dir.list().toList()) {
        await f.delete();
      }
      await dir.delete();
    }
  });
  test('real profile file persistence retains decision on reload', () async {
    final dir = await Directory.systemTemp.createTemp('gsl-recommendation-');
    final path = '${dir.path}/profile.json';
    addTearDown(() async {
      await File(path).delete();
      await dir.delete();
    });
    await File(path).writeAsString(converted());
    await persistProfileRecommendation(envelope({'schema': 1, 'status': 'none'}), path);
    final saved = await File(path).readAsString();
    expect(SubscriptionRecommendation.read(saved).known, isTrue);
    expect(SubscriptionRecommendation.read(saved).defaultTag(['Legacy § 1']), isNull);
    expect(parseSubscriptionLines(saved).length, 3);
  });

  test('explicit none survives real conversion boundary and leaves all manual rows', () {
    final saved = withConvertedRecommendation(
      envelope({'schema': 1, 'status': 'none', 'logical_id': null, 'endpoint': null}),
      converted(),
    );
    final p = SubscriptionRecommendation.read(saved);
    expect(p.known, isTrue);
    expect(p.selected, isFalse);
    expect(p.defaultTag([group('ln_a'), group('ln_b')]), isNull);
    expect(parseSubscriptionLines(saved).length, 3);
    expect(jsonDecode(saved)['route'], {'final': 'proxy'});
  });
  test('selected binds actual available group endpoint, not first row or name', () {
    final p = SubscriptionRecommendation.read(withConvertedRecommendation(envelope(selected()), converted()));
    expect(p.selected, isTrue);
    expect(p.logicalId, 'ln_b');
    expect(p.defaultTag([group('ln_a'), group('ln_b')]), group('ln_b'));
  });
  test('standalone recommendation binds actual converted endpoint and remains manual', () {
    final p = SubscriptionRecommendation.read(
      withConvertedRecommendation(envelope(selected(host: 'legacy.invalid', id: null)), converted()),
    );
    expect(p.defaultTag(['other', 'Legacy § 1']), 'Legacy § 1');
  });
  test('foreign, damaged, unknown and missing selected targets fail closed', () {
    for (final d in [
      selected(host: 'foreign.invalid'),
      {'schema': 2, 'status': 'selected'},
      'broken',
      null,
    ]) {
      final p = SubscriptionRecommendation.read(withConvertedRecommendation(envelope(d), converted()));
      expect(p.known, isTrue);
      expect(p.defaultTag([group('ln_a')]), isNull);
    }
  });
  test('absence preserves old server semantics and does not inherit old none', () {
    expect(SubscriptionRecommendation.read(converted()).defaultTag(['legacy']), 'legacy');
    final old = withConvertedRecommendation(envelope({'schema': 1, 'status': 'none'}), converted());
    final refreshed = withConvertedRecommendation('legacy-subscription', old);
    expect(SubscriptionRecommendation.read(refreshed).known, isFalse);
  });
  test('cached conversion retains none and strips arbitrary policy data', () {
    final saved = withConvertedRecommendation(
      envelope({'schema': 1, 'status': 'none', 'password': 'must-not-persist'}),
      converted(),
    );
    final again = withConvertedRecommendation(saved, converted());
    expect(SubscriptionRecommendation.read(again).known, isTrue);
    expect(SubscriptionRecommendation.read(again).selected, isFalse);
    expect(again, isNot(contains('must-not-persist')));
  });
  test('incomplete selected identity cannot become standalone recommendation', () {
    final d = selected(host: 'legacy.invalid', id: null)..remove('logical_id');
    final p = SubscriptionRecommendation.read(withConvertedRecommendation(envelope(d), converted()));
    expect(p.selected, isFalse);
  });
  test('selected runtime tag missing never silently picks another line', () {
    final p = SubscriptionRecommendation.read(withConvertedRecommendation(envelope(selected()), converted()));
    expect(p.defaultTag([group('ln_a')]), isNull);
  });
}
