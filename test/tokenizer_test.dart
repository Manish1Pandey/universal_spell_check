import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

void main() {
  test('splits words and reports UTF-16 offsets', () {
    expect(tokenizeWords('Hello, world!'), const <WordToken>[
      WordToken('Hello', 0, 5),
      WordToken('world', 7, 12),
    ]);
  });

  test('offsets stay correct after emoji (surrogate pairs)', () {
    const String text = '😀 teh 👍🏽 cat';
    final List<WordToken> t = tokenizeWords(text);
    expect(t.map((WordToken w) => w.text), <String>['teh', 'cat']);
    for (final WordToken w in t) {
      expect(text.substring(w.start, w.end), w.text);
    }
    expect(t.first.start, 3);
  });

  test('keeps inner apostrophes and hyphens, drops outer ones', () {
    expect(
      tokenizeWords(
        "'don't' e-mail -dash- rock’n’roll",
      ).map((WordToken w) => w.text),
      <String>["don't", 'e-mail', 'dash', 'rock’n’roll'],
    );
  });

  test('skips URLs, e-mail addresses and pure numbers', () {
    expect(
      tokenizeWords(
        'see https://exmaple.com/pth www.foo.org mail me@exmaple.com 42 3.14 21st',
      ).map((WordToken w) => w.text),
      <String>['see', 'mail', '21st'],
    );
  });

  test('handles non-Latin scripts and combining marks', () {
    expect(
      tokenizeWords('naïve café Привет').map((WordToken w) => w.text),
      <String>['naïve', 'café', 'Привет'],
    );
    // "e" + COMBINING ACUTE ACCENT stays one word.
    expect(tokenizeWords('café ok').first.text, 'café');
  });

  test('extra word characters', () {
    expect(
      tokenizeWords(
        'C# and F#',
        extraWordChars: '#',
      ).map((WordToken w) => w.text),
      <String>['C#', 'and', 'F#'],
    );
  });

  test('empty text', () {
    expect(tokenizeWords(''), isEmpty);
    expect(tokenizeWords('   \n\t'), isEmpty);
  });
}
