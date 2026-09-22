import 'dart:io';

import 'package:universal_spell_check/universal_spell_check.dart';

/// The bundled en_US `.aff` text, read from disk.
final String enUsAff = File('dictionaries/en_US.aff').readAsStringSync();

/// The bundled en_US `.dic` text, read from disk.
final String enUsDic = File('dictionaries/en_US.dic').readAsStringSync();

HunspellDictionary? _enUs;

/// The bundled en_US dictionary, parsed once per test file.
HunspellDictionary get enUsDictionary =>
    _enUs ??= HunspellDictionary.parse(enUsAff, enUsDic);
