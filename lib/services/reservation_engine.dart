import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reservation.dart';
import '../models/student_context.dart';
import 'webetu_api_service.dart';

typedef NotificationCallback = Future<void> Function({
  required String title,
  required String body,
  bool isAlert,
});

class AutoReservationOutcome {
  final bool shouldRetryLater;
  final String status; // 'success', 'warning', 'error', 'skipped'
  final String summary;
  final int newlyReservedCount;
  final int totalConfirmedCount;
  final int totalExpectedCount;
  final int unconfirmedTomorrowCount;
  final bool requiresReauth;
  final List<Reservation> verifiedReservations;

  AutoReservationOutcome({
    required this.shouldRetryLater,
    required this.status,
    required this.summary,
    this.newlyReservedCount = 0,
    this.totalConfirmedCount = 0,
    this.totalExpectedCount = 0,
    this.unconfirmedTomorrowCount = 0,
    this.requiresReauth = false,
    this.verifiedReservations = const [],
  });
}

class ReservationEngine {
  static String _formatDate(DateTime dt) =>
      "${dt.year.toString().padLeft(4, '0')}-"
      "${dt.month.toString().padLeft(2, '0')}-"
      "${dt.day.toString().padLeft(2, '0')}";

  static String _formatDateShort(DateTime dt) =>
      "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}";

  static String _formatTimestamp(DateTime dt) =>
      "${_formatDate(dt)} "
      "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";

  static bool _canSendThrottledAlert(
    SharedPreferences prefs,
    DateTime now,
    Duration minInterval, {
    required bool force,
  }) {
    if (force) return true;
    final lastTs = prefs.getInt('webetu_last_alert_ts') ?? 0;
    final elapsedMs = now.millisecondsSinceEpoch - lastTs;
    return elapsedMs >= minInterval.inMilliseconds;
  }

  static Future<void> _recordAlertSent(SharedPreferences prefs, DateTime now) async {
    await prefs.setInt('webetu_last_alert_ts', now.millisecondsSinceEpoch);
  }

  static Future<void> _saveRunState(
    SharedPreferences prefs,
    DateTime now, {
    required String status,
    required String message,
  }) async {
    await prefs.setString('webetu_last_bg_run_time', _formatTimestamp(now));
    await prefs.setString('webetu_last_bg_run_status', status);
    await prefs.setString('webetu_last_bg_run_message', message);
  }

  static Future<void> _persistSession(SharedPreferences prefs, WebetuApiService api) async {
    if (api.progresToken != null &&
        api.onouToken != null &&
        api.studentUuid != null &&
        api.studentContext != null) {
      await prefs.setString('webetu_progres_token', api.progresToken!);
      await prefs.setString('webetu_onou_token', api.onouToken!);
      await prefs.setString('webetu_student_uuid', api.studentUuid!);
      await prefs.setString('webetu_student_context', jsonEncode(api.studentContext!.toJson()));
    }
  }

