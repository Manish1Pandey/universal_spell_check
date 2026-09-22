import 'dart:typed_data';

import 'affix.dart';
import 'dictionary.dart';

enum _Cap { none, initial, all, mixed, mixedInitial }

/// A Hunspell-compatible spell checker working on a [HunspellDictionary].
///
/// ```dart
/// final hunspell = Hunspell(HunspellDictionary.parse(affText, dicText));
/// hunspell.check('color');      // true
/// hunspell.check('colour');     // false (en_US)
/// hunspell.suggest('recieve');  // ['receive', ...]
/// ```
///
/// This class is synchronous and pure Dart, so it runs on every platform.
/// For text fields use `HunspellSpellChecker`, which moves the work off the
/// UI isolate where the platform allows it.
class Hunspell {
  /// Creates a checker for [dictionary].
  Hunspell(this.dictionary);

  /// The dictionary this checker uses.
  final HunspellDictionary dictionary;

  List<String>? _lowerKeys;
  List<List<WordEntry>>? _entriesByKey;

  static final RegExp _number = RegExp(r'^[+-]?\d+(?:[.,:/-]\d+)*\.?$');

  /// Returns `true` when [word] is spelled correctly.
  ///
  /// Applies Hunspell's rules: input conversion (`ICONV`), capitalisation
  /// (a lower-case dictionary word also matches its `Capitalised` and
  /// `UPPER-CASE` forms, but `Paris` does not match `paris`), affixes,
  /// `COMPOUNDRULE` compounds and `BREAK` points (e.g. hyphens). Numbers are
  /// always accepted.
  bool check(String word) {
    final String w = _convert(word.trim(), dictionary.inputConversions);
    if (w.isEmpty || _number.hasMatch(w)) {
      return true;
    }
    return _checkWithBreaks(w, 0);
  }

  bool _checkWithBreaks(String w, int depth) {
    if (_checkCased(w) != null) {
      return true;
    }
    if (depth > 8) {
      return false;
    }
    for (final String p in dictionary.breakPatterns) {
      if (p.length > 1 && p.startsWith('^')) {
        final String pat = p.substring(1);
        if (w.length > pat.length &&
            w.startsWith(pat) &&
            _checkWithBreaks(w.substring(pat.length), depth + 1)) {
          return true;
        }
      } else if (p.length > 1 && p.endsWith(r'$')) {
        final String pat = p.substring(0, p.length - 1);
        if (w.length > pat.length &&
            w.endsWith(pat) &&
            _checkWithBreaks(
              w.substring(0, w.length - pat.length),
              depth + 1,
            )) {
          return true;
        }
      } else if (p.isNotEmpty) {
        int idx = w.indexOf(p);
        while (idx > 0 && idx + p.length < w.length) {
          if (_checkWithBreaks(w.substring(0, idx), depth + 1) &&
              _checkWithBreaks(w.substring(idx + p.length), depth + 1)) {
            return true;
          }
          idx = w.indexOf(p, idx + 1);
        }
      }
    }
    return false;
  }

  /// Splits [word] at its `BREAK` points and returns the parts that are
  /// misspelled, as `(start, end)` offsets into [word]. Returns an empty list
  /// when the whole word is correct, or a single range covering the word when
  /// it has no break points.
  List<(int, int)> misspelledParts(String word) {
    if (check(word)) {
      return const <(int, int)>[];
    }
    const String hyphen = '-';
    if (!dictionary.breakPatterns.contains(hyphen) || !word.contains(hyphen)) {
      return <(int, int)>[(0, word.length)];
    }
    final List<(int, int)> bad = <(int, int)>[];
    int start = 0;
    while (start <= word.length) {
      int end = word.indexOf(hyphen, start);
      if (end < 0) end = word.length;
      if (end > start && !check(word.substring(start, end))) {
        bad.add((start, end));
      }
      start = end + 1;
    }
    return bad.isEmpty ? <(int, int)>[(0, word.length)] : bad;
  }

