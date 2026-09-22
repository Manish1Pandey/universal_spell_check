import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native checker finds misspellings with correct ranges', (
    WidgetTester tester,
  ) async {
    final UniversalSpellCheckService service = UniversalSpellCheckService(
      backend: kIsWeb ? SpellCheckBackend.hunspell : SpellCheckBackend.auto,
    );
    const Locale enUS = Locale('en', 'US');
    const String text = '😀 I recieve teh mesage';
    final List<SuggestionSpan>? spans = await service
        .fetchSpellCheckSuggestions(enUS, text);
    debugPrint('availability: ${await service.availability(enUS)}');
    debugPrint('native languages: ${await service.nativeLanguages()}');
    debugPrint('spans: $spans');
    expect(spans, isNotNull);
    expect(
      spans!.map(
        (SuggestionSpan s) => text.substring(s.range.start, s.range.end),
      ),
      <String>['recieve', 'teh', 'mesage'],
    );
    expect(spans.first.suggestions, contains('receive'));
    final SpellCheckAvailability a = await service.availability(enUS);
    expect(a.isAvailable, isTrue);
  });
}
