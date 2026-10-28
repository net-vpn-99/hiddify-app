import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/model/transport_group.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/panel_auth/data/own_subscribe.dart';

String groupTag(String id) =>
    'gsl-ln-v1:${base64Url.encode(utf8.encode(jsonEncode({
      'id': id,
      'name': '日本 东京 01 | 标准线路',
      'revision': 1,
      'endpoints': [
        {'id': '${id}_tcp', 'host': 'node.example', 'port': 25443, 'kind': 'tcp', 'available': true, 'tag': 'gsl-ep-v1:${id}_tcp:0123456789abcdef§hide§'},
        {'id': '${id}_udp', 'host': 'node.example', 'port': 24443, 'kind': 'udp', 'available': true, 'tag': 'gsl-ep-v1:${id}_udp:0123456789abcdef§hide§'},
      ],
    }))).replaceAll('=', '')}';

void main() {
  test('same display name never substitutes another explicit logical identity', () {
    final a = splitNodeName(groupTag('ln_a'));
    final b = splitNodeName(groupTag('ln_b'));
    expect(sameNodeIdentity(a, b), isFalse);
    expect(sameNodeIdentity(a, splitNodeName(groupTag('ln_a'))), isTrue);
    expect(sameNodeIdentity(a, splitNodeName(a.name)), isFalse);
  });

  test('logical identity decodes and renders its human name', () {
    final tag = groupTag('ln_tokyo');
    expect(GslTransportGroup.tryParse(tag)?.id, 'ln_tokyo');
    expect(splitNodeName(tag).name, '日本 东京 01');
    expect(splitNodeName(tag).routeId, 'ln_tokyo');
  });
  test('one logical row hides its physical members without merging different IDs', () {
    final lines = parseSubscriptionLines(
      jsonEncode({
        'outbounds': [
          {'type': 'selector', 'tag': groupTag('ln_a')},
          {'type': 'selector', 'tag': groupTag('ln_b')},
          {'type': 'vless', 'tag': 'gsl-ep-v1:ln_a_tcp:0123456789abcdef§hide§'},
        ],
      }),
    );
    expect(lines.length, 2);
    expect(lines.map((e) => e.routeId), ['ln_a', 'ln_b']);
  });
  test('malformed or unversioned metadata is not a logical group', () {
    expect(GslTransportGroup.tryParse('gsl-ln-v1:invalid'), isNull);
    expect(GslTransportGroup.tryParse('日本 东京 01'), isNull);
  });
  test('only own known panel subscription opts in and preserves token', () {
    final own = Uri.parse(
      withOwnTransportSchema('https://api-hk.paperkiln.download/api/v1/client/subscribe?token=a%2Bb'),
    );
    expect(own.queryParameters['gsl_transport_schema'], '1');
    expect(own.queryParameters['flag'], 'general');
    expect(own.queryParameters['token'], 'a+b');
    const other = 'https://third-party.example/api/v1/client/subscribe?token=x';
    expect(withOwnTransportSchema(other), other);
  });
}
