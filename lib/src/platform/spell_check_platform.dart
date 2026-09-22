import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../models.dart';
import 'method_channel_platform.dart';

/// Outcome of a native spell-check request.
sealed class NativeCheckOutcome {
  const NativeCheckOutcome();
}

/// The native checker produced results.
final class NativeCheckResults extends NativeCheckOutcome {
  /// Wraps [ranges] (sorted, non-overlapping).
  const NativeCheckResults(this.ranges);

  /// Misspelled ranges.
  final List<SpellCheckRange> ranges;
}

/// The native checker cannot check this locale (or does not exist).
final class NativeCheckUnavailable extends NativeCheckOutcome {
  /// Creates the outcome with a human-readable [reason].
  const NativeCheckUnavailable(this.reason);

  /// Why no check was possible.
  final String reason;
}

/// The request was superseded by a newer one (Android/iOS only); the text
/// field should keep its current marks.
final class NativeCheckCancelled extends NativeCheckOutcome {
  /// Creates the outcome.
  const NativeCheckCancelled();
}

/// Platform interface for the native spell checkers.
///
/// Each platform registers its own implementation: a method channel on
/// macOS/Windows, a word-list channel on Linux, Flutter's
/// `DefaultSpellCheckService` on Android/iOS and a no-native stub on the web.
abstract class UniversalSpellCheckPlatform extends PlatformInterface {
  /// Constructs a platform implementation.
  UniversalSpellCheckPlatform() : super(token: _token);

  static final Object _token = Object();

  static UniversalSpellCheckPlatform _instance =
      MethodChannelUniversalSpellCheck();

  /// The implementation in use.
  static UniversalSpellCheckPlatform get instance => _instance;

  /// Replaces the implementation (platform plugins and tests).
  static set instance(UniversalSpellCheckPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// The engine behind [check].
  ResolvedSpellChecker get nativeChecker;

  /// Spell checks [text] for [locale].
  Future<NativeCheckOutcome> check(
    Locale locale,
    String text, {
    required int maxSuggestions,
  });

  /// The native language tag used for [locale], or `null` if unsupported.
  Future<String?> resolveLanguage(Locale locale);

  /// Language tags the native checker has dictionaries for.
  Future<List<String>> availableLanguages();

  /// Sorts ranges by start offset and drops overlaps, as `EditableText`
  /// requires.
  @protected
  static List<SpellCheckRange> normalize(List<SpellCheckRange> ranges) {
    final List<SpellCheckRange> sorted = List<SpellCheckRange>.of(ranges)
      ..sort((a, b) => a.start.compareTo(b.start));
    final List<SpellCheckRange> out = <SpellCheckRange>[];
    int lastEnd = -1;
    for (final SpellCheckRange r in sorted) {
      if (r.start < 0 || r.end <= r.start || r.start < lastEnd) continue;
      out.add(r);
      lastEnd = r.end;
    }
    return out;
  }
}
