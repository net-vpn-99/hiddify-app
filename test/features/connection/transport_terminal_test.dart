import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/proxy/model/transport_group.dart';

class _Connection extends ConnectionNotifier {
  int stops = 0;
  @override
  Stream<ConnectionStatus> build() async* { yield const Connected(); }
  @override
  Future<void> abortConnection() async { stops++; }
}
class _Reporter extends ConnectReporter {
  _Reporter(super.ref);
  final cancellations = <String>[];
  @override
  bool get attemptOpen => true;
  @override
  Future<void> reportCancel(String stepSlug, {String? detail}) async { cancellations.add(stepSlug); }
}
void main() {
  test('completed unknown ends cold-start verification without reporting a dead tunnel', () async {
    late _Connection connection;
    late _Reporter reporter;
    final container = ProviderContainer(overrides: [
      connectionNotifierProvider.overrideWith(() => connection = _Connection()),
      connectReporterProvider.overrideWith((ref) => reporter = _Reporter(ref)),
      transportSelectionProvider.overrideWith((ref) => const TransportSelectionState(group: 'test-group', phase: 'checking')),
    ]);
    addTearDown(container.dispose);
    container.listen(stabilityProvider, (_, __) {});
    await container.read(connectionNotifierProvider.future);
    await Future<void>.delayed(Duration.zero);
    container.read(transportSelectionProvider.notifier).state = const TransportSelectionState(
      group: 'test-group', phase: 'unconfirmed', reason: 'all_requests_ended',
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(connectProgressProvider).failedStep, 5);
    expect(container.read(connectProgressProvider).title, '线路尚未确认');
    expect(container.read(connectProgressProvider).unconfirmed, isTrue);
    expect(container.read(stabilityProvider).confirmed, isFalse);
    expect(reporter.cancellations, ['verify']);
    expect(connection.stops, 1);
  });
}
