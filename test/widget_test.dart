import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check/universal_spell_check.dart';

import 'test_dictionary.dart';

void main() {
  late UniversalSpellCheckService service;

  setUp(() {
    service = UniversalSpellCheckService(
      backend: SpellCheckBackend.hunspell,
      hunspellDictionaries: <String, HunspellSource>{
        'en': HunspellSource.text(enUsAff, enUsDic),
      },
      useIsolate: false,
    );
  });

  Future<EditableTextState> pumpField(
    WidgetTester tester,
    TextEditingController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TextField(
              controller: controller,
              spellCheckConfiguration: UniversalSpellCheck.configuration(
                service: service,
              ),
              contextMenuBuilder: UniversalSpellCheck.contextMenuBuilder,
            ),
          ),
        ),
      ),
    );
    return tester.state<EditableTextState>(find.byType(EditableText));
  }

  Future<void> typeAndCheck(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    // The dictionary parse and check complete asynchronously.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  testWidgets('configuration() wires service, style and toolbar builder', (
    WidgetTester tester,
  ) async {
    final SpellCheckConfiguration c = UniversalSpellCheck.configuration(
      service: service,
    );
    expect(c.spellCheckService, same(service));
    expect(c.misspelledTextStyle, isNotNull);
    expect(c.spellCheckSuggestionsToolbarBuilder, isNotNull);
    expect(
      UniversalSpellCheck.configuration().spellCheckService,
      same(UniversalSpellCheckService.instance),
    );
  });

  testWidgets('misspelled text style follows the platform', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(
      UniversalSpellCheck.misspelledTextStyle,
      CupertinoTextFieldStyleProbe.cupertino,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(
      UniversalSpellCheck.misspelledTextStyle,
      TextField.materialMisspelledTextStyle,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('TextField receives SuggestionSpans for typed text', (
    WidgetTester tester,
  ) async {
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    final EditableTextState state = await pumpField(tester, controller);
    expect(state.spellCheckEnabled, isTrue);

    await typeAndCheck(tester, 'I recieve teh mail');
    final SpellCheckResults? results = state.spellCheckResults;
    expect(results, isNotNull);
    expect(results!.spellCheckedText, 'I recieve teh mail');
    expect(
      results.suggestionSpans.map((SuggestionSpan s) => s.range),
      const <TextRange>[
        TextRange(start: 2, end: 9),
        TextRange(start: 10, end: 13),
      ],
    );
    expect(results.suggestionSpans.first.suggestions.first, 'receive');

    // The rendered text span carries the misspelled style.
    final TextSpan span = state.buildTextSpan();
    final List<InlineSpan> styled = <InlineSpan>[];
    span.visitChildren((InlineSpan s) {
      if (s is TextSpan &&
          s.style?.decoration == TextDecoration.underline &&
          (s.text == 'recieve' || s.text == 'teh')) {
        styled.add(s);
      }
      return true;
    });
    expect(styled, hasLength(2));
  });

  testWidgets('right-click menu offers suggestions and replaces the word', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    final EditableTextState state = await pumpField(tester, controller);
    await typeAndCheck(tester, 'teh cat');

    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    expect(
      UniversalSpellCheck.misspelledSpanAtSelection(state)?.range,
      const TextRange(start: 0, end: 3),
    );
    final List<ContextMenuButtonItem> items =
        UniversalSpellCheck.suggestionButtonItems(state);
    expect(items.first.label, 'the');
    expect(items.last.label, 'Ignore');

    state.showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('the'), findsOneWidget);
    expect(find.text('Ignore'), findsOneWidget);
    expect(find.text('Copy'), findsNothing, reason: 'collapsed selection');
    // The default cut/copy/paste items are kept after the suggestions.
    expect(
      state.contextMenuButtonItems.map((ContextMenuButtonItem i) => i.type),
      contains(ContextMenuButtonType.selectAll),
    );

    await tester.tap(find.text('the'));
    await tester.pumpAndSettle();
    expect(controller.text, 'the cat');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Ignore removes the marks and remembers the word', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    final EditableTextState state = await pumpField(tester, controller);
    await typeAndCheck(tester, 'Manish met Manish');
    expect(state.spellCheckResults!.suggestionSpans, hasLength(2));

    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    state.showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore'));
    await tester.pumpAndSettle();

    expect(service.isIgnored('manish'), isTrue);
    expect(state.spellCheckResults!.suggestionSpans, isEmpty);
    await typeAndCheck(tester, 'Manish met Manish again');
    expect(state.spellCheckResults!.suggestionSpans, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop suggestions toolbar builder lists suggestions', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    final EditableTextState state = await pumpField(tester, controller);
    await typeAndCheck(tester, 'wrold');
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    expect(state.showSpellCheckSuggestionsToolbar(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('world'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('no suggestion items for read-only fields or correct words', (
    WidgetTester tester,
  ) async {
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    final EditableTextState state = await pumpField(tester, controller);
    await typeAndCheck(tester, 'hello teh');
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    expect(UniversalSpellCheck.suggestionButtonItems(state), isEmpty);
  });
}

/// Exposes the Cupertino misspelled style for comparison.
abstract final class CupertinoTextFieldStyleProbe {
  /// Cupertino's misspelled text style.
  static TextStyle get cupertino =>
      CupertinoTextField.cupertinoMisspelledTextStyle;
}
