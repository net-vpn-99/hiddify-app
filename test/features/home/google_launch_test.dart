import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/sites_catalog.dart';

void main() {
  test('Google quick button opens a search page instead of the regional home redirect', () {
    final uri = const SiteLink(id: 'google', name: 'Google', url: 'https://www.google.com/').launchUri;
    expect(uri.scheme, 'https');
    expect(uri.host, 'www.google.com');
    expect(uri.path, '/search');
    expect(uri.queryParameters['q'], isNotEmpty);
  });
  test('configured search queries and unrelated site URLs remain unchanged', () {
    const query = 'https://www.google.com/search?q=custom';
    expect(const SiteLink(id: 'google', name: 'Google', url: query).launchUri.toString(), query);
    expect(const SiteLink(id: 'other', name: 'Other', url: 'https://example.com/').launchUri.toString(), 'https://example.com/');
  });
}
