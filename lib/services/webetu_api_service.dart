import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:uuid/uuid.dart';

import '../models/restaurant.dart';
import '../models/reservation.dart';
import '../models/student_context.dart';

class WebetuHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

class MfaRequiredException implements Exception {
  final String message;
  MfaRequiredException([this.message = 'Code de vérification 2FA (MFA) requis.']);
  @override
  String toString() => message;
}

class ApiHttpException implements Exception {
  final int statusCode;
  final String message;
  final String body;

  ApiHttpException({
    required this.statusCode,
    required this.message,
    this.body = '',
  });

  bool get isExpiredRequest =>
      statusCode == 403 && body.toLowerCase().contains('expired request');

  bool get isAuthError =>
      statusCode == 401 || (statusCode == 403 && !isExpiredRequest);

  bool get isTransient =>
      isExpiredRequest || statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => message;
}

enum SessionStatus {
  valid,
  refreshed,
  expired,
  networkError,
}

class ReservationResultItem {
  final int mealType;
  final String mealName;
  final String date;
  final String status; // 'success', 'already_reserved', 'failed', 'error'
  final String message;
  final bool isTransientError;
  final int? statusCode;

  ReservationResultItem({
    required this.mealType,
    required this.mealName,
    required this.date,
    required this.status,
    required this.message,
    this.isTransientError = false,
    this.statusCode,
  });

  bool get isSuccess => status == 'success';
  bool get isSkipped => status == 'already_reserved';
  bool get isConfirmed => isSuccess || isSkipped;
}

class WebetuApiService {
  static const String hmacSecret = "pUzHUW2WX54uCzhO8JC2eQ6g1Ol21upw";
  static const String defaultBaseProgres = "https://api-webetu.mesrs.dz";
  static const String defaultBaseOnou = "https://gs-api.onou.dz";

  static const Map<int, String> mealNames = {
    1: "Petit-déjeuner (Breakfast / فطور)",
    2: "Déjeuner (Lunch / غداء)",
    3: "Dîner (Dinner / عشاء)",
  };

  static const Map<int, String> mealShortNames = {
    1: "Petit-déjeuner",
    2: "Déjeuner",
    3: "Dîner",
  };

  String baseProgres = defaultBaseProgres;
  String baseOnou = defaultBaseOnou;

  late final http.Client _client;
  final Duration retryDelay;
  Future<void> Function(String newOnouToken)? onOnouTokenRefreshed;

  String? progresToken;
  String? studentUuid;
  StudentContext? studentContext;
  String? onouToken;
  String? currentUsername;

  WebetuApiService({
    http.Client? client,
    this.retryDelay = const Duration(milliseconds: 1500),
    this.onOnouTokenRefreshed,
  }) {
    if (client != null) {
      _client = client;
    } else {
      final io = HttpClient();
      io.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      io.connectionTimeout = const Duration(seconds: 20);
      _client = IOClient(io);
    }
  }

  bool get isAuthenticated => progresToken != null && onouToken != null;

  bool get canRefreshOnou =>
      progresToken != null &&
      progresToken!.isNotEmpty &&
      studentUuid != null &&
      studentUuid!.isNotEmpty &&
      studentContext != null;

  void restoreSession({
    required String progresToken,
    required String onouToken,
    required String studentUuid,
    required StudentContext studentContext,
    String? username,
  }) {
    this.progresToken = progresToken;
    this.onouToken = onouToken;
    this.studentUuid = studentUuid;
    this.studentContext = studentContext;
    if (username != null) currentUsername = username;
  }

  static String _decodeBody(http.Response resp) {
    try {
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } catch (_) {
      return resp.body;
    }
  }

  static bool _isExpiredRequestResponse(http.Response resp) {
    return resp.statusCode == 403 && _decodeBody(resp).toLowerCase().contains('expired request');
  }

  static bool _isRetryableStatus(http.Response resp) {
    return _isExpiredRequestResponse(resp) ||
        resp.statusCode == 408 ||
        resp.statusCode == 429 ||
        resp.statusCode >= 500;
  }

