import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'affix.dart';

/// A word from the `.dic` file with its flags.
class WordEntry {
  /// Creates a dictionary entry.
  const WordEntry(this.word, this.flags);

  /// The word as written in the dictionary.
  final String word;

  /// Affix and attribute flags attached to the word.
  final Int32List flags;
}

/// Thrown when a `.aff` or `.dic` file cannot be parsed.
class HunspellFormatException implements Exception {
  /// Creates the exception with a human-readable [message].
  const HunspellFormatException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'HunspellFormatException: $message';
}

/// Decodes raw `.aff`/`.dic` bytes using the `SET` directive of the `.aff`.
///
/// `UTF-8` (the default when `SET` is absent) is decoded as UTF-8; any
/// `ISO8859-*` or other single-byte set is decoded as Latin-1, which is exact
/// for ISO8859-1 and keeps ASCII intact for the others.
({String aff, String dic}) decodeHunspellBytes(List<int> aff, List<int> dic) {
  final String affLatin1 = latin1.decode(aff, allowInvalid: true);
  final RegExpMatch? set = RegExp(
    r'^SET\s+(\S+)',
    multiLine: true,
  ).firstMatch(affLatin1);
  final String encoding = (set?.group(1) ?? 'UTF-8').toUpperCase();
  final bool isUtf8 = encoding == 'UTF-8' || encoding == 'UTF8';
  String decode(List<int> bytes) {
    final String s = isUtf8
        ? utf8.decode(bytes, allowMalformed: true)
        : latin1.decode(bytes, allowInvalid: true);
    return s.startsWith('﻿') ? s.substring(1) : s;
  }

  return (aff: decode(aff), dic: decode(dic));
}

/// A parsed Hunspell dictionary: affix rules plus the word list.
///
/// Build one with [HunspellDictionary.parse] (synchronous) or
/// [HunspellDictionary.parseAsync] (yields to the event loop while parsing,
/// for use on the web where there are no isolates).
class HunspellDictionary {
  HunspellDictionary._();

  /// Parses the text of an `.aff` file and a `.dic` file.
  factory HunspellDictionary.parse(String aff, String dic) {
    final HunspellDictionary d = HunspellDictionary._();
    d._parseAff(aff);
    final List<String> lines = const LineSplitter().convert(dic);
    d._parseDicLines(lines, 0, lines.length);
    d._finish();
    return d;
  }

  /// Like [HunspellDictionary.parse] but yields to the event loop every
  /// [chunkSize] dictionary lines so a UI stays responsive.
  static Future<HunspellDictionary> parseAsync(
    String aff,
    String dic, {
    int chunkSize = 4000,
  }) async {
    final HunspellDictionary d = HunspellDictionary._();
    d._parseAff(aff);
    await Future<void>.delayed(Duration.zero);
    final List<String> lines = const LineSplitter().convert(dic);
    for (int i = 0; i < lines.length; i += chunkSize) {
      final int end = i + chunkSize < lines.length
          ? i + chunkSize
          : lines.length;
      d._parseDicLines(lines, i, end);
      await Future<void>.delayed(Duration.zero);
    }
    d._finish();
    return d;
  }

  /// Flag syntax used by this dictionary.
  FlagType flagType = FlagType.char;

  /// Characters tried when inserting or replacing letters for suggestions.
  String tryChars = '';

  /// Keyboard layout rows (`KEY`), separated by `|`.
  String keyboard = 'qwertyuiop|asdfghjkl|zxcvbnm';

  /// Extra characters that belong to words (`WORDCHARS`).
  String wordChars = '';

  /// `REP` pairs: common misspelling pattern → replacement.
  final List<(String, String)> replacements = <(String, String)>[];

  /// `MAP` groups of related characters/strings.
  final List<List<String>> mapGroups = <List<String>>[];

  /// `ICONV` input conversions.
  final List<(String, String)> inputConversions = <(String, String)>[];

  /// `OCONV` output conversions.
  final List<(String, String)> outputConversions = <(String, String)>[];

  /// `BREAK` patterns (defaults to `-`, `^-`, `-$`).
  List<String> breakPatterns = <String>['-', '^-', r'-$'];

