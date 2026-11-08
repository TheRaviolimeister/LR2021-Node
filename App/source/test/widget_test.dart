import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/ui/theme.dart';
import 'package:lr2021_app/ui/widgets.dart';

void main() {
  testWidgets('Signalbalken zeichnen', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const Scaffold(body: Center(child: SignalBars(snr: 3.5))),
    ));
    expect(find.byType(SignalBars), findsOneWidget);
  });
}
