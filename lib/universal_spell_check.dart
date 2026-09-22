/// Spell checking for Flutter text fields on every platform: macOS
/// (NSSpellChecker), Windows (ISpellChecker), Linux (Enchant-2), web
/// (pure-Dart Hunspell) and Android/iOS (Flutter's default service).
///
/// Solves https://github.com/flutter/flutter/issues/40682.
library;

export 'src/hunspell/affix.dart';
export 'src/hunspell/dictionary.dart'
    show
        HunspellDictionary,
        HunspellFormatException,
        WordEntry,
        decodeHunspellBytes;
export 'src/hunspell/hunspell.dart' show Hunspell;
export 'src/hunspell/source.dart'
    show
        AssetHunspellSource,
        HunspellSource,
        TextHunspellSource,
        UrlHunspellSource;
export 'src/hunspell/spell_checker.dart' show HunspellSpellChecker;
export 'src/models.dart';
export 'src/platform/method_channel_platform.dart'
    show LinuxUniversalSpellCheck, MethodChannelUniversalSpellCheck;
export 'src/platform/mobile_platform.dart' show UniversalSpellCheckMobile;
export 'src/platform/spell_check_platform.dart';
export 'src/service.dart';
export 'src/tokenizer.dart';
export 'src/ui.dart';
