import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/model/transport_group.dart';

String tag(bool tcp, bool udp) => '$gslGroupPrefix${base64Url.encode(utf8.encode(jsonEncode({
  'id': 'ln_os05', 'name': '日本 大阪 05 双传输内测', 'revision': 1,
  'endpoints': [
    {'id': 'tcp', 'kind': 'tcp', 'available': tcp, 'tag': '${gslEndpointPrefix}tcp:abc§hide§'},
    {'id': 'udp', 'kind': 'udp', 'available': udp, 'tag': '${gslEndpointPrefix}udp:def§hide§'},
  ],
}))).replaceAll('=', '')}';

void main() {
  test('completed unconfirmed selection is no longer pending', () {
    expect(const TransportSelectionState(phase: 'unconfirmed').pending, isFalse);
    expect(const TransportSelectionState(phase: 'checking').pending, isTrue);
  });
  test('both unavailable endpoints remain an explicit unavailable logical group', () {
    expect(GslTransportGroup.tryParse(tag(false, false))!.available, isFalse);
    expect(GslTransportGroup.tryParse(tag(false, true))!.available, isTrue);
  });
  test('profile availability uses stable logical id and ignores unrelated names', () {
    final raw = jsonEncode({'outbounds': [{'tag': tag(false, false)}, {'tag': '普通节点'}]});
    expect(unavailableTransportGroups(raw), {'ln_os05'});
    expect(unavailableTransportGroups('invalid'), isEmpty);
  });
}
