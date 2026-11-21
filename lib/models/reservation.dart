class Reservation {
  final dynamic id;
  final String dateReserve;
  final String mealTypeFr;
  final String mealTypeAr;
  final int? mealTypeId;
  final String depotFr;
  final String depotAr;
  final bool canDelete;

  Reservation({
    required this.id,
    required this.dateReserve,
    required this.mealTypeFr,
    required this.mealTypeAr,
    this.mealTypeId,
    required this.depotFr,
    required this.depotAr,
    required this.canDelete,
  });

  static String _normalizeDate(dynamic raw) {
    final s = (raw ?? '').toString().trim();
    if (s.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
      return s.substring(0, 10);
    }
    return s;
  }

  static int? _parseMealTypeId(Map<String, dynamic> json) {
    final raw = json['menu_type'] ?? json['meal_type'] ?? json['mealtype_id'] ?? json['id_mealtype'];
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  factory Reservation.fromJson(Map<String, dynamic> json) {
    return Reservation(
      id: json['id'],
      dateReserve: _normalizeDate(json['date_reserve']),
      mealTypeFr: (json['mealtype_fr'] ?? '').toString().trim(),
      mealTypeAr: (json['mealtype_ar'] ?? '').toString().trim(),
      mealTypeId: _parseMealTypeId(json),
      depotFr: (json['depot_fr'] ?? '').toString().trim(),
      depotAr: (json['depot_ar'] ?? '').toString().trim(),
      canDelete: json['candelete'] == true || json['candelete'] == 1,
    );
  }

  String get mealLabel {
    if (mealTypeFr.isNotEmpty) {
      if (mealTypeAr.isNotEmpty && mealTypeFr != mealTypeAr) {
        return '$mealTypeFr / $mealTypeAr';
      }
      return mealTypeFr;
    }
    return mealTypeAr.isNotEmpty ? mealTypeAr : 'Repas';
  }

  String get restaurantName {
    if (depotFr.isNotEmpty) return depotFr;
    if (depotAr.isNotEmpty) return depotAr;
    return 'Restaurant';
  }
}
