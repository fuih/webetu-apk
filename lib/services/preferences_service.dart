import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const String _keyUsername = 'webetu_username';
  static const String _keyPassword = 'webetu_password';
  static const String _keyRememberMe = 'webetu_remember_me';
  static const String _keyDefaultDepot = 'webetu_default_depot';
  static const String _keyDefaultMeals = 'webetu_default_meals';
  static const String _keyAutoWindow = 'webetu_auto_window';
  static const String _keyBgAutoReserve = 'webetu_bg_auto_reserve';
  static const String _keyLastBgRunTime = 'webetu_last_bg_run_time';
  static const String _keyLastBgRunStatus = 'webetu_last_bg_run_status';
  static const String _keyLastBgRunMessage = 'webetu_last_bg_run_message';
  static const String _keyActiveDays = 'webetu_active_days';

  final SharedPreferences _prefs;

  PreferencesService(this._prefs);

  static Future<PreferencesService> getInstance() async {
    final prefs = await SharedPreferences.getInstance();
    return PreferencesService(prefs);
  }

  bool get rememberMe => _prefs.getBool(_keyRememberMe) ?? false;

  String? get savedUsername => _prefs.getString(_keyUsername);

  String? get savedPassword => _prefs.getString(_keyPassword);

  int? get defaultDepotId => _prefs.getInt(_keyDefaultDepot);

  List<int> get defaultMeals {
    final rawList = _prefs.getStringList(_keyDefaultMeals);
    if (rawList == null || rawList.isEmpty) {
      return [2, 3]; // Default to Lunch and Dinner
    }
    return rawList.map((e) => int.tryParse(e) ?? 2).toList();
  }

  int get autoReserveWindow => _prefs.getInt(_keyAutoWindow) ?? 3;

  Future<void> saveCredentials({
    required String username,
    required String password,
    required bool rememberMe,
  }) async {
    await _prefs.setBool(_keyRememberMe, rememberMe);
    if (rememberMe) {
      await _prefs.setString(_keyUsername, username);
      await _prefs.setString(_keyPassword, password);
    } else {
      await _prefs.remove(_keyUsername);
      await _prefs.remove(_keyPassword);
    }
  }

  Future<void> clearCredentials() async {
    await _prefs.remove(_keyUsername);
    await _prefs.remove(_keyPassword);
    await _prefs.setBool(_keyRememberMe, false);
  }

  Future<void> saveDefaultDepot(int depotId) async {
    await _prefs.setInt(_keyDefaultDepot, depotId);
  }

  Future<void> saveDefaultMeals(List<int> meals) async {
    final strList = meals.map((e) => e.toString()).toList();
    await _prefs.setStringList(_keyDefaultMeals, strList);
  }

  Future<void> saveAutoReserveWindow(int days) async {
    await _prefs.setInt(_keyAutoWindow, days);
  }

  bool get isBackgroundAutoReserveEnabled => _prefs.getBool(_keyBgAutoReserve) ?? false;

  Future<void> setBackgroundAutoReserveEnabled(bool enabled) async {
    await _prefs.setBool(_keyBgAutoReserve, enabled);
  }

  String? get lastBgRunTime => _prefs.getString(_keyLastBgRunTime);

  Future<void> setLastBgRunTime(String time) async {
    await _prefs.setString(_keyLastBgRunTime, time);
  }

  String? get lastBgRunStatus => _prefs.getString(_keyLastBgRunStatus);

  Future<void> setLastBgRunStatus(String status) async {
    await _prefs.setString(_keyLastBgRunStatus, status);
  }

  String? get lastBgRunMessage => _prefs.getString(_keyLastBgRunMessage);

  Future<void> setLastBgRunMessage(String message) async {
    await _prefs.setString(_keyLastBgRunMessage, message);
  }

  Set<int> get activeDaysOfWeek {
    final list = _prefs.getStringList(_keyActiveDays);
    if (list == null || list.isEmpty) {
      return {7, 1, 2, 3, 4}; // Dimanche à Jeudi par défaut en Algérie
    }
    return list.map((e) => int.tryParse(e) ?? 1).toSet();
  }

  Future<void> saveActiveDaysOfWeek(Set<int> days) async {
    await _prefs.setStringList(_keyActiveDays, days.map((e) => e.toString()).toList());
  }
}
