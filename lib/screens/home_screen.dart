import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../models/restaurant.dart';
import '../models/reservation.dart';
import '../models/student_context.dart';
import '../services/webetu_api_service.dart';
import '../services/preferences_service.dart';
import '../services/background_service.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  int _currentTabIndex = 0; // 0: Auto (Préférences), 1: Historique (Réservations)

  List<Restaurant> _restaurants = [];
  Restaurant? _selectedRestaurant;
  List<Reservation> _reservations = [];

  bool _isLoadingRestaurants = true;
  bool _isLoadingReservations = true;
  bool _isReservingNow = false;
  bool _isBackgroundEnabled = false;

  // Selected meal types: 1 (Petit-déj), 2 (Déjeuner), 3 (Dîner)
  final Set<int> _selectedMeals = {2, 3};

  // Active days of the week: 7: Dimanche, 1: Lundi, 2: Mardi, 3: Mercredi, 4: Jeudi, 5: Vendredi, 6: Samedi
  final Set<int> _activeDays = {7, 1, 2, 3, 4};

  // Filter in Historique tab: 'all', 'reserved', 'tocheck'
  String _activeFilter = 'all';

  // Real-time reservation feedback items
  final List<ReservationResultItem> _latestResults = [];
  String? _lastExecutionSummary;

  @override
  void initState() {
    super.initState();
    _selectedMeals.clear();
    _selectedMeals.addAll(widget.prefsService.defaultMeals);
    _activeDays.clear();
    _activeDays.addAll(widget.prefsService.activeDaysOfWeek);
    _isBackgroundEnabled = widget.prefsService.isBackgroundAutoReserveEnabled;

    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    await Future.wait([
      _loadRestaurants(),
      _loadReservations(),
    ]);
  }

  Future<void> _loadRestaurants() async {
    setState(() => _isLoadingRestaurants = true);
    try {
      final list = await widget.apiService.getRestaurants();
      if (!mounted) return;

      setState(() {
        _restaurants = list;
        final savedDepotId = widget.prefsService.defaultDepotId;
        if (savedDepotId != null && list.any((r) => r.id == savedDepotId)) {
          _selectedRestaurant = list.firstWhere((r) => r.id == savedDepotId);
        } else if (list.isNotEmpty) {
          _selectedRestaurant = list.first;
        } else {
          _selectedRestaurant = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      _showSnackbar('Erreur de chargement des restaurants: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingRestaurants = false);
    }
  }

  Future<void> _loadReservations() async {
    setState(() => _isLoadingReservations = true);
    try {
      final list = await widget.apiService.getReservations();
      if (!mounted) return;
      setState(() {
        list.sort((a, b) => b.dateReserve.compareTo(a.dateReserve));
        _reservations = list;
      });
    } catch (e) {
      if (!mounted) return;
      _showSnackbar('Erreur de chargement des réservations: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingReservations = false);
    }
  }

  void _showSnackbar(String message, {bool isError = false}) {
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
      await BackgroundReservationService.enableDailyReservation();
      _showSnackbar('Pilote automatique activé ! Vos repas seront réservés chaque jour.');

      // Request notification permission and background battery optimization
      await BackgroundReservationService.requestNotificationPermission();
      final isIgnored = await BackgroundReservationService.isBatteryOptimizationIgnored();
      if (!isIgnored && mounted) {
        await _showBackgroundOptimizationPrompt();
      }
    } else {
      await BackgroundReservationService.disableDailyReservation();
      _showSnackbar('Pilote automatique mis en pause.');
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
                child: const Text('Autoriser l\'arrière-plan', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
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
    await widget.prefsService.saveDefaultMeals(_selectedMeals.toList());
    await widget.prefsService.saveActiveDaysOfWeek(_activeDays);
    if (_selectedRestaurant != null) {
      await widget.prefsService.saveDefaultDepot(_selectedRestaurant!.id);
    }
    _showSnackbar('Préférences enregistrées avec succès !');
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
      _latestResults.clear();
      _lastExecutionSummary = null;
    });

    try {
      final existing = await widget.apiService.getReservations();
      final now = DateTime.now();

      int successCount = 0;
      int skippedCount = 0;
      int errorCount = 0;

      final window = widget.prefsService.autoReserveWindow;
      for (int i = 1; i <= window; i++) {
        final targetDate = now.add(Duration(days: i));
        if (!_activeDays.contains(targetDate.weekday)) {
          continue; // Respect active days
        }

        final dateStr = DateFormat('yyyy-MM-dd').format(targetDate);
        final items = await widget.apiService.reserveMeals(
          dateStr: dateStr,
          mealTypes: _selectedMeals.toList(),
          depotId: _selectedRestaurant!.id,
          existingReservations: existing,
        );

        for (final r in items) {
          _latestResults.add(r);
          if (r.isSuccess) successCount++;
          if (r.isSkipped) skippedCount++;
          if (r.status == 'failed' || r.status == 'error') errorCount++;
        }
      }

      setState(() {
        _lastExecutionSummary = "Résultats : $successCount réservé(s), $skippedCount déjà confirmé(s)"
            "${errorCount > 0 ? ', $errorCount échec(s)' : ''}";
      });

      _showSnackbar(_lastExecutionSummary!);
      await _loadReservations();
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

            // 5. Retry policy / Offline resilience container (Node 2:253)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFEEF4F2),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Sans réseau ? Rien n’est perdu.',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Color(0xFF235F53),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Les tentatives reprennent au retour d’Internet, si la réservation est encore ouverte.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF47645D),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
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

            // Quick instant reserve action
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _isReservingNow ? null : _runManualReserveNow,
                icon: _isReservingNow
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00796B)))
                    : const Icon(Icons.bolt_rounded, size: 20, color: Color(0xFF00796B)),
                label: Text(
                  _isReservingNow ? 'Réservation en cours...' : '⚡ Réserver immédiatement pour demain',
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

    // Filter reservations
    final filtered = _reservations.where((r) {
      if (_activeFilter == 'all') return true;
      if (_activeFilter == 'reserved') return true;
      return true;
    }).toList();

    return RefreshIndicator(
      onRefresh: _loadReservations,
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
                        lastBgTime != null ? lastBgTime.split(' ').last : '06:32',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF172E2B),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Dernière synchro',
                        style: TextStyle(fontSize: 11, color: Color(0xFF637571)),
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
    return DateFormat('EEEE d MMMM', 'fr_FR').format(DateTime.parse(dateStr));
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