  /// Returns up to [max] suggestions for [word], best first.
  ///
  /// Edit-based candidates come first (`REP` table, case fixes, `MAP`,
  /// swapped letters, forgotten/extra letters, keyboard neighbours from
  /// `KEY`, wrong letters from `TRY`, moved letters, split words). If none
  /// of them is a real word an n-gram search over the word list is used.
  /// Words flagged `NOSUGGEST` or `FORBIDDENWORD` are never returned.
  List<String> suggest(String word, {int max = 5}) {
    if (max <= 0) {
      return const <String>[];
    }
    final String w = _convert(word.trim(), dictionary.inputConversions);
    if (w.isEmpty) {
      return const <String>[];
    }
    final _Cap cap = _capType(w);
    final Map<String, int> ranked = <String, int>{};
    final Map<String, bool> memo = <String, bool>{};
    int seq = 0;

    void addAll(List<(String, int)> found, String Function(String) recase) {
      for (final (String cand, int tier) in found) {
        final String c = recase(cand);
        if (c == w) continue;
        final int score = tier * 1000000 + seq++;
        final int? old = ranked[c];
        if (old == null || score < old) {
          ranked[c] = score;
        }
      }
    }

    final String lower = w.toLowerCase();
    switch (cap) {
      case _Cap.none:
        addAll(_editCandidates(w, memo), _identity);
      case _Cap.initial:
        addAll(_editCandidates(w, memo), _identity);
        addAll(_editCandidates(lower, memo), _capitalizeIfLower);
      case _Cap.all:
        addAll(_editCandidates(lower, memo), _upper);
        addAll(_editCandidates(w, memo), _identity);
      case _Cap.mixed:
      case _Cap.mixedInitial:
        addAll(_editCandidates(w, memo), _identity);
        addAll(_editCandidates(lower, memo), _identity);
    }

    List<String> out;
    if (ranked.isNotEmpty) {
      final List<MapEntry<String, int>> sorted = ranked.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      out = <String>[for (final MapEntry<String, int> e in sorted) e.key];
    } else {
      final List<String> ng = _ngramSuggest(lower, max);
      out = <String>[
        for (final String s in ng)
          switch (cap) {
            _Cap.initial => _capitalizeIfLower(s),
            _Cap.all => _upper(s),
            _ => s,
          },
      ];
    }
    final List<String> result = <String>[];
    for (final String s in out) {
      final String converted = _convert(s, dictionary.outputConversions);
      if (converted != word && !result.contains(converted)) {
        result.add(converted);
      }
      if (result.length >= max) break;
    }
    return result;
  }

  // ---------------------------------------------------------------------
  // Checking

  WordEntry? _checkCased(String w) {
    WordEntry? e = _checkWord(w);
    if (e != null) {
      return e;
    }
    final _Cap cap = _capType(w);
    if (cap == _Cap.all) {
      final String lower = w.toLowerCase();
      e = _checkWord(lower);
      if (e != null && !hasFlag(e.flags, dictionary.keepCaseFlag)) return e;
      final String init = _capitalize(lower);
      e = _checkWord(init);
      if (e != null && !hasFlag(e.flags, dictionary.keepCaseFlag)) return e;
      final int apos = lower.indexOf("'");
      if (apos >= 0 && apos < lower.length - 1) {
        final String form =
            _capitalize(lower.substring(0, apos + 1)) +
            _capitalize(lower.substring(apos + 1));
        e = _checkWord(form);
        if (e != null && !hasFlag(e.flags, dictionary.keepCaseFlag)) return e;
      }
    } else if (cap == _Cap.initial) {
      e = _checkWord(w.toLowerCase());
      if (e != null && !hasFlag(e.flags, dictionary.keepCaseFlag)) return e;
    }
    return null;
  }

  WordEntry? _checkWord(String w) {
    final HunspellDictionary d = dictionary;
    final List<WordEntry>? entries = d.words[w];
    if (entries != null) {
      for (final WordEntry e in entries) {
        if (hasFlag(e.flags, d.forbiddenFlag)) {
          return null;
        }
      }
      for (final WordEntry e in entries) {
        if (!hasFlag(e.flags, d.needAffixFlag) &&
            !hasFlag(e.flags, d.onlyInCompoundFlag)) {
          return e;
        }
      }
    }
    return _suffixCheck(w, null, null) ??
        _twoSuffixCheck(w, null) ??
        _prefixCheck(w) ??
        _compoundCheck(w);
  }

  bool _rootUsable(WordEntry e) =>
      !hasFlag(e.flags, dictionary.onlyInCompoundFlag) &&
      !hasFlag(e.flags, dictionary.forbiddenFlag);

