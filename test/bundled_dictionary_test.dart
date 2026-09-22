// End-to-end through the service with the bundled asset (no dart:io).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled en_US works through the service end to end', () async {
    final UniversalSpellCheckService s = UniversalSpellCheckService(
      backend: SpellCheckBackend.hunspell,
    );
    const String text = 'Ths sentense has 2 speling errrors, don’t it?';
    final List<SpellCheckRange>? r = await s.check(
      const Locale('en', 'US'),
      text,
    );
    expect(
      r!.map((SpellCheckRange x) => text.substring(x.start, x.end)),
      <String>['Ths', 'sentense', 'speling', 'errrors'],
    );
    expect(r[1].suggestions.first, 'sentence');
    expect(r[2].suggestions.first, 'spelling');
    expect(r[3].suggestions.first, 'errors');
    await HunspellSpellChecker.disposeShared();
  });
}
