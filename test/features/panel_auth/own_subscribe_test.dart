import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/panel_auth/data/own_subscribe.dart';

void main() {
  group('looksLikeOwnPanelSubscribe', () {
    test('accepts standard Xboard subscribe URL', () {
      expect(
        looksLikeOwnPanelSubscribe(
          'https://api-hk.inkspindle.com/api/v1/client/subscribe?token=abc',
        ),
        isTrue,
      );
    });

    test('rejects clash and other third-party links', () {
      expect(looksLikeOwnPanelSubscribe('https://example.com/clash.yaml'), isFalse);
      expect(looksLikeOwnPanelSubscribe('https://api-hk.inkspindle.com/not-subscribe?token=abc'), isFalse);
      expect(looksLikeOwnPanelSubscribe('https://api-hk.inkspindle.com/api/v1/client/subscribe'), isFalse);
    });

    test('other Xboard providers share the same path and must not be treated as ours', () {
      const foreign = 'https://unrelated-provider.example/api/v1/client/subscribe?token=demo';
      expect(looksLikeOwnPanelSubscribe(foreign), isTrue);
      expect(isKnownPanelHost(foreign), isFalse);
      expect(isOwnAccountSubscribeSource(foreign), isFalse);
    });

    test('known panel subscribe URL is account-importable', () {
      expect(
        isOwnAccountSubscribeSource(
          'https://api-hk.inkspindle.com/api/v1/client/subscribe?token=abc',
        ),
        isTrue,
      );
    });
  });

  group('buildOwnSubscribeUrl', () {
    test('rebuilds from current API and encodes token', () {
      expect(
        buildOwnSubscribeUrl(
          apiBase: 'https://api.gsldone.com/',
          token: 'a b',
          originalUrl: 'https://old.example/api/v1/client/subscribe?token=old&flag=1',
        ),
        'https://api.gsldone.com/api/v1/client/subscribe?token=a+b&flag=1',
      );
    });

    test('leaves third-party URL alone when there is no token', () {
      expect(
        buildOwnSubscribeUrl(
          apiBase: 'https://api-hk.inkspindle.com',
          originalUrl: 'https://example.com/clash.yaml',
        ),
        'https://example.com/clash.yaml',
      );
    });
  });
}
