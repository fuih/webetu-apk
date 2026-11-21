import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webetu_reservation/models/student_context.dart';
import 'package:webetu_reservation/services/reservation_engine.dart';
import 'package:webetu_reservation/services/webetu_api_service.dart';

class _SentNotification {
  final String title;
  final String body;
  final bool isAlert;
  _SentNotification(this.title, this.body, this.isAlert);
}

Map<String, Object> _basePrefs({
  bool enabled = true,
  String? username = '202400000001',
  String? password = 'secret',
  int? depotId = 312,
  List<String>? meals,
  List<String>? activeDays,
  String? progresToken = 'valid-progres-jwt',
  String? onouToken = 'valid-onou-bearer',
  String? uuid = 'student-uuid-123',
  bool includeSession = true,
}) {
  final ctx = StudentContext(
    uuid: uuid ?? 'student-uuid-123',
    studentName: 'Test Student',
    anneeAcademiqueId: 2026,
    diaId: 1001,
    wilayaId: 25,
    residenceId: 500,
  );
  final map = <String, Object>{
    'webetu_bg_auto_reserve': enabled,
    'webetu_default_meals': meals ?? ['2', '3'],
    'webetu_active_days': activeDays ?? ['7', '1', '2', '3', '4'],
    'webetu_auto_window': 3,
  };
  if (username != null) map['webetu_username'] = username;
  if (password != null) map['webetu_password'] = password;
  if (depotId != null) map['webetu_default_depot'] = depotId;
  if (includeSession && progresToken != null && onouToken != null && uuid != null) {
    map['webetu_progres_token'] = progresToken;
    map['webetu_onou_token'] = onouToken;
    map['webetu_student_uuid'] = uuid;
    map['webetu_student_context'] = jsonEncode(ctx.toJson());
  }
  return map;
}

http.Response _jsonResp(dynamic body, [int status = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json'},
  );
}

