import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

import 'test_dictionary.dart';

void main() {
  late Hunspell en;

  setUpAll(() {
    en = Hunspell(enUsDictionary);
  });

  group('en_US dictionary', () {
    test('parses the whole bundled word list', () {
      expect(enUsDictionary.wordCount, greaterThan(49000));
      expect(enUsDictionary.flagType, FlagType.char);
      expect(enUsDictionary.replacements, isNotEmpty);
      expect(enUsDictionary.compoundRules, hasLength(2));
    });

    test('accepts correctly spelled words, including affixed forms', () {
      for (final String w in <String>[
        'hello', 'the', 'color', 'colors', 'colored', 'recolored',
        'discolored', // PFX E + SFX D cross product
        'unhappiness', 'happiest', 'cried', 'cities', 'walked', 'running',
        'reusable', 'children', "children's", "don't", 'a', 'I',
      ]) {
        expect(en.check(w), isTrue, reason: w);
      }
    });

    test('rejects misspelled words', () {
      for (final String w in <String>[
        'teh',
        'recieve',
        'walkd',
        'runing',
        'citys',
        'definately',
        'seperate',
        'colour',
        'happyness',
        'xqzvbn',
      ]) {
        expect(en.check(w), isFalse, reason: w);
      }
    });

    test('applies Hunspell capitalisation rules', () {
      expect(en.check('Hello'), isTrue);
      expect(en.check('HELLO'), isTrue);
      expect(en.check('Paris'), isTrue);
      expect(en.check('PARIS'), isTrue);
      expect(en.check('paris'), isFalse, reason: 'proper noun lower-cased');
      expect(en.check("DON'T"), isTrue);
    });

    test('ICONV maps the typographic apostrophe', () {
      expect(en.check('don’t'), isTrue);
    });

    test('COMPOUNDRULE accepts ordinals and rejects bad ones', () {
      for (final String w in <String>['1st', '21st', '11th', '12th', '123rd']) {
        expect(en.check(w), isTrue, reason: w);
      }
      expect(en.check('11st'), isFalse);
      expect(en.check('22th'), isFalse);
    });

    test('numbers are always correct', () {
      expect(en.check('2026'), isTrue);
      expect(en.check('3.14'), isTrue);
      expect(en.check('1,000,000'), isTrue);
    });

    test('BREAK splits hyphenated words', () {
      expect(en.check('well-known'), isTrue);
      expect(en.check('e-mail'), isTrue);
      expect(en.check('well-knwn'), isFalse);
      expect(en.misspelledParts('well-knwn'), <(int, int)>[(5, 9)]);
      expect(en.misspelledParts('well-known'), isEmpty);
      expect(en.misspelledParts('teh'), <(int, int)>[(0, 3)]);
    });
  });

  group('en_US suggestions', () {
    test('common typos get the right first suggestion', () {
      const Map<String, String> expected = <String, String>{
        'teh': 'the',
        'recieve': 'receive',
        'helo': 'hello',
        'wierd': 'weird',
        'occured': 'occurred',
        'seperate': 'separate',
        'definately': 'definitely',
        'accomodate': 'accommodate',
        'untill': 'until',
        'goverment': 'government',
        'becuase': 'because',
        'speling': 'spelling',
        'thier': 'their',
        'happyness': 'happiness',
      };
      expected.forEach((String typo, String fix) {
        expect(en.suggest(typo).first, fix, reason: typo);
      });
    });

    test('REP table can suggest two words', () {
      expect(en.suggest('alot'), contains('a lot'));
    });

    test('splits run-together words when nothing else fits', () {
      expect(en.suggest('inthe').first, 'in the');
    });

    test('n-gram fallback finds words two edits away', () {
      expect(en.suggest('acomodate').first, 'accommodate');
    });

    test('restores the case of the input', () {
      expect(en.suggest('Recieve').first, 'Receive');
      expect(en.suggest('RECIEVE').first, 'RECEIVE');
      expect(en.suggest('paris').first, 'Paris');
    });

    test('respects max and never returns the input itself', () {
      final List<String> s = en.suggest('thier', max: 2);
      expect(s, hasLength(2));
      expect(s, isNot(contains('thier')));
      expect(en.suggest('thier', max: 0), isEmpty);
    });

    test('NOSUGGEST words are accepted but never suggested', () {
      expect(en.check('bullshit'), isTrue);
      expect(en.suggest('bullshyt'), isNot(contains('bullshit')));
    });
  });

  group('affix-file features (custom dictionaries)', () {
    test('KEEPCASE, NOSUGGEST, FORBIDDENWORD, NEEDAFFIX, REP', () {
      final Hunspell h = Hunspell(
        HunspellDictionary.parse(
          '''
SET UTF-8
TRY abcdefghijklmnopqrstuvwxyz
KEEPCASE K
NOSUGGEST N
FORBIDDENWORD F
NEEDAFFIX X
REP 1
REP ph f
SFX S Y 1
SFX S 0 s .
''',
          '''
6
Dart/K
darn/N
fone/S
foo/X
foos/F
bar/S
''',
        ),
      );
      expect(h.check('Dart'), isTrue);
      expect(h.check('DART'), isFalse, reason: 'KEEPCASE blocks re-casing');
      expect(h.check('darn'), isTrue);
      expect(h.suggest('darm'), isNot(contains('darn')));
      expect(h.check('foo'), isFalse, reason: 'NEEDAFFIX root alone');
      expect(h.check('foos'), isFalse, reason: 'FORBIDDENWORD');
      expect(h.check('bars'), isTrue);
      expect(h.suggest('phone').first, 'fone', reason: 'REP ph -> f');
    });

    test('FLAG long with AF aliases and two-level suffixes', () {
      final Hunspell h = Hunspell(
        HunspellDictionary.parse(
          '''
FLAG long
AF 2
AF Aa
AF BbAa
SFX Aa Y 1
SFX Aa 0 ing/Cc .
SFX Cc Y 1
SFX Cc 0 s .
PFX Bb Y 1
PFX Bb 0 re .
''',
          '''
2
walk/1
read/2
''',
        ),
      );
      expect(h.dictionary.flagType, FlagType.long);
      expect(h.check('walking'), isTrue);
      expect(h.check('walkings'), isTrue, reason: 'continuation class Cc');
      expect(h.check('reread'), isTrue);
      expect(h.check('rereading'), isTrue, reason: 'cross product');
      expect(h.check('rewalk'), isFalse);
    });

    test('FLAG num', () {
      final Hunspell h = Hunspell(
        HunspellDictionary.parse(
          'FLAG num\nSFX 101 Y 1\nSFX 101 y ies [^aeiou]y\n',
          '1\nberry/101,7\n',
        ),
      );
      expect(h.check('berries'), isTrue);
      expect(h.check('berrys'), isFalse);
    });

    test('MAP groups drive suggestions', () {
      final Hunspell h = Hunspell(
        HunspellDictionary.parse('SET UTF-8\nMAP 1\nMAP eé\n', '1\ncafé\n'),
      );
      expect(h.suggest('cafe').first, 'café');
    });

    test('decodeHunspellBytes honours SET ISO8859-1', () {
      final List<int> aff = latin1.encode('SET ISO8859-1\n');
      final List<int> dic = latin1.encode('1\nnaïve\n');
      final ({String aff, String dic}) text = decodeHunspellBytes(aff, dic);
      final Hunspell h = Hunspell(HunspellDictionary.parse(text.aff, text.dic));
      expect(h.check('naïve'), isTrue);
    });

    test('malformed affix rules throw HunspellFormatException', () {
      expect(
        () => HunspellDictionary.parse('SFX A Y 1\nPFX broken\n', '0\n'),
        throwsA(isA<HunspellFormatException>()),
      );
    });
  });
}
