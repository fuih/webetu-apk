import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/restaurant.dart';
import '../models/reservation.dart';
import '../models/student_context.dart';
import '../services/webetu_api_service.dart';
import '../services/preferences_service.dart';
import '../services/background_service.dart';
import '../services/reservation_engine.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  final WebetuApiService apiService;
  final PreferencesService prefsService;
  final StudentContext studentContext;

  const HomeScreen({
    super.key,
    required this.apiService,
    required this.prefsService,
    required this.studentContext,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentTabIndex = 0; // 0: Auto (Préférences), 1: Historique (Réservations)

  List<Restaurant> _restaurants = [];
  Restaurant? _selectedRestaurant;
  List<Reservation> _reservations = [];

  bool _isLoadingRestaurants = true;
  bool _isLoadingReservations = true;
  bool _isReservingNow = false;
  bool _isBackgroundEnabled = false;
  bool _isWorkScheduled = false;
  bool _isBatteryUnrestricted = true;
  bool _areNotificationsAllowed = true;
  bool _isRestrictedOem = false;
  bool _isTestingBackground = false;
  bool _hasTriggeredForegroundSafetyNet = false;

  // Selected meal types: 1 (Petit-déj), 2 (Déjeuner), 3 (Dîner)
  final Set<int> _selectedMeals = {2, 3};

  // Active days of the week: 7: Dimanche, 1: Lundi, 2: Mardi, 3: Mercredi, 4: Jeudi, 5: Vendredi, 6: Samedi
  final Set<int> _activeDays = {7, 1, 2, 3, 4};

  // Filter in Historique tab: 'all', 'reserved', 'tocheck'
  String _activeFilter = 'all';

  // Real-time reservation feedback items
  String? _lastExecutionSummary;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedMeals.clear();
    _selectedMeals.addAll(widget.prefsService.defaultMeals);
    _activeDays.clear();
    _activeDays.addAll(widget.prefsService.activeDaysOfWeek);
    _isBackgroundEnabled = widget.prefsService.isBackgroundAutoReserveEnabled;

    _loadInitialData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshOnResume();
    }
  }

  Future<void> _refreshOnResume() async {
    await widget.prefsService.reload();
    await _loadBackgroundDiagnostics();
    if (mounted) {
      setState(() {
        _isBackgroundEnabled = widget.prefsService.isBackgroundAutoReserveEnabled;
      });
    }
    await _loadReservations(silent: true);
  }

  Future<void> _loadInitialData() async {
    await widget.prefsService.reload();
    await Future.wait([
      _loadRestaurants(),
      _loadReservations(),
      _loadBackgroundDiagnostics(),
    ]);
    await _runForegroundSafetyNetIfNeeded();
  }

  Future<void> _loadBackgroundDiagnostics() async {
    try {
      await widget.prefsService.reload();
      if (_isBackgroundEnabled) {
        await BackgroundReservationService.ensureScheduledIfEnabled(true);
      }
      final results = await Future.wait<bool>([
        BackgroundReservationService.isDailyTaskScheduled(),
        BackgroundReservationService.isBatteryOptimizationIgnored(),
        BackgroundReservationService.areNotificationsEnabled(),
        BackgroundReservationService.isRestrictedOem(),
      ]);
      if (!mounted) return;
      setState(() {
        _isWorkScheduled = results[0];
        _isBatteryUnrestricted = results[1];
        _areNotificationsAllowed = results[2];
        _isRestrictedOem = results[3];
      });
    } catch (_) {}
  }

  Future<void> _persistCurrentConfigAndSession() async {
    await widget.prefsService.saveDefaultMeals(_selectedMeals.toList());
    await widget.prefsService.saveActiveDaysOfWeek(_activeDays);
    if (_selectedRestaurant != null) {
      await widget.prefsService.saveDefaultDepot(_selectedRestaurant!.id);
    }
    if (widget.apiService.progresToken != null &&
        widget.apiService.onouToken != null &&
        widget.apiService.studentUuid != null) {
      await widget.prefsService.saveSession(
        progresToken: widget.apiService.progresToken!,
        onouToken: widget.apiService.onouToken!,
        studentUuid: widget.apiService.studentUuid!,
        studentContext: widget.studentContext,
      );
    }
  }

  /// Belt-and-suspenders safety net: whenever the user opens the app while Auto-Reserve is ON,
  /// ensure their config/session is persisted and immediately fill any missing active meals in the 3-day window.
  Future<void> _runForegroundSafetyNetIfNeeded() async {
    if (_hasTriggeredForegroundSafetyNet || !_isBackgroundEnabled) return;
    if (_selectedRestaurant == null || _selectedMeals.isEmpty) return;
    _hasTriggeredForegroundSafetyNet = true;

    await _persistCurrentConfigAndSession();

    // Quick check if any upcoming active slot is missing before doing any POST calls
    final now = DateTime.now();
    final window = widget.prefsService.autoReserveWindow;
    bool hasMissingSlot = false;
    for (int i = 1; i <= window; i++) {
      final d = now.add(Duration(days: i));
      if (!_activeDays.contains(d.weekday)) continue;
      final dateStr = DateFormat('yyyy-MM-dd').format(d);
      for (final meal in _selectedMeals) {
        if (!widget.apiService.isAlreadyReserved(dateStr, meal, _reservations)) {
          hasMissingSlot = true;
          break;
        }
      }
      if (hasMissingSlot) break;
    }

    if (!hasMissingSlot) return;

    try {
      final rawPrefs = await SharedPreferences.getInstance();
      final outcome = await ReservationEngine.run(
        prefs: rawPrefs,
        api: widget.apiService,
        ignoreEnabledCheck: true,
      );
      await widget.prefsService.reload();
      if (!mounted) return;
      if (outcome.verifiedReservations.isNotEmpty) {
        final sorted = List<Reservation>.from(outcome.verifiedReservations)
          ..sort((a, b) => b.dateReserve.compareTo(a.dateReserve));
        setState(() {
          _reservations = sorted;
          if (outcome.newlyReservedCount > 0) {
            _lastExecutionSummary = outcome.summary;
          }
        });
      }
      if (outcome.newlyReservedCount > 0) {
        _showSnackbar('✓ ${outcome.summary}');
      }
    } catch (_) {}
  }

  Future<void> _loadRestaurants() async {
    setState(() => _isLoadingRestaurants = true);
    try {
      final list = await widget.apiService.getRestaurants();
      if (!mounted) return;

      Restaurant? chosen;
      bool shouldPersistDefault = false;
      final savedDepotId = widget.prefsService.defaultDepotId;
      if (savedDepotId != null && list.any((r) => r.id == savedDepotId)) {
        chosen = list.firstWhere((r) => r.id == savedDepotId);
      } else if (list.isNotEmpty) {
        chosen = list.first;
        shouldPersistDefault = true;
      }

      if (shouldPersistDefault && chosen != null) {
        await widget.prefsService.saveDefaultDepot(chosen.id);
      }

      if (!mounted) return;
      setState(() {
        _restaurants = list;
        _selectedRestaurant = chosen;
      });
    } catch (e) {
      if (!mounted) return;
      _showSnackbar('Erreur de chargement des restaurants: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingRestaurants = false);
    }
  }

  Future<void> _loadReservations({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoadingReservations = true);
    }
    try {
      final list = await widget.apiService.getReservations();
      if (!mounted) return;
      setState(() {
        list.sort((a, b) => b.dateReserve.compareTo(a.dateReserve));
        _reservations = list;
      });
    } catch (e) {
      if (!mounted || silent) return;
      _showSnackbar('Erreur de chargement des réservations: $e', isError: true);
    } finally {
      if (mounted && !silent) setState(() => _isLoadingReservations = false);
    }
  }

  void _showSnackbar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFC62828) : const Color(0xFF00796B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _toggleBackgroundReservation(bool value) async {
    if (value && _selectedRestaurant == null) {
      _showSnackbar('Veuillez d\'abord sélectionner votre restaurant.', isError: true);
      return;
    }
    if (value && _selectedMeals.isEmpty) {
      _showSnackbar('Veuillez activer au moins un repas.', isError: true);
      return;
    }

    setState(() {
      _isBackgroundEnabled = value;
    });

    await widget.prefsService.setBackgroundAutoReserveEnabled(value);

    if (value) {
      // Persist restaurant, meals, active days & session tokens BEFORE scheduling WorkManager!
      await _persistCurrentConfigAndSession();
      await BackgroundReservationService.enableDailyReservation(runImmediateSync: false);
      await _loadBackgroundDiagnostics();

      _showSnackbar('Pilote automatique activé ! Vérification toutes les 4h + réservation immédiate.');

      // Request notification permission and background battery optimization
      await BackgroundReservationService.requestNotificationPermission();
      await _loadBackgroundDiagnostics();

      if ((!_isBatteryUnrestricted || !_areNotificationsAllowed) && mounted) {
        await _showBackgroundOptimizationPrompt();
      }

      // Immediately book & verify upcoming meals so the student is covered right now
      if (mounted && !_isReservingNow) {
        await _runManualReserveNow();
      }
    } else {
      await BackgroundReservationService.disableDailyReservation();
      await _loadBackgroundDiagnostics();
      _showSnackbar('Pilote automatique mis en pause.');
    }
  }

  Future<void> _triggerBackgroundTest() async {
    if (_selectedRestaurant == null) {
      _showSnackbar('Veuillez d\'abord sélectionner un restaurant.', isError: true);
      return;
    }

    setState(() => _isTestingBackground = true);
    try {
      await _persistCurrentConfigAndSession();
      await BackgroundReservationService.requestNotificationPermission();
      await BackgroundReservationService.triggerBackgroundTest();
      _showSnackbar(
        'Test arrière-plan lancé via Android WorkManager ! Une notification va apparaître dans quelques secondes.',
      );

      // Refresh UI automatically after WorkManager finishes its headless run
      for (final waitSec in [4, 6]) {
        await Future.delayed(Duration(seconds: waitSec));
        if (!mounted) return;
        await _loadBackgroundDiagnostics();
        await _loadReservations(silent: true);
      }
    } catch (e) {
      _showSnackbar('Erreur lors du lancement du test : $e', isError: true);
    } finally {
      if (mounted) setState(() => _isTestingBackground = false);
    }
  }

  Future<void> _showBackgroundOptimizationPrompt() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E7E5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDDF4ED),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.bolt_rounded, color: Color(0xFF00796B), size: 24),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Autorisation d\'arrière-plan',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF172E2B),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Pour garantir que WebEtu Resto réserve automatiquement vos repas chaque soir même si vous n\'ouvrez pas l\'application :',
              style: TextStyle(fontSize: 13, color: Color(0xFF637571), height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE0E7E5)),
              ),
              child: Column(
                children: [
                  Row(
                    children: const [
                      Icon(Icons.notifications_active_rounded, color: Color(0xFF00796B), size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Notifications : pour vous alerter du succès de la réservation.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF172E2B)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: const [
                      Icon(Icons.battery_charging_full_rounded, color: Color(0xFF00796B), size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Batterie sans restriction : pour éviter qu\'Android ne bloque la tâche.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF172E2B)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (!_areNotificationsAllowed) ...[
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF00796B)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  icon: const Icon(Icons.notifications_active_rounded, color: Color(0xFF00796B), size: 18),
                  onPressed: () async {
                    final granted = await BackgroundReservationService.requestNotificationPermission();
                    if (!granted) {
                      await BackgroundReservationService.openAppSettings();
                    }
                    await _loadBackgroundDiagnostics();
                  },
                  label: const Text(
                    'Activer les notifications',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00796B)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00796B),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await BackgroundReservationService.requestIgnoreBatteryOptimization();
                },
                child: const Text('Autoriser la batterie sans restriction', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            if (_isRestrictedOem) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFE0E7E5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                  ),
                  icon: const Icon(Icons.settings_power_rounded, color: Color(0xFF172E2B), size: 18),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await BackgroundReservationService.openAutoStartSettings();
                  },
                  label: const Text(
                    'Autoriser le démarrage automatique (Xiaomi / OEM)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF172E2B)),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Plus tard', style: TextStyle(color: Color(0xFF637571))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveAllPreferences() async {
    await _persistCurrentConfigAndSession();
    if (_isBackgroundEnabled) {
      await BackgroundReservationService.enableDailyReservation(runImmediateSync: true);
      await _loadBackgroundDiagnostics();
    }
    _showSnackbar('Préférences enregistrées et synchronisées avec le pilote automatique !');
  }

  void _showRestaurantPicker() {
    if (_restaurants.isEmpty) {
      if (_isLoadingRestaurants) {
        _showSnackbar('Chargement des restaurants en cours...');
      } else {
        _showSnackbar('Actualisation des restaurants...');
        _loadRestaurants();
      }
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        String searchQuery = '';
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filtered = _restaurants.where((r) {
              final q = searchQuery.toLowerCase();
              return r.nameFr.toLowerCase().contains(q) ||
                  r.nameAr.contains(searchQuery) ||
                  r.id.toString().contains(q);
            }).toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0E7E5),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: const [
                              Icon(Icons.storefront_rounded, color: Color(0xFF00796B), size: 22),
                              SizedBox(width: 8),
                              Text(
                                'Choisir un Restaurant Universitaire',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Color(0xFF172E2B),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            decoration: InputDecoration(
                              hintText: 'Rechercher par nom ou numéro...',
                              hintStyle: const TextStyle(color: Color(0xFF637571), fontSize: 13),
                              prefixIcon: const Icon(Icons.search, color: Color(0xFF00796B), size: 20),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFFE0E7E5)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFFE0E7E5)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF00796B), width: 1.5),
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF8F9FA),
                            ),
                            onChanged: (val) {
                              setModalState(() {
                                searchQuery = val;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFE0E7E5)),
                    Expanded(
                      child: ListView.separated(
                        controller: scrollController,
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFEDF0EF)),
                        itemBuilder: (_, idx) {
                          final r = filtered[idx];
                          final isSelected = _selectedRestaurant?.id == r.id;

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isSelected ? const Color(0xFF00796B) : const Color(0xFFDDF4ED),
                              foregroundColor: isSelected ? Colors.white : const Color(0xFF005D52),
                              child: Text('${r.id}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                            title: Text(
                              r.nameFr.isNotEmpty ? r.nameFr : r.nameAr,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: const Color(0xFF172E2B),
                                fontSize: 14,
                              ),
                            ),
                            subtitle: r.nameAr.isNotEmpty && r.nameFr.isNotEmpty
                                ? Text(r.nameAr, textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 12, color: Color(0xFF637571)))
                                : null,
                            trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Color(0xFF00796B)) : null,
                            onTap: () async {
                              setState(() {
                                _selectedRestaurant = r;
                              });
                              await widget.prefsService.saveDefaultDepot(r.id);
                              if (ctx.mounted) Navigator.pop(ctx);
                              _showSnackbar('Restaurant sélectionné : ${r.shortName}');
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _runManualReserveNow() async {
    if (_selectedRestaurant == null) {
      _showSnackbar('Veuillez sélectionner un restaurant.', isError: true);
      return;
    }
    if (_selectedMeals.isEmpty) {
      _showSnackbar('Veuillez sélectionner au moins un repas.', isError: true);
      return;
    }

    setState(() {
      _isReservingNow = true;
      _lastExecutionSummary = null;
    });

    try {
      await _persistCurrentConfigAndSession();
      final rawPrefs = await SharedPreferences.getInstance();
      final outcome = await ReservationEngine.run(
        prefs: rawPrefs,
        api: widget.apiService,
        ignoreEnabledCheck: true,
      );

      await widget.prefsService.reload();
      if (!mounted) return;

      setState(() {
        _lastExecutionSummary = outcome.summary;
        if (outcome.verifiedReservations.isNotEmpty) {
          final sorted = List<Reservation>.from(outcome.verifiedReservations)
            ..sort((a, b) => b.dateReserve.compareTo(a.dateReserve));
          _reservations = sorted;
        }
      });

      _showSnackbar(outcome.summary, isError: outcome.status == 'error');
      if (outcome.verifiedReservations.isEmpty) {
        await _loadReservations(silent: true);
      }
    } catch (e) {
      _showSnackbar('Erreur lors de la réservation : $e', isError: true);
    } finally {
      if (mounted) setState(() => _isReservingNow = false);
    }
  }

  Future<void> _cancelReservation(Reservation r) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Annuler cette réservation ?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text(
          'Voulez-vous vraiment annuler votre repas pour ${r.mealLabel} le ${r.dateReserve} ?',
          style: const TextStyle(fontSize: 13, color: Color(0xFF172E2B)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Non', style: TextStyle(color: Color(0xFF637571))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Oui, annuler'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await widget.apiService.cancelReservation(r.id);
      _showSnackbar('Réservation annulée.');
      await _loadReservations();
    } catch (e) {
      _showSnackbar('Erreur lors de l\'annulation : $e', isError: true);
    }
  }

  void _handleLogout() {
    widget.apiService.logout();
    widget.prefsService.clearCredentials();
    widget.prefsService.setBackgroundAutoReserveEnabled(false);
    BackgroundReservationService.disableDailyReservation();

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
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            // Custom Top App Bar matching Figma
            _buildCustomHeader(),

            // Screen Body (Auto or Historique)
            Expanded(
              child: _currentTabIndex == 0
                  ? _buildAutoTabContent()
                  : _buildHistoriqueTabContent(),
            ),

            // Bottom Navigation matching Figma
            _buildBottomNavigation(),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // TOP APP BAR HEADER
  // ==========================================
  Widget _buildCustomHeader() {
    final isAuto = _currentTabIndex == 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      color: const Color(0xFFF8F9FA),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAuto ? 'VOTRE PILOTE AUTOMATIQUE' : 'VOTRE SUIVI AU QUOTIDIEN',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    letterSpacing: 0.8,
                    color: Color(0xFF00796B),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isAuto ? 'Automatisation' : 'Historique',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                    color: Color(0xFF172E2B),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00796B)),
            tooltip: 'Actualiser',
            onPressed: () {
              _loadRestaurants();
              _loadReservations();
              _loadBackgroundDiagnostics();
            },
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: IconButton(
              icon: const Icon(Icons.logout_rounded, color: Color(0xFF637571), size: 20),
              tooltip: 'Se déconnecter',
              onPressed: _handleLogout,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 1: AUTOMATISATION (FIGMA NODE 2:7)
  // ==========================================
  Widget _buildAutoTabContent() {
    return RefreshIndicator(
      onRefresh: _loadInitialData,
      color: const Color(0xFF00796B),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Banner "Réservation Automatique" (Node 2:215)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFDDF4ED),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Réservation automatique',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Color(0xFF005D52),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _isBackgroundEnabled
                              ? 'Active · On s’occupe de vos repas.'
                              : 'En pause · Activez pour automatiser.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF356C61),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _isBackgroundEnabled,
                    activeTrackColor: const Color(0xFF00796B),
                    activeThumbColor: Colors.white,
                    inactiveTrackColor: Colors.black12,
                    inactiveThumbColor: Colors.white,
                    onChanged: _toggleBackgroundReservation,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 2. Section "Vos repas" (Node 2:220)
            const Text(
              'Vos repas',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Color(0xFF172E2B),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choisissez les repas à réserver chaque jour.',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF637571),
              ),
            ),
            const SizedBox(height: 12),

            // Meal Preferences Card (Node 2:222)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE0E7E5)),
              ),
              child: Column(
                children: [
                  // Petit-déjeuner
                  _buildMealSwitchRow(
                    mealId: 1,
                    frenchName: 'Petit-déjeuner',
                    arabicName: 'فطور',
                    arabicColor: const Color(0xFF996200),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16, color: Color(0xFFEDF0EF)),

                  // Déjeuner
                  _buildMealSwitchRow(
                    mealId: 2,
                    frenchName: 'Déjeuner',
                    arabicName: 'غداء',
                    arabicColor: const Color(0xFFE65100),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16, color: Color(0xFFEDF0EF)),

                  // Dîner
                  _buildMealSwitchRow(
                    mealId: 3,
                    frenchName: 'Dîner',
                    arabicName: 'عشاء',
                    arabicColor: const Color(0xFF303F9F),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 3. Section "Les jours de la semaine" (Node 2:237)
            const Text(
              'Les jours de la semaine',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Color(0xFF172E2B),
              ),
            ),
            const SizedBox(height: 12),

            // 7 Days Circles Row (Node 2:238 - 2:250)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildDayCircle('S', 6, 'Samedi'),
                _buildDayCircle('D', 7, 'Dimanche'),
                _buildDayCircle('L', 1, 'Lundi'),
                _buildDayCircle('M', 2, 'Mardi'),
                _buildDayCircle('M', 3, 'Mercredi'),
                _buildDayCircle('J', 4, 'Jeudi'),
                _buildDayCircle('V', 5, 'Vendredi'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _formatActiveDaysLabel(),
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF637571),
              ),
            ),
            const SizedBox(height: 20),

            // 4. University Restaurant Card (Figma Node 2:205 style)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE0E7E5)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: InkWell(
                onTap: _showRestaurantPicker,
                child: Row(
                  children: [
                    const Icon(Icons.location_on_rounded, color: Color(0xFF00796B), size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Votre restaurant',
                            style: TextStyle(fontSize: 11, color: Color(0xFF637571)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _selectedRestaurant?.displayName ?? 'Sélectionner un restaurant...',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Color(0xFF172E2B),
                            ),
                          ),
                          if (_selectedRestaurant != null && _selectedRestaurant!.nameAr.isNotEmpty)
                            Text(
                              _selectedRestaurant!.nameAr,
                              textDirection: TextDirection.rtl,
                              style: const TextStyle(fontSize: 12, color: Color(0xFF637571)),
                            ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Color(0xFF637571)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 5. Live Background Health & Offline Resilience Card
            _buildBackgroundHealthCard(),
            const SizedBox(height: 16),

            // 6. Action Button: "Enregistrer mes préférences" (Node 2:256)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _saveAllPreferences,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00796B),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: const Text(
                  'Enregistrer mes préférences',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Quick instant reserve action (runs full 2-pass server-verified booking)
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _isReservingNow ? null : _runManualReserveNow,
                icon: _isReservingNow
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00796B)))
                    : const Icon(Icons.bolt_rounded, size: 20, color: Color(0xFF00796B)),
                label: Text(
                  _isReservingNow ? 'Réservation & vérification...' : 'Réserver & vérifier maintenant',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF00796B)),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF00796B)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                ),
              ),
            ),

            if (_lastExecutionSummary != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  _lastExecutionSummary!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF00796B)),
                ),
              ),
            ],

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildBackgroundHealthCard() {
    final lastTime = widget.prefsService.lastBgRunTime;
    final lastStatus = widget.prefsService.lastBgRunStatus;
    final lastMsg = widget.prefsService.lastBgRunMessage;
    final isLastError = lastStatus == 'error';

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFEEF4F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLastError ? const Color(0xFFE57373) : const Color(0xFFD5E6E1),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _isBackgroundEnabled && _isWorkScheduled
                    ? Icons.verified_rounded
                    : Icons.schedule_rounded,
                size: 18,
                color: const Color(0xFF00796B),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Fiabilité en arrière-plan (vérification toutes les 4h)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Color(0xFF235F53),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Sans réseau ? Rien n’est perdu : Android relance la tâche dès le retour d’Internet et vérifie vos repas directement sur ONOU.',
            style: TextStyle(
              fontSize: 11.5,
              color: Color(0xFF47645D),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildDiagnosticChip(
                label: _isBackgroundEnabled
                    ? (_isWorkScheduled ? 'Planificateur actif ✓' : 'Planification...')
                    : 'Planificateur en pause',
                isOk: _isBackgroundEnabled && _isWorkScheduled,
                onTap: _isBackgroundEnabled
                    ? () async {
                        await BackgroundReservationService.enableDailyReservation();
                        await _loadBackgroundDiagnostics();
                      }
                    : null,
              ),
              _buildDiagnosticChip(
                label: _areNotificationsAllowed ? 'Notifications ✓' : 'Activer notifications !',
                isOk: _areNotificationsAllowed,
                onTap: !_areNotificationsAllowed
                    ? () async {
                        final ok = await BackgroundReservationService.requestNotificationPermission();
                        if (!ok) {
                          await BackgroundReservationService.openAppSettings();
                        }
                        await _loadBackgroundDiagnostics();
                      }
                    : null,
              ),
              _buildDiagnosticChip(
                label: _isBatteryUnrestricted ? 'Batterie libre ✓' : 'Autoriser batterie !',
                isOk: _isBatteryUnrestricted,
                onTap: !_isBatteryUnrestricted
                    ? () async {
                        await BackgroundReservationService.requestIgnoreBatteryOptimization();
                        await _loadBackgroundDiagnostics();
                      }
                    : null,
              ),
            ],
          ),
          if (lastTime != null || lastMsg != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (lastTime != null)
                    Text(
                      'Dernière vérification : $lastTime',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF172E2B),
                      ),
                    ),
                  if (lastMsg != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      lastMsg,
                      style: TextStyle(
                        fontSize: 11,
                        color: isLastError ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (_isBackgroundEnabled) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _isTestingBackground ? null : _triggerBackgroundTest,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: _isTestingBackground
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00796B)),
                          )
                        : const Icon(Icons.play_circle_outline_rounded, size: 16, color: Color(0xFF00796B)),
                    label: Text(
                      _isTestingBackground
                          ? 'Test en cours...'
                          : 'Tester l\'arrière-plan (notif)',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF00796B),
                      ),
                    ),
                  ),
                ),
                if (_isRestrictedOem) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => BackgroundReservationService.openAutoStartSettings(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.settings_power_rounded, size: 15, color: Color(0xFF47645D)),
                    label: const Text(
                      'Démarrage auto',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF47645D),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDiagnosticChip({
    required String label,
    required bool isOk,
    VoidCallback? onTap,
  }) {
    final bgColor = isOk ? const Color(0xFFEAF5EC) : const Color(0xFFFFF3E0);
    final fgColor = isOk ? const Color(0xFF2E7D32) : const Color(0xFFE65100);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fgColor.withValues(alpha: 0.25)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fgColor,
          ),
        ),
      ),
    );
  }

  Widget _buildMealSwitchRow({
    required int mealId,
    required String frenchName,
    required String arabicName,
    required Color arabicColor,
  }) {
    final isSelected = _selectedMeals.contains(mealId);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            frenchName,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF172E2B),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            arabicName,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.normal,
              color: arabicColor,
            ),
          ),
          const Spacer(),
          Switch(
            value: isSelected,
            activeTrackColor: const Color(0xFF00796B),
            activeThumbColor: Colors.white,
            inactiveTrackColor: Colors.black12,
            inactiveThumbColor: Colors.white,
            onChanged: (val) {
              setState(() {
                val ? _selectedMeals.add(mealId) : _selectedMeals.remove(mealId);
              });
              widget.prefsService.saveDefaultMeals(_selectedMeals.toList());
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDayCircle(String label, int weekday, String dayName) {
    final isActive = _activeDays.contains(weekday);

    return InkWell(
      onTap: () {
        setState(() {
          isActive ? _activeDays.remove(weekday) : _activeDays.add(weekday);
        });
        widget.prefsService.saveActiveDaysOfWeek(_activeDays);
      },
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF00796B) : Colors.white,
          shape: BoxShape.circle,
          border: isActive ? null : Border.all(color: const Color(0xFFE0E7E5)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isActive ? Colors.white : const Color(0xFF637571),
          ),
        ),
      ),
    );
  }

  String _formatActiveDaysLabel() {
    if (_activeDays.contains(7) && _activeDays.contains(1) && _activeDays.contains(2) && _activeDays.contains(3) && _activeDays.contains(4) && !_activeDays.contains(5) && !_activeDays.contains(6)) {
      return 'Du dimanche au jeudi · week-end désactivé';
    }
    if (_activeDays.length == 7) {
      return 'Tous les jours de la semaine (7j/7)';
    }
    return '${_activeDays.length} jour(s) actif(s) par semaine';
  }

  // ==========================================
  // TAB 2: HISTORIQUE / TICKETS (FIGMA NODE 2:12)
  // ==========================================
  Widget _buildHistoriqueTabContent() {
    final lastBgTime = widget.prefsService.lastBgRunTime;
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // Filter reservations
    final filtered = _reservations.where((r) {
      if (_activeFilter == 'all') return true;
      if (_activeFilter == 'reserved') {
        return r.dateReserve.compareTo(todayStr) >= 0;
      }
      if (_activeFilter == 'tocheck') {
        return r.canDelete;
      }
      return true;
    }).toList();

    return RefreshIndicator(
      onRefresh: () async {
        await widget.prefsService.reload();
        await _loadReservations();
        await _loadBackgroundDiagnostics();
      },
      color: const Color(0xFF00796B),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        children: [
          // 1. Monthly Summary Card (Node 2:258)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE0E7E5)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_reservations.length}',
                        style: const TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00796B),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'repas réservés ce mois-ci',
                        style: TextStyle(fontSize: 11, color: Color(0xFF637571)),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 48,
                  color: const Color(0xFFE0E7E5),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lastBgTime != null ? lastBgTime.split(' ').last : '—',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF172E2B),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastBgTime != null ? 'Dernière synchro' : 'Aucune synchro auto',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF637571)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Filter Capsule Bar (Node 2:264)
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFEBEFED),
              borderRadius: BorderRadius.circular(21),
            ),
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                _buildFilterItem('Tous', 'all'),
                _buildFilterItem('Réservés', 'reserved'),
                _buildFilterItem('À vérifier', 'tocheck'),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 3. Grouped Tickets by Date (Node 2:271)
          if (_isLoadingReservations)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF00796B))),
            )
          else if (filtered.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              alignment: Alignment.center,
              child: Column(
                children: const [
                  Icon(Icons.event_busy_rounded, size: 48, color: Color(0xFFE0E7E5)),
                  SizedBox(height: 12),
                  Text(
                    'Aucun repas réservé pour le moment',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF172E2B)),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Activez l\'auto-réservation pour programmer vos repas.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF637571)),
                  ),
                ],
              ),
            )
          else ...[
            ..._buildGroupedReservationCards(filtered),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterItem(String title, String key) {
    final isSelected = _activeFilter == key;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _activeFilter = key;
          });
        },
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(17),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? const Color(0xFF00796B) : const Color(0xFF637571),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupedReservationCards(List<Reservation> list) {
    // Group by date
    final Map<String, List<Reservation>> groups = {};
    for (final r in list) {
      groups.putIfAbsent(r.dateReserve, () => []).add(r);
    }

    final widgets = <Widget>[];

    groups.forEach((dateStr, reservations) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _getDateHeaderTitle(dateStr),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF172E2B),
                ),
              ),
              Text(
                dateStr,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF637571),
                ),
              ),
            ],
          ),
        ),
      );

      widgets.add(
        Container(
          margin: const EdgeInsets.only(bottom: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE0E7E5)),
          ),
          child: Column(
            children: [
              for (int i = 0; i < reservations.length; i++) ...[
                _buildTicketRow(reservations[i]),
                if (i < reservations.length - 1)
                  const Divider(height: 1, indent: 16, endIndent: 16, color: Color(0xFFEDF0EF)),
              ],
            ],
          ),
        ),
      );
    });

    return widgets;
  }

  String _getDateHeaderTitle(String dateStr) {
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final tomorrowStr = DateFormat('yyyy-MM-dd').format(now.add(const Duration(days: 1)));

    if (dateStr == todayStr) return "Aujourd’hui";
    if (dateStr == tomorrowStr) return "Demain";
    final parsed = DateTime.tryParse(dateStr);
    if (parsed == null) return dateStr;
    return DateFormat('EEEE d MMMM', 'fr_FR').format(parsed);
  }

  Widget _buildTicketRow(Reservation r) {
    final frLower = r.mealTypeFr.toLowerCase();
    Color stripeColor = const Color(0xFF00796B);
    String arabicLabel = r.mealTypeAr;

    if (frLower.contains('petit')) {
      stripeColor = const Color(0xFF996200);
      if (arabicLabel.isEmpty) arabicLabel = 'فطور';
    } else if (frLower.contains('déjeuner') || frLower.contains('dejeuner')) {
      stripeColor = const Color(0xFFE65100);
      if (arabicLabel.isEmpty) arabicLabel = 'غداء';
    } else if (frLower.contains('dîner') || frLower.contains('diner')) {
      stripeColor = const Color(0xFF303F9F);
      if (arabicLabel.isEmpty) arabicLabel = 'عشاء';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // 4px vertical colored stripe
          Container(
            width: 4,
            height: 28,
            decoration: BoxDecoration(
              color: stripeColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      r.mealTypeFr.isNotEmpty ? r.mealTypeFr : 'Repas',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF172E2B),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      arabicLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: stripeColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  r.restaurantName,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF637571),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Confirmed Status Pill (Node 2:276)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF5EC),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '✓ Réservé',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2E7D32),
              ),
            ),
          ),
          if (r.canDelete) ...[
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFF637571)),
              tooltip: 'Annuler',
              onPressed: () => _cancelReservation(r),
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(4),
            ),
          ],
        ],
      ),
    );
  }

  // ==========================================
  // BOTTOM NAVIGATION (FIGMA NODE 2:11 / 2:16)
  // ==========================================
  Widget _buildBottomNavigation() {
    return Container(
      height: 72,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E7E5), width: 1)),
      ),
      child: Row(
        children: [
          // Tab 1: Auto (Node 2:76)
          Expanded(
            child: InkWell(
              onTap: () {
                setState(() => _currentTabIndex = 0);
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 56,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _currentTabIndex == 0 ? const Color(0xFFDDF4ED) : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: _currentTabIndex == 0 ? const Color(0xFF00796B) : const Color(0xFF637571),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Auto',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: _currentTabIndex == 0 ? FontWeight.w600 : FontWeight.w500,
                      color: _currentTabIndex == 0 ? const Color(0xFF00796B) : const Color(0xFF637571),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Tab 2: Historique (Node 2:81)
          Expanded(
            child: InkWell(
              onTap: () {
                setState(() => _currentTabIndex = 1);
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 56,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _currentTabIndex == 1 ? const Color(0xFFDDF4ED) : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.history_rounded,
                      size: 20,
                      color: _currentTabIndex == 1 ? const Color(0xFF00796B) : const Color(0xFF637571),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Historique',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: _currentTabIndex == 1 ? FontWeight.w600 : FontWeight.w500,
                      color: _currentTabIndex == 1 ? const Color(0xFF00796B) : const Color(0xFF637571),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
