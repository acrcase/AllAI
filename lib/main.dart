import 'package:flutter/material.dart';

import 'app.dart';
import 'data/profile_store.dart';
import 'l10n/l10n.dart';
import 'data/services_store.dart';
import 'platform/web_config.dart';
import 'usage/usage_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    WebConfig.init(),
    ServicesStore.instance.load(),
    L10n.instance.load(),
    ProfileStore.instance.load(),
  ]);
  UsageRepository.instance
    ..watchLifecycle()
    ..init();
  runApp(const AllAIApp());
}