  WordEntry? _suffixCheck(String w, AffixEntry? pfx, int? requiredCont) {
    final HunspellDictionary d = dictionary;
    final int len = w.length;
    final int minStart = len - d.maxSuffixLength < 0
        ? 0
        : len - d.maxSuffixLength;
    for (int i = len; i >= minStart; i--) {
      final List<AffixEntry>? list = d.suffixesByAppend[w.substring(i)];
      if (list == null) continue;
      if (i == 0 && !d.fullStrip) continue;
      final String stem = w.substring(0, i);
      for (final AffixEntry se in list) {
        if (pfx != null && !se.crossProduct) continue;
        if (requiredCont != null &&
            !hasFlag(se.continuationFlags, requiredCont)) {
          continue;
        }
        if (pfx == null &&
            requiredCont == null &&
            hasFlag(se.continuationFlags, d.needAffixFlag)) {
          continue;
        }
        final String root = stem + se.strip;
        if (!se.condition.matchesEnd(root)) continue;
        final List<WordEntry>? entries = d.words[root];
        if (entries == null) continue;
        for (final WordEntry e in entries) {
          if (!hasFlag(e.flags, se.flag) || !_rootUsable(e)) continue;
          if (pfx != null &&
              !hasFlag(e.flags, pfx.flag) &&
              !hasFlag(se.continuationFlags, pfx.flag)) {
            continue;
          }
          return e;
        }
      }
    }
    return null;
  }

  WordEntry? _twoSuffixCheck(String w, AffixEntry? pfx) {
    final HunspellDictionary d = dictionary;
    if (d.continuationClasses.isEmpty) return null;
    final int len = w.length;
    final int minStart = len - d.maxSuffixLength < 0
        ? 0
        : len - d.maxSuffixLength;
    for (int i = len; i >= minStart; i--) {
      final List<AffixEntry>? list = d.suffixesByAppend[w.substring(i)];
      if (list == null) continue;
      if (i == 0 && !d.fullStrip) continue;
      final String stem = w.substring(0, i);
      for (final AffixEntry s1 in list) {
        if (!d.continuationClasses.contains(s1.flag)) continue;
        if (pfx != null && !s1.crossProduct) continue;
        final String tmp = stem + s1.strip;
        if (!s1.condition.matchesEnd(tmp)) continue;
        final WordEntry? e = _suffixCheck(tmp, pfx, s1.flag);
        if (e != null) return e;
      }
    }
    return null;
  }

  WordEntry? _prefixCheck(String w) {
    final HunspellDictionary d = dictionary;
    final int len = w.length;
    final int maxI = d.maxPrefixLength < len ? d.maxPrefixLength : len;
    for (int i = 0; i <= maxI; i++) {
      final List<AffixEntry>? list = d.prefixesByAppend[w.substring(0, i)];
      if (list == null) continue;
      if (i == len && !d.fullStrip) continue;
      final String rest = w.substring(i);
      for (final AffixEntry pe in list) {
        final String root = pe.strip + rest;
        if (!pe.condition.matchesStart(root)) continue;
        if (!hasFlag(pe.continuationFlags, d.needAffixFlag)) {
          final List<WordEntry>? entries = d.words[root];
          if (entries != null) {
            for (final WordEntry e in entries) {
              if (hasFlag(e.flags, pe.flag) && _rootUsable(e)) return e;
            }
          }
        }
        if (pe.crossProduct) {
          final WordEntry? e =
              _suffixCheck(root, pe, null) ?? _twoSuffixCheck(root, pe);
          if (e != null) return e;
        }
      }
    }
    return null;
  }

  WordEntry? _compoundCheck(String w) {
    final HunspellDictionary d = dictionary;
    if (d.compoundRules.isEmpty ||
        w.length < 2 * d.compoundMin ||
        w.length > 100) {
      return null;
    }
    for (final List<CompoundRuleToken> rule in d.compoundRules) {
      if (_matchRule(rule, 0, w, 0, 0)) {
        return WordEntry(w, Int32List(0));
      }
    }
    return null;
  }

