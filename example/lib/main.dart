import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web, let Flutter's context menu (with suggestions) replace the
  // browser's own right-click menu.
  await UniversalSpellCheck.useFlutterContextMenuOnWeb();
  runApp(const SpellCheckDemoApp());
}

/// A tiny made-up dictionary showing HunspellSource.text with PFX/SFX,
/// REP, KEEPCASE and NOSUGGEST rules.
const String _customAff = '''
SET UTF-8
TRY aeioustrnlmkbdgp
KEEPCASE K
NOSUGGEST N
REP 1
REP ph f
PFX U Y 1
PFX U 0 un .
SFX S Y 2
SFX S y ies [^aeiou]y
SFX S 0 s [^y]
''';

const String _customDic = '''
6
flutter/US
widget/S
berry/S
Dart/K
fone/S
darn/N
''';

/// Demo app root.
class SpellCheckDemoApp extends StatelessWidget {
  /// Creates the app.
  const SpellCheckDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'universal_spell_check',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const DemoPage(),
    );
  }
}

/// The single demo screen.
class DemoPage extends StatefulWidget {
  /// Creates the page.
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  static const List<Locale> _locales = <Locale>[
    Locale('en', 'US'),
    Locale('en', 'GB'),
    Locale('fr', 'FR'),
    Locale('de', 'DE'),
    Locale('es', 'ES'),
  ];

  // One service per backend, created once (never inside build()).
  final Map<SpellCheckBackend, UniversalSpellCheckService> _services =
      <SpellCheckBackend, UniversalSpellCheckService>{
        SpellCheckBackend.auto: UniversalSpellCheckService.instance,
        SpellCheckBackend.native: UniversalSpellCheckService(
          backend: SpellCheckBackend.native,
        ),
        SpellCheckBackend.hunspell: UniversalSpellCheckService(
          backend: SpellCheckBackend.hunspell,
        ),
      };

  final UniversalSpellCheckService _customService = UniversalSpellCheckService(
    backend: SpellCheckBackend.hunspell,
    hunspellDictionaries: const <String, HunspellSource>{
      'en': HunspellSource.text(_customAff, _customDic),
    },
  );

  final TextEditingController _editor = TextEditingController();
  final TextEditingController _custom = TextEditingController();
  final TextEditingController _word = TextEditingController(text: 'recieve');
  final TextEditingController _affUrl = TextEditingController();
  final TextEditingController _dicUrl = TextEditingController();

  SpellCheckBackend _backend = SpellCheckBackend.auto;
  Locale _locale = _locales.first;
  SpellCheckAvailability? _availability;
  List<String> _nativeLanguages = const <String>[];
  String _wordResult = '';
  String _urlResult = '';
  bool _loadingUrl = false;

  UniversalSpellCheckService get _service => _services[_backend]!;

  @override
  void initState() {
    super.initState();
    _refreshAvailability();
    unawaited(_service.warmUp(_locale));
    _service.nativeLanguages().then((List<String> langs) {
      if (mounted) setState(() => _nativeLanguages = langs);
    });
  }

  @override
  void dispose() {
    _editor.dispose();
    _custom.dispose();
    _word.dispose();
    _affUrl.dispose();
    _dicUrl.dispose();
    super.dispose();
  }

  Future<void> _refreshAvailability() async {
    final SpellCheckAvailability a = await _service.availability(_locale);
    if (mounted) setState(() => _availability = a);
  }

  Future<void> _checkWord() async {
    final HunspellSpellChecker checker = HunspellSpellChecker.shared(
      const HunspellSource.bundledEnUS(),
    );
    final String word = _word.text.trim();
    if (word.isEmpty) return;
    final bool ok = await checker.checkWord(word);
    final List<String> suggestions = ok
        ? const <String>[]
        : await checker.suggest(word);
    if (!mounted) return;
    setState(() {
      _wordResult = ok
          ? '"$word" is correct.'
          : '"$word" is misspelled. Suggestions: '
                '${suggestions.isEmpty ? '(none)' : suggestions.join(', ')}';
    });
  }

