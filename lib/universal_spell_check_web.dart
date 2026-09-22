import 'dart:ui' show Locale;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/models.dart';
import 'src/platform/spell_check_platform.dart';

/// Web implementation of the platform interface.
///
/// Browsers expose no API to query their built-in spell checker, and
/// Flutter web draws text itself, so there is no native checker here:
/// `UniversalSpellCheckService` uses its pure-Dart Hunspell engine instead.
class UniversalSpellCheckWeb extends UniversalSpellCheckPlatform {
  /// Registers this implementation with the web plugin registrar.
  static void registerWith(Registrar registrar) {
    UniversalSpellCheckPlatform.instance = UniversalSpellCheckWeb();
  }

  @override
  ResolvedSpellChecker get nativeChecker => ResolvedSpellChecker.none;

  @override
  Future<NativeCheckOutcome> check(
    Locale locale,
    String text, {
    required int maxSuggestions,
  }) async {
    return const NativeCheckUnavailable(
      'Browsers do not expose their spell checker to web apps.',
    );
  }

  @override
  Future<String?> resolveLanguage(Locale locale) async => null;

  @override
  Future<List<String>> availableLanguages() async => const <String>[];
}
