import 'dart:async';

import '../models.dart';
import 'source.dart';
import 'worker.dart';
import 'worker_web.dart' if (dart.library.io) 'worker_io.dart';

/// Asynchronous Hunspell spell checker for whole texts.
///
/// On Android, iOS, macOS, Windows and Linux the dictionary is parsed and
/// queried in a long-lived background isolate (unless [useIsolate] is
/// false). On the web, where Dart has no isolates, it runs on the main
/// thread but yields to the event loop while parsing and checking.
///
/// The dictionary is loaded lazily on first use; call [load] to warm it up.
class HunspellSpellChecker {
  /// Creates a checker for [source].
  HunspellSpellChecker(this.source, {this.useIsolate = true});

  /// Returns a checker for [source] shared by everyone who asks for the same
  /// source (same [HunspellSource.cacheKey]), so a dictionary is parsed once
  /// per app. Shared checkers are never disposed.
  factory HunspellSpellChecker.shared(
    HunspellSource source, {
    bool useIsolate = true,
  }) {
    return _shared.putIfAbsent((
      source.cacheKey,
      useIsolate,
    ), () => HunspellSpellChecker(source, useIsolate: useIsolate));
  }

  static final Map<Object, HunspellSpellChecker> _shared =
      <Object, HunspellSpellChecker>{};

  /// Disposes every checker created by [HunspellSpellChecker.shared],
  /// stopping their isolates and freeing the parsed dictionaries. Later
  /// calls to [HunspellSpellChecker.shared] create fresh checkers.
  static Future<void> disposeShared() async {
    final List<HunspellSpellChecker> all = _shared.values.toList();
    _shared.clear();
    await Future.wait(<Future<void>>[
      for (final HunspellSpellChecker c in all) c.dispose(),
    ]);
  }

  /// Where the dictionary comes from.
  final HunspellSource source;

  /// Whether to use a background isolate on platforms that have them.
  final bool useIsolate;

  Future<HunspellWorker>? _worker;
  bool _disposed = false;

  /// Loads and parses the dictionary if that has not happened yet.
  ///
  /// Throws if the dictionary cannot be loaded; a later call retries.
  Future<void> load() async {
    await _ensureWorker();
  }

  Future<HunspellWorker> _ensureWorker() {
    if (_disposed) {
      return Future<HunspellWorker>.error(
        StateError('HunspellSpellChecker was disposed'),
      );
    }
    return _worker ??= _start();
  }

  Future<HunspellWorker> _start() async {
    try {
      final ({String aff, String dic}) text = await source.load();
      final HunspellWorker w = await spawnHunspellWorker(
        text.aff,
        text.dic,
        useIsolate: useIsolate,
      );
      if (_disposed) {
        await w.dispose();
        throw StateError('HunspellSpellChecker was disposed');
      }
      return w;
    } catch (_) {
      // Allow a later call to retry (e.g. after a network error).
      _worker = null;
      rethrow;
    }
  }

  /// Checks [text]; returns sorted misspelled ranges with up to
  /// [maxSuggestions] suggestions each.
  Future<List<SpellCheckRange>> check(
    String text, {
    int maxSuggestions = 5,
  }) async {
    if (text.isEmpty) return const <SpellCheckRange>[];
    final HunspellWorker w = await _ensureWorker();
    return w.checkText(text, maxSuggestions);
  }

  /// Whether a single [word] is spelled correctly.
  Future<bool> checkWord(String word) async =>
      (await _ensureWorker()).checkWord(word);

  /// Up to [max] suggestions for [word].
  Future<List<String>> suggest(String word, {int max = 5}) async =>
      (await _ensureWorker()).suggest(word, max);

  /// Stops the background isolate. The checker cannot be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final Future<HunspellWorker>? w = _worker;
    _worker = null;
    if (w != null) {
      try {
        await (await w).dispose();
      } catch (_) {
        // Loading failed; nothing to release.
      }
    }
  }
}