  bool _matchRule(
    List<CompoundRuleToken> rule,
    int ti,
    String w,
    int pos,
    int parts,
  ) {
    if (ti == rule.length) {
      return pos == w.length && parts >= 2;
    }
    final CompoundRuleToken t = rule[ti];
    if ((t.quantifier == '*' || t.quantifier == '?') &&
        _matchRule(rule, ti + 1, w, pos, parts)) {
      return true;
    }
    final HunspellDictionary d = dictionary;
    for (int end = pos + d.compoundMin; end <= w.length; end++) {
      final String part = w.substring(pos, end);
      if (!d.compoundPartWords.contains(part)) continue;
      bool ok = false;
      for (final WordEntry e in d.words[part]!) {
        if (hasFlag(e.flags, t.flag)) {
          ok = true;
          break;
        }
      }
      if (!ok) continue;
      final int next = t.quantifier == '*' ? ti : ti + 1;
      if (_matchRule(rule, next, w, end, parts + 1)) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // Suggestions

  bool _suggestible(String cand, Map<String, bool> memo) {
    final bool? known = memo[cand];
    if (known != null) return known;
    bool ok;
    if (cand.contains(' ')) {
      ok = cand.split(' ').every((String p) => p.isNotEmpty && _okPart(p));
    } else {
      ok = _okPart(cand);
    }
    memo[cand] = ok;
    return ok;
  }

  bool _okPart(String p) {
    final WordEntry? e = _checkCased(p);
    return e != null &&
        !hasFlag(e.flags, dictionary.noSuggestFlag) &&
        !hasFlag(e.flags, dictionary.forbiddenFlag);
  }

  /// Edit-distance-1 style candidates with their tier (lower is better).
  List<(String, int)> _editCandidates(String w, Map<String, bool> memo) {
    final HunspellDictionary d = dictionary;
    final List<(String, int)> out = <(String, int)>[];
    final int len = w.length;
    void add(String cand, int tier) {
      if (cand != w && cand.isNotEmpty && _suggestible(cand, memo)) {
        out.add((cand, tier));
      }
    }

    // Tier 0: case fixes, REP table, MAP.
    // Only case forms the dictionary spells that way ("paris" -> "Paris",
    // "nasa" -> "NASA"), not every word re-cased.
    for (final String form in <String>[_capitalize(w), w.toUpperCase()]) {
      if (form != w && _checkWord(form) != null) {
        add(form, 0);
      }
    }
    for (final (String from, String to) in d.replacements) {
      final bool atStart = from.startsWith('^');
      final bool atEnd = from.length > 1 && from.endsWith(r'$');
      final String pat = from.substring(
        atStart ? 1 : 0,
        atEnd ? from.length - 1 : from.length,
      );
      if (pat.isEmpty) continue;
      int idx = w.indexOf(pat);
      while (idx >= 0) {
        final bool okStart = !atStart || idx == 0;
        final bool okEnd = !atEnd || idx + pat.length == len;
        if (okStart && okEnd) {
          add(w.substring(0, idx) + to + w.substring(idx + pat.length), 0);
        }
        idx = w.indexOf(pat, idx + 1);
      }
    }
    for (final List<String> group in d.mapGroups) {
      for (final String a in group) {
        int idx = w.indexOf(a);
        while (idx >= 0) {
          for (final String b in group) {
            if (b != a) {
              add(w.substring(0, idx) + b + w.substring(idx + a.length), 0);
            }
          }
          idx = w.indexOf(a, idx + 1);
        }
      }
    }

    final List<int> cu = w.codeUnits;
    // Tier 1: swapped adjacent letters ("teh" -> "the").
    for (int i = 0; i + 1 < len; i++) {
      if (cu[i] == cu[i + 1]) continue;
      final List<int> c = List<int>.of(cu);
      c[i] = cu[i + 1];
      c[i + 1] = cu[i];
      add(String.fromCharCodes(c), 1);
    }
    if (len == 4 || len == 5) {
      // Two swaps: "ahev" -> "have".
      final List<int> c = List<int>.of(cu);
      c[0] = cu[1];
      c[1] = cu[0];
      c[len - 2] = cu[len - 1];
      c[len - 1] = cu[len - 2];
      add(String.fromCharCodes(c), 1);
      if (len == 5) {
        final List<int> c2 = List<int>.of(cu);
        c2[0] = cu[1];
        c2[1] = cu[0];
        c2[2] = cu[3];
        c2[3] = cu[2];
        add(String.fromCharCodes(c2), 1);
      }
    }

    final String tryChars = d.tryChars;
    // Tier 2: forgotten letter.
    for (int t = 0; t < tryChars.length; t++) {
      final String ch = tryChars[t];
      final bool upper = ch != ch.toLowerCase();
      for (int i = 0; i <= len; i++) {
        if (upper && i > 0) continue;
        // A missing doubled letter ("helo" -> "hello") is the most common
        // insertion typo, so it ranks with the swaps.
        final bool doubles =
            (i > 0 && w[i - 1] == ch) || (i < len && w[i] == ch);
        add(w.substring(0, i) + ch + w.substring(i), doubles ? 1 : 2);
      }
    }

    // Tier 3: extra letter.
    for (int i = 0; i < len; i++) {
      if (i > 0 && cu[i] == cu[i - 1]) continue; // same result as i-1
      add(w.substring(0, i) + w.substring(i + 1), 3);
    }

    // Tier 4: keyboard neighbour / wrong case.
    final String kb = d.keyboard;
    for (int i = 0; i < len; i++) {
      final String ch = w[i];
      final String up = ch.toUpperCase();
      if (up != ch) {
        add(w.substring(0, i) + up + w.substring(i + 1), 4);
      }
      int k = kb.indexOf(ch);
      while (k >= 0) {
        if (k > 0 && kb[k - 1] != '|') {
          add(w.substring(0, i) + kb[k - 1] + w.substring(i + 1), 4);
        }
        if (k + 1 < kb.length && kb[k + 1] != '|') {
          add(w.substring(0, i) + kb[k + 1] + w.substring(i + 1), 4);
        }
        k = kb.indexOf(ch, k + 1);
      }
    }

    // Tier 5: wrong letter (TRY characters).
    for (int t = 0; t < tryChars.length; t++) {
      final String ch = tryChars[t];
      final bool upper = ch != ch.toLowerCase();
      for (int i = 0; i < len; i++) {
        if (upper && i > 0) continue;
        if (w[i] == ch) continue;
        add(w.substring(0, i) + ch + w.substring(i + 1), 5);
      }
    }

    // Tier 6: long swaps, moved letters, doubled syllables.
    for (int i = 0; i < len; i++) {
      for (int j = i + 2; j < len && j <= i + 4; j++) {
        if (cu[i] == cu[j]) continue;
        final List<int> c = List<int>.of(cu);
        c[i] = cu[j];
        c[j] = cu[i];
        add(String.fromCharCodes(c), 6);
      }
    }
    for (int i = 0; i < len; i++) {
      for (int j = i + 2; j <= len && j <= i + 4; j++) {
        // Move cu[i] forward to position j-1.
        final List<int> c = List<int>.of(cu)..removeAt(i);
        c.insert(j - 1, cu[i]);
        add(String.fromCharCodes(c), 6);
      }
      for (int j = i - 2; j >= 0 && j >= i - 4; j--) {
        final List<int> c = List<int>.of(cu)..removeAt(i);
        c.insert(j, cu[i]);
        add(String.fromCharCodes(c), 6);
      }
    }
    for (int i = 3; i < len; i++) {
      if (cu[i] == cu[i - 2] && cu[i - 1] == cu[i - 3]) {
        add(w.substring(0, i - 1) + w.substring(i + 1), 6);
      }
    }

    // Tier 7: split into two words ("inthe" -> "in the"). Only offered when
    // nothing better exists, because short dictionary words ("ed", "he")
    // make most splits noise.
    if (out.isNotEmpty) {
      return out;
    }
    for (int i = 2; i <= len - 2; i++) {
      add('${w.substring(0, i)} ${w.substring(i)}', 7);
    }
    return out;
  }

  List<String> _ngramSuggest(String w, int max) {
    final HunspellDictionary d = dictionary;
    final int n = w.length;
    if (n < 2) return const <String>[];
    if (_lowerKeys == null) {
      final List<String> keys = <String>[];
      final List<List<WordEntry>> vals = <List<WordEntry>>[];
      d.words.forEach((String k, List<WordEntry> v) {
        keys.add(k.toLowerCase());
        vals.add(v);
      });
      _lowerKeys = keys;
      _entriesByKey = vals;
    }
    final List<String> keys = _lowerKeys!;
    final List<List<WordEntry>> vals = _entriesByKey!;

    // 1. Best 100 roots by 3-gram similarity.
    const int maxRoots = 100;
    final List<(int, WordEntry)> roots = <(int, WordEntry)>[];
    int worst = -1 << 30;
    for (int k = 0; k < keys.length; k++) {
      final String key = keys[k];
      final int diff = key.length - n;
      if (diff > 4 || diff < -6) continue;
      final int sc = _ngram(3, w, key, longerWorse: true) + _leftCommon(w, key);
      if (roots.length >= maxRoots && sc <= worst) continue;
      for (final WordEntry e in vals[k]) {
        if (hasFlag(e.flags, d.noSuggestFlag) ||
            hasFlag(e.flags, d.forbiddenFlag) ||
            hasFlag(e.flags, d.onlyInCompoundFlag)) {
          continue;
        }
        roots.add((sc, e));
        break;
      }
      if (roots.length > maxRoots) {
        roots.sort((a, b) => b.$1.compareTo(a.$1));
        roots.removeLast();
        worst = roots.last.$1;
      } else if (roots.length == maxRoots) {
        roots.sort((a, b) => b.$1.compareTo(a.$1));
        worst = roots.last.$1;
      }
    }

    // 2. Threshold from mangled copies of the word (as Hunspell does).
    int thresh = 0;
    for (int sp = 1; sp < 4; sp++) {
      final List<int> mw = List<int>.of(w.codeUnits);
      for (int k = sp; k < n; k += 4) {
        mw[k] = 0x2A; // '*'
      }
      thresh += _ngram(n, w, String.fromCharCodes(mw), anyMismatch: true);
    }
    thresh = thresh ~/ 3 - 1;

    // 3. Expand roots to their affixed forms and score them.
    final Map<String, int> guesses = <String, int>{};
    final Map<String, bool> memo = <String, bool>{};
    for (final (int _, WordEntry root) in roots) {
      for (final String form in _expand(root)) {
        final String lf = form.toLowerCase();
        final int sc = _ngram(n, w, lf, anyMismatch: true) + _leftCommon(w, lf);
        if (sc <= thresh) continue;
        final int lcs = _lcs(w, lf);
        final int re =
            _ngram(2, w, lf, anyMismatch: true, weighted: true) +
            _ngram(2, lf, w, anyMismatch: true, weighted: true);
        final int finalScore =
            2 * lcs -
            (n - lf.length).abs() +
            _leftCommon(w, lf) +
            _ngram(4, w, lf, anyMismatch: true) +
            re;
        if (lcs * 2 < (n > lf.length ? n : lf.length)) continue;
        final int? old = guesses[form];
        if (old == null || finalScore > old) {
          guesses[form] = finalScore;
        }
      }
    }
    final List<MapEntry<String, int>> sorted = guesses.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final List<String> out = <String>[];
    for (final MapEntry<String, int> e in sorted) {
      if (e.key.toLowerCase() == w) continue;
      if (!_suggestible(e.key, memo)) continue;
      out.add(e.key);
      if (out.length >= max) break;
    }
    return out;
  }

  /// All forms of [root]: the word itself plus one prefix, one or two
  /// suffixes, and prefix+suffix cross products.
  List<String> _expand(WordEntry root) {
    final HunspellDictionary d = dictionary;
    final List<String> forms = <String>[];
    if (!hasFlag(root.flags, d.needAffixFlag)) {
      forms.add(root.word);
    }
    final List<(String, AffixEntry)> suffixed = <(String, AffixEntry)>[];
    for (final int f in root.flags) {
      final List<AffixEntry>? list = d.affixesByFlag[f];
      if (list == null) continue;
      for (final AffixEntry a in list) {
        if (a.isPrefix) continue;
        final String? s = a.applyTo(root.word);
        if (s == null) continue;
        forms.add(s);
        suffixed.add((s, a));
        for (final int cf in a.continuationFlags) {
          for (final AffixEntry a2
              in d.affixesByFlag[cf] ?? const <AffixEntry>[]) {
            if (a2.isPrefix) continue;
            final String? s2 = a2.applyTo(s);
            if (s2 != null) forms.add(s2);
          }
        }
      }
    }
    for (final int f in root.flags) {
      final List<AffixEntry>? list = d.affixesByFlag[f];
      if (list == null) continue;
      for (final AffixEntry p in list) {
        if (!p.isPrefix) continue;
        final String? s = p.applyTo(root.word);
        if (s != null) forms.add(s);
        if (!p.crossProduct) continue;
        for (final (String sf, AffixEntry sa) in suffixed) {
          if (!sa.crossProduct) continue;
          final String? ps = p.applyTo(sf);
          if (ps != null) forms.add(ps);
        }
      }
    }
    return forms;
  }

  // ---------------------------------------------------------------------
  // Helpers

  static int _ngram(
    int n,
    String s1,
    String s2, {
    bool longerWorse = false,
    bool anyMismatch = false,
    bool weighted = false,
  }) {
    final int l1 = s1.length;
    final int l2 = s2.length;
    if (l2 == 0) return 0;
    int nscore = 0;
    for (int j = 1; j <= n; j++) {
      int ns = 0;
      for (int i = 0; i <= l1 - j; i++) {
        if (_containsSub(s2, s1, i, j)) {
          ns++;
        } else if (weighted) {
          ns--;
          if (i == 0 || i == l1 - j) ns--;
        }
      }
      nscore += ns;
      if (ns < 2 && !weighted) break;
    }
    int penalty = 0;
    if (longerWorse) penalty = (l2 - l1) - 2;
    if (anyMismatch) penalty = (l2 - l1).abs() - 2;
    return nscore - (penalty > 0 ? penalty : 0);
  }

  /// Whether [hay] contains `needle.substring(start, start + len)`.
  static bool _containsSub(String hay, String needle, int start, int len) {
    final int last = hay.length - len;
    outer:
    for (int h = 0; h <= last; h++) {
      for (int k = 0; k < len; k++) {
        if (hay.codeUnitAt(h + k) != needle.codeUnitAt(start + k)) {
          continue outer;
        }
      }
      return true;
    }
    return false;
  }

  static int _leftCommon(String a, String b) {
    final int m = a.length < b.length ? a.length : b.length;
    int i = 0;
    while (i < m && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int _lcs(String a, String b) {
    final int m = a.length;
    final int n = b.length;
    List<int> prev = List<int>.filled(n + 1, 0);
    List<int> cur = List<int>.filled(n + 1, 0);
    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        cur[j] = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)
            ? prev[j - 1] + 1
            : (prev[j] > cur[j - 1] ? prev[j] : cur[j - 1]);
      }
      final List<int> t = prev;
      prev = cur;
      cur = t;
    }
    return prev[n];
  }

  static _Cap _capType(String w) {
    int upper = 0;
    int lower = 0;
    bool firstUpper = false;
    bool first = true;
    for (final int r in w.runes) {
      final String c = String.fromCharCode(r);
      final bool isUpper = c != c.toLowerCase();
      final bool isLower = c != c.toUpperCase();
      if (isUpper) {
        upper++;
        if (first) firstUpper = true;
      } else if (isLower) {
        lower++;
      }
      first = false;
    }
    if (upper == 0) return _Cap.none;
    if (firstUpper && upper == 1) return _Cap.initial;
    if (lower == 0) return _Cap.all;
    return firstUpper ? _Cap.mixedInitial : _Cap.mixed;
  }

  static String _identity(String s) => s;

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    final int first = s.runes.first;
    final String head = String.fromCharCode(first);
    return head.toUpperCase() + s.substring(head.length);
  }

  static String _capitalizeIfLower(String s) {
    if (s.isEmpty) return s;
    final String head = String.fromCharCode(s.runes.first);
    return head == head.toLowerCase() ? _capitalize(s) : s;
  }

  static String _upper(String s) => s.toUpperCase();

  static String _convert(String s, List<(String, String)> table) {
    if (table.isEmpty) return s;
    // Longest-match, left-to-right replacement (Hunspell ICONV/OCONV).
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < s.length) {
      String? bestFrom;
      String? bestTo;
      for (final (String from, String to) in table) {
        if (from.isNotEmpty &&
            s.startsWith(from, i) &&
            (bestFrom == null || from.length > bestFrom.length)) {
          bestFrom = from;
          bestTo = to;
        }
      }
      if (bestFrom != null) {
        out.write(bestTo);
        i += bestFrom.length;
      } else {
        out.writeCharCode(s.codeUnitAt(i));
        i++;
      }
    }
    return out.toString();
  }
}
