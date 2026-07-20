import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ads_remover/ui/home_page.dart';
import 'package:ads_remover/ui/processing_state.dart';

void main() {
  testWidgets('App loads home page', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ProcessingState(),
        child: const MaterialApp(home: HomePage()),
      ),
    );
    expect(find.text('Ads Remover'), findsOneWidget);
  });
}
