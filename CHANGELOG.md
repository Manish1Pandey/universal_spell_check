## 0.1.0

* Initial release.
* `UniversalSpellCheckService`, a `SpellCheckService` for every platform:
  NSSpellChecker (macOS), ISpellChecker (Windows 8+), Enchant-2 loaded at
  runtime (Linux), a pure-Dart Hunspell engine (web and fallback), and
  Flutter's `DefaultSpellCheckService` (Android/iOS).
* Pure-Dart Hunspell engine: PFX/SFX with cross products and continuation
  classes, FLAG char/long/num/UTF-8, AF, TRY, KEY, REP, MAP, ICONV/OCONV,
  KEEPCASE, NOSUGGEST, FORBIDDENWORD, NEEDAFFIX, ONLYINCOMPOUND,
  COMPOUNDRULE, BREAK; edit-based and n-gram suggestions.
* Runs in a background isolate on native platforms; yields to the event loop
  on the web.
* Bundled SCOWL en_US dictionary (size 60) with its license.
* `UniversalSpellCheck.configuration()`, a suggestions toolbar for desktop,
  and a context menu builder with suggestions and "Ignore".
