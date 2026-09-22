import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';
import 'package:universal_spell_check/src/hunspell/text_checker.dart';

import 'test_dictionary.dart';

void main() {
  late HunspellTextChecker checker;

  setUpAll(() {
    checker = HunspellTextChecker(Hunspell(enUsDictionary));
  });

  test('ranges cover exactly the misspelled words', () {
    const String text = 'I recieve teh mesage tomorow.';
    final List<SpellCheckRange> r = checker.checkText(text);
    expect(
      r.map((SpellCheckRange x) => text.substring(x.start, x.end)),
      <String>['recieve', 'teh', 'mesage', 'tomorow'],
    );
    expect(r[0].start, 2);
    expect(r[0].end, 9);
    expect(r[0].suggestions.first, 'receive');
    expect(r[1].suggestions.first, 'the');
    expect(r[2].suggestions, contains('message'));
    expect(r[3].suggestions, contains('tomorrow'));
  });

  test('ranges are UTF-16 offsets that survive emoji', () {
    const String text = '👋🏽 Helo 😀 wrold';
    final List<SpellCheckRange> r = checker.checkText(text);
    expect(
      r.map((SpellCheckRange x) => text.substring(x.start, x.end)),
      <String>['Helo', 'wrold'],
    );
    expect(r.first.suggestions.first, 'Hello');
    expect(r.last.suggestions.first, 'world');
  });

  test('only the misspelled part of a hyphenated word is marked', () {
    const String text = 'a well-knwn fact';
    final List<SpellCheckRange> r = checker.checkText(text);
    expect(r, hasLength(1));
    expect(text.substring(r.single.start, r.single.end), 'knwn');
    expect(r.single.suggestions, contains('known'));
  });

  test('results are sorted, non-overlapping and convert to SuggestionSpan', () {
    const String text = 'teh teh qwzx, recieve. Correct words here.';
    final List<SpellCheckRange> r = checker.checkText(text);
    for (int i = 1; i < r.length; i++) {
      expect(r[i].start, greaterThanOrEqualTo(r[i - 1].end));
    }
    final SuggestionSpan span = r.first.toSuggestionSpan();
    expect(span.range, const TextRange(start: 0, end: 3));
    expect(span.suggestions.first, 'the');
    expect(SpellCheckRange.fromSuggestionSpan(span), r.first);
  });

  test('maxSuggestions limits and can disable suggestions', () {
    expect(
      checker.checkText('thier', maxSuggestions: 1).single.suggestions,
      <String>['their'],
    );
    expect(
      checker.checkText('thier', maxSuggestions: 0).single.suggestions,
      isEmpty,
    );
  });

  test('cooperative checking returns the same result', () async {
    const String text = 'Ths is a longr text with sevral typos in it.';
    expect(await checker.checkTextCooperatively(text), checker.checkText(text));
  });

  test('correct text yields no ranges', () {
    expect(
      checker.checkText(
        "The quick brown fox doesn't jump over 21st-century dogs.",
      ),
      isEmpty,
    );
  });
}