Map<String, dynamic> _reservationJson(String date, int mealType, {int id = 1}) {
  final fr = mealType == 1
      ? 'Petit-déjeuner'
      : mealType == 2
          ? 'Déjeuner'
          : 'Dîner';
  final ar = mealType == 1
      ? 'فطور'
      : mealType == 2
          ? 'غداء'
          : 'عشاء';
  return {
    'id': id,
    'date_reserve': date,
    'mealtype_fr': fr,
    'mealtype_ar': ar,
    'depot_fr': 'Resto Central',
    'depot_ar': 'المطعم المركزي',
    'candelete': true,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed Monday: 2026-11-16 (weekday == 1).
  // Day +1: Tue 2026-11-17 (2), Day +2: Wed 2026-11-18 (3), Day +3: Thu 2026-11-19 (4) -> all active!
  final monday = DateTime(2026, 11, 16, 20, 0);

  test('1. Auto-fetches & persists missing depotId, books and server-verifies all 6 meals', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(depotId: null));
    final prefs = await SharedPreferences.getInstance();

    final serverDb = <Map<String, dynamic>>[];
    int nextId = 1;

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/getdepotres')) {
        return _jsonResp({
          'depots': [
            {'id': 312, 'nameFR': 'Resto Central', 'nameAR': 'المطعم المركزي'}
          ]
        });
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return _jsonResp({'data': serverDb});
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final detail = jsonDecode((body['details'] as List).first as String) as Map<String, dynamic>;
        expect(detail['idDepot'], 312);
        serverDb.add(_reservationJson(detail['date_reserve'], detail['menu_type'], id: nextId++));
        return _jsonResp({'status': 'ok'});
      }
      return http.Response('Not found', 404);
    });

    final notifications = <_SentNotification>[];
    final api = WebetuApiService(client: client, retryDelay: Duration.zero);

    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );

    expect(outcome.shouldRetryLater, isFalse);
    expect(outcome.status, 'success');
    expect(outcome.newlyReservedCount, 6);
    expect(outcome.totalConfirmedCount, 6);
    expect(outcome.totalExpectedCount, 6);
    expect(outcome.unconfirmedTomorrowCount, 0);
    expect(prefs.getInt('webetu_default_depot'), 312);
    expect(notifications.length, 1);
    expect(notifications.first.isAlert, isFalse);
  });

  test('2. 2FA user with expired onouToken silently renews via loginpwebetu without 2FA', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(onouToken: 'expired-onou-token'));
    final prefs = await SharedPreferences.getInstance();

    final serverDb = <Map<String, dynamic>>[];
    bool progresLoginCalled = false;
    int loginOnouCalls = 0;

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/authentication/v1/')) {
        progresLoginCalled = true;
        return http.Response('{"error":"mfaKey is required"}', 400);
      }
      if (req.url.path.endsWith('/api/loginpwebetu')) {
        loginOnouCalls++;
        return http.Response(jsonEncode({'token': 'fresh-onou-token-999'}), 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        if (req.headers['authorization'] != 'Bearer fresh-onou-token-999') {
          return http.Response('{"message":"Unauthenticated"}', 401);
        }
        return _jsonResp({'data': serverDb});
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        expect(req.headers['authorization'], 'Bearer fresh-onou-token-999');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final detail = jsonDecode((body['details'] as List).first as String) as Map<String, dynamic>;
        serverDb.add(_reservationJson(detail['date_reserve'], detail['menu_type']));
        return http.Response(jsonEncode({'success': true}), 200);
      }
      return http.Response('Not found', 404);
    });

    final api = WebetuApiService(client: client, retryDelay: Duration.zero);
    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
    );

    expect(progresLoginCalled, isFalse);
    expect(loginOnouCalls, 1);
    expect(prefs.getString('webetu_onou_token'), 'fresh-onou-token-999');
    expect(outcome.status, 'success');
    expect(outcome.totalConfirmedCount, 6);
    expect(outcome.shouldRetryLater, isFalse);
  });

  test('3. Transient 503 outage on getReservations does NOT trigger false 2FA login and schedules retry', () async {
    SharedPreferences.setMockInitialValues(_basePrefs());
    final prefs = await SharedPreferences.getInstance();

    bool progresLoginCalled = false;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/authentication/v1/')) {
        progresLoginCalled = true;
        return http.Response('{"error":"mfaKey is required"}', 400);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return http.Response('Service Unavailable', 503);
      }
      return http.Response('Not found', 404);
    });

    final api = WebetuApiService(client: client, retryDelay: Duration.zero);
    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
    );

    expect(progresLoginCalled, isFalse);
    expect(outcome.requiresReauth, isFalse);
    expect(outcome.shouldRetryLater, isTrue);
    expect(outcome.status, 'error');
  });

  test('4. Genuinely expired progresToken on 2FA account sends alert notification and throttles duplicates', () async {
    SharedPreferences.setMockInitialValues(_basePrefs());
    final prefs = await SharedPreferences.getInstance();

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student') ||
          req.url.path.endsWith('/api/loginpwebetu')) {
        return http.Response('{"message":"Token expired"}', 401);
      }
      if (req.url.path.endsWith('/api/authentication/v1/')) {
        return http.Response('{"error":"mfaKey is required"}', 400);
      }
      return http.Response('Not found', 404);
    });

    final notifications = <_SentNotification>[];
    final api = WebetuApiService(client: client, retryDelay: Duration.zero);

    final first = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );

    expect(first.requiresReauth, isTrue);
    expect(first.shouldRetryLater, isFalse);
    expect(notifications.length, 1);
    expect(notifications.first.isAlert, isTrue);
    expect(notifications.first.title, contains('2FA'));

    // Second run 1 hour later should be throttled (no spam)
    await ReservationEngine.run(
      prefs: prefs,
      api: WebetuApiService(client: client, retryDelay: Duration.zero),
      now: monday.add(const Duration(hours: 1)),
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );
    expect(notifications.length, 1);
  });

  test('5. Retries on 403 Expired request with fresh HMAC signature and succeeds', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(meals: ['2']));
    final prefs = await SharedPreferences.getInstance();

    final serverDb = <Map<String, dynamic>>[];
    int reserveCalls = 0;
    final seenNonces = <String>{};

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return _jsonResp({'data': serverDb});
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        reserveCalls++;
        final nonce = req.headers['X-Nonce']!;
        seenNonces.add(nonce);
        if (reserveCalls == 1) {
          return http.Response('{"message":"Expired request"}', 403);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final detail = jsonDecode((body['details'] as List).first as String) as Map<String, dynamic>;
        serverDb.add(_reservationJson(detail['date_reserve'], detail['menu_type']));
        return http.Response('{"status":"ok"}', 200);
      }
      return http.Response('Not found', 404);
    });

    final api = WebetuApiService(client: client, retryDelay: Duration.zero);
    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
    );

    expect(outcome.status, 'success');
    expect(outcome.totalConfirmedCount, 3);
    expect(seenNonces.length, reserveCalls); // Every retry generated a fresh nonce!
  });

  test('6. Server verification catches silent HTTP 200 drop and retries until truly confirmed on ONOU', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(meals: ['2']));
    final prefs = await SharedPreferences.getInstance();

    final serverDb = <Map<String, dynamic>>[];
    final attemptsByDate = <String, int>{};

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return _jsonResp({'data': serverDb});
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final detail = jsonDecode((body['details'] as List).first as String) as Map<String, dynamic>;
        final date = detail['date_reserve'] as String;
        attemptsByDate[date] = (attemptsByDate[date] ?? 0) + 1;

        // On first attempt for 2026-11-17, return HTTP 200 WITHOUT actually persisting to serverDb!
        if (date == '2026-11-17' && attemptsByDate[date] == 1) {
          return http.Response('{"ok": true}', 200);
        }
        serverDb.add(_reservationJson(date, detail['menu_type']));
        return http.Response('{"ok": true}', 200);
      }
      return http.Response('Not found', 404);
    });

    final api = WebetuApiService(client: client, retryDelay: Duration.zero);
    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
    );

    // Pass 2 verification caught that 2026-11-17 was missing on server and booked it on attempt 2!
    expect(attemptsByDate['2026-11-17'], 2);
    expect(outcome.status, 'success');
    expect(outcome.totalConfirmedCount, 3);
    expect(outcome.unconfirmedTomorrowCount, 0);
    expect(outcome.shouldRetryLater, isFalse);
  });

  test('7. HTTP 200 with {"success":false} is NOT falsely marked as reserved; alerts when tomorrow fails', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(meals: ['2']));
    final prefs = await SharedPreferences.getInstance();

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return http.Response(jsonEncode({'data': []}), 200);
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        return _jsonResp({'success': false, 'message': 'Quota dépassé'});
      }
      return http.Response('Not found', 404);
    });

    final notifications = <_SentNotification>[];
    final api = WebetuApiService(client: client, retryDelay: Duration.zero);
    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );

    expect(outcome.status, 'error');
    expect(outcome.totalConfirmedCount, 0);
    expect(outcome.unconfirmedTomorrowCount, 1);
    expect(notifications.length, 1);
    expect(notifications.first.isAlert, isTrue);
  });

  test('8. Persistent 503 during reserveMeals returns shouldRetryLater=true and alerts user', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(meals: ['2']));
    final prefs = await SharedPreferences.getInstance();

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return http.Response(jsonEncode({'data': []}), 200);
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        return http.Response('Bad Gateway', 502);
      }
      return http.Response('Not found', 404);
    });

    final notifications = <_SentNotification>[];
    final api = WebetuApiService(client: client, retryDelay: Duration.zero);
    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: api,
      now: monday,
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );

    expect(outcome.shouldRetryLater, isTrue);
    expect(outcome.unconfirmedTomorrowCount, 1);
    expect(notifications.length, 1);
    expect(notifications.first.isAlert, isTrue);
  });

  test('9. Routine check when all meals already reserved stays quiet; manual test notifies', () async {
    SharedPreferences.setMockInitialValues(_basePrefs(meals: ['2']));
    final prefs = await SharedPreferences.getInstance();

    final serverDb = [
      _reservationJson('2026-11-17', 2, id: 1),
      _reservationJson('2026-11-18', 2, id: 2),
      _reservationJson('2026-11-19', 2, id: 3),
    ];

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return _jsonResp({'data': serverDb});
      }
      return http.Response('Should not reserve again', 500);
    });

    final notifications = <_SentNotification>[];
    final routine = await ReservationEngine.run(
      prefs: prefs,
      api: WebetuApiService(client: client, retryDelay: Duration.zero),
      now: monday,
      isManualTest: false,
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );

    expect(routine.status, 'success');
    expect(routine.newlyReservedCount, 0);
    expect(routine.totalConfirmedCount, 3);
    expect(routine.shouldRetryLater, isFalse);
    expect(notifications, isEmpty); // No spam!

    final manual = await ReservationEngine.run(
      prefs: prefs,
      api: WebetuApiService(client: client, retryDelay: Duration.zero),
      now: monday,
      isManualTest: true,
      verifyRetryDelay: Duration.zero,
      notify: ({required title, required body, bool isAlert = false}) async {
        notifications.add(_SentNotification(title, body, isAlert));
      },
    );

    expect(manual.status, 'success');
    expect(notifications.length, 1); // Manual test ALWAYS confirms via notification!
    expect(notifications.first.isAlert, isFalse);
  });

  test('10. Active days Sun-Thu skips Fri & Sat and reserves Sunday (Day +3 on Thursday)', () async {
    // Thursday 2026-11-19 (weekday == 4)
    // +1 = Fri 2026-11-20 (5 - skipped), +2 = Sat 2026-11-21 (6 - skipped), +3 = Sun 2026-11-22 (7 - ACTIVE!)
    final thursday = DateTime(2026, 11, 19, 19, 0);
    SharedPreferences.setMockInitialValues(_basePrefs(
      meals: ['2'],
      activeDays: ['7', '1', '2', '3', '4'],
      password: null, // Also verifies booking works with saved session even when password is null!
    ));
    final prefs = await SharedPreferences.getInstance();

    final serverDb = <Map<String, dynamic>>[];
    final bookedDates = <String>[];

    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/infos/configuration')) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/api/meal-reservations/student')) {
        return _jsonResp({'data': serverDb});
      }
      if (req.url.path.endsWith('/api/reservemeal')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final detail = jsonDecode((body['details'] as List).first as String) as Map<String, dynamic>;
        bookedDates.add(detail['date_reserve']);
        serverDb.add(_reservationJson(detail['date_reserve'], detail['menu_type']));
        return http.Response('{"ok": true}', 200);
      }
      return http.Response('Not found', 404);
    });

    final outcome = await ReservationEngine.run(
      prefs: prefs,
      api: WebetuApiService(client: client, retryDelay: Duration.zero),
      now: thursday,
      verifyRetryDelay: Duration.zero,
    );

    expect(bookedDates, ['2026-11-22']);
    expect(outcome.newlyReservedCount, 1);
    expect(outcome.totalConfirmedCount, 1);
    expect(outcome.totalExpectedCount, 1);
    expect(outcome.status, 'success');
  });

  test('11. validateAndRefreshSession distinguishes networkError vs refreshed vs expired', () async {
    final ctx = StudentContext(uuid: 'u1', studentName: 'S', wilayaId: 25, residenceId: 1);

    // Offline -> networkError (must NOT kick 2FA user back to login screen!)
    final offlineApi = WebetuApiService(
      client: MockClient((_) async => throw const SocketException('No internet')),
      retryDelay: Duration.zero,
    )..restoreSession(
        progresToken: 'p',
        onouToken: 'o',
        studentUuid: 'u1',
        studentContext: ctx,
      );
    expect(await offlineApi.validateAndRefreshSession(), SessionStatus.networkError);

    // Expired onouToken + valid progresToken -> refreshed!
    final refreshApi = WebetuApiService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/api/infos/configuration')) return http.Response('{}', 200);
        if (req.url.path.endsWith('/api/loginpwebetu')) {
          return http.Response(jsonEncode({'token': 'new-onou'}), 200);
        }
        if (req.url.path.endsWith('/api/meal-reservations/student')) {
          if (req.headers['authorization'] == 'Bearer new-onou') {
            return http.Response('{"data":[]}', 200);
          }
          return http.Response('Unauthorized', 401);
        }
        return http.Response('', 404);
      }),
      retryDelay: Duration.zero,
    )..restoreSession(
        progresToken: 'p',
        onouToken: 'old-onou',
        studentUuid: 'u1',
        studentContext: ctx,
      );
    expect(await refreshApi.validateAndRefreshSession(), SessionStatus.refreshed);
    expect(refreshApi.onouToken, 'new-onou');

    // Both tokens expired -> expired!
    final expiredApi = WebetuApiService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/api/infos/configuration')) return http.Response('{}', 200);
        return http.Response('Unauthorized', 401);
      }),
      retryDelay: Duration.zero,
    )..restoreSession(
        progresToken: 'dead-p',
        onouToken: 'dead-o',
        studentUuid: 'u1',
        studentContext: ctx,
      );
    expect(await expiredApi.validateAndRefreshSession(), SessionStatus.expired);
  });
}
