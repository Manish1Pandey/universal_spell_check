import 'dart:async';

import '../models.dart';
import 'dictionary.dart';
import 'hunspell.dart';
import 'text_checker.dart';

/// Runs a parsed Hunspell dictionary somewhere (background isolate or the
/// current isolate) and answers requests asynchronously.
abstract class HunspellWorker {
  /// Checks a whole text.
  Future<List<SpellCheckRange>> checkText(String text, int maxSuggestions);

  /// Checks one word.
  Future<bool> checkWord(String word);

  /// Suggests replacements for one word.
  Future<List<String>> suggest(String word, int max);

  /// Extra word characters from the dictionary's `WORDCHARS`.
  String get wordChars;

  /// Releases the worker. Pending requests fail with a [StateError].
  Future<void> dispose();
}

/// A worker that runs in the current isolate.
///
/// With [cooperative] set it parses and checks in slices, yielding to the
/// event loop in between; this is what the web uses, since Dart on the web
/// has no isolates.
class InlineHunspellWorker implements HunspellWorker {
  InlineHunspellWorker._(this._checker, this.cooperative);

  /// Parses the dictionary and creates the worker.
  static Future<InlineHunspellWorker> create(
    String aff,
    String dic, {
    required bool cooperative,
  }) async {
    final HunspellDictionary d = cooperative
        ? await HunspellDictionary.parseAsync(aff, dic)
        : HunspellDictionary.parse(aff, dic);
    return InlineHunspellWorker._(
      HunspellTextChecker(Hunspell(d)),
      cooperative,
    );
  }

  final HunspellTextChecker _checker;

  /// Whether long work yields to the event loop.
  final bool cooperative;

  bool _disposed = false;

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('HunspellWorker was disposed');
    }
  }

  @override
  String get wordChars => _checker.dictionary.wordChars;

  @override
  Future<List<SpellCheckRange>> checkText(
    String text,
    int maxSuggestions,
  ) async {
    _ensureAlive();
    if (cooperative) {
      return _checker.checkTextCooperatively(
        text,
        maxSuggestions: maxSuggestions,
      );
    }
    return _checker.checkText(text, maxSuggestions: maxSuggestions);
  }

  @override
  Future<bool> checkWord(String word) async {
    _ensureAlive();
    return _checker.hunspell.check(word);
  }

  @override
  Future<List<String>> suggest(String word, int max) async {
    _ensureAlive();
    return _checker.suggest(word, max);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}
