import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'reservation_engine.dart';
import 'webetu_api_service.dart';

const String kDailyReservationTask = "dz.mesrs.webetu.daily_reservation";
const String kImmediateSyncTask = "dz.mesrs.webetu.immediate_sync";
const String kManualTestTask = "dz.mesrs.webetu.manual_bg_test";

/// Top-level background dispatcher required by WorkManager.
/// Must keep @pragma('vm:entry-point') so AOT/obfuscation preserves its callback handle.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = WebetuHttpOverrides();

    final isManualTest =
        taskName == "manualBgTestTask" || (inputData != null && inputData['isManualTest'] == true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final api = WebetuApiService();

      final outcome = await ReservationEngine.run(
        prefs: prefs,
        api: api,
        isManualTest: isManualTest,
        ignoreEnabledCheck: isManualTest,
        notify: ({required title, required body, bool isAlert = false}) async {
          await _showLocalNotification(
            title: title,
            body: body,
            isAlert: isAlert,
          );
        },
      );

      // Returning false tells Android WorkManager to retry automatically with backoff!
      return !outcome.shouldRetryLater;
    } catch (e) {
      try {
        final now = DateTime.now();
        final nowFormatted =
            "${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} "
            "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('webetu_last_bg_run_time', nowFormatted);
        await prefs.setString('webetu_last_bg_run_status', 'error');
        await prefs.setString(
          'webetu_last_bg_run_message',
          "Erreur inattendue en arrière-plan : $e. Nouvelle tentative programmée.",
        );
      } catch (_) {}
      return false;
    }
  });
}

Future<void> _showLocalNotification({
  required String title,
  required String body,
  bool isAlert = false,
}) async {
  try {
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await flutterLocalNotificationsPlugin.initialize(initSettings);

    final androidDetails = AndroidNotificationDetails(
      isAlert ? 'webetu_auto_reserve_alerts' : 'webetu_auto_reserve_channel',
      isAlert ? 'Alertes WebEtu Resto' : 'Réservations WebEtu',
      channelDescription: isAlert
          ? 'Alertes urgentes (session expirée ou repas de demain non confirmé)'
          : 'Confirmations de réservation automatique des repas ONOU',
      importance: isAlert ? Importance.max : Importance.high,
      priority: isAlert ? Priority.max : Priority.high,
      styleInformation: BigTextStyleInformation(body),
      icon: '@mipmap/ic_launcher',
    );
    final notificationDetails = NotificationDetails(android: androidDetails);

    await flutterLocalNotificationsPlugin.show(
      isAlert ? 1002 : 1001,
      title,
      body,
      notificationDetails,
    );
  } catch (_) {
    // Silently ignore notification failure in background
  }
}

class BackgroundReservationService {
  static bool _initialized = false;
  static const MethodChannel _platform = MethodChannel('dz.mesrs.webetu/background_service');

  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      await Workmanager().initialize(callbackDispatcher);
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  /// Registers periodic background reservation task (every 4 hours = 6x/day).
  /// Uses NetworkType.connected: if there is no internet, Android WorkManager
  /// automatically holds the task and executes it the moment 4G or Wi-Fi returns!
  static Future<void> enableDailyReservation({bool runImmediateSync = false}) async {
    await initialize();
    await Workmanager().registerPeriodicTask(
      kDailyReservationTask,
      "dailyReservationTask",
      frequency: const Duration(hours: 4),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );

    if (runImmediateSync) {
      await triggerImmediateSync();
    }
  }

  /// Self-heals the periodic schedule on app startup / resume if the toggle is ON
  /// but Android cleared or hasn't registered the periodic WorkManager job yet.
  static Future<void> ensureScheduledIfEnabled(bool isEnabled) async {
    await initialize();
    if (!isEnabled) return;
    try {
      final scheduled = await isDailyTaskScheduled();
      if (!scheduled) {
        await enableDailyReservation(runImmediateSync: false);
      }
    } catch (_) {}
  }

  /// Queries Android WorkManager directly to check if the periodic task is ENQUEUED or RUNNING.
  static Future<bool> isDailyTaskScheduled() async {
    try {
      await initialize();
      return await Workmanager().isScheduledByUniqueName(kDailyReservationTask);
    } catch (_) {
      return false;
    }
  }

  /// Cancels the scheduled periodic background task
  static Future<void> disableDailyReservation() async {
    await initialize();
    await Workmanager().cancelByUniqueName(kDailyReservationTask);
  }

  /// Schedules an immediate one-off background execution (e.g. after changing settings or reconnecting)
  static Future<void> triggerImmediateSync() async {
    await initialize();
    await Workmanager().registerOneOffTask(
      kImmediateSyncTask,
      "syncReservationTask",
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
    );
  }

  /// Schedules an expedited one-off WorkManager task that ALWAYS fires a notification
  /// so the user can test and verify real Android background execution on their phone.
  static Future<void> triggerBackgroundTest() async {
    await initialize();
    await Workmanager().registerOneOffTask(
      kManualTestTask,
      "manualBgTestTask",
      inputData: {'isManualTest': true},
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      expedited: true,
      outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
    );
  }

  /// Requests notification permission on Android 13+
  static Future<bool> requestNotificationPermission() async {
    try {
      final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidImpl?.requestNotificationsPermission();
      return granted ?? await areNotificationsEnabled();
    } catch (_) {
      return true;
    }
  }

  /// Checks whether OS notifications are currently allowed for this app
  static Future<bool> areNotificationsEnabled() async {
    try {
      final res = await _platform.invokeMethod<bool>('areNotificationsEnabled');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Checks if battery optimization is disabled for reliable background execution
  static Future<bool> isBatteryOptimizationIgnored() async {
    try {
      final res = await _platform.invokeMethod<bool>('isBatteryOptimizationIgnored');
      return res ?? false;
    } catch (_) {
      return true;
    }
  }

  /// Prompts Android OS to allow unconstrained background execution
  static Future<void> requestIgnoreBatteryOptimization() async {
    try {
      await _platform.invokeMethod('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }

  /// Returns true on OEM devices known to aggressively restrict background tasks (Xiaomi, Oppo, Huawei, etc.)
  static Future<bool> isRestrictedOem() async {
    try {
      final res = await _platform.invokeMethod<bool>('isRestrictedOem');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens OEM AutoStart / Background permissions screen (with fallback to App Details Settings)
  static Future<void> openAutoStartSettings() async {
    try {
      await _platform.invokeMethod('openAutoStartSettings');
    } catch (_) {}
  }

  /// Opens standard Android App Details settings (for notifications / battery / permissions)
  static Future<void> openAppSettings() async {
    try {
      await _platform.invokeMethod('openAppSettings');
    } catch (_) {}
  }
}
