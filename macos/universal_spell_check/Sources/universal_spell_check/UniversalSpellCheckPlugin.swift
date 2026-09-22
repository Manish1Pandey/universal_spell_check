import Cocoa
import FlutterMacOS

/// macOS implementation of universal_spell_check, backed by NSSpellChecker.
///
/// Channel: `universal_spell_check`
/// - `checkText` {text, language, maxSuggestions} -> [{start, end, suggestions}]
///   or nil when no dictionary matches `language`. Offsets are UTF-16 code
///   units (NSString indices), which is what Flutter's TextRange uses.
/// - `resolveLanguage` {language} -> String? (NSSpellChecker language id)
/// - `availableLanguages` -> [String]
public class UniversalSpellCheckPlugin: NSObject, FlutterPlugin {
  private let spellChecker = NSSpellChecker.shared
  /// A private spell document so "ignored" state never leaks into other apps
  /// or documents.
  private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "universal_spell_check",
      binaryMessenger: registrar.messenger)
    let instance = UniversalSpellCheckPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Connect to the system spelling server up front. On a cold start the
    // very first request can otherwise come back empty while the server
    // loads its dictionaries.
    DispatchQueue.main.async {
      _ = instance.spellChecker.checkSpelling(of: "xqzvbn", startingAt: 0)
    }
  }

  deinit {
    spellChecker.closeSpellDocument(withTag: documentTag)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "checkText":
      guard let text = args["text"] as? String,
        let language = args["language"] as? String
      else {
        result(
          FlutterError(
            code: "bad_arguments",
            message: "checkText needs 'text' and 'language' strings",
            details: nil))
        return
      }
      let maxSuggestions = max(0, (args["maxSuggestions"] as? NSNumber)?.intValue ?? 5)
      guard let resolved = resolveLanguage(language) else {
        result(nil)
        return
      }
      result(check(text: text, language: resolved, maxSuggestions: maxSuggestions))
    case "resolveLanguage":
      guard let language = args["language"] as? String else {
        result(
          FlutterError(
            code: "bad_arguments", message: "resolveLanguage needs 'language'",
            details: nil))
        return
      }
      result(resolveLanguage(language))
    case "availableLanguages":
      result(spellChecker.availableLanguages)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Maps a BCP-47 tag ("en-US", "zh-Hant-TW") to one of
  /// NSSpellChecker.availableLanguages ("en_US", "en", ...).
  private func resolveLanguage(_ tag: String) -> String? {
    let available = spellChecker.availableLanguages
    let normalized = tag.replacingOccurrences(of: "-", with: "_")
    let parts = normalized.split(separator: "_").map(String.init)
    guard let languageCode = parts.first, !languageCode.isEmpty else { return nil }

    var candidates = [normalized]
    if parts.count >= 2, let region = parts.last {
      candidates.append("\(languageCode)_\(region)")
    }
    candidates.append(languageCode)
    for candidate in candidates {
      if let match = available.first(where: {
        $0.caseInsensitiveCompare(candidate) == .orderedSame
      }) {
        return match
      }
    }
    // Any regional variant of the same language ("en" -> "en_GB").
    let prefix = languageCode.lowercased() + "_"
    return available.first(where: { $0.lowercased().hasPrefix(prefix) })
  }

  private func check(text: String, language: String, maxSuggestions: Int) -> [[String: Any]] {
    let length = (text as NSString).length
    var results: [[String: Any]] = []
    var offset = 0
    while offset < length {
      var wordCount = 0
      let range = spellChecker.checkSpelling(
        of: text,
        startingAt: offset,
        language: language,
        wrap: false,
        inSpellDocumentWithTag: documentTag,
        wordCount: &wordCount)
      if range.location == NSNotFound || range.length == 0 || range.location < offset {
        break
      }
      var suggestions: [String] = []
      if maxSuggestions > 0 {
        let guesses =
          spellChecker.guesses(
            forWordRange: range,
            in: text,
            language: language,
            inSpellDocumentWithTag: documentTag) ?? []
        suggestions = Array(guesses.prefix(maxSuggestions))
      }
      results.append([
        "start": range.location,
        "end": range.location + range.length,
        "suggestions": suggestions,
      ])
      offset = range.location + range.length
    }
    return results
  }
}
