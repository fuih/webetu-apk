import 'package:flutter/material.dart';
import '../services/webetu_api_service.dart';
import '../services/preferences_service.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  final WebetuApiService apiService;
  final PreferencesService prefsService;

  const LoginScreen({
    super.key,
    required this.apiService,
    required this.prefsService,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _mfaController = TextEditingController();

  bool _rememberMe = true;
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _showMfaInput = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  void _loadSavedCredentials() {
    final savedUser = widget.prefsService.savedUsername;
    final savedPass = widget.prefsService.savedPassword;
    final remember = widget.prefsService.rememberMe;

    if (remember && savedUser != null && savedPass != null) {
      _usernameController.text = savedUser;
      _passwordController.text = savedPass;
      setState(() {
        _rememberMe = true;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _mfaController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    final mfaCode = _showMfaInput ? _mfaController.text.trim() : null;

    if (_showMfaInput && (mfaCode == null || mfaCode.length < 6)) {
      setState(() {
        _errorMessage = 'Veuillez saisir le code à 6 chiffres de votre application Authenticator.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final studentCtx = await widget.apiService.authenticate(
        username,
        password,
        mfaKey: mfaCode,
      );

      // Save or clear credentials
      await widget.prefsService.saveCredentials(
        username: username,
        password: password,
        rememberMe: _rememberMe,
      );

      if (_rememberMe &&
          widget.apiService.progresToken != null &&
          widget.apiService.onouToken != null &&
          widget.apiService.studentUuid != null) {
        await widget.prefsService.saveSession(
          progresToken: widget.apiService.progresToken!,
          onouToken: widget.apiService.onouToken!,
          studentUuid: widget.apiService.studentUuid!,
          studentContext: studentCtx,
        );
      }

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
    } on MfaRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _showMfaInput = true;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header Logo & Titles
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.restaurant_rounded,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'WebEtu Resto',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'حجز الإطعام الجامعي التلقائي',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Réservation automatique des repas ONOU',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Login Card
                    Card(
                      elevation: 3,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Identifiants WebEtu / PROGRES',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Username / BAC Matricule
                              TextFormField(
                                controller: _usernameController,
                                keyboardType: TextInputType.text,
                                textInputAction: TextInputAction.next,
                                decoration: InputDecoration(
                                  labelText: 'Matricule BAC (Nom d\'utilisateur)',
                                  hintText: 'Ex: 2024xxxxxxxx',
                                  prefixIcon: const Icon(Icons.badge_outlined),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                ),
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Veuillez saisir votre matricule';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),

                              // Password
                              TextFormField(
                                controller: _passwordController,
                                obscureText: _obscurePassword,
                                textInputAction: TextInputAction.done,
                                onFieldSubmitted: (_) => _handleLogin(),
                                decoration: InputDecoration(
                                  labelText: 'Mot de passe PROGRES',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscurePassword = !_obscurePassword;
                                      });
                                    },
                                  ),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                ),
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Veuillez saisir votre mot de passe';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 10),

                              // Remember Me Switch
                              Row(
                                children: [
                                  Checkbox(
                                    value: _rememberMe,
                                    onChanged: (val) {
                                      setState(() {
                                        _rememberMe = val ?? true;
                                      });
                                    },
                                  ),
                                  const Text('Se souvenir de moi'),
                                ],
                              ),

                              // 2FA / MFA Code Section (appears if account requires 2FA)
                              if (_showMfaInput) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDDF4ED),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: const Color(0xFF00796B).withValues(alpha: 0.3)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: const [
                                          Icon(Icons.security_rounded, color: Color(0xFF00796B), size: 20),
                                          SizedBox(width: 8),
                                          Text(
                                            'Double authentification (2FA)',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                              color: Color(0xFF005D52),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      const Text(
                                        'Ouvrez votre application d\'authentification (Google Authenticator, Authy...) et saisissez le code à 6 chiffres.',
                                        style: TextStyle(fontSize: 12, color: Color(0xFF235F53), height: 1.3),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _mfaController,
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.done,
                                  maxLength: 6,
                                  textAlign: TextAlign.center,
                                  autofocus: true,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 8,
                                    color: Color(0xFF00796B),
                                  ),
                                  decoration: InputDecoration(
                                    counterText: '',
                                    labelText: 'Code de sécurité (6 chiffres)',
                                    hintText: '123456',
                                    hintStyle: TextStyle(
                                      letterSpacing: 8,
                                      color: Colors.grey.shade400,
                                      fontWeight: FontWeight.normal,
                                    ),
                                    prefixIcon: const Icon(Icons.pin_rounded, color: Color(0xFF00796B)),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFF00796B), width: 2),
                                    ),
                                    filled: true,
                                    fillColor: const Color(0xFFF8F9FA),
                                  ),
                                  onChanged: (val) {
                                    if (val.trim().length == 6) {
                                      _handleLogin();
                                    }
                                  },
                                  onFieldSubmitted: (_) => _handleLogin(),
                                ),
                              ],

                              if (_errorMessage != null) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.errorContainer,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _errorMessage!,
                                          style: TextStyle(
                                            color: theme.colorScheme.onErrorContainer,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              const SizedBox(height: 20),

                              // Login Button
                              FilledButton.icon(
                                onPressed: _isLoading ? null : _handleLogin,
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                icon: _isLoading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : Icon(_showMfaInput ? Icons.verified_user_rounded : Icons.login_rounded),
                                label: Text(
                                  _isLoading
                                      ? (_showMfaInput ? 'Validation du code...' : 'Connexion en cours...')
                                      : (_showMfaInput ? 'Valider le code 2FA' : 'Se connecter'),
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                              ),

                              if (_showMfaInput) ...[
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _showMfaInput = false;
                                      _errorMessage = null;
                                      _mfaController.clear();
                                    });
                                  },
                                  child: const Text('Retour à la saisie des identifiants', style: TextStyle(fontSize: 12)),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),
                    Text(
                      'Connexion sécurisée via l\'API officielle PROGRES & ONOU',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
