// Renders a spell-checked TextField with the platform's real checker and
// saves a PNG of it (used for the package README screenshots).
//
//   flutter test integration_test/screenshot_test.dart -d macos
//
// The app is sandboxed, so the PNGs go to the app's temporary directory; the
// test prints their paths.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture spell-checked TextField and context menu', (
    WidgetTester tester,
  ) async {
    final GlobalKey boundaryKey = GlobalKey();
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: Colors.indigo),
          home: Scaffold(
            appBar: AppBar(title: const Text('universal_spell_check · macOS')),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topCenter,
                child: TextField(
                  controller: controller,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  spellCheckConfiguration: UniversalSpellCheck.configuration(),
                  contextMenuBuilder: UniversalSpellCheck.contextMenuBuilder,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    const String text =
        'I recieve teh mesage tomorow. NSSpellChecker now checks '
        'Flutter text fields on macOS.';
    await tester.enterText(find.byType(TextField), text);
    final EditableTextState state = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    for (int i = 0; i < 50 && state.spellCheckResults == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    final List<SuggestionSpan> spans = state.spellCheckResults!.suggestionSpans;
    expect(
      spans.map(
        (SuggestionSpan s) => text.substring(s.range.start, s.range.end),
      ),
      containsAll(<String>['recieve', 'teh', 'mesage', 'tomorow']),
    );
    await tester.pumpAndSettle();
    final String marked = await _save(boundaryKey, 'macos_underlines.png');

    final SuggestionSpan teh = spans.firstWhere(
      (SuggestionSpan s) => text.substring(s.range.start, s.range.end) == 'teh',
    );
    controller.selection = TextSelection(
      baseOffset: teh.range.start,
      extentOffset: teh.range.end,
    );
    await tester.pump();
    expect(state.showToolbar(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('the'), findsOneWidget);
    expect(find.text('Ignore'), findsOneWidget);
    final String menu = await _save(boundaryKey, 'macos_context_menu.png');

    debugPrint('SCREENSHOT $marked');
    debugPrint('SCREENSHOT $menu');
  });
}

Future<String> _save(GlobalKey key, String name) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image image = await boundary.toImage(pixelRatio: 2);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  final File file = File('${Directory.systemTemp.path}/$name');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file.path;
}
