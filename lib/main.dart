import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'services/webetu_api_service.dart';
import 'services/preferences_service.dart';
import 'services/background_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = WebetuHttpOverrides();
  await initializeDateFormatting('fr_FR', null);
  await BackgroundReservationService.initialize();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  final prefsService = await PreferencesService.getInstance();
  final apiService = WebetuApiService();

  runApp(WebetuRestoApp(
    prefsService: prefsService,
    apiService: apiService,
  ));
}

class WebetuRestoApp extends StatelessWidget {
  final PreferencesService prefsService;
  final WebetuApiService apiService;

  const WebetuRestoApp({
    super.key,
    required this.prefsService,
    required this.apiService,
  });

  @override
  Widget build(BuildContext context) {
    const primaryTeal = Color(0xFF00796B);

    return MaterialApp(
      title: 'WebEtu Resto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryTeal,
          primary: primaryTeal,
          secondary: const Color(0xFFF57C00), // Orange for lunch/meals
          surface: const Color(0xFFFBFBFB),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      home: SplashScreen(
        prefsService: prefsService,
        apiService: apiService,
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  final PreferencesService prefsService;
  final WebetuApiService apiService;

  const SplashScreen({
    super.key,
    required this.prefsService,
    required this.apiService,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAutoLogin();
  }

  Future<void> _checkAutoLogin() async {
    final remember = widget.prefsService.rememberMe;
    final user = widget.prefsService.savedUsername;
    final pass = widget.prefsService.savedPassword;

    if (remember && user != null && pass != null && user.isNotEmpty && pass.isNotEmpty) {
      try {
        final studentCtx = await widget.apiService.authenticate(user, pass);
        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => HomeScreen(
              apiService: widget.apiService,
              prefsService: widget.prefsService,
              studentContext: studentCtx,
            ),
          ),
        );
        return;
      } catch (_) {
        // Fallback to login screen with prefilled credentials
      }
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          apiService: widget.apiService,
          prefsService: widget.prefsService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.restaurant_rounded,
                size: 64,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'WebEtu Resto',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'حجز الإطعام الجامعي',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
