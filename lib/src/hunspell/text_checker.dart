import 'dart:async';

import '../models.dart';
import '../tokenizer.dart';
import 'dictionary.dart';
import 'hunspell.dart';

/// Checks whole texts with a [Hunspell] instance, caching per-word results.
///
/// Used inside the background isolate (native) or directly (web).
class HunspellTextChecker {
  /// Creates a text checker for [hunspell].
  HunspellTextChecker(this.hunspell, {this.cacheSize = 20000});

  /// The word-level checker.
  final Hunspell hunspell;

  /// Maximum number of cached word results before the cache is reset.
  final int cacheSize;

  final Map<String, List<(int, int)>> _partsCache =
      <String, List<(int, int)>>{};
  final Map<String, List<String>> _suggestCache = <String, List<String>>{};

  /// The dictionary backing [hunspell].
  HunspellDictionary get dictionary => hunspell.dictionary;

  /// Misspelled parts of [word] (cached).
  List<(int, int)> misspelledParts(String word) {
    final List<(int, int)>? hit = _partsCache[word];
    if (hit != null) return hit;
    if (_partsCache.length >= cacheSize) _partsCache.clear();
    return _partsCache[word] = hunspell.misspelledParts(word);
  }

  /// Suggestions for [word] (cached per `word` + [max]).
  List<String> suggest(String word, int max) {
    final String key = '$max\u0000$word';
    final List<String>? hit = _suggestCache[key];
    if (hit != null) return hit;
    if (_suggestCache.length >= cacheSize) _suggestCache.clear();
    return _suggestCache[key] = List<String>.unmodifiable(
      hunspell.suggest(word, max: max),
    );
  }

  /// Checks [text] and returns sorted, non-overlapping misspelled ranges.
  List<SpellCheckRange> checkText(String text, {int maxSuggestions = 5}) {
    final List<SpellCheckRange> out = <SpellCheckRange>[];
    for (final WordToken t in tokenizeWords(
      text,
      extraWordChars: dictionary.wordChars,
    )) {
      _checkToken(t, maxSuggestions, out);
    }
    return out;
  }

  /// Like [checkText] but yields to the event loop whenever a slice of work
  /// has taken longer than [budget], so the UI isolate stays responsive.
  Future<List<SpellCheckRange>> checkTextCooperatively(
    String text, {
    int maxSuggestions = 5,
    Duration budget = const Duration(milliseconds: 8),
  }) async {
    final List<SpellCheckRange> out = <SpellCheckRange>[];
    final Stopwatch sw = Stopwatch()..start();
    for (final WordToken t in tokenizeWords(
      text,
      extraWordChars: dictionary.wordChars,
    )) {
      _checkToken(t, maxSuggestions, out);
      if (sw.elapsed > budget) {
        await Future<void>.delayed(Duration.zero);
        sw.reset();
      }
    }
    return out;
  }

  void _checkToken(WordToken t, int maxSuggestions, List<SpellCheckRange> out) {
    for (final (int s, int e) in misspelledParts(t.text)) {
      final String part = t.text.substring(s, e);
      out.add(
        SpellCheckRange(
          t.start + s,
          t.start + e,
          maxSuggestions > 0 ? suggest(part, maxSuggestions) : const <String>[],
        ),
      );
    }
  }
}
