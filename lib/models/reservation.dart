class Reservation {
  final dynamic id;
  final String dateReserve;
  final String mealTypeFr;
  final String mealTypeAr;
  final String depotFr;
  final String depotAr;
  final bool canDelete;

  Reservation({
    required this.id,
    required this.dateReserve,
    required this.mealTypeFr,
    required this.mealTypeAr,
    required this.depotFr,
    required this.depotAr,
    required this.canDelete,
  });

  factory Reservation.fromJson(Map<String, dynamic> json) {
    return Reservation(
      id: json['id'],
      dateReserve: (json['date_reserve'] ?? '').toString(),
      mealTypeFr: (json['mealtype_fr'] ?? '').toString().trim(),
      mealTypeAr: (json['mealtype_ar'] ?? '').toString().trim(),
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