  /// `COMPOUNDRULE` patterns.
  final List<List<CompoundRuleToken>> compoundRules =
      <List<CompoundRuleToken>>[];

  /// Minimum length of a compound part (`COMPOUNDMIN`, default 3).
  int compoundMin = 3;

  /// `KEEPCASE` flag.
  int? keepCaseFlag;

  /// `NOSUGGEST` flag.
  int? noSuggestFlag;

  /// `FORBIDDENWORD` flag.
  int? forbiddenFlag;

  /// `NEEDAFFIX` (or `PSEUDOROOT`) flag.
  int? needAffixFlag;

  /// `ONLYINCOMPOUND` flag.
  int? onlyInCompoundFlag;

  /// Whether `FULLSTRIP` allows affixes to strip the entire stem.
  bool fullStrip = false;

  /// Prefix rules indexed by their appended string.
  final Map<String, List<AffixEntry>> prefixesByAppend =
      <String, List<AffixEntry>>{};

  /// Suffix rules indexed by their appended string.
  final Map<String, List<AffixEntry>> suffixesByAppend =
      <String, List<AffixEntry>>{};

  /// All affix rules indexed by flag.
  final Map<int, List<AffixEntry>> affixesByFlag = <int, List<AffixEntry>>{};

  /// Flags that appear as continuation classes of some affix.
  final Set<int> continuationClasses = <int>{};

  /// Longest prefix / suffix append string (bounds lookups).
  int maxPrefixLength = 0;

  /// See [maxPrefixLength].
  int maxSuffixLength = 0;

  /// Words by their exact spelling (homonyms share a key).
  final Map<String, List<WordEntry>> words = <String, List<WordEntry>>{};

  /// Words usable as `COMPOUNDRULE` parts.
  final Set<String> compoundPartWords = <String>{};

  final List<Int32List> _aliases = <Int32List>[];
  final Set<int> _compoundRuleFlags = <int>{};

  /// Number of distinct spellings loaded from the `.dic` file.
  int get wordCount => words.length;

  void _parseAff(String aff) {
    final List<String> lines = const LineSplitter().convert(aff);
    // FLAG must be known before anything that parses flags.
    for (final String raw in lines) {
      final List<String> p = _fields(raw);
      if (p.length >= 2 && p[0] == 'FLAG') {
        switch (p[1].toUpperCase()) {
          case 'LONG':
            flagType = FlagType.long;
          case 'NUM':
            flagType = FlagType.num;
          case 'UTF-8':
          case 'UTF8':
            flagType = FlagType.utf8;
        }
      }
    }
    bool sawBreak = false;
    int i = 0;
    while (i < lines.length) {
      final List<String> p = _fields(lines[i]);
      i++;
      if (p.isEmpty) {
        continue;
      }
      switch (p[0]) {
        case 'TRY':
          if (p.length > 1) tryChars = p[1];
        case 'KEY':
          if (p.length > 1) keyboard = p[1];
        case 'WORDCHARS':
          if (p.length > 1) wordChars = p[1];
        case 'KEEPCASE':
          if (p.length > 1) keepCaseFlag = parseSingleFlag(p[1], flagType);
        case 'NOSUGGEST':
          if (p.length > 1) noSuggestFlag = parseSingleFlag(p[1], flagType);
        case 'FORBIDDENWORD':
          if (p.length > 1) forbiddenFlag = parseSingleFlag(p[1], flagType);
        case 'NEEDAFFIX':
        case 'PSEUDOROOT':
          if (p.length > 1) needAffixFlag = parseSingleFlag(p[1], flagType);
        case 'ONLYINCOMPOUND':
          if (p.length > 1) {
            onlyInCompoundFlag = parseSingleFlag(p[1], flagType);
          }
        case 'COMPOUNDMIN':
          if (p.length > 1) {
            compoundMin = int.tryParse(p[1]) ?? compoundMin;
            if (compoundMin < 1) compoundMin = 1;
          }
        case 'FULLSTRIP':
          fullStrip = true;
        case 'AF':
          // "AF <count>" header, then "AF <flags>" lines (1-based aliases).
          final int count = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
          for (int k = 0; k < count && i < lines.length; k++, i++) {
            final List<String> q = _fields(lines[i]);
            _aliases.add(
              q.length > 1 && q[0] == 'AF'
                  ? parseFlagString(q[1], flagType)
                  : Int32List(0),
            );
          }
        case 'REP':
          i = _readTable(lines, i, p, 'REP', (List<String> q) {
            if (q.length > 2) {
              replacements.add((q[1], q[2].replaceAll('_', ' ')));
            }
          });
        case 'ICONV':
          i = _readTable(lines, i, p, 'ICONV', (List<String> q) {
            if (q.length > 2) inputConversions.add((q[1], q[2]));
          });
        case 'OCONV':
          i = _readTable(lines, i, p, 'OCONV', (List<String> q) {
            if (q.length > 2) outputConversions.add((q[1], q[2]));
          });
        case 'MAP':
          i = _readTable(lines, i, p, 'MAP', (List<String> q) {
            if (q.length > 1) mapGroups.add(_parseMapGroup(q[1]));
          });
        case 'BREAK':
          if (!sawBreak) {
            breakPatterns = <String>[];
            sawBreak = true;
          }
          i = _readTable(lines, i, p, 'BREAK', (List<String> q) {
            if (q.length > 1) breakPatterns.add(q[1]);
          });
        case 'COMPOUNDRULE':
          i = _readTable(lines, i, p, 'COMPOUNDRULE', (List<String> q) {
            if (q.length > 1) {
              final List<CompoundRuleToken> rule = _parseCompoundRule(q[1]);
              if (rule.isNotEmpty) {
                compoundRules.add(rule);
                for (final CompoundRuleToken t in rule) {
                  _compoundRuleFlags.add(t.flag);
                }
              }
            }
          });
        case 'PFX':
        case 'SFX':
          i = _readAffixBlock(lines, i, p);
      }
    }
  }

