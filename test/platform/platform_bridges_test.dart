import 'dart:io';

import 'package:allai/platform/app_dock.dart';
import 'package:allai/platform/menu_bridge.dart';
import 'package:allai/platform/window_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const dockChannel = MethodChannel('allai/dock');
  const windowChannel = MethodChannel('allai/window');
  const menuChannel = MethodChannel('allai/menu');
  final calls = <MethodCall>[];

  void mock(MethodChannel channel, Object? Function(MethodCall call) reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  tearDown(() {
    for (final c in [dockChannel, windowChannel, menuChannel]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    calls.clear();
  });

  group('AppDock', skip: !Platform.isMacOS, () {
    test('dock bundleId ve rect gönderir, durum adını çözer', () async {
      mock(dockChannel, (_) => 'docked');
      final state = await AppDock.instance.dock('k', 'com.x', const Rect.fromLTWH(10, 20, 300, 200));
      expect(state, DockState.docked);
      expect(calls.single.method, 'dock');
      expect(calls.single.arguments,
          {'key': 'k', 'bundleId': 'com.x', 'separateProfile': false, 'x': 10.0, 'y': 20.0, 'width': 300.0, 'height': 200.0});
    });

    test('yerli durumlar enum karşılığına eşlenir', () async {
      for (final name in ['needsPermission', 'notInstalled', 'idle', 'failed']) {
        mock(dockChannel, (_) => name);
        expect(await AppDock.instance.dock('k', 'a', Rect.zero), DockState.values.byName(name));
      }
    });

    test('yerli hata ve eksik eklenti failed / false döner', () async {
      mock(dockChannel, (_) => throw PlatformException(code: 'x'));
      expect(await AppDock.instance.dock('k', 'a', Rect.zero), DockState.failed);
      messenger.setMockMethodCallHandler(dockChannel, null);
      expect(await AppDock.instance.isTrusted(), isFalse);
      expect(await AppDock.instance.isInstalled('a'), isFalse);
    });

    test('ikinci hesap: separateProfile, close, supportsProfiles ve deleteProfile kart kimliğiyle gider', () async {
      mock(dockChannel, (call) => switch (call.method) {
            'dock' => 'docked',
            'supportsProfiles' => true,
            _ => null,
          });
      await AppDock.instance.dock('claude-2', 'com.x', Rect.zero, separateProfile: true);
      expect(await AppDock.instance.supportsProfiles('com.x'), isTrue);
      await AppDock.instance.close('claude-2');
      await AppDock.instance.deleteProfile('claude-2');
      expect(calls.map((c) => c.method), ['dock', 'supportsProfiles', 'close', 'deleteProfile']);
      expect((calls[0].arguments as Map)['separateProfile'], isTrue);
      expect(calls[1].arguments, {'bundleId': 'com.x'});
      expect(calls[2].arguments, {'key': 'claude-2'});
      expect(calls[3].arguments, {'key': 'claude-2'});
    });

    test('eksik eklentide supportsProfiles false döner', () async {
      expect(await AppDock.instance.supportsProfiles('com.x'), isFalse);
    });

    test('isTrusted prompt bayrağını iletir', () async {
      mock(dockChannel, (_) => true);
      expect(await AppDock.instance.isTrusted(prompt: true), isTrue);
      expect(calls.single.arguments, {'prompt': true});
    });

    test('olaylar DockEvent olarak gelir', () async {
      messenger.setMockStreamHandler(
        const EventChannel('allai/dock/events'),
        MockStreamHandler.inline(onListen: (_, sink) {
          sink.success({'type': 'terminated', 'key': 'claude-2', 'bundleId': 'com.x'});
        }),
      );
      final event = await AppDock.instance.events.first;
      expect(event.type, 'terminated');
      expect(event.key, 'claude-2');
      expect(event.bundleId, 'com.x');
      expect(event.message, isNull);
    });
  });

  group('WindowBridge', skip: !Platform.isMacOS, () {
    test('startDrag, toggleZoom ve isFullScreen kanala gider', () async {
      mock(windowChannel, (call) => call.method == 'isFullScreen' ? true : null);
      await WindowBridge.startDrag();
      await WindowBridge.toggleZoom();
      expect(await WindowBridge.isFullScreen(), isTrue);
      expect(calls.map((c) => c.method), ['startDrag', 'toggleZoom', 'isFullScreen']);
    });
  });

  group('MenuBridge', skip: !Platform.isMacOS, () {
    Future<void> nativeSends(String method, [Object? args]) => messenger.handlePlatformMessage(
          'allai/menu',
          const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );

    test('yerli menü seçimi işleyiciye eylem ve sırayla ulaşır', () async {
      final got = <(String, int?)>[];
      MenuBridge.setHandler((action, index) => got.add((action, index)));
      await nativeSends('open', 2);
      await nativeSends('home');
      expect(got, [('open', 2), ('home', null)]);
      MenuBridge.setHandler(null);
    });

    test('setServiceNames listeyi gönderir', () async {
      mock(menuChannel, (_) => null);
      await MenuBridge.setServiceNames(['Claude', 'ChatGPT']);
      expect(calls.single.method, 'setServiceNames');
      expect(calls.single.arguments, ['Claude', 'ChatGPT']);
    });
  });
}
