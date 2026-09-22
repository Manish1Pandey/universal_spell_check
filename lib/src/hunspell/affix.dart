import 'dart:typed_data';

/// How flags are written in a Hunspell `.aff`/`.dic` pair (`FLAG` directive).
enum FlagType {
  /// One character per flag (the Hunspell default).
  char,

  /// Two characters per flag (`FLAG long`).
  long,

  /// Comma-separated decimal numbers (`FLAG num`).
  num,

  /// One Unicode code point per flag (`FLAG UTF-8`).
  utf8,
}

/// Parses a flag string such as `SMDG`, `AaBb` or `101,102` into flag codes.
Int32List parseFlagString(String s, FlagType type) {
  if (s.isEmpty) {
    return Int32List(0);
  }
  switch (type) {
    case FlagType.char:
      return Int32List.fromList(s.codeUnits);
    case FlagType.utf8:
      return Int32List.fromList(s.runes.toList());
    case FlagType.long:
      final List<int> out = <int>[];
      for (int i = 0; i + 1 < s.length; i += 2) {
        out.add(s.codeUnitAt(i) * 65536 + s.codeUnitAt(i + 1));
      }
      if (s.length.isOdd) {
        out.add(s.codeUnitAt(s.length - 1) * 65536);
      }
      return Int32List.fromList(out);
    case FlagType.num:
      final List<int> out = <int>[];
      for (final String part in s.split(',')) {
        final int? v = int.tryParse(part.trim());
        if (v != null) {
          out.add(v);
        }
      }
      return Int32List.fromList(out);
  }
}

/// Parses a single flag (as used by `KEEPCASE X`, `NOSUGGEST !`, ...).
int? parseSingleFlag(String s, FlagType type) {
  final Int32List flags = parseFlagString(s, type);
  return flags.isEmpty ? null : flags.first;
}

/// Returns whether [flags] contains [flag] (lists are short, so linear scan).
bool hasFlag(Int32List flags, int? flag) {
  if (flag == null) {
    return false;
  }
  for (int i = 0; i < flags.length; i++) {
    if (flags[i] == flag) {
      return true;
    }
  }
  return false;
}

/// One position of an affix condition such as `[^aeiou]` or `y`.
class _CondUnit {
  _CondUnit.any() : chars = null, negate = false;
  _CondUnit.set(this.chars, this.negate);

  final Set<int>? chars;
  final bool negate;

  bool matches(int c) {
    final Set<int>? set = chars;
    if (set == null) {
      return true;
    }
    return negate ? !set.contains(c) : set.contains(c);
  }
}

/// A Hunspell affix condition (the last column of a `PFX`/`SFX` rule).
///
/// For suffixes it must match the *end* of the stem, for prefixes the
/// *start*. `.` means "no condition".
class AffixCondition {
  AffixCondition._(this._units);

  /// Parses a condition pattern like `[^aeiou]y`, `.` or `e`.
  factory AffixCondition.parse(String pattern) {
    if (pattern == '.' || pattern.isEmpty) {
      return AffixCondition._(const <_CondUnit>[]);
    }
    final List<_CondUnit> units = <_CondUnit>[];
    final List<int> cu = pattern.codeUnits;
    int i = 0;
    while (i < cu.length) {
      final int c = cu[i];
      if (c == 0x5B /* [ */ ) {
        int j = i + 1;
        bool negate = false;
        if (j < cu.length && cu[j] == 0x5E /* ^ */ ) {
          negate = true;
          j++;
        }
        final Set<int> set = <int>{};
        while (j < cu.length && cu[j] != 0x5D /* ] */ ) {
          set.add(cu[j]);
          j++;
        }
        units.add(_CondUnit.set(set, negate));
        i = j + 1;
      } else if (c == 0x2E /* . */ ) {
        units.add(_CondUnit.any());
        i++;
      } else {
        units.add(_CondUnit.set(<int>{c}, false));
        i++;
      }
    }
    return AffixCondition._(units);
  }

  final List<_CondUnit> _units;

  /// Number of characters the condition inspects.
  int get length => _units.length;

  /// Whether the condition holds at the end of [word].
  bool matchesEnd(String word) {
    final int n = _units.length;
    if (n == 0) {
      return true;
    }
    if (word.length < n) {
      return false;
    }
    final int offset = word.length - n;
    for (int i = 0; i < n; i++) {
      if (!_units[i].matches(word.codeUnitAt(offset + i))) {
        return false;
      }
    }
    return true;
  }

  /// Whether the condition holds at the start of [word].
  bool matchesStart(String word) {
    final int n = _units.length;
    if (n == 0) {
      return true;
    }
    if (word.length < n) {
      return false;
    }
    for (int i = 0; i < n; i++) {
      if (!_units[i].matches(word.codeUnitAt(i))) {
        return false;
      }
    }
    return true;
  }
}

/// One `PFX` or `SFX` rule line.
class AffixEntry {
  /// Creates an affix rule.
  AffixEntry({
    required this.flag,
    required this.isPrefix,
    required this.crossProduct,
    required this.strip,
    required this.append,
    required this.condition,
    required this.continuationFlags,
  });

  /// The flag that enables this affix on a dictionary word.
  final int flag;

  /// `true` for `PFX`, `false` for `SFX`.
  final bool isPrefix;

  /// Whether the rule may combine with an affix of the other kind.
  final bool crossProduct;

  /// Characters removed from the stem before [append] is added.
  final String strip;

  /// Characters added to the stem.
  final String append;

  /// Condition the stem must satisfy.
  final AffixCondition condition;

  /// Continuation classes (flags after `/` in the append column).
  final Int32List continuationFlags;

  /// Applies this affix to [stem], or returns `null` when it does not apply.
  String? applyTo(String stem) {
    if (isPrefix) {
      if (!condition.matchesStart(stem) || !stem.startsWith(strip)) {
        return null;
      }
      return append + stem.substring(strip.length);
    }
    if (!condition.matchesEnd(stem) || !stem.endsWith(strip)) {
      return null;
    }
    return stem.substring(0, stem.length - strip.length) + append;
  }
}

/// A token of a `COMPOUNDRULE` pattern: a flag plus an optional `*` or `?`.
class CompoundRuleToken {
  /// Creates a rule token.
  const CompoundRuleToken(this.flag, this.quantifier);

  /// Flag a compound part must carry.
  final int flag;

  /// `''`, `'*'` or `'?'`.
  final String quantifier;
}
