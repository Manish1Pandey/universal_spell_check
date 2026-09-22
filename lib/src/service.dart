import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'hunspell/source.dart';
import 'hunspell/spell_checker.dart';
import 'models.dart';
import 'platform/spell_check_platform.dart';

/// A [SpellCheckService] that works on every Flutter platform.
///
/// | Platform | Engine |
/// |----------|--------|
/// | Android, iOS | Flutter's `DefaultSpellCheckService` |
/// | macOS | `NSSpellChecker` |
/// | Windows 8+ | `ISpellChecker` |
/// | Linux | Enchant-2 (if installed) |
/// | Web | pure-Dart Hunspell with the bundled en_US dictionary |
///
/// With [SpellCheckBackend.auto] (the default) a desktop platform whose
/// native checker cannot handle the locale falls back to Hunspell when
/// [hunspellDictionaries] has a dictionary for it.
///
/// ```dart
/// TextField(
///   spellCheckConfiguration: SpellCheckConfiguration(
///     spellCheckService: UniversalSpellCheckService.instance,
///     misspelledTextStyle: UniversalSpellCheck.misspelledTextStyle,
///   ),
/// )
/// ```
class UniversalSpellCheckService implements SpellCheckService {
  /// Creates a service.
  ///
  /// * [backend]: which engine to use; see [SpellCheckBackend].
  /// * [hunspellDictionaries]: Hunspell dictionaries by language tag. Keys
  ///   are matched as `en-US`, then `en_US`, then `en`. Defaults to
  ///   `{'en': HunspellSource.bundledEnUS()}`.
  /// * [useIsolate]: run Hunspell in a background isolate where supported.
  /// * [maxSuggestions]: suggestions per misspelled word.
  /// * [ignoredWords]: words never marked (case-insensitive).
  UniversalSpellCheckService({
    this.backend = SpellCheckBackend.auto,
    Map<String, HunspellSource>? hunspellDictionaries,
    this.useIsolate = true,
    this.maxSuggestions = 5,
    Iterable<String> ignoredWords = const <String>[],
  }) : assert(maxSuggestions >= 0, 'maxSuggestions must not be negative'),
       hunspellDictionaries = Map<String, HunspellSource>.unmodifiable(
         hunspellDictionaries ??
             const <String, HunspellSource>{'en': HunspellSource.bundledEnUS()},
       ) {
    for (final String w in ignoredWords) {
      ignoreWord(w);
    }
  }

  /// The app-wide default service used by `UniversalSpellCheck`.
  static final UniversalSpellCheckService instance =
      UniversalSpellCheckService();

  /// Which engine answers requests.
  final SpellCheckBackend backend;

  /// Hunspell dictionaries by language tag.
  final Map<String, HunspellSource> hunspellDictionaries;

  /// Whether Hunspell runs in a background isolate (ignored on the web).
  final bool useIsolate;

  /// Maximum suggestions per misspelled word.
  final int maxSuggestions;

  final Set<String> _ignored = <String>{};
  final Set<String> _nativeUnavailable = <String>{};

  UniversalSpellCheckPlatform get _platform =>
      UniversalSpellCheckPlatform.instance;

  /// Words ignored for this service (lower-cased).
  Set<String> get ignoredWords => Set<String>.unmodifiable(_ignored);

  /// Stops marking [word] (case-insensitive) in future results.
  void ignoreWord(String word) {
    final String w = word.trim().toLowerCase();
    if (w.isNotEmpty) _ignored.add(w);
  }

  /// Marks [word] again after [ignoreWord].
  void unignoreWord(String word) => _ignored.remove(word.trim().toLowerCase());

