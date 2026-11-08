import 'package:flutter/material.dart';

import 'state/app.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init();
  runApp(const Lr2021App());
}

class Lr2021App extends StatelessWidget {
  const Lr2021App({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'LR2021 Node',
        locale: Locale(app.settings.lang == 'de' ? 'de' : 'en'),
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (app.settings.theme) { 1 => ThemeMode.light, 2 => ThemeMode.dark, _ => ThemeMode.system },
        home: const Shell(),
      ),
    );
  }
}
