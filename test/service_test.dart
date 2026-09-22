import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

import 'test_dictionary.dart';

const MethodChannel _channel = MethodChannel('universal_spell_check');
const Locale _enUS = Locale('en', 'US');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final List<MethodCall> calls = <MethodCall>[];

  void mockNative(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(() {
    calls.clear();
    UniversalSpellCheckPlatform.instance = MethodChannelUniversalSpellCheck();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('native (macOS / Windows method channel)', () {
    test('maps native ranges to sorted SuggestionSpans', () async {
      mockNative((MethodCall call) async {
        expect(call.method, 'checkText');
        return <Object?>[
          <String, Object?>{
            'start': 10,
            'end': 13,
            'suggestions': <String>['the'],
          },
          <String, Object?>{
            'start': 2,
            'end': 9,
            'suggestions': <String>['receive', 'relieve'],
          },
        ];
      });
      final UniversalSpellCheckService s = UniversalSpellCheckService(
        backend: SpellCheckBackend.native,
      );
      final List<SuggestionSpan>? spans = await s.fetchSpellCheckSuggestions(
        _enUS,
        'I recieve teh cat',
      );
      expect(spans, const <SuggestionSpan>[
        SuggestionSpan(TextRange(start: 2, end: 9), <String>[
          'receive',
          'relieve',
        ]),
        SuggestionSpan(TextRange(start: 10, end: 13), <String>['the']),
      ]);
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['text'], 'I recieve teh cat');
      expect(args['language'], 'en-US');
      expect(args['maxSuggestions'], 5);
    });

    test('drops overlapping and invalid native ranges', () async {
      mockNative(
        (MethodCall call) async => <Object?>[
          <String, Object?>{'start': 0, 'end': 5, 'suggestions': <String>[]},
          <String, Object?>{'start': 3, 'end': 7, 'suggestions': <String>[]},
          <String, Object?>{'start': 8, 'end': 8, 'suggestions': <String>[]},
        ],
      );
      final List<SpellCheckRange>? r = await UniversalSpellCheckService(
        backend: SpellCheckBackend.native,
      ).check(_enUS, 'abcdefghijk');
      expect(r, const <SpellCheckRange>[SpellCheckRange(0, 5, <String>[])]);
    });

    test(
      'null from native (unsupported language) falls back to Hunspell',
      () async {
        mockNative((MethodCall call) async => null);
        final UniversalSpellCheckService s = UniversalSpellCheckService(
          hunspellDictionaries: <String, HunspellSource>{
            'en': HunspellSource.text(enUsAff, enUsDic),
          },
          useIsolate: false,
        );
        final List<SpellCheckRange>? r = await s.check(_enUS, 'teh cat');
        expect(r, hasLength(1));
        expect(r!.single.suggestions.first, 'the');
        // The unavailable locale is remembered: no second native round trip.
        await s.check(_enUS, 'teh dog');
        expect(calls, hasLength(1));
      },
    );

    test('backend.native never falls back', () async {
      mockNative((MethodCall call) async => null);
      final UniversalSpellCheckService s = UniversalSpellCheckService(
        backend: SpellCheckBackend.native,
        hunspellDictionaries: <String, HunspellSource>{
          'en': HunspellSource.text(enUsAff, enUsDic),
        },
      );
      expect(await s.check(_enUS, 'teh cat'), isEmpty);
      expect((await s.availability(_enUS)).isAvailable, isFalse);
    });

    test('no native plugin and no dictionary -> no marks', () async {
      final UniversalSpellCheckService s = UniversalSpellCheckService(
        hunspellDictionaries: const <String, HunspellSource>{},
      );
      expect(await s.check(const Locale('fr', 'FR'), 'bonjour'), isEmpty);
      final SpellCheckAvailability a = await s.availability(
        const Locale('fr', 'FR'),
      );
      expect(a.isAvailable, isFalse);
      expect(a.reason, contains('fr-FR'));
    });

    test('PlatformException is reported as unavailable, not thrown', () async {
      mockNative((MethodCall call) async {
        throw PlatformException(code: 'check_failed', message: 'boom');
      });
      final NativeCheckOutcome o = await MethodChannelUniversalSpellCheck()
          .check(_enUS, 'x', maxSuggestions: 1);
      expect(o, isA<NativeCheckUnavailable>());
      expect((o as NativeCheckUnavailable).reason, 'boom');
    });

    test('availability and languages come from the native side', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      mockNative((MethodCall call) async {
        switch (call.method) {
          case 'resolveLanguage':
            return 'en_US';
          case 'availableLanguages':
            return <String>['en', 'en_US', 'fr'];
        }
        return null;
      });
      final UniversalSpellCheckService s = UniversalSpellCheckService();
      final SpellCheckAvailability a = await s.availability(_enUS);
      expect(a.checker, ResolvedSpellChecker.nsSpellChecker);
      expect(a.language, 'en_US');
      expect(await s.nativeLanguages(), <String>['en', 'en_US', 'fr']);
      expect(calls.first.arguments, <String, Object?>{'language': 'en-US'});
    });
  });

  group('Linux (Enchant word list)', () {
    test(
      'sends distinct words and maps results back to every occurrence',
      () async {
        UniversalSpellCheckPlatform.instance = LinuxUniversalSpellCheck();
        mockNative((MethodCall call) async {
          expect(call.method, 'checkWords');
          final List<Object?> words =
              (call.arguments as Map<Object?, Object?>)['words']!
                  as List<Object?>;
          expect(words, <String>['teh', 'cat', "don't"]);
          return <Object?>[
            <String>['the', 'tech'],
            null,
            null,
          ];
        });
        const String text = 'teh cat don’t teh';
        final List<SpellCheckRange>? r = await UniversalSpellCheckService(
          backend: SpellCheckBackend.native,
        ).check(_enUS, text);
        expect(r, const <SpellCheckRange>[
          SpellCheckRange(0, 3, <String>['the', 'tech']),
          SpellCheckRange(14, 17, <String>['the', 'tech']),
        ]);
        expect(text.substring(14, 17), 'teh');
      },
    );

    test('missing libenchant (null reply) is unavailable', () async {
      final LinuxUniversalSpellCheck p = LinuxUniversalSpellCheck();
      mockNative((MethodCall call) async => null);
      final NativeCheckOutcome o = await p.check(
        _enUS,
        'hello',
        maxSuggestions: 3,
      );
      expect(o, isA<NativeCheckUnavailable>());
      expect(p.nativeChecker, ResolvedSpellChecker.enchant);
    });
  });

  group('Android / iOS delegate', () {
    test('uses the wrapped service and passes cancellation through', () async {
      final _FakeService fake = _FakeService();
      UniversalSpellCheckPlatform.instance = UniversalSpellCheckMobile(
        service: fake,
      );
      final UniversalSpellCheckService s = UniversalSpellCheckService(
        maxSuggestions: 1,
      );
      fake.next = const <SuggestionSpan>[
        SuggestionSpan(TextRange(start: 0, end: 3), <String>['the', 'tea']),
      ];
      final List<SuggestionSpan>? spans = await s.fetchSpellCheckSuggestions(
        _enUS,
        'teh',
      );
      expect(spans, const <SuggestionSpan>[
        SuggestionSpan(TextRange(start: 0, end: 3), <String>['the']),
      ]);
      fake.next = null;
      expect(await s.fetchSpellCheckSuggestions(_enUS, 'teh'), isNull);
      expect(
        (await s.availability(_enUS)).checker,
        ResolvedSpellChecker.flutterDefault,
      );
    });
  });

  group('Hunspell backend and ignore list', () {
    late UniversalSpellCheckService s;
    setUp(() {
      s = UniversalSpellCheckService(
        backend: SpellCheckBackend.hunspell,
        hunspellDictionaries: <String, HunspellSource>{
          'en': HunspellSource.text(enUsAff, enUsDic),
        },
        useIsolate: false,
        ignoredWords: const <String>['Flutterly'],
      );
    });

    test('never touches the native channel', () async {
      mockNative((MethodCall call) async => fail('native called'));
      expect(await s.check(_enUS, 'teh'), hasLength(1));
      expect(calls, isEmpty);
    });

    test('ignored words are filtered case-insensitively', () async {
      expect(await s.check(_enUS, 'flutterly FLUTTERLY'), isEmpty);
      expect(await s.check(_enUS, 'Manish wrote it'), hasLength(1));
      s.ignoreWord('manish');
      expect(s.isIgnored('MANISH'), isTrue);
      expect(await s.check(_enUS, 'Manish wrote it'), isEmpty);
      s.unignoreWord('Manish');
      expect(await s.check(_enUS, 'Manish wrote it'), hasLength(1));
      expect(s.ignoredWords, <String>{'flutterly'});
    });

    test('locale keys match tag, underscore form and language', () async {
      final SpellCheckAvailability a = await s.availability(
        const Locale('en', 'GB'),
      );
      expect(a.checker, ResolvedSpellChecker.hunspell);
      expect(a.language, 'en');
      expect(
        (await s.availability(const Locale('de'))).checker,
        ResolvedSpellChecker.none,
      );
      await s.warmUp(_enUS);
    });

    test('empty text short-circuits', () async {
      expect(await s.fetchSpellCheckSuggestions(_enUS, ''), isEmpty);
    });
  });
}

class _FakeService implements SpellCheckService {
  List<SuggestionSpan>? next;

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async => next;
}
