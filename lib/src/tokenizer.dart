/// A word found in a text by [tokenizeWords].
///
/// [start] and [end] are UTF-16 code unit offsets into the original text
/// (the same unit Flutter's `TextRange` uses); [end] is exclusive.
class WordToken {
  /// Creates a token for [text] spanning `[start, end)`.
  const WordToken(this.text, this.start, this.end);

  /// The word exactly as it appears in the source text.
  final String text;

  /// Offset of the first code unit of the word.
  final int start;

  /// Offset one past the last code unit of the word.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is WordToken &&
      other.text == text &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(text, start, end);

  @override
  String toString() => 'WordToken("$text", $start, $end)';
}

final RegExp _chunk = RegExp(r'\S+');
final RegExp _url = RegExp(r'^[\(\[<"]*([a-zA-Z][a-zA-Z0-9+.-]*://|www\.)');
final RegExp _email = RegExp(r'[^\s@]+@[^\s@]+\.[^\s@]+');
final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);
final Map<String, RegExp> _wordPatterns = <String, RegExp>{};

RegExp _wordPattern(String extraWordChars) {
  return _wordPatterns.putIfAbsent(extraWordChars, () {
    final String extra = _escapeForCharClass(extraWordChars);
    final String w = '[\\p{L}\\p{M}\\p{N}$extra]';
    // Apostrophes and hyphens join word characters, but never start or end
    // a word: "don't", "e-mail", but not "'quoted'" or "trailing-".
    return RegExp("$w+(?:['’\\-]$w+)*", unicode: true);
  });
}

String _escapeForCharClass(String chars) {
  final StringBuffer out = StringBuffer();
  for (final int rune in chars.runes) {
    final String c = String.fromCharCode(rune);
    if (r'\]^-['.contains(c)) {
      out.write('\\');
    }
    out.write(c);
  }
  return out.toString();
}

/// Splits [text] into the words a spell checker should look at.
///
/// Words are runs of Unicode letters, combining marks and digits (plus any
/// [extraWordChars], e.g. a Hunspell `WORDCHARS` value). Apostrophes (`'` and
/// `’`) and hyphens are kept when they sit *between* word characters, so
/// `don't` and `e-mail` stay single tokens. Tokens without any letter (pure
/// numbers), URLs and e-mail addresses are skipped.
///
/// Offsets are UTF-16 code units, so they are valid `TextRange` values for
/// Flutter even when the text contains emoji or other astral characters.
List<WordToken> tokenizeWords(String text, {String extraWordChars = ''}) {
  final List<WordToken> tokens = <WordToken>[];
  if (text.isEmpty) {
    return tokens;
  }
  final RegExp word = _wordPattern(extraWordChars);
  for (final RegExpMatch chunk in _chunk.allMatches(text)) {
    final String chunkText = chunk.group(0)!;
    if (_url.hasMatch(chunkText) || _email.hasMatch(chunkText)) {
      continue;
    }
    for (final RegExpMatch m in word.allMatches(chunkText)) {
      final String w = m.group(0)!;
      if (!_hasLetter.hasMatch(w)) {
        continue;
      }
      tokens.add(WordToken(w, chunk.start + m.start, chunk.start + m.end));
    }
  }
  return tokens;
}