  /// Reads a "`KEYWORD <count>`" table. Returns the index after it.
  int _readTable(
    List<String> lines,
    int i,
    List<String> header,
    String keyword,
    void Function(List<String>) onRow,
  ) {
    final int? count = header.length > 1 ? int.tryParse(header[1]) : null;
    if (count == null) {
      // Not a header: a single inline entry (e.g. "BREAK -").
      onRow(header);
      return i;
    }
    int read = 0;
    while (read < count && i < lines.length) {
      final List<String> q = _fields(lines[i]);
      i++;
      if (q.isEmpty) {
        continue;
      }
      if (q[0] != keyword) {
        return i - 1;
      }
      onRow(q);
      read++;
    }
    return i;
  }

  int _readAffixBlock(List<String> lines, int i, List<String> header) {
    if (header.length < 4) {
      throw HunspellFormatException('Malformed affix header: $header');
    }
    final bool isPrefix = header[0] == 'PFX';
    final int? flag = parseSingleFlag(header[1], flagType);
    final bool cross = header[2] == 'Y';
    final int count = int.tryParse(header[3]) ?? 0;
    if (flag == null) {
      throw HunspellFormatException('Affix without a flag: $header');
    }
    int read = 0;
    while (read < count && i < lines.length) {
      final List<String> q = _fields(lines[i]);
      i++;
      if (q.isEmpty) {
        continue;
      }
      if (q[0] != header[0] || q.length < 4) {
        throw HunspellFormatException('Malformed affix rule: ${lines[i - 1]}');
      }
      final String strip = q[2] == '0' ? '' : q[2];
      String appendField = q[3];
      Int32List cont = Int32List(0);
      final int slash = appendField.indexOf('/');
      if (slash >= 0) {
        cont = _resolveFlags(appendField.substring(slash + 1));
        appendField = appendField.substring(0, slash);
      }
      final String append = appendField == '0' ? '' : appendField;
      final String cond = q.length > 4 ? q[4] : '.';
      final AffixEntry entry = AffixEntry(
        flag: flag,
        isPrefix: isPrefix,
        crossProduct: cross,
        strip: strip,
        append: append,
        condition: AffixCondition.parse(cond),
        continuationFlags: cont,
      );
      (isPrefix ? prefixesByAppend : suffixesByAppend)
          .putIfAbsent(append, () => <AffixEntry>[])
          .add(entry);
      affixesByFlag.putIfAbsent(flag, () => <AffixEntry>[]).add(entry);
      continuationClasses.addAll(cont);
      if (isPrefix) {
        if (append.length > maxPrefixLength) maxPrefixLength = append.length;
      } else {
        if (append.length > maxSuffixLength) maxSuffixLength = append.length;
      }
      read++;
    }
    return i;
  }

