import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'dictionary.dart';

/// Where a Hunspell `.aff`/`.dic` pair comes from.
///
/// ```dart
/// HunspellSource.bundledEnUS();                         // ships with this package
/// HunspellSource.asset('assets/de_DE.aff', 'assets/de_DE.dic');
/// HunspellSource.url(Uri.parse('https://…/fr.aff'), Uri.parse('https://…/fr.dic'));
/// HunspellSource.text(affString, dicString);
/// ```
///
/// Bytes are decoded according to the `SET` line of the `.aff` file.
abstract class HunspellSource {
  /// Const constructor for subclasses.
  const HunspellSource();

  /// Loads the pair from a Flutter [AssetBundle] (default: `rootBundle`).
  ///
  /// Assets of another package are addressed as
  /// `packages/<package>/<path>`.
  const factory HunspellSource.asset(
    String affPath,
    String dicPath, {
    AssetBundle? bundle,
  }) = AssetHunspellSource;

  /// Downloads the pair over HTTP(S). On the web the server must allow
  /// cross-origin requests (CORS) from your app's origin.
  factory HunspellSource.url(
    Uri affUrl,
    Uri dicUrl, {
    Map<String, String>? headers,
    http.Client? client,
  }) = UrlHunspellSource;

  /// Uses dictionary text that is already in memory.
  const factory HunspellSource.text(String aff, String dic) =
      TextHunspellSource;

  /// The en_US dictionary bundled with this package (SCOWL size 60,
  /// 2020.12.07; see `dictionaries/LICENSE-en_US.txt`).
  const factory HunspellSource.bundledEnUS() = _BundledEnUsSource;

  /// Loads and decodes the `.aff` and `.dic` text.
  Future<({String aff, String dic})> load();

  /// Identity used to share one parsed dictionary between spell checkers.
  Object get cacheKey;
}

/// A [HunspellSource] reading Flutter assets.
class AssetHunspellSource extends HunspellSource {
  /// See [HunspellSource.asset].
  const AssetHunspellSource(this.affPath, this.dicPath, {this.bundle});

  /// Asset key of the `.aff` file.
  final String affPath;

  /// Asset key of the `.dic` file.
  final String dicPath;

  /// Bundle to read from; `rootBundle` when null.
  final AssetBundle? bundle;

  static const String _selfPrefix = 'packages/universal_spell_check/';

  @override
  Object get cacheKey => ('asset', bundle, affPath, dicPath);

  @override
  Future<({String aff, String dic})> load() async {
    final AssetBundle b = bundle ?? rootBundle;
    final List<Uint8List> bytes = await Future.wait(<Future<Uint8List>>[
      _loadBytes(b, affPath),
      _loadBytes(b, dicPath),
    ]);
    return decodeHunspellBytes(bytes[0], bytes[1]);
  }

  static Future<Uint8List> _loadBytes(AssetBundle b, String key) async {
    try {
      final ByteData data = await b.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on FlutterError {
      // When this package is itself the root package (its own tests), its
      // assets are registered without the "packages/<name>/" prefix.
      if (key.startsWith(_selfPrefix)) {
        final ByteData data = await b.load(key.substring(_selfPrefix.length));
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
      rethrow;
    }
  }
}

class _BundledEnUsSource extends AssetHunspellSource {
  const _BundledEnUsSource()
    : super(
        'packages/universal_spell_check/dictionaries/en_US.aff',
        'packages/universal_spell_check/dictionaries/en_US.dic',
      );
}

/// A [HunspellSource] downloading the files over HTTP(S).
class UrlHunspellSource extends HunspellSource {
  /// See [HunspellSource.url].
  UrlHunspellSource(this.affUrl, this.dicUrl, {this.headers, this.client});

  /// URL of the `.aff` file.
  final Uri affUrl;

  /// URL of the `.dic` file.
  final Uri dicUrl;

  /// Extra request headers (e.g. authorization).
  final Map<String, String>? headers;

  /// HTTP client to use; a temporary one is created when null.
  final http.Client? client;

  @override
  Object get cacheKey => ('url', affUrl, dicUrl);

  @override
  Future<({String aff, String dic})> load() async {
    final http.Client c = client ?? http.Client();
    try {
      final List<Uint8List> bytes = await Future.wait(<Future<Uint8List>>[
        _get(c, affUrl),
        _get(c, dicUrl),
      ]);
      return decodeHunspellBytes(bytes[0], bytes[1]);
    } finally {
      if (client == null) c.close();
    }
  }

  Future<Uint8List> _get(http.Client c, Uri url) async {
    final http.Response r = await c.get(url, headers: headers);
    if (r.statusCode != 200) {
      throw http.ClientException(
        'HTTP ${r.statusCode} while downloading dictionary',
        url,
      );
    }
    return r.bodyBytes;
  }
}

/// A [HunspellSource] with the dictionary text already in memory.
class TextHunspellSource extends HunspellSource {
  /// See [HunspellSource.text].
  const TextHunspellSource(this.aff, this.dic);

  /// Contents of the `.aff` file.
  final String aff;

  /// Contents of the `.dic` file.
  final String dic;

  @override
  Object get cacheKey => this;

  @override
  Future<({String aff, String dic})> load() async => (aff: aff, dic: dic);
}