  /// Whether [word] is on the ignore list.
  bool isIgnored(String word) => _ignored.contains(word.trim().toLowerCase());

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    final List<SpellCheckRange>? ranges = await check(locale, text);
    if (ranges == null) return null;
    return <SuggestionSpan>[
      for (final SpellCheckRange r in ranges) r.toSuggestionSpan(),
    ];
  }

  /// Like [fetchSpellCheckSuggestions] but returns [SpellCheckRange]s.
  ///
  /// Returns `null` only when the platform cancelled the request because a
  /// newer one is pending (Android/iOS); an empty list when nothing is
  /// misspelled or no checker is available for [locale].
  Future<List<SpellCheckRange>?> check(Locale locale, String text) async {
    if (text.isEmpty) return const <SpellCheckRange>[];
    final NativeCheckOutcome outcome = await _run(locale, text);
    switch (outcome) {
      case NativeCheckCancelled():
        return null;
      case NativeCheckUnavailable():
        return const <SpellCheckRange>[];
      case NativeCheckResults(:final List<SpellCheckRange> ranges):
        if (_ignored.isEmpty) return ranges;
        return <SpellCheckRange>[
          for (final SpellCheckRange r in ranges)
            if (r.end <= text.length &&
                !_ignored.contains(
                  text.substring(r.start, r.end).toLowerCase(),
                ))
              r,
        ];
    }
  }

  Future<NativeCheckOutcome> _run(Locale locale, String text) async {
    final String tag = locale.toLanguageTag();
    if (backend != SpellCheckBackend.hunspell &&
        !_nativeUnavailable.contains(tag)) {
      final NativeCheckOutcome outcome = await _platform.check(
        locale,
        text,
        maxSuggestions: maxSuggestions,
      );
      if (outcome is! NativeCheckUnavailable) return outcome;
      if (backend == SpellCheckBackend.native) return outcome;
      _nativeUnavailable.add(tag);
    }
    if (backend == SpellCheckBackend.native) {
      return NativeCheckUnavailable('No native dictionary for "$tag".');
    }
    final HunspellSource? source = _sourceFor(locale)?.$2;
    if (source == null) {
      return NativeCheckUnavailable('No Hunspell dictionary for "$tag".');
    }
    try {
      final List<SpellCheckRange> ranges = await HunspellSpellChecker.shared(
        source,
        useIsolate: useIsolate,
      ).check(text, maxSuggestions: maxSuggestions);
      return NativeCheckResults(ranges);
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'universal_spell_check',
          context: ErrorDescription('while spell checking with Hunspell'),
        ),
      );
      return NativeCheckUnavailable('Hunspell failed: $e');
    }
  }

  (String, HunspellSource)? _sourceFor(Locale locale) {
    final List<String> keys = <String>[
      locale.toLanguageTag(),
      if (locale.countryCode != null && locale.countryCode!.isNotEmpty)
        '${locale.languageCode}_${locale.countryCode}',
      locale.languageCode,
    ];
    for (final String k in keys) {
      final HunspellSource? s = hunspellDictionaries[k];
      if (s != null) return (k, s);
    }
    return null;
  }

  /// Reports which engine will check [locale] and whether it can.
  Future<SpellCheckAvailability> availability(Locale locale) async {
    if (backend != SpellCheckBackend.hunspell &&
        _platform.nativeChecker != ResolvedSpellChecker.none) {
      final String? lang = await _platform.resolveLanguage(locale);
      if (lang != null) {
        return SpellCheckAvailability(
          checker: _platform.nativeChecker,
          language: lang,
        );
      }
    }
    if (backend == SpellCheckBackend.native) {
      return SpellCheckAvailability(
        checker: ResolvedSpellChecker.none,
        language: null,
        reason: 'No native dictionary for "${locale.toLanguageTag()}".',
      );
    }
    final (String, HunspellSource)? source = _sourceFor(locale);
    if (source == null) {
      return SpellCheckAvailability(
        checker: ResolvedSpellChecker.none,
        language: null,
        reason: 'No dictionary for "${locale.toLanguageTag()}".',
      );
    }
    return SpellCheckAvailability(
      checker: ResolvedSpellChecker.hunspell,
      language: source.$1,
    );
  }

  /// Language tags the native checker has dictionaries for (empty on the
  /// web and on Android/iOS, where Flutter does not expose the list).
  Future<List<String>> nativeLanguages() => _platform.availableLanguages();

  /// Loads the Hunspell dictionary for [locale] ahead of time, if Hunspell
  /// will be used for it, so the first keystroke is not delayed by parsing.
  Future<void> warmUp(Locale locale) async {
    final SpellCheckAvailability a = await availability(locale);
    if (a.checker != ResolvedSpellChecker.hunspell) return;
    final HunspellSource? source = _sourceFor(locale)?.$2;
    if (source != null) {
      await HunspellSpellChecker.shared(source, useIsolate: useIsolate).load();
    }
  }
}
