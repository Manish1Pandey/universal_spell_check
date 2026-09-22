#ifndef FLUTTER_PLUGIN_UNIVERSAL_SPELL_CHECK_PLUGIN_H_
#define FLUTTER_PLUGIN_UNIVERSAL_SPELL_CHECK_PLUGIN_H_

// windows.h must come before spellcheck.h.
#include <windows.h>
#include <spellcheck.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace universal_spell_check {

// Windows implementation of universal_spell_check, backed by the Windows
// Spell Checking API (ISpellCheckerFactory / ISpellChecker, Windows 8+).
//
// Channel "universal_spell_check":
//  - checkText {text, language, maxSuggestions}
//      -> [{start, end, suggestions}] (UTF-16 offsets), or null when no
//         dictionary supports the language.
//  - resolveLanguage {language} -> string or null
//  - availableLanguages -> [string]
class UniversalSpellCheckPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  UniversalSpellCheckPlugin();

  virtual ~UniversalSpellCheckPlugin();

  // Disallow copy and assign.
  UniversalSpellCheckPlugin(const UniversalSpellCheckPlugin&) = delete;
  UniversalSpellCheckPlugin& operator=(const UniversalSpellCheckPlugin&) =
      delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  // Returns the spell checker factory, creating it on first use, or nullptr
  // when the Spell Checking API is unavailable (e.g. Windows 7).
  ISpellCheckerFactory* Factory();

  // Maps a BCP-47 tag ("en-US") to a tag the factory supports, trying the
  // exact tag, the bare language, then any region of the same language.
  std::optional<std::wstring> ResolveLanguage(const std::wstring& tag);

  // Returns a cached checker for a supported language, or nullptr.
  ISpellChecker* CheckerFor(const std::wstring& language);

  std::vector<std::wstring> SupportedLanguages();

  // Runs ISpellChecker::Check over |text| and collects the results.
  // Returns std::nullopt (and fills |error|) if the API call fails.
  std::optional<flutter::EncodableList> Check(ISpellChecker* checker,
                                              const std::wstring& text,
                                              int max_suggestions,
                                              std::string* error);

  Microsoft::WRL::ComPtr<ISpellCheckerFactory> factory_;
  bool factory_failed_ = false;
  bool com_initialized_ = false;
  std::map<std::wstring, Microsoft::WRL::ComPtr<ISpellChecker>> checkers_;
};

}  // namespace universal_spell_check

#endif  // FLUTTER_PLUGIN_UNIVERSAL_SPELL_CHECK_PLUGIN_H_
