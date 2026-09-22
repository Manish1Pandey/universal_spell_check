#include "universal_spell_check_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <objbase.h>
#include <spellcheck.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cwchar>
#include <cwctype>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace universal_spell_check {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), length);
  return wide;
}

std::string WideToUtf8(const wchar_t* wide, size_t size) {
  if (wide == nullptr || size == 0) {
    return std::string();
  }
  const int length =
      ::WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(size), nullptr,
                            0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(size), utf8.data(),
                        length, nullptr, nullptr);
  return utf8;
}

std::string WideToUtf8(const std::wstring& wide) {
  return WideToUtf8(wide.data(), wide.size());
}

std::wstring ToLower(std::wstring s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return s;
}

const EncodableMap* ArgumentsMap(
    const flutter::MethodCall<EncodableValue>& call) {
  return std::get_if<EncodableMap>(call.arguments());
}

const std::string* StringArgument(const EncodableMap* args, const char* key) {
  if (args == nullptr) {
    return nullptr;
  }
  auto it = args->find(EncodableValue(key));
  if (it == args->end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&it->second);
}

int IntArgument(const EncodableMap* args, const char* key, int fallback) {
  if (args == nullptr) {
    return fallback;
  }
  auto it = args->find(EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  if (const int32_t* v = std::get_if<int32_t>(&it->second)) {
    return static_cast<int>(*v);
  }
  if (const int64_t* v = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*v);
  }
  return fallback;
}

}  // namespace

// static
void UniversalSpellCheckPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "universal_spell_check",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<UniversalSpellCheckPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

UniversalSpellCheckPlugin::UniversalSpellCheckPlugin() {}

UniversalSpellCheckPlugin::~UniversalSpellCheckPlugin() {
  // Release COM objects before balancing our CoInitializeEx call.
  checkers_.clear();
  factory_.Reset();
  if (com_initialized_) {
    ::CoUninitialize();
  }
}

ISpellCheckerFactory* UniversalSpellCheckPlugin::Factory() {
  if (factory_) {
    return factory_.Get();
  }
  if (factory_failed_) {
    return nullptr;
  }
  // The Flutter runner initialises COM on the platform thread already; this
  // call is then a cheap S_FALSE that we balance in the destructor.
  // RPC_E_CHANGED_MODE means COM is initialised in another mode, which is
  // still usable and must not be balanced.
  const HRESULT init = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (init == S_OK || init == S_FALSE) {
    com_initialized_ = true;
  }
  const HRESULT hr =
      ::CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr,
                         CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory_));
  if (FAILED(hr) || !factory_) {
    factory_.Reset();
    factory_failed_ = true;
    return nullptr;
  }
  return factory_.Get();
}

std::vector<std::wstring> UniversalSpellCheckPlugin::SupportedLanguages() {
  std::vector<std::wstring> languages;
  ISpellCheckerFactory* factory = Factory();
  if (factory == nullptr) {
    return languages;
  }
  ComPtr<IEnumString> enumerator;
  if (FAILED(factory->get_SupportedLanguages(&enumerator)) || !enumerator) {
    return languages;
  }
  while (true) {
    LPOLESTR language = nullptr;
    ULONG fetched = 0;
    if (enumerator->Next(1, &language, &fetched) != S_OK || fetched == 0) {
      break;
    }
    if (language != nullptr) {
      languages.emplace_back(language);
      ::CoTaskMemFree(language);
    }
  }
  return languages;
}

std::optional<std::wstring> UniversalSpellCheckPlugin::ResolveLanguage(
    const std::wstring& tag) {
  ISpellCheckerFactory* factory = Factory();
  if (factory == nullptr || tag.empty()) {
    return std::nullopt;
  }
  std::wstring normalized = tag;
  std::replace(normalized.begin(), normalized.end(), L'_', L'-');

  BOOL supported = FALSE;
  if (SUCCEEDED(factory->IsSupported(normalized.c_str(), &supported)) &&
      supported) {
    return normalized;
  }
  const std::wstring language = normalized.substr(0, normalized.find(L'-'));
  supported = FALSE;
  if (language != normalized &&
      SUCCEEDED(factory->IsSupported(language.c_str(), &supported)) &&
      supported) {
    return language;
  }
  // Any regional variant of the same language ("en" -> "en-GB"), preferring
  // an exact case-insensitive match.
  const std::wstring wanted = ToLower(normalized);
  const std::wstring prefix = ToLower(language) + L"-";
  std::optional<std::wstring> fallback;
  for (const std::wstring& candidate : SupportedLanguages()) {
    const std::wstring lower = ToLower(candidate);
    if (lower == wanted) {
      return candidate;
    }
    if (!fallback && lower.compare(0, prefix.size(), prefix) == 0) {
      fallback = candidate;
    }
  }
  return fallback;
}

ISpellChecker* UniversalSpellCheckPlugin::CheckerFor(
    const std::wstring& language) {
  auto it = checkers_.find(language);
  if (it != checkers_.end()) {
    return it->second.Get();
  }
  ISpellCheckerFactory* factory = Factory();
  if (factory == nullptr) {
    return nullptr;
  }
  ComPtr<ISpellChecker> checker;
  if (FAILED(factory->CreateSpellChecker(language.c_str(), &checker)) ||
      !checker) {
    return nullptr;
  }
  ISpellChecker* raw = checker.Get();
  checkers_.emplace(language, std::move(checker));
  return raw;
}