  Future<void> _loadFromUrl() async {
    final Uri? aff = Uri.tryParse(_affUrl.text.trim());
    final Uri? dic = Uri.tryParse(_dicUrl.text.trim());
    if (aff == null || dic == null || !aff.hasScheme || !dic.hasScheme) {
      setState(() => _urlResult = 'Enter two absolute URLs (.aff and .dic).');
      return;
    }
    setState(() {
      _loadingUrl = true;
      _urlResult = 'Downloading…';
    });
    final HunspellSpellChecker checker = HunspellSpellChecker(
      HunspellSource.url(aff, dic),
    );
    try {
      final List<SpellCheckRange> ranges = await checker.check(
        _editor.text.isEmpty ? 'Sample txet to chekc.' : _editor.text,
      );
      if (!mounted) return;
      setState(() {
        _urlResult = ranges.isEmpty
            ? 'Loaded. No misspellings in the editor text.'
            : 'Loaded. Misspelled: ${ranges.map((SpellCheckRange r) => '${(_editor.text.isEmpty ? 'Sample txet to chekc.' : _editor.text).substring(r.start, r.end)} → ${r.suggestions.take(3).join('/')}').join(', ')}';
      });
    } catch (e) {
      if (mounted) setState(() => _urlResult = 'Failed: $e');
    } finally {
      await checker.dispose();
      if (mounted) setState(() => _loadingUrl = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('universal_spell_check')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text('Spell-checked editor', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                DropdownButton<SpellCheckBackend>(
                  value: _backend,
                  items: <DropdownMenuItem<SpellCheckBackend>>[
                    for (final SpellCheckBackend b in SpellCheckBackend.values)
                      DropdownMenuItem<SpellCheckBackend>(
                        value: b,
                        child: Text('Backend: ${b.name}'),
                      ),
                  ],
                  onChanged: (SpellCheckBackend? b) {
                    if (b == null) return;
                    setState(() => _backend = b);
                    _refreshAvailability();
                  },
                ),
                DropdownButton<Locale>(
                  value: _locale,
                  items: <DropdownMenuItem<Locale>>[
                    for (final Locale l in _locales)
                      DropdownMenuItem<Locale>(
                        value: l,
                        child: Text('Locale: ${l.toLanguageTag()}'),
                      ),
                  ],
                  onChanged: (Locale? l) {
                    if (l == null) return;
                    setState(() => _locale = l);
                    _refreshAvailability();
                  },
                ),
              ],
            ),
            Text(
              _availability == null
                  ? 'Checking availability…'
                  : _availability!.isAvailable
                  ? 'Engine: ${_availability!.checker.name} '
                        '(${_availability!.language})'
                  : 'Not available: ${_availability!.reason}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Localizations.override(
              context: context,
              locale: _locale,
              child: TextField(
                // A new key per backend/locale so the field re-checks.
                key: ValueKey<Object>((_backend, _locale)),
                controller: _editor,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText:
                      'Type here, e.g. "I recieve teh mesage tomorow". '
                      'Right-click (or tap on mobile) a marked word.',
                ),
                spellCheckConfiguration: UniversalSpellCheck.configuration(
                  service: _service,
                ),
                contextMenuBuilder: UniversalSpellCheck.contextMenuBuilder,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text('Ignored:', style: theme.textTheme.bodySmall),
                if (_service.ignoredWords.isEmpty)
                  Text(
                    'none (use “Ignore” in the menu)',
                    style: theme.textTheme.bodySmall,
                  ),
                for (final String w in _service.ignoredWords)
                  InputChip(
                    label: Text(w),
                    onDeleted: () => setState(() => _service.unignoreWord(w)),
                  ),
                TextButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Refresh list'),
                ),
              ],
            ),
            const Divider(height: 32),
            Text(
              'Hunspell word lookup (bundled en_US)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _word,
                    decoration: const InputDecoration(labelText: 'Word'),
                    onSubmitted: (_) => _checkWord(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _checkWord, child: const Text('Check')),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(_wordResult),
            const Divider(height: 32),
            Text(
              'Custom in-memory dictionary',
              style: theme.textTheme.titleMedium,
            ),
            Text(
              'Words: flutter (+un-, -s), widget(s), berry/berries, Dart '
              '(KEEPCASE: "dart" is wrong), fone (REP ph→f), darn '
              '(NOSUGGEST: accepted but never suggested).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _custom,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Try: unflutters berrys widgest dart phones',
              ),
              spellCheckConfiguration: UniversalSpellCheck.configuration(
                service: _customService,
              ),
              contextMenuBuilder: UniversalSpellCheck.contextMenuBuilder,
            ),
            const Divider(height: 32),
            Text(
              'Load a dictionary from URLs',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _affUrl,
              decoration: const InputDecoration(labelText: '.aff URL'),
            ),
            TextField(
              controller: _dicUrl,
              decoration: const InputDecoration(labelText: '.dic URL'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _loadingUrl ? null : _loadFromUrl,
                child: const Text('Load and check editor text'),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(_urlResult),
            const Divider(height: 32),
            Text(
              'Native dictionaries on this device',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              _nativeLanguages.isEmpty
                  ? 'None reported (web, Android/iOS, or no native checker).'
                  : _nativeLanguages.join(', '),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