  List<String> _parseMapGroup(String s) {
    final List<String> out = <String>[];
    int i = 0;
    while (i < s.length) {
      if (s[i] == '(') {
        final int close = s.indexOf(')', i);
        if (close > i) {
          out.add(s.substring(i + 1, close));
          i = close + 1;
          continue;
        }
      }
      // Keep surrogate pairs together.
      final int unit = s.codeUnitAt(i);
      final int width = (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < s.length)
          ? 2
          : 1;
      out.add(s.substring(i, i + width));
      i += width;
    }
    return out;
  }

  List<CompoundRuleToken> _parseCompoundRule(String s) {
    final List<CompoundRuleToken> out = <CompoundRuleToken>[];
    int i = 0;
    while (i < s.length) {
      String flagText;
      if (s[i] == '(') {
        final int close = s.indexOf(')', i);
        if (close < 0) break;
        flagText = s.substring(i + 1, close);
        i = close + 1;
      } else if (flagType == FlagType.utf8) {
        final int unit = s.codeUnitAt(i);
        final int width = (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < s.length)
            ? 2
            : 1;
        flagText = s.substring(i, i + width);
        i += width;
      } else {
        flagText = s[i];
        i++;
      }
      String q = '';
      if (i < s.length && (s[i] == '*' || s[i] == '?')) {
        q = s[i];
        i++;
      }
      final int? flag = parseSingleFlag(flagText, flagType);
      if (flag != null) {
        out.add(CompoundRuleToken(flag, q));
      }
    }
    return out;
  }

  Int32List _resolveFlags(String text) {
    if (_aliases.isNotEmpty) {
      final int? index = int.tryParse(text);
      if (index != null && index >= 1 && index <= _aliases.length) {
        return _aliases[index - 1];
      }
    }
    return parseFlagString(text, flagType);
  }

  void _parseDicLines(List<String> lines, int from, int to) {
    for (int n = from; n < to; n++) {
      if (n == 0) {
        // First line is the approximate word count.
        final String first = lines[0].trim();
        if (int.tryParse(first) != null) {
          continue;
        }
      }
      String line = lines[n];
      if (line.isEmpty || line.startsWith('\t') || line.startsWith('#')) {
        continue;
      }
      // Morphological fields start after a tab or " xx:" – drop them.
      final int tab = line.indexOf('\t');
      if (tab >= 0) line = line.substring(0, tab);
      final int space = line.indexOf(' ');
      if (space > 0) line = line.substring(0, space);
      line = line.trimRight();
      if (line.isEmpty) continue;
      // Find the flag separator: first '/' not escaped and not at position 0.
      int slash = -1;
      for (int k = 1; k < line.length; k++) {
        if (line.codeUnitAt(k) == 0x2F && line.codeUnitAt(k - 1) != 0x5C) {
          slash = k;
          break;
        }
      }
      final String word = (slash < 0 ? line : line.substring(0, slash))
          .replaceAll(r'\/', '/');
      final Int32List flags = slash < 0
          ? Int32List(0)
          : _resolveFlags(line.substring(slash + 1));
      words.putIfAbsent(word, () => <WordEntry>[]).add(WordEntry(word, flags));
      if (_compoundRuleFlags.isNotEmpty) {
        for (final int f in flags) {
          if (_compoundRuleFlags.contains(f)) {
            compoundPartWords.add(word);
            break;
          }
        }
      }
    }
  }

  void _finish() {
    if (tryChars.isEmpty) {
      tryChars = 'esianrtolcdugmphbyfvkwzxjq';
    }
  }

  static List<String> _fields(String line) {
    final String t = line.trim();
    if (t.isEmpty || t.startsWith('#')) {
      return const <String>[];
    }
    return t.split(RegExp(r'\s+'));
  }
}
