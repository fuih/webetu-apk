import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../models/student_context.dart';
import 'webetu_api_service.dart';

const String kDailyReservationTask = "dz.mesrs.webetu.daily_reservation";

/// Top-level background dispatcher required by WorkManager
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = WebetuHttpOverrides();

    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool('webetu_bg_auto_reserve') ?? false;
      if (!isEnabled) {
        return true;
      }

      final username = prefs.getString('webetu_username');
      final password = prefs.getString('webetu_password');
      if (username == null || password == null || username.isEmpty || password.isEmpty) {
        return true;
      }

      final depotId = prefs.getInt('webetu_default_depot');
      if (depotId == null || depotId == 0) {
        return true;
      }

      final rawMeals = prefs.getStringList('webetu_default_meals') ?? ['2', '3'];
      final meals = rawMeals.map((e) => int.tryParse(e) ?? 2).toList();
      final window = prefs.getInt('webetu_auto_window') ?? 3;
      final rawDays = prefs.getStringList('webetu_active_days');
      final activeDays = rawDays?.map((e) => int.tryParse(e) ?? 1).toSet() ?? {7, 1, 2, 3, 4};

      final api = WebetuApiService();

      // Check if we have an active saved session (especially useful for 2FA accounts)
      final savedProgresToken = prefs.getString('webetu_progres_token');
      final savedOnouToken = prefs.getString('webetu_onou_token');
      final savedStudentUuid = prefs.getString('webetu_student_uuid');
      final savedCtxJson = prefs.getString('webetu_student_context');

      bool sessionRestored = false;
      if (savedProgresToken != null && savedOnouToken != null && savedStudentUuid != null && savedCtxJson != null) {
        try {
          final ctx = StudentContext.fromJson(jsonDecode(savedCtxJson));
          api.restoreSession(
            progresToken: savedProgresToken,
            onouToken: savedOnouToken,
            studentUuid: savedStudentUuid,
            studentContext: ctx,
            username: username,
          );
          sessionRestored = true;
        } catch (_) {}
      }

      if (!sessionRestored) {
        await api.authenticate(username, password);
      } else {
        try {
          await api.getReservations();
        } catch (_) {
          // Token expired, re-authenticate if possible
          await api.authenticate(username, password);
          if (api.isAuthenticated && api.studentContext != null) {
            await prefs.setString('webetu_progres_token', api.progresToken!);
            await prefs.setString('webetu_onou_token', api.onouToken!);
            await prefs.setString('webetu_student_uuid', api.studentUuid!);
            await prefs.setString('webetu_student_context', jsonEncode(api.studentContext!.toJson()));
          }
        }
      }

      final existingReservations = await api.getReservations();
      final now = DateTime.now();

      int successCount = 0;
      int skippedCount = 0;
      int errorCount = 0;

      for (int i = 1; i <= window; i++) {
        final targetDate = now.add(Duration(days: i));
        if (!activeDays.contains(targetDate.weekday)) {
          continue; // Skip inactive days of week (e.g. weekend)
        }

        final dateStr = "${targetDate.year.toString().padLeft(4, '0')}-"
            "${targetDate.month.toString().padLeft(2, '0')}-"
            "${targetDate.day.toString().padLeft(2, '0')}";

        final results = await api.reserveMeals(
          dateStr: dateStr,
          mealTypes: meals,
          depotId: depotId,
          existingReservations: existingReservations,
        );

        for (final r in results) {
          if (r.isSuccess) successCount++;
          if (r.isSkipped) skippedCount++;
          if (r.status == 'failed' || r.status == 'error') errorCount++;
        }
      }

      final nowFormatted = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} "
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

      await prefs.setString('webetu_last_bg_run_time', nowFormatted);
      await prefs.setString('webetu_last_bg_run_status', errorCount > 0 && successCount == 0 ? 'error' : 'success');

      String summary;
      if (successCount > 0) {
        summary = "$successCount repas réservé(s) pour les prochains jours !";
      } else if (skippedCount > 0) {
        summary = "Tous les repas sont déjà réservés ($skippedCount repas vérifiés).";
      } else {
        summary = "Aucun créneau disponible pour le moment.";
      }

      if (errorCount > 0) {
        summary += " ($errorCount erreur(s))";
      }

      await prefs.setString('webetu_last_bg_run_message', summary);

      // Display local notification on student's phone
      await _showLocalNotification(
        title: "WebEtu Resto : Réservation Automatique",
        body: summary,
      );

      return true;
    } catch (e) {
      final now = DateTime.now();
      final nowFormatted = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} "
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('webetu_last_bg_run_time', nowFormatted);
      await prefs.setString('webetu_last_bg_run_status', 'error');

      String errorMessage = "Échec de connexion : $e. Nouvelle tentative programmée.";
      if (e is MfaRequiredException || e.toString().contains('2FA') || e.toString().contains('mfaKey')) {
        errorMessage = "Double authentification (2FA) active : ouvrez l'application ou désactivez la 2FA dans WebEtu officiel pour l'auto-réservation.";
      }

      await prefs.setString('webetu_last_bg_run_message', errorMessage);

      // Return false to tell Android WorkManager to retry when network condition is met
      return false;
    }
  });
}

Future<void> _showLocalNotification({required String title, required String body}) async {
  try {
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await flutterLocalNotificationsPlugin.initialize(initSettings);

    const androidDetails = AndroidNotificationDetails(
      'webetu_auto_reserve_channel',
      'Réservations WebEtu',
      channelDescription: 'Notifications de réservation automatique des repas ONOU',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const notificationDetails = NotificationDetails(android: androidDetails);

    await flutterLocalNotificationsPlugin.show(
      1001,
      title,
      body,
      notificationDetails,
    );
  } catch (_) {
    // Silently ignore notification failure in background
  }
}

class BackgroundReservationService {
  static Future<void> initialize() async {
    try {
      await Workmanager().initialize(callbackDispatcher);
    } catch (_) {}
  }

  /// Registers daily background periodic task.
  /// Uses NetworkType.connected: if there is no internet, Android WorkManager
  /// will automatically wait and trigger as soon as the phone connects to 4G or Wi-Fi!
  static Future<void> enableDailyReservation() async {
    await Workmanager().registerPeriodicTask(
      kDailyReservationTask,
      "dailyReservationTask",
      frequency: const Duration(hours: 12),
      constraints: Constraints(
        networkType: NetworkType.connected, // <--- OFFLINE RESILIENCE!
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );
  }

  /// Cancels the scheduled daily background task
  static Future<void> disableDailyReservation() async {
    await Workmanager().cancelByUniqueName(kDailyReservationTask);
  }

  /// Schedules an immediate one-off background execution (e.g. on Wi-Fi reconnect)
  static Future<void> triggerImmediateSync() async {
    await Workmanager().registerOneOffTask(
      "dz.mesrs.webetu.sync_${DateTime.now().millisecondsSinceEpoch}",
      "syncReservationTask",
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  static const MethodChannel _platform = MethodChannel('dz.mesrs.webetu/background_service');

  /// Requests notification permission on Android 13+
  static Future<bool> requestNotificationPermission() async {
    try {
      final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidImpl?.requestNotificationsPermission();
      return granted ?? true;
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
}
