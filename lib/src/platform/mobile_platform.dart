import 'dart:ui' show Locale;

import 'package:flutter/services.dart';

import '../models.dart';
import 'spell_check_platform.dart';

/// Android and iOS implementation: delegates to Flutter's own
/// [DefaultSpellCheckService] (Android spell checker service / UITextChecker).
class UniversalSpellCheckMobile extends UniversalSpellCheckPlatform {
  /// Creates the implementation, optionally around a custom [service].
  UniversalSpellCheckMobile({SpellCheckService? service})
    : _service = service ?? DefaultSpellCheckService();

  /// Registers this implementation (called by the generated plugin
  /// registrant on Android and iOS).
  static void registerWith() {
    UniversalSpellCheckPlatform.instance = UniversalSpellCheckMobile();
  }

  final SpellCheckService _service;

  @override
  ResolvedSpellChecker get nativeChecker => ResolvedSpellChecker.flutterDefault;

  @override
  Future<NativeCheckOutcome> check(
    Locale locale,
    String text, {
    required int maxSuggestions,
  }) async {
    final List<SuggestionSpan>? spans = await _service
        .fetchSpellCheckSuggestions(locale, text);
    if (spans == null) {
      // DefaultSpellCheckService returns null when a newer request
      // superseded this one.
      return const NativeCheckCancelled();
    }
    return NativeCheckResults(
      UniversalSpellCheckPlatform.normalize(<SpellCheckRange>[
        for (final SuggestionSpan s in spans)
          SpellCheckRange(
            s.range.start,
            s.range.end,
            s.suggestions.take(maxSuggestions).toList(),
          ),
      ]),
    );
  }

  @override
  Future<String?> resolveLanguage(Locale locale) async =>
      locale.toLanguageTag();

  @override
  Future<List<String>> availableLanguages() async => const <String>[];
}