std::optional<EncodableList> UniversalSpellCheckPlugin::Check(
    ISpellChecker* checker, const std::wstring& text, int max_suggestions,
    std::string* error) {
  EncodableList results;
  if (text.empty()) {
    return results;
  }
  ComPtr<IEnumSpellingError> errors;
  HRESULT hr = checker->Check(text.c_str(), &errors);
  if (FAILED(hr) || !errors) {
    *error = "ISpellChecker::Check failed (HRESULT " + std::to_string(hr) + ")";
    return std::nullopt;
  }
  while (true) {
    ComPtr<ISpellingError> spelling_error;
    if (errors->Next(&spelling_error) != S_OK || !spelling_error) {
      break;  // S_FALSE: no more errors.
    }
    ULONG start = 0;
    ULONG length = 0;
    CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
    if (FAILED(spelling_error->get_StartIndex(&start)) ||
        FAILED(spelling_error->get_Length(&length)) ||
        FAILED(spelling_error->get_CorrectiveAction(&action))) {
      continue;
    }
    // CORRECTIVE_ACTION_DELETE flags repeated words ("the the"), which is
    // not a spelling mistake; Flutter's spell check only marks misspellings.
    if (length == 0 || action == CORRECTIVE_ACTION_DELETE ||
        action == CORRECTIVE_ACTION_NONE ||
        static_cast<size_t>(start) + length > text.size()) {
      continue;
    }
    EncodableList suggestions;
    if (max_suggestions > 0) {
      if (action == CORRECTIVE_ACTION_REPLACE) {
        LPWSTR replacement = nullptr;
        if (SUCCEEDED(spelling_error->get_Replacement(&replacement)) &&
            replacement != nullptr) {
          suggestions.emplace_back(WideToUtf8(replacement, wcslen(replacement)));
          ::CoTaskMemFree(replacement);
        }
      } else if (action == CORRECTIVE_ACTION_GET_SUGGESTIONS) {
        const std::wstring word = text.substr(start, length);
        ComPtr<IEnumString> enumerator;
        if (SUCCEEDED(checker->Suggest(word.c_str(), &enumerator)) &&
            enumerator) {
          while (static_cast<int>(suggestions.size()) < max_suggestions) {
            LPOLESTR suggestion = nullptr;
            ULONG fetched = 0;
            if (enumerator->Next(1, &suggestion, &fetched) != S_OK ||
                fetched == 0) {
              break;
            }
            if (suggestion != nullptr) {
              suggestions.emplace_back(
                  WideToUtf8(suggestion, wcslen(suggestion)));
              ::CoTaskMemFree(suggestion);
            }
          }
        }
      }
    }
    EncodableMap range;
    range[EncodableValue("start")] = EncodableValue(static_cast<int32_t>(start));
    range[EncodableValue("end")] =
        EncodableValue(static_cast<int32_t>(start + length));
    range[EncodableValue("suggestions")] = EncodableValue(std::move(suggestions));
    results.emplace_back(std::move(range));
  }
  return results;
}

void UniversalSpellCheckPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const EncodableMap* args = ArgumentsMap(method_call);

  if (method == "checkText") {
    const std::string* text = StringArgument(args, "text");
    const std::string* language = StringArgument(args, "language");
    if (text == nullptr || language == nullptr) {
      result->Error("bad_arguments",
                    "checkText needs 'text' and 'language' strings");
      return;
    }
    const int max_suggestions =
        (std::max)(0, IntArgument(args, "maxSuggestions", 5));
    const std::optional<std::wstring> resolved =
        ResolveLanguage(Utf8ToWide(*language));
    ISpellChecker* checker = resolved ? CheckerFor(*resolved) : nullptr;
    if (checker == nullptr) {
      result->Success();  // null: language unsupported / API unavailable.
      return;
    }
    std::string error;
    std::optional<EncodableList> ranges =
        Check(checker, Utf8ToWide(*text), max_suggestions, &error);
    if (!ranges) {
      result->Error("check_failed", error);
      return;
    }
    result->Success(EncodableValue(std::move(*ranges)));
  } else if (method == "resolveLanguage") {
    const std::string* language = StringArgument(args, "language");
    if (language == nullptr) {
      result->Error("bad_arguments", "resolveLanguage needs 'language'");
      return;
    }
    const std::optional<std::wstring> resolved =
        ResolveLanguage(Utf8ToWide(*language));
    if (resolved) {
      result->Success(EncodableValue(WideToUtf8(*resolved)));
    } else {
      result->Success();
    }
  } else if (method == "availableLanguages") {
    EncodableList languages;
    for (const std::wstring& language : SupportedLanguages()) {
      languages.emplace_back(WideToUtf8(language));
    }
    result->Success(EncodableValue(std::move(languages)));
  } else {
    result->NotImplemented();
  }
}

}  // namespace universal_spell_check
