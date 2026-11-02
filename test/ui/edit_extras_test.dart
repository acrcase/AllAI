import 'package:allai/core/theme.dart';
import 'package:allai/data/profile_store.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/ui/chrome/edit_extras.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    L10n.instance.debugSet('en');
    ProfileStore.instance.name = '';
  });

  Widget host(ValueNotifier<bool> editing) => MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(body: Center(child: GreetingLine(editing: editing))),
  );

  testWidgets('ad boşken "Your name" görünür; düzenleme kipinde dokununca yazılıp kaydedilir', (tester) async {
    final editing = ValueNotifier(false);
    await tester.pumpWidget(host(editing));
    expect(find.text('Your name'), findsOneWidget);

    editing.value = true;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Your name'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Ada');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ProfileStore.instance.name, 'Ada');
    expect(find.text('Ada'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('profile.name.v1'), 'Ada');
  });

  testWidgets('düzenleme kipi dışında ada dokunmak yazdırmaz', (tester) async {
    await tester.pumpWidget(host(ValueNotifier(false)));
    await tester.tap(find.text('Your name'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('dil seçimi dili değiştirir ve kaydeder', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Builder(builder: (c) => TextButton(onPressed: () => showLanguageDialog(c), child: const Text('x'))),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch'));
    await tester.pumpAndSettle();
    expect(L10n.instance.code, 'de');
    expect(t('core.edit'), 'Bearbeiten');
    L10n.instance.debugSet('en');
  });
}