  /// Executes a complete, server-verified automatic reservation cycle.
  /// Shared by the Android WorkManager background worker and foreground safety-net.
  static Future<AutoReservationOutcome> run({
    required SharedPreferences prefs,
    required WebetuApiService api,
    DateTime? now,
    bool isManualTest = false,
    bool ignoreEnabledCheck = false,
    Duration verifyRetryDelay = const Duration(seconds: 3),
    NotificationCallback? notify,
  }) async {
    final currentTime = now ?? DateTime.now();

    try {
      await prefs.reload();
    } catch (_) {}

    final isEnabled = prefs.getBool('webetu_bg_auto_reserve') ?? false;
    if (!ignoreEnabledCheck && !isEnabled) {
      return AutoReservationOutcome(
        shouldRetryLater: false,
        status: 'skipped',
        summary: 'Réservation automatique désactivée.',
      );
    }

    // Wire automatic persistence whenever WebetuApiService silently refreshes the ONOU token
    api.onOnouTokenRefreshed = (newToken) async {
      await prefs.setString('webetu_onou_token', newToken);
    };

    final username = prefs.getString('webetu_username');
    final password = prefs.getString('webetu_password');
    final savedProgresToken = prefs.getString('webetu_progres_token');
    final savedOnouToken = prefs.getString('webetu_onou_token');
    final savedStudentUuid = prefs.getString('webetu_student_uuid');
    final savedCtxJson = prefs.getString('webetu_student_context');

    StudentContext? savedCtx;
    if (savedCtxJson != null && savedCtxJson.isNotEmpty) {
      try {
        savedCtx = StudentContext.fromJson(jsonDecode(savedCtxJson) as Map<String, dynamic>);
      } catch (_) {}
    }

    final hasSavedSession = savedProgresToken != null &&
        savedProgresToken.isNotEmpty &&
        savedOnouToken != null &&
        savedOnouToken.isNotEmpty &&
        savedStudentUuid != null &&
        savedStudentUuid.isNotEmpty &&
        savedCtx != null;

    final hasCredentials = username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty;

    if (!hasSavedSession && !hasCredentials) {
      const msg = "Aucun compte connecté. Ouvrez WebEtu Resto pour vous reconnecter.";
      await _saveRunState(prefs, currentTime, status: 'error', message: msg);
      if (notify != null &&
          _canSendThrottledAlert(prefs, currentTime, const Duration(hours: 6), force: isManualTest)) {
        await notify(
          title: "⚠️ WebEtu Resto : Connexion requise",
          body: msg,
          isAlert: true,
        );
        await _recordAlertSent(prefs, currentTime);
      }
      return AutoReservationOutcome(
        shouldRetryLater: false,
        status: 'error',
        summary: msg,
        requiresReauth: true,
      );
    }

    // Always pull latest remote API endpoints
    await api.fetchRemoteConfig();

    // =========================================================================
    // 3-TIER AUTHENTICATION & INITIAL RESERVATION FETCH
    // Tier 1: Restore cached tokens -> getReservations()
    // Tier 2: Inside getReservations(), expired onouToken auto-refreshes via loginOnou()
    // Tier 3: ONLY on true auth failure (401/403 after loginOnou), re-authenticate via PROGRES
    // =========================================================================
    List<Reservation> initialReservations;
    try {
      if (hasSavedSession) {
        api.restoreSession(
          progresToken: savedProgresToken,
          onouToken: savedOnouToken,
          studentUuid: savedStudentUuid,
          studentContext: savedCtx,
          username: username,
        );

        try {
          initialReservations = await api.getReservations();
        } on ApiHttpException catch (e) {
          if (!e.isAuthError) {
            // Transient server/HTTP error — do NOT falsely blame 2FA or re-login!
            rethrow;
          }
          // progresToken itself expired -> Tier 3 fallback
          if (!hasCredentials) {
            throw MfaRequiredException(
              "Votre session WebEtu a expiré. Ouvrez l'application pour vous reconnecter.",
            );
          }
          await api.authenticate(username, password);
          await _persistSession(prefs, api);
          initialReservations = await api.getReservations();
        }
      } else {
        await api.authenticate(username!, password!);
        await _persistSession(prefs, api);
        initialReservations = await api.getReservations();
      }
    } on MfaRequiredException catch (_) {
      const msg =
          "Session 2FA expirée : ouvrez WebEtu Resto et saisissez votre code Authenticator à 6 chiffres pour réactiver la réservation automatique.";
      await _saveRunState(prefs, currentTime, status: 'error', message: msg);
      if (notify != null &&
          _canSendThrottledAlert(prefs, currentTime, const Duration(hours: 6), force: isManualTest)) {
        await notify(
          title: "⚠️ WebEtu Resto : Reconnexion 2FA requise",
          body: "Votre session a expiré. Ouvrez l'application pour entrer votre code 2FA afin d'assurer vos repas.",
          isAlert: true,
        );
        await _recordAlertSent(prefs, currentTime);
      }
      return AutoReservationOutcome(
        shouldRetryLater: false,
        status: 'error',
        summary: msg,
        requiresReauth: true,
      );
    } on ApiHttpException catch (e) {
      if (e.isAuthError) {
        const msg = "Identifiants invalides ou session expirée. Ouvrez WebEtu Resto pour vous reconnecter.";
        await _saveRunState(prefs, currentTime, status: 'error', message: msg);
        if (notify != null &&
            _canSendThrottledAlert(prefs, currentTime, const Duration(hours: 6), force: isManualTest)) {
          await notify(
            title: "⚠️ WebEtu Resto : Reconnexion requise",
            body: msg,
            isAlert: true,
          );
          await _recordAlertSent(prefs, currentTime);
        }
        return AutoReservationOutcome(
          shouldRetryLater: false,
          status: 'error',
          summary: msg,
          requiresReauth: true,
        );
      }
      final msg = "Serveur WebEtu/ONOU temporairement indisponible (HTTP ${e.statusCode}). Nouvelle tentative automatique programmée.";
      await _saveRunState(prefs, currentTime, status: 'error', message: msg);
      return AutoReservationOutcome(
        shouldRetryLater: true,
        status: 'error',
        summary: msg,
      );
    } catch (e) {
      final msg = "Réseau ou serveur indisponible ($e). Nouvelle tentative automatique programmée.";
      await _saveRunState(prefs, currentTime, status: 'error', message: msg);
      return AutoReservationOutcome(
        shouldRetryLater: true,
        status: 'error',
        summary: msg,
      );
    }

    // =========================================================================
    // RESOLVE RESTAURANT (DEPOT ID) — AUTO-FETCH IF MISSING
    // =========================================================================
    int? depotId = prefs.getInt('webetu_default_depot');
    if (depotId == null || depotId == 0) {
      try {
        final restaurants = await api.getRestaurants();
        if (restaurants.isNotEmpty) {
          depotId = restaurants.first.id;
          await prefs.setInt('webetu_default_depot', depotId);
        }
      } catch (e) {
        final msg = "Impossible de récupérer votre restaurant ($e). Nouvelle tentative programmée.";
        await _saveRunState(prefs, currentTime, status: 'error', message: msg);
        return AutoReservationOutcome(
          shouldRetryLater: true,
          status: 'error',
          summary: msg,
        );
      }
    }

    if (depotId == null || depotId == 0) {
      const msg = "Aucun restaurant universitaire disponible pour votre compte. Choisissez un restaurant dans l'application.";
      await _saveRunState(prefs, currentTime, status: 'error', message: msg);
      if (notify != null &&
          _canSendThrottledAlert(prefs, currentTime, const Duration(hours: 6), force: isManualTest)) {
        await notify(
          title: "⚠️ WebEtu Resto : Restaurant non configuré",
          body: msg,
          isAlert: true,
        );
        await _recordAlertSent(prefs, currentTime);
      }
      return AutoReservationOutcome(
        shouldRetryLater: false,
        status: 'error',
        summary: msg,
      );
    }

    // =========================================================================
    // RESOLVE MEALS, ACTIVE DAYS, AND TARGET SLOTS
    // =========================================================================
    final rawMeals = prefs.getStringList('webetu_default_meals');
    final meals = <int>[];
    for (final raw in (rawMeals == null || rawMeals.isEmpty ? ['2', '3'] : rawMeals)) {
      final parsed = int.tryParse(raw);
      if (parsed != null && parsed >= 1 && parsed <= 3 && !meals.contains(parsed)) {
        meals.add(parsed);
      }
    }
    if (meals.isEmpty) {
      meals.addAll([2, 3]);
    }

    final windowRaw = prefs.getInt('webetu_auto_window') ?? 3;
    final window = windowRaw < 1 ? 1 : windowRaw;

    final rawDays = prefs.getStringList('webetu_active_days');
    final activeDays = (rawDays == null || rawDays.isEmpty)
        ? {7, 1, 2, 3, 4}
        : rawDays.map((e) => int.tryParse(e)).whereType<int>().toSet();

    final targetDates = <DateTime>[];
    for (int i = 1; i <= window; i++) {
      final d = currentTime.add(Duration(days: i));
      if (activeDays.contains(d.weekday)) {
        targetDates.add(d);
      }
    }

    if (targetDates.isEmpty) {
      final msg = "Aucun jour actif dans les $window prochains jours.";
      await _saveRunState(prefs, currentTime, status: 'success', message: msg);
      if (notify != null && isManualTest) {
        await notify(
          title: "WebEtu Resto : Test arrière-plan réussi ✓",
          body: msg,
          isAlert: false,
        );
      }
      return AutoReservationOutcome(
        shouldRetryLater: false,
        status: 'success',
        summary: msg,
        verifiedReservations: initialReservations,
      );
    }

    final tomorrowStr = _formatDate(currentTime.add(const Duration(days: 1)));

    // Record what was ALREADY confirmed on ONOU before we start booking
    final alreadyHadBefore = <String>{};
    for (final d in targetDates) {
      final dateStr = _formatDate(d);
      for (final meal in meals) {
        if (api.isAlreadyReserved(dateStr, meal, initialReservations)) {
          alreadyHadBefore.add('$dateStr|$meal');
        }
      }
    }

    // =========================================================================
    // PASS 1: BOOK ALL MISSING MEALS ACROSS ACTIVE UPCOMING DAYS
    // =========================================================================
    final permanentRejections = <String, String>{};
    bool hadTransientError = false;
    final errorMessages = <String>[];

    for (final d in targetDates) {
      final dateStr = _formatDate(d);
      final missingForDate = meals
          .where((m) => !alreadyHadBefore.contains('$dateStr|$m'))
          .toList();

      if (missingForDate.isEmpty) continue;

      final results = await api.reserveMeals(
        dateStr: dateStr,
        mealTypes: missingForDate,
        depotId: depotId,
        existingReservations: initialReservations,
      );

      for (final r in results) {
        final key = '${r.date}|${r.mealType}';
        if (r.status == 'error' || r.isTransientError) {
          hadTransientError = true;
          errorMessages.add('${r.mealName} (${r.date}): ${r.message}');
        } else if (r.status == 'failed') {
          permanentRejections[key] = r.message;
          errorMessages.add('${r.mealName} (${r.date}): ${r.message}');
        }
      }
    }

    // =========================================================================
    // PASS 2: MANDATORY SERVER-SIDE VERIFICATION & RECOVERY RETRY
    // Re-fetch reservations directly from ONOU to guarantee the student is TRULY reserved!
    // =========================================================================
    List<Reservation> verifiedReservations;
    try {
      verifiedReservations = await api.getReservations();
    } catch (_) {
      // Could not verify right now -> ask WorkManager to retry and re-verify!
      const msg = "Réservation envoyée mais vérification ONOU interrompue. Nouvelle vérification automatique prévue.";
      await _saveRunState(prefs, currentTime, status: 'warning', message: msg);
      return AutoReservationOutcome(
        shouldRetryLater: true,
        status: 'warning',
        summary: msg,
        verifiedReservations: initialReservations,
      );
    }

    // Cross-check EVERY expected slot against ONOU's real reservation list
    final unconfirmedSlotsByDate = <String, List<int>>{};
    for (final d in targetDates) {
      final dateStr = _formatDate(d);
      for (final meal in meals) {
        final key = '$dateStr|$meal';
        final confirmedOnServer = api.isAlreadyReserved(dateStr, meal, verifiedReservations);
        if (!confirmedOnServer && !permanentRejections.containsKey(key)) {
          unconfirmedSlotsByDate.putIfAbsent(dateStr, () => []).add(meal);
        }
      }
    }

    // If any slot was NOT confirmed on server (even if Pass 1 returned 200 or had transient error),
    // retry booking those specific missing slots and re-verify!
    if (unconfirmedSlotsByDate.isNotEmpty) {
      if (verifyRetryDelay > Duration.zero) {
        await Future.delayed(verifyRetryDelay);
      }

      for (final entry in unconfirmedSlotsByDate.entries) {
        final retryResults = await api.reserveMeals(
          dateStr: entry.key,
          mealTypes: entry.value,
          depotId: depotId,
          existingReservations: verifiedReservations,
        );
        for (final r in retryResults) {
          final key = '${r.date}|${r.mealType}';
          if (r.status == 'error' || r.isTransientError) {
            hadTransientError = true;
          } else if (r.status == 'failed') {
            permanentRejections[key] = r.message;
          }
        }
      }

      try {
        verifiedReservations = await api.getReservations();
      } catch (_) {
        hadTransientError = true;
      }
    }

    // =========================================================================
    // GROUND-TRUTH VERIFIED TALLY FROM ONOU SERVER
    // =========================================================================
    int totalExpectedCount = targetDates.length * meals.length;
    int totalConfirmedCount = 0;
    int newlyReservedCount = 0;
    int unconfirmedTomorrowCount = 0;
    bool allUnconfirmedTomorrowPermanentlyRejected = true;
    final newlyReservedLabels = <String>[];

    for (final d in targetDates) {
      final dateStr = _formatDate(d);
      final shortDate = _formatDateShort(d);
      for (final meal in meals) {
        final key = '$dateStr|$meal';
        final isConfirmedNow = api.isAlreadyReserved(dateStr, meal, verifiedReservations);
        if (isConfirmedNow) {
          totalConfirmedCount++;
          if (!alreadyHadBefore.contains(key)) {
            newlyReservedCount++;
            final mealName = WebetuApiService.mealShortNames[meal] ?? 'Repas $meal';
            newlyReservedLabels.add('$mealName ($shortDate)');
          }
        } else if (dateStr == tomorrowStr) {
          unconfirmedTomorrowCount++;
          if (!permanentRejections.containsKey(key)) {
            allUnconfirmedTomorrowPermanentlyRejected = false;
          }
        }
      }
    }

    final hasMissingSlots = totalConfirmedCount < totalExpectedCount;
    final shouldRetryLater = hasMissingSlots &&
        (hadTransientError || (unconfirmedTomorrowCount > 0 && !allUnconfirmedTomorrowPermanentlyRejected));

    String status;
    String summary;

    if (newlyReservedCount > 0 && unconfirmedTomorrowCount == 0) {
      status = 'success';
      final detail = newlyReservedLabels.take(4).join(', ');
      summary = "$newlyReservedCount repas réservé(s) et confirmé(s) sur ONOU : $detail ($totalConfirmedCount/$totalExpectedCount).";
    } else if (unconfirmedTomorrowCount == 0 && totalConfirmedCount == totalExpectedCount) {
      status = 'success';
      summary = "Tous vos repas à venir sont confirmés sur ONOU ($totalConfirmedCount/$totalExpectedCount).";
    } else if (unconfirmedTomorrowCount == 0 && totalConfirmedCount > 0) {
      status = 'success';
      summary = "$totalConfirmedCount/$totalExpectedCount repas confirmés sur ONOU (les jours suivants ouvriront bientôt).";
    } else if (unconfirmedTomorrowCount > 0) {
      status = 'error';
      final reason = errorMessages.isNotEmpty ? errorMessages.first : "créneau non confirmé sur ONOU";
      summary = "Attention : $unconfirmedTomorrowCount repas de demain non confirmé(s) ($reason).";
    } else {
      status = shouldRetryLater ? 'error' : 'warning';
      summary = errorMessages.isNotEmpty
          ? "Aucun repas confirmé : ${errorMessages.first}"
          : "Aucun créneau ouvert pour le moment ($totalConfirmedCount/$totalExpectedCount).";
    }

    await _saveRunState(prefs, currentTime, status: status, message: summary);

    // =========================================================================
    // SMART NOTIFICATIONS
    // =========================================================================
    if (notify != null) {
      if (newlyReservedCount > 0 && unconfirmedTomorrowCount == 0) {
        await notify(
          title: "WebEtu Resto : $newlyReservedCount repas confirmé(s) ✓",
          body: summary,
          isAlert: false,
        );
      } else if (unconfirmedTomorrowCount > 0) {
        if (_canSendThrottledAlert(prefs, currentTime, const Duration(hours: 2), force: isManualTest)) {
          await notify(
            title: "⚠️ WebEtu Resto : Repas de demain non confirmé",
            body: shouldRetryLater
                ? "$summary Nouvelle tentative automatique en cours."
                : summary,
            isAlert: true,
          );
          await _recordAlertSent(prefs, currentTime);
        }
      } else if (isManualTest) {
        await notify(
          title: status == 'success'
              ? "WebEtu Resto : Test arrière-plan réussi ✓"
              : "WebEtu Resto : Résultat du test arrière-plan",
          body: summary,
          isAlert: status == 'error',
        );
      }
    }

    return AutoReservationOutcome(
      shouldRetryLater: shouldRetryLater,
      status: status,
      summary: summary,
      newlyReservedCount: newlyReservedCount,
      totalConfirmedCount: totalConfirmedCount,
      totalExpectedCount: totalExpectedCount,
      unconfirmedTomorrowCount: unconfirmedTomorrowCount,
      verifiedReservations: verifiedReservations,
    );
  }
}
