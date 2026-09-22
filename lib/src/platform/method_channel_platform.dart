import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../tokenizer.dart';
import 'spell_check_platform.dart';

/// Talks to the native macOS (`NSSpellChecker`) and Windows
/// (`ISpellChecker`) implementations, which tokenise the text themselves.
class MethodChannelUniversalSpellCheck extends UniversalSpellCheckPlatform {
  /// The channel shared with the native code.
  @visibleForTesting
  final MethodChannel channel = const MethodChannel('universal_spell_check');

  @override
  ResolvedSpellChecker get nativeChecker => switch (defaultTargetPlatform) {
    TargetPlatform.macOS => ResolvedSpellChecker.nsSpellChecker,
    TargetPlatform.windows => ResolvedSpellChecker.windowsSpellChecker,
    TargetPlatform.linux => ResolvedSpellChecker.enchant,
    _ => ResolvedSpellChecker.none,
  };

  @override
  Future<NativeCheckOutcome> check(
    Locale locale,
    String text, {
    required int maxSuggestions,
  }) async {
    final String tag = locale.toLanguageTag();
    try {
      final List<Object?>? raw = await channel.invokeListMethod<Object?>(
        'checkText',
        <String, Object>{
          'text': text,
          'language': tag,
          'maxSuggestions': maxSuggestions,
        },
      );
      if (raw == null) {
        return NativeCheckUnavailable('No native dictionary for "$tag".');
      }
      return NativeCheckResults(
        UniversalSpellCheckPlatform.normalize(<SpellCheckRange>[
          for (final Object? m in raw)
            if (m is Map) SpellCheckRange.fromMap(m),
        ]),
      );
    } on MissingPluginException {
      return const NativeCheckUnavailable(
        'No native spell checker on this platform.',
      );
    } on PlatformException catch (e) {
      return NativeCheckUnavailable(e.message ?? e.code);
    }
  }

  @override
  Future<String?> resolveLanguage(Locale locale) async {
    try {
      return await channel.invokeMethod<String>(
        'resolveLanguage',
        <String, Object>{'language': locale.toLanguageTag()},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<String>> availableLanguages() async {
    try {
      return await channel.invokeListMethod<String>('availableLanguages') ??
          const <String>[];
    } on MissingPluginException {
      return const <String>[];
    } on PlatformException {
      return const <String>[];
    }
  }
}

/// Linux implementation: tokenises in Dart (see [tokenizeWords]) and asks
/// Enchant-2 about each distinct word, so offsets are computed in one tested
/// place.
class LinuxUniversalSpellCheck extends MethodChannelUniversalSpellCheck {
  /// Registers this implementation (called by the generated plugin
  /// registrant on Linux).
  static void registerWith() {
    UniversalSpellCheckPlatform.instance = LinuxUniversalSpellCheck();
  }

  @override
  ResolvedSpellChecker get nativeChecker => ResolvedSpellChecker.enchant;

  @override
  Future<NativeCheckOutcome> check(
    Locale locale,
    String text, {
    required int maxSuggestions,
  }) async {
    final String tag = locale.toLanguageTag();
    final List<WordToken> tokens = tokenizeWords(text);
    final List<String> words = <String>{
      for (final WordToken t in tokens) t.text,
    }.toList();
    // Enchant dictionaries use the ASCII apostrophe.
    final List<String> query = <String>[
      for (final String w in words) w.replaceAll('\u2019', "'"),
    ];
    try {
      final List<Object?>? raw = await channel.invokeListMethod<Object?>(
        'checkWords',
        <String, Object>{
          'words': query,
          'language': tag,
          'maxSuggestions': maxSuggestions,
        },
      );
      if (raw == null) {
        return NativeCheckUnavailable(
          'Enchant-2 (libenchant-2.so.2) or a dictionary for "$tag" '
          'is not installed.',
        );
      }
      if (raw.length != words.length) {
        return const NativeCheckUnavailable('Malformed reply from Enchant.');
      }
      final Map<String, List<String>> misspelled = <String, List<String>>{};
      for (int i = 0; i < words.length; i++) {
        final Object? r = raw[i];
        if (r is List) {
          misspelled[words[i]] = r.whereType<String>().toList();
        }
      }
      return NativeCheckResults(<SpellCheckRange>[
        for (final WordToken t in tokens)
          if (misspelled.containsKey(t.text))
            SpellCheckRange(t.start, t.end, misspelled[t.text]!),
      ]);
    } on MissingPluginException {
      return const NativeCheckUnavailable('Linux plugin not registered.');
    } on PlatformException catch (e) {
      return NativeCheckUnavailable(e.message ?? e.code);
    }
  }
}
