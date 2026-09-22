import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_spell_check_example/main.dart';

void main() {
  testWidgets('demo page shows every section', (WidgetTester tester) async {
    await tester.pumpWidget(const SpellCheckDemoApp());
    await tester.pump();
    expect(find.text('Spell-checked editor'), findsOneWidget);
    expect(find.text('Hunspell word lookup (bundled en_US)'), findsOneWidget);
    expect(find.text('Custom in-memory dictionary'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });
}
