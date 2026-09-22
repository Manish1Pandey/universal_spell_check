import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

import 'test_dictionary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HunspellSpellChecker', () {
    for (final bool useIsolate in <bool>[true, false]) {
      test('checks text (useIsolate: $useIsolate)', () async {
        final HunspellSpellChecker c = HunspellSpellChecker(
          HunspellSource.text(enUsAff, enUsDic),
          useIsolate: useIsolate,
        );
        addTearDown(c.dispose);
        final List<SpellCheckRange> r = await c.check('Helo wrold');
        expect(r, hasLength(2));
        expect((r[0].start, r[0].end, r[0].suggestions.first), (0, 4, 'Hello'));
        expect(
          (r[1].start, r[1].end, r[1].suggestions.first),
          (5, 10, 'world'),
        );
        expect(await c.checkWord('world'), isTrue);
        expect(await c.checkWord('wrold'), isFalse);
        expect(await c.suggest('wrold', max: 1), <String>['world']);
        expect(await c.check(''), isEmpty);
      });
    }

    test('loads the bundled en_US asset', () async {
      final HunspellSpellChecker c = HunspellSpellChecker(
        const HunspellSource.bundledEnUS(),
      );
      addTearDown(c.dispose);
      await c.load();
      expect(await c.checkWord('color'), isTrue);
      expect(await c.checkWord('colour'), isFalse);
    });

    test('a broken dictionary reports an error and can be retried', () async {
      final HunspellSpellChecker c = HunspellSpellChecker(
        const HunspellSource.text('PFX A Y 1\nPFX bad\n', '0\n'),
      );
      addTearDown(c.dispose);
      await expectLater(c.load(), throwsA(anything));
      await expectLater(c.load(), throwsA(anything));
    });

    test('missing assets surface as errors', () async {
      final HunspellSpellChecker c = HunspellSpellChecker(
        const HunspellSource.asset('nope.aff', 'nope.dic'),
      );
      addTearDown(c.dispose);
      await expectLater(c.check('abc'), throwsA(anything));
    });

    test('disposed checkers refuse work', () async {
      final HunspellSpellChecker c = HunspellSpellChecker(
        HunspellSource.text(enUsAff, enUsDic),
      );
      await c.load();
      await c.dispose();
      await expectLater(c.check('teh'), throwsStateError);
    });

    test('shared() returns one checker per source', () async {
      const HunspellSource s = HunspellSource.bundledEnUS();
      expect(
        identical(
          HunspellSpellChecker.shared(s),
          HunspellSpellChecker.shared(s),
        ),
        isTrue,
      );
      final HunspellSpellChecker a = HunspellSpellChecker.shared(s);
      await HunspellSpellChecker.disposeShared();
      expect(identical(a, HunspellSpellChecker.shared(s)), isFalse);
      await HunspellSpellChecker.disposeShared();
    });

    test('url source downloads through the given client', () async {
      const Map<String, String> files = <String, String>{
        'https://dict.test/x.aff': 'SET UTF-8\nSFX S Y 1\nSFX S 0 s .\n',
        'https://dict.test/x.dic': '1\ncat/S\n',
      };
      final MockClient client = MockClient((http.Request request) async {
        final String? body = files[request.url.toString()];
        return body == null
            ? http.Response('not found', 404)
            : http.Response(body, 200);
      });
      final HunspellSpellChecker c = HunspellSpellChecker(
        HunspellSource.url(
          Uri.parse('https://dict.test/x.aff'),
          Uri.parse('https://dict.test/x.dic'),
          client: client,
        ),
        useIsolate: false,
      );
      addTearDown(c.dispose);
      expect(await c.checkWord('cats'), isTrue);
      expect(await c.checkWord('dogs'), isFalse);

      final HunspellSpellChecker missing = HunspellSpellChecker(
        HunspellSource.url(
          Uri.parse('https://dict.test/missing.aff'),
          Uri.parse('https://dict.test/x.dic'),
          client: client,
        ),
      );
      addTearDown(missing.dispose);
      await expectLater(missing.load(), throwsA(anything));
    });
  });

  test('TextHunspellSource and asset sources expose stable cache keys', () {
    const HunspellSource a = HunspellSource.asset('a.aff', 'a.dic');
    const HunspellSource b = HunspellSource.asset('a.aff', 'a.dic');
    expect(a.cacheKey, b.cacheKey);
    expect(const HunspellSource.bundledEnUS().cacheKey, isNot(a.cacheKey));
  });
}
