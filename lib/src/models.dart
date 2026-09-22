import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One misspelled range of a text with its replacement suggestions.
///
/// [start]/[end] are UTF-16 offsets (end exclusive), exactly like
/// [TextRange], so a range converts losslessly to a [SuggestionSpan].
class SpellCheckRange {
  /// Creates a range covering `[start, end)` with [suggestions].
  const SpellCheckRange(this.start, this.end, this.suggestions);

  /// Builds a range from the map sent by the native platform code:
  /// `{start: int, end: int, suggestions: List<String>}`.
  factory SpellCheckRange.fromMap(Map<Object?, Object?> map) {
    final Object? rawSuggestions = map['suggestions'];
    return SpellCheckRange(
      (map['start']! as num).toInt(),
      (map['end']! as num).toInt(),
      rawSuggestions is List
          ? rawSuggestions.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  /// Converts a Flutter [SuggestionSpan].
  factory SpellCheckRange.fromSuggestionSpan(SuggestionSpan span) =>
      SpellCheckRange(span.range.start, span.range.end, span.suggestions);

  /// Offset of the first code unit of the misspelled word.
  final int start;

  /// Offset one past the last code unit of the misspelled word.
  final int end;

  /// Replacement candidates, best first. May be empty.
  final List<String> suggestions;

  /// Converts to the type Flutter's `SpellCheckService` returns.
  SuggestionSpan toSuggestionSpan() =>
      SuggestionSpan(TextRange(start: start, end: end), suggestions);

  @override
  bool operator ==(Object other) =>
      other is SpellCheckRange &&
      other.start == start &&
      other.end == end &&
      listEquals(other.suggestions, suggestions);

  @override
  int get hashCode => Object.hash(start, end, Object.hashAll(suggestions));

  @override
  String toString() => 'SpellCheckRange($start, $end, $suggestions)';
}

/// Which engine answers spell-check requests.
enum SpellCheckBackend {
  /// Native checker when available (NSSpellChecker, ISpellChecker, Enchant,
  /// Android/iOS system checker), otherwise the bundled Hunspell engine when a
  /// dictionary exists for the locale. On the web this is always Hunspell.
  auto,

  /// Only the platform's native checker. Nothing is marked when it is
  /// unavailable.
  native,

  /// Only the pure-Dart Hunspell engine, on every platform.
  hunspell,
}

/// The engine that will actually be used for a locale, as reported by
/// `UniversalSpellCheckService.availability`.
enum ResolvedSpellChecker {
  /// macOS `NSSpellChecker`.
  nsSpellChecker,

  /// Windows `ISpellChecker`.
  windowsSpellChecker,

  /// Linux Enchant-2.
  enchant,

  /// Flutter's `DefaultSpellCheckService` (Android / iOS).
  flutterDefault,

  /// The pure-Dart Hunspell engine.
  hunspell,

  /// No checker can handle the locale.
  none,
}

/// Result of `UniversalSpellCheckService.availability`.
class SpellCheckAvailability {
  /// Creates an availability report.
  const SpellCheckAvailability({
    required this.checker,
    required this.language,
    this.reason,
  });

  /// The engine that will be used.
  final ResolvedSpellChecker checker;

  /// The dictionary/language tag the engine resolved the locale to
  /// (e.g. `en_US`, `en-GB`), or `null` when [isAvailable] is false.
  final String? language;

  /// Why nothing is available, when [isAvailable] is false.
  final String? reason;

  /// Whether text in the requested locale will be spell checked.
  bool get isAvailable => checker != ResolvedSpellChecker.none;

  @override
  String toString() =>
      'SpellCheckAvailability($checker, language: $language'
      '${reason == null ? '' : ', reason: $reason'})';
}
