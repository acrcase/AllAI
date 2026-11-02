import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Karşılama başlığındaki ad. Boşsa "Your name" yer tutucusu görünür; kullanıcı düzenleme kipinde yazar.
class ProfileStore extends ChangeNotifier {
  ProfileStore._();
  static final instance = ProfileStore._();

  static const _key = 'profile.name.v1';
  String name = '';

  Future<void> load() async {
    try {
      name = (await SharedPreferences.getInstance()).getString(_key) ?? '';
    } catch (_) {}
  }

  Future<void> setName(String value) async {
    final next = value.trim();
    if (next == name) return;
    name = next;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, next);
    } catch (_) {}
  }
}
