# universal_spell_check — Specification

Written before implementation. Solves
[flutter/flutter#40682](https://github.com/flutter/flutter/issues/40682): Flutter's
built-in spell check (`SpellCheckConfiguration` + `DefaultSpellCheckService`) only
works on Android and iOS. Web, macOS, Windows and Linux get nothing.

## 1. Purpose

Give every Flutter platform a working `SpellCheckService` that plugs straight into
`TextField(spellCheckConfiguration: ...)` / `EditableText`, plus a context menu that
offers the suggestions on desktop and web, where Flutter never shows its spell-check
toolbar on its own.

## 2. Functional requirements

| ID | Requirement |
|----|-------------|
| FR-1 | `UniversalSpellCheckService implements SpellCheckService`; `fetchSpellCheckSuggestions(Locale, String)` returns sorted, non-overlapping `SuggestionSpan`s whose ranges are UTF-16 offsets into the given text. |
| FR-2 | macOS backend: Swift, `NSSpellChecker` (`checkSpelling(of:startingAt:language:…)` for ranges and `guesses(forWordRange:…)` for suggestions); language resolved from the `Locale` (`en-US` → `en_US` → `en` → any `en_*`). |
| FR-3 | Windows backend: C++, `ISpellCheckerFactory` / `ISpellChecker` (Windows 8+); `Check()` for ranges, `Suggest()` for suggestions, `CORRECTIVE_ACTION_REPLACE` honoured. |
| FR-4 | Linux backend: C, Enchant-2 loaded at runtime with `dlopen("libenchant-2.so.2")`; when the library or a dictionary for the language is missing the backend reports *unavailable* instead of crashing or failing to link. |
| FR-5 | Web backend: pure-Dart Hunspell-compatible engine. Loads `.aff`/`.dic` from Flutter assets, a URL, or in-memory text. Supports `SET` (UTF-8 / ISO8859-x as Latin-1), `FLAG` (char/long/num/UTF-8), `AF` aliases, `PFX`/`SFX` with conditions, strip strings and cross products, two-level suffixes (continuation classes), `TRY`, `KEY`, `REP`, `MAP`, `ICONV`/`OCONV`, `KEEPCASE`, `NOSUGGEST`, `FORBIDDENWORD`, `NEEDAFFIX`, `ONLYINCOMPOUND`, `COMPOUNDRULE` + `COMPOUNDMIN`, `WORDCHARS`, `BREAK`. Hunspell capitalisation rules (lower / Initial / ALLCAPS / mixed). |
| FR-6 | Hunspell suggestions: REP table, MAP, case fixes, adjacent/long swaps, KEY neighbours, extra/forgotten/moved/wrong characters (TRY order), doubled two-char sequences, split into two words; n-gram fallback over the word list when no edit-based suggestion exists. `NOSUGGEST`/`FORBIDDENWORD` words are never suggested. |
| FR-7 | The Hunspell engine runs in a long-lived background isolate on native platforms. On the web (no isolates in Dart web) it runs on the main thread but yields to the event loop between chunks while parsing and checking. |
| FR-8 | A bundled en_US dictionary (SCOWL size 60, 2020.12.07, with its licence) is used on the web, and as fallback on desktop when the native checker is unavailable for an English locale. Callers can supply any other Hunspell dictionary. |
| FR-9 | Android/iOS: delegate to Flutter's `DefaultSpellCheckService`. |
| FR-10 | `UniversalSpellCheck.configuration()` returns a `SpellCheckConfiguration` with the service, a misspelled text style (red wavy underline) and a platform-appropriate suggestions toolbar builder. |
| FR-11 | `UniversalSpellCheck.contextMenuBuilder` adds suggestion items, "Ignore" and the default cut/copy/paste items to the right-click / long-press menu. |
| FR-12 | `ignoreWord()` hides a word for the rest of the session on every backend. |
| FR-13 | `availability(Locale)` tells the app which backend will be used and whether it can check that language. |

## 3. Can / Cannot

| Can | Cannot (honest limits) |
|-----|------------------------|
| Mark misspellings and offer suggestions on macOS, Windows 8+, Linux (with Enchant-2 installed), web, Android, iOS. | Query the browser's own spellchecker on the web: browsers expose no API for it, and Flutter web draws text itself. That is why a bundled Hunspell engine exists. |
| Use any Hunspell `.aff`/`.dic` pair on the web or as a desktop fallback. | Implement 100 % of Hunspell: no morphological analysis (`AM`, stemming output), no `COMPOUNDFLAG`/`COMPOUNDBEGIN`-style compounding (only `COMPOUNDRULE`), no `CHECKSHARPS`, no `PHONE` table, no Hunspell-exact suggestion order. en_US is fully covered. |
| Run the Hunspell engine off the UI isolate on native platforms. | Run it in a Web Worker: on the web it runs on the main thread in chunks. Parsing en_US takes a few hundred ms there, once. |
| Fall back to the bundled en_US dictionary when a desktop OS has no checker for an English locale. | Check languages with no native dictionary and no Hunspell dictionary supplied: the service then returns no marks and `availability()` says so. |
| Show suggestions in the context menu on desktop/web. | Show Flutter's tap-to-open spell-check toolbar on desktop: Flutter's gesture code only opens it on Android/iOS. Desktop/web use the right-click menu instead. On the web you must disable the browser context menu (`BrowserContextMenu.disableContextMenu()`) to see it. |
| Ignore words for the session. | Persist a user dictionary or teach the OS dictionary new words. |
| Build and run on macOS and web here (verified). | Be built or run on Windows/Linux from this Mac. That code is written against the documented APIs but has not been compiled here. |

## 4. Public API sketch

```dart
class UniversalSpellCheckService implements SpellCheckService {
  UniversalSpellCheckService({
    SpellCheckBackend backend = SpellCheckBackend.auto,
    HunspellSource? hunspellSource,          // default: bundled en_US
    bool fallbackToHunspell = true,
    bool useIsolate = true,
    int maxSuggestions = 5,
  });
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(Locale locale, String text);
  Future<SpellCheckAvailability> availability(Locale locale);
  void ignoreWord(String word);
  Set<String> get ignoredWords;
  Future<void> dispose();
}

enum SpellCheckBackend { auto, native, hunspell, platformDefault }

abstract final class UniversalSpellCheck {
  static SpellCheckConfiguration configuration({...});
  static TextStyle get misspelledTextStyle;
  static Widget suggestionsToolbarBuilder(BuildContext, EditableTextState);
  static Widget contextMenuBuilder(BuildContext, EditableTextState);
  static List<ContextMenuButtonItem> suggestionButtonItems(EditableTextState, {...});
}

class HunspellSource { .asset(aff, dic), .url(aff, dic), .text(aff, dic), .bundledEnUS() }
class HunspellDictionary { static HunspellDictionary parse(String aff, String dic); }
class Hunspell { bool check(String word); List<String> suggest(String word, {int max}); }
class HunspellSpellChecker { Future<List<SpellCheckRange>> check(String text); }
List<WordToken> tokenizeWords(String text, {String extraWordChars});
```

## 5. Platform matrix

| Platform | Backend | Native code | Built here |
|----------|---------|-------------|------------|
| Android | Flutter `DefaultSpellCheckService` | none (Dart plugin class) | yes (apk --debug) |
| iOS | Flutter `DefaultSpellCheckService` | none (Dart plugin class) | yes (--no-codesign) |
| macOS 10.14+ | `NSSpellChecker` | Swift | yes |
| Windows 8+ | `ISpellChecker` | C++ | no (needs Windows) |
| Linux | Enchant-2 via `dlopen` | C (GObject) | no (needs Linux) |
| Web | Pure-Dart Hunspell + bundled en_US | none | yes |

## 6. Channel protocol (`universal_spell_check`)

| Method | Args | Result |
|--------|------|--------|
| `checkText` (macOS, Windows) | `{text, language, maxSuggestions}` | `List<{start, end, suggestions}>`, or `null` if the language is unsupported |
| `checkWords` (Linux) | `{words: List<String>, language, maxSuggestions}` | `List<List<String>?>` (null = correct), or `null` if unavailable |
| `availableLanguages` | – | `List<String>` (empty if no checker) |
| `resolveLanguage` | `{language}` | resolved tag or `null` |

Linux uses Dart-side tokenisation (`tokenizeWords`) so UTF-16 offsets are computed in
one tested place; macOS and Windows tokenise natively with the OS rules.