  static bool _isAuthStatus(http.Response resp) {
    return resp.statusCode == 401 || (resp.statusCode == 403 && !_isExpiredRequestResponse(resp));
  }

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() requestFn, {
    int maxAttempts = 3,
    Duration timeout = const Duration(seconds: 18),
  }) async {
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final resp = await requestFn().timeout(timeout);
        if (_isRetryableStatus(resp) && attempt < maxAttempts) {
          if (retryDelay > Duration.zero) {
            await Future.delayed(retryDelay * attempt);
          }
          continue;
        }
        return resp;
      } on TimeoutException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      } on HandshakeException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts && retryDelay > Duration.zero) {
        await Future.delayed(retryDelay * attempt);
      }
    }
    throw lastError ?? Exception("Erreur réseau après $maxAttempts tentatives.");
  }

  /// Quickly tests if the currently restored session tokens are still valid on ONOU / PROGRES.
  /// If only the ONOU token expired while the PROGRES token is still valid, silently refreshes
  /// the ONOU token via `/api/loginpwebetu` without requiring a new login or 2FA code.
  Future<SessionStatus> validateAndRefreshSession() async {
    if (!isAuthenticated) return SessionStatus.expired;
    try {
      await fetchRemoteConfig();
      final url = Uri.parse('$baseOnou/api/meal-reservations/student')
          .replace(queryParameters: _buildQueryParams());

      final resp = await _sendWithRetry(
        () => _client.get(url, headers: _signHeaders('', auth: onouToken, isBearer: true)),
        maxAttempts: 2,
        timeout: const Duration(seconds: 10),
      );

      if (resp.statusCode == 200) {
        return SessionStatus.valid;
      }

      if (_isAuthStatus(resp) && canRefreshOnou) {
        try {
          await loginOnou();
          final retryResp = await _sendWithRetry(
            () => _client.get(url, headers: _signHeaders('', auth: onouToken, isBearer: true)),
            maxAttempts: 2,
            timeout: const Duration(seconds: 10),
          );
          if (retryResp.statusCode == 200) {
            return SessionStatus.refreshed;
          }
          if (_isAuthStatus(retryResp)) {
            return SessionStatus.expired;
          }
          return SessionStatus.networkError;
        } on ApiHttpException catch (e) {
          return e.isAuthError ? SessionStatus.expired : SessionStatus.networkError;
        } catch (_) {
          return SessionStatus.networkError;
        }
      }

      if (_isAuthStatus(resp)) {
        return SessionStatus.expired;
      }
      return SessionStatus.networkError;
    } catch (_) {
      return SessionStatus.networkError;
    }
  }

  Future<bool> validateSession() async {
    final status = await validateAndRefreshSession();
    return status == SessionStatus.valid || status == SessionStatus.refreshed;
  }

  Map<String, String> _signHeaders(String dataStr, {String? auth, bool isBearer = false}) {
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final nonce = const Uuid().v4();
    final message = '$timestamp|$nonce|$dataStr';

    final hmacSha256 = Hmac(sha256, utf8.encode(hmacSecret));
    final signature = hmacSha256.convert(utf8.encode(message)).toString();

    final headers = <String, String>{
      'X-Timestamp': timestamp,
      'X-Nonce': nonce,
      'X-Signature': signature,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': 'okhttp/4.9.2 Webetu/2.5.0',
    };

    if (auth != null && auth.isNotEmpty) {
      headers['authorization'] = isBearer ? 'Bearer $auth' : auth;
    }

    return headers;
  }

  Future<void> fetchRemoteConfig() async {
    try {
      final url = Uri.parse('$baseProgres/api/infos/configuration');
      final resp = await _client.get(url).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) {
          if (data['urlApiProgres'] != null && data['urlApiProgres'].toString().isNotEmpty) {
            baseProgres = data['urlApiProgres'].toString();
          }
          if (data['urlApiOnou'] != null && data['urlApiOnou'].toString().isNotEmpty) {
            baseOnou = data['urlApiOnou'].toString();
          }
        }
      }
    } catch (_) {
      // Fallback to default hardcoded endpoints
    }
  }

  /// Exchanges an active PROGRES token + student context for a fresh ONOU Bearer token.
  /// Works for 2FA accounts without requiring a new 6-digit TOTP code as long as progresToken is valid.
  Future<String> loginOnou() async {
    if (!canRefreshOnou) {
      throw ApiHttpException(
        statusCode: 401,
        message: "Contexte PROGRES manquant pour renouveler la session ONOU.",
      );
    }

    final onouUrl = Uri.parse('$baseOnou/api/loginpwebetu');
    final onouPayload = jsonEncode({
      'uuid': studentUuid,
      'wilaya': studentContext!.wilayaId,
      'residence': studentContext!.residenceId,
      'token': progresToken,
    });

    final onouResp = await _sendWithRetry(
      () => _client.post(onouUrl, body: onouPayload, headers: _signHeaders(onouPayload)),
      maxAttempts: 3,
      timeout: const Duration(seconds: 15),
    );

    if (onouResp.statusCode != 200) {
      throw ApiHttpException(
        statusCode: onouResp.statusCode,
        message: "Échec de connexion au service ONOU (${onouResp.statusCode}): ${onouResp.body}",
        body: onouResp.body,
      );
    }

    final onouData = jsonDecode(onouResp.body);
    String? newToken;
    if (onouData is Map<String, dynamic>) {
      newToken = (onouData['token'] ?? onouData['data']?['token'] ?? onouData['accessToken'])?.toString();
    } else if (onouData is String) {
      newToken = onouData;
    }

    if (newToken == null || newToken.isEmpty) {
      throw Exception("Échec de récupération du token ONOU.");
    }

    onouToken = newToken;
    if (onOnouTokenRefreshed != null) {
      try {
        await onOnouTokenRefreshed!(newToken);
      } catch (_) {}
    }
    return newToken;
  }

  /// Full automated authentication workflow:
  /// 1. PROGRES Login (with optional mfaKey for 2FA) -> 2. Context resolution -> 3. ONOU SSO Login
  Future<StudentContext> authenticate(
    String username,
    String password, {
    String? mfaKey,
  }) async {
    currentUsername = username;
    await fetchRemoteConfig();

    // 1. PROGRES Login
    final loginUrl = Uri.parse('$baseProgres/api/authentication/v1/');
    final Map<String, dynamic> bodyMap = {
      'username': username,
      'password': password,
    };
    if (mfaKey != null && mfaKey.trim().isNotEmpty) {
      bodyMap['mfaKey'] = mfaKey.trim();
    }
    final payload = jsonEncode(bodyMap);

    final resp = await _sendWithRetry(
      () => _client.post(loginUrl, body: payload, headers: _signHeaders(payload)),
      maxAttempts: 3,
      timeout: const Duration(seconds: 20),
    );

    if (resp.statusCode != 200) {
      final bodyStr = resp.body;
      if (resp.statusCode == 400 && bodyStr.contains('mfaKey is required')) {
        throw MfaRequiredException(
          "Double authentification (2FA) requise. Veuillez saisir le code à 6 chiffres de votre application Authenticator.",
        );
      }
      if (resp.statusCode == 400 &&
          (bodyStr.contains('mfaKey') ||
              bodyStr.toLowerCase().contains('invalid') ||
              bodyStr.toLowerCase().contains('expire'))) {
        throw Exception("Code 2FA incorrect ou expiré. Veuillez vérifier sur votre application Authenticator.");
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw ApiHttpException(
          statusCode: resp.statusCode,
          message: "Matricule ou mot de passe incorrect (Invalid credentials).",
          body: bodyStr,
        );
      }
      throw ApiHttpException(
        statusCode: resp.statusCode,
        message: "Échec de connexion Webetu (${resp.statusCode}): $bodyStr",
        body: bodyStr,
      );
    }

    final loginData = jsonDecode(resp.body) as Map<String, dynamic>;
    progresToken = loginData['token'];
    studentUuid = loginData['uuid'];

    if (progresToken == null || studentUuid == null) {
      throw Exception("Réponse de connexion invalide: token ou uuid manquant.");
    }

    // 2. Fetch Student Context
    final authHeader = progresToken!;

    // 2.1 Academic Year
    final yearUrl = Uri.parse('$baseProgres/api/infos/AnneeAcademiqueEncours');
    final yearResp = await _sendWithRetry(
      () => _client.get(yearUrl, headers: _signHeaders('', auth: authHeader)),
      maxAttempts: 2,
      timeout: const Duration(seconds: 12),
    );
    int? yearId;
    if (yearResp.statusCode == 200) {
      final yearData = jsonDecode(yearResp.body);
      yearId = yearData['id'];
    }

    // 2.2 DIA
    final diaUrl = Uri.parse('$baseProgres/api/infos/bac/$studentUuid/anneeAcademique/$yearId/dia');
    final diaResp = await _sendWithRetry(
      () => _client.get(diaUrl, headers: _signHeaders('', auth: authHeader)),
      maxAttempts: 2,
      timeout: const Duration(seconds: 12),
    );

    int? diaId;
    String studentName = username;
    dynamic residenceId;

    if (diaResp.statusCode == 200) {
      final diaData = jsonDecode(diaResp.body) as Map<String, dynamic>;
      diaId = diaData['id'];
      final prenom = (diaData['individuPrenomLatin'] ?? '').toString();
      final nom = (diaData['individuNomLatin'] ?? '').toString();
      if (prenom.isNotEmpty || nom.isNotEmpty) {
        studentName = '$prenom $nom'.trim();
      }

      final hebergements = diaData['hebergement'] as List<dynamic>?;
      if (hebergements != null) {
        for (final h in hebergements) {
          if (h['idAnneeAcademique'] == yearId) {
            residenceId = h['idResidance'];
            break;
          }
        }
      }
    }

    if (residenceId == null) {
      try {
        final hebergUrl = Uri.parse('$baseProgres/api/infos/bac/$studentUuid/demandesHebregement');
        final hebergResp = await _sendWithRetry(
          () => _client.get(hebergUrl, headers: _signHeaders('', auth: authHeader)),
          maxAttempts: 2,
          timeout: const Duration(seconds: 10),
        );
        if (hebergResp.statusCode == 200) {
          final demandes = jsonDecode(hebergResp.body) as List<dynamic>?;
          if (demandes != null && demandes.isNotEmpty) {
            for (final d in demandes) {
              if (d['idAnneeAcademique'] == yearId || demandes.length == 1) {
                residenceId = d['idResidance'];
                break;
              }
            }
          }
        }
      } catch (_) {}
    }

    // 2.3 Wilaya
    dynamic wilayaId;
    if (diaId != null) {
      final wilayaUrl = Uri.parse('$baseProgres/api/infos/wilayaInscription/$diaId');
      final wilayaResp = await _sendWithRetry(
        () => _client.get(wilayaUrl, headers: _signHeaders('', auth: authHeader)),
        maxAttempts: 2,
        timeout: const Duration(seconds: 12),
      );
      if (wilayaResp.statusCode == 200) {
        final wData = jsonDecode(wilayaResp.body);
        if (wData is Map<String, dynamic>) {
          wilayaId = wData['id'] ?? (wData['data'] is Map ? wData['data']['id'] : wData['data']);
        } else {
          wilayaId = wData;
        }
      }
    }

    studentContext = StudentContext(
      uuid: studentUuid!,
      studentName: studentName,
      anneeAcademiqueId: yearId,
      diaId: diaId,
      wilayaId: wilayaId,
      residenceId: residenceId,
    );

    // 3. ONOU SSO Login
    await loginOnou();

    return studentContext!;
  }

  Map<String, String> _buildQueryParams() {
    final params = <String, String>{};
    if (studentUuid != null) params['uuid'] = studentUuid!;
    if (studentContext?.wilayaId != null) params['wilaya'] = studentContext!.wilayaId.toString();
    if (studentContext?.residenceId != null) params['residence'] = studentContext!.residenceId.toString();
    if (progresToken != null) params['token'] = progresToken!;
    return params;
  }

  Future<http.Response> _onouGetWithAutoRefresh(Uri url) async {
    var resp = await _sendWithRetry(
      () => _client.get(url, headers: _signHeaders('', auth: onouToken, isBearer: true)),
      maxAttempts: 3,
      timeout: const Duration(seconds: 15),
    );

    if (_isAuthStatus(resp) && canRefreshOnou) {
      await loginOnou();
      resp = await _sendWithRetry(
        () => _client.get(url, headers: _signHeaders('', auth: onouToken, isBearer: true)),
        maxAttempts: 2,
        timeout: const Duration(seconds: 15),
      );
    }

    return resp;
  }

  /// Fetches available university restaurants (depots)
  Future<List<Restaurant>> getRestaurants() async {
    if (!isAuthenticated) {
      throw ApiHttpException(statusCode: 401, message: "Session non authentifiée.");
    }

    final url = Uri.parse('$baseOnou/api/getdepotres').replace(queryParameters: _buildQueryParams());
    final resp = await _onouGetWithAutoRefresh(url);

    if (resp.statusCode != 200) {
      throw ApiHttpException(
        statusCode: resp.statusCode,
        message: "Impossible de récupérer la liste des restaurants (${resp.statusCode})",
        body: _decodeBody(resp),
      );
    }

    final dynamic parsed = jsonDecode(_decodeBody(resp));
    List<dynamic> items = [];
    if (parsed is Map) {
      if (parsed['depots'] is List) {
        items = parsed['depots'];
      } else if (parsed['data'] is Map && parsed['data']['depots'] is List) {
        items = parsed['data']['depots'];
      } else if (parsed['data'] is List) {
        items = parsed['data'];
      }
    } else if (parsed is List) {
      items = parsed;
    }

    return items.map((e) => Restaurant.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Fetches current confirmed meal reservations
  Future<List<Reservation>> getReservations() async {
    if (!isAuthenticated) {
      throw ApiHttpException(statusCode: 401, message: "Session non authentifiée.");
    }

    final url = Uri.parse('$baseOnou/api/meal-reservations/student').replace(queryParameters: _buildQueryParams());
    final resp = await _onouGetWithAutoRefresh(url);

    if (resp.statusCode != 200) {
      throw ApiHttpException(
        statusCode: resp.statusCode,
        message: "Impossible de récupérer les réservations (${resp.statusCode})",
        body: _decodeBody(resp),
      );
    }

    final dynamic parsed = jsonDecode(_decodeBody(resp));
    List<dynamic> items = [];
    if (parsed is Map) {
      if (parsed['data'] is List) {
        items = parsed['data'];
      }
    } else if (parsed is List) {
      items = parsed;
    }

    return items.map((e) => Reservation.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Checks if a meal is already booked for dateStr
  bool isAlreadyReserved(String dateStr, int mealType, List<Reservation> reservations) {
    final normalizedTarget = dateStr.trim();
    for (final r in reservations) {
      if (r.dateReserve.trim().startsWith(normalizedTarget)) {
        if (r.mealTypeId != null && r.mealTypeId == mealType) {
          return true;
        }

        final fr = r.mealTypeFr.toLowerCase();
        final ar = r.mealTypeAr;

        if (mealType == 1 &&
            (fr.contains('petit') || ar.contains('فطور') || ar.contains('إفطار') || ar.contains('افطار'))) {
          return true;
        }
        if (mealType == 2 &&
            (fr.contains('déjeuner') || fr.contains('dejeuner') || ar.contains('غداء')) &&
            !fr.contains('petit')) {
          return true;
        }
        if (mealType == 3 && (fr.contains('dîner') || fr.contains('diner') || ar.contains('عشاء'))) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _isDuplicateResponse(String bodyText) {
    final errStr = bodyText.toLowerCase();
    return errStr.contains('duplicate') ||
        errStr.contains('déjà une réservation') ||
        errStr.contains('deja une reservation') ||
        errStr.contains('déjà réservé') ||
        errStr.contains('deja reserve') ||
        errStr.contains('already reserved') ||
        bodyText.contains('محجوز') ||
        bodyText.contains('مسبقا');
  }

  static String? _extractHiddenFailureMessage(dynamic resJson) {
    if (resJson is! Map) return null;
    final successVal = resJson['success'];
    final statusVal = resJson['status'];
    final errorVal = resJson['error'];

    final isExplicitFail = successVal == false ||
        statusVal == false ||
        (statusVal is String &&
            (statusVal.toLowerCase() == 'error' || statusVal.toLowerCase() == 'failed')) ||
        (errorVal != null && errorVal.toString().trim().isNotEmpty && errorVal != false);

    if (!isExplicitFail) return null;

    if (resJson['message'] != null && resJson['message'].toString().trim().isNotEmpty) {
      return resJson['message'].toString();
    }
    if (errorVal != null && errorVal.toString().trim().isNotEmpty) {
      return errorVal.toString();
    }
    return "Le serveur a refusé la réservation.";
  }

  /// Reserves meals for a specific date with automatic retry on transient errors
  /// and silent ONOU token refresh if the bearer token expires mid-run.
  Future<List<ReservationResultItem>> reserveMeals({
    required String dateStr,
    required List<int> mealTypes,
    required int depotId,
    List<Reservation>? existingReservations,
  }) async {
    if (!isAuthenticated) {
      throw ApiHttpException(statusCode: 401, message: "Session non authentifiée.");
    }

    final reservations = existingReservations ?? await getReservations();
    final results = <ReservationResultItem>[];

    final url = Uri.parse('$baseOnou/api/reservemeal');

    for (final mealType in mealTypes) {
      final mealName = mealShortNames[mealType] ?? 'Type $mealType';

      // Duplicate check against already-fetched reservations
      if (isAlreadyReserved(dateStr, mealType, reservations)) {
        results.add(ReservationResultItem(
          mealType: mealType,
          mealName: mealName,
          date: dateStr,
          status: 'already_reserved',
          message: "Déjà réservé",
        ));
        continue;
      }

      final detailsStr = jsonEncode({
        'date_reserve': dateStr,
        'menu_type': mealType,
        'idDepot': depotId,
      });

      final payload = jsonEncode({
        'uuid': studentUuid,
        'wilaya': studentContext?.wilayaId,
        'residence': studentContext?.residenceId,
        'token': progresToken,
        'details': [detailsStr],
      });

      try {
        var resp = await _sendWithRetry(
          () => _client.post(
            url,
            body: payload,
            headers: _signHeaders(payload, auth: onouToken, isBearer: true),
          ),
          maxAttempts: 3,
          timeout: const Duration(seconds: 18),
        );

        // If ONOU token expired mid-run, silently refresh via progresToken and retry once
        if (_isAuthStatus(resp) && canRefreshOnou) {
          try {
            await loginOnou();
            resp = await _sendWithRetry(
              () => _client.post(
                url,
                body: payload,
                headers: _signHeaders(payload, auth: onouToken, isBearer: true),
              ),
              maxAttempts: 2,
              timeout: const Duration(seconds: 18),
            );
          } catch (_) {
            // Keep original auth failure response
          }
        }

        final bodyText = _decodeBody(resp);
        dynamic resJson;
        try {
          resJson = jsonDecode(bodyText);
        } catch (_) {
          resJson = bodyText;
        }

        if (_isDuplicateResponse(bodyText)) {
          results.add(ReservationResultItem(
            mealType: mealType,
            mealName: mealName,
            date: dateStr,
            status: 'already_reserved',
            message: "Déjà réservé sur le serveur",
            statusCode: resp.statusCode,
          ));
          continue;
        }

        if (resp.statusCode == 200 || resp.statusCode == 201) {
          final hiddenFailure = _extractHiddenFailureMessage(resJson);
          if (hiddenFailure != null) {
            results.add(ReservationResultItem(
              mealType: mealType,
              mealName: mealName,
              date: dateStr,
              status: 'failed',
              message: hiddenFailure,
              isTransientError: false,
              statusCode: resp.statusCode,
            ));
          } else {
            results.add(ReservationResultItem(
              mealType: mealType,
              mealName: mealName,
              date: dateStr,
              status: 'success',
              message: "Réservé avec succès!",
              statusCode: resp.statusCode,
            ));
          }
        } else {
          String msg = "Erreur HTTP ${resp.statusCode}";
          if (resJson is Map && resJson['message'] != null) {
            msg = resJson['message'].toString();
          }
          results.add(ReservationResultItem(
            mealType: mealType,
            mealName: mealName,
            date: dateStr,
            status: 'failed',
            message: msg,
            isTransientError: _isRetryableStatus(resp) || _isAuthStatus(resp),
            statusCode: resp.statusCode,
          ));
        }
      } catch (e) {
        results.add(ReservationResultItem(
          mealType: mealType,
          mealName: mealName,
          date: dateStr,
          status: 'error',
          message: "Erreur réseau: $e",
          isTransientError: true,
        ));
      }
    }

    return results;
  }

  /// Cancels an existing reservation
  Future<bool> cancelReservation(dynamic reservationId) async {
    if (!isAuthenticated) {
      throw ApiHttpException(statusCode: 401, message: "Session non authentifiée.");
    }

    final url = Uri.parse('$baseOnou/api/reservemeal/$reservationId');
    final payload = jsonEncode({
      'data': {
        'uuid': studentUuid,
        'wilaya': studentContext?.wilayaId,
        'residence': studentContext?.residenceId,
        'token': progresToken,
      }
    });

    var resp = await _sendWithRetry(
      () => _client.delete(
        url,
        body: payload,
        headers: _signHeaders(payload, auth: onouToken, isBearer: true),
      ),
      maxAttempts: 2,
      timeout: const Duration(seconds: 15),
    );

    if (_isAuthStatus(resp) && canRefreshOnou) {
      await loginOnou();
      resp = await _sendWithRetry(
        () => _client.delete(
          url,
          body: payload,
          headers: _signHeaders(payload, auth: onouToken, isBearer: true),
        ),
        maxAttempts: 2,
        timeout: const Duration(seconds: 15),
      );
    }

    if (resp.statusCode == 200 || resp.statusCode == 204) {
      return true;
    }
    throw ApiHttpException(
      statusCode: resp.statusCode,
      message: "Impossible d'annuler la réservation (HTTP ${resp.statusCode})",
      body: resp.body,
    );
  }

  void logout() {
    progresToken = null;
    studentUuid = null;
    studentContext = null;
    onouToken = null;
    currentUsername = null;
  }
}
