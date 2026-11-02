import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'l10n/l10n.dart';
import 'ui/root_screen.dart';

class AllAIApp extends StatelessWidget {
  const AllAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Dil değişince bütün ağaç yeniden kurulur; metinler t() ile anında okunur.
    return ListenableBuilder(
      listenable: L10n.instance,
      builder: (context, _) => _app(),
    );
  }

  Widget _app() {
    return MaterialApp(
      title: 'AllAI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const Scaffold(body: RootScreen()),
    );
  }
}
