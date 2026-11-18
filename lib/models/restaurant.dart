class Restaurant {
  final int id;
  final String nameFr;
  final String nameAr;

  Restaurant({
    required this.id,
    required this.nameFr,
    required this.nameAr,
  });

  factory Restaurant.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] ?? json['idDepot'] ?? 0;
    final id = rawId is int ? rawId : int.tryParse(rawId.toString()) ?? 0;
    final nameFr = (json['nameFR'] ?? json['name'] ?? '').toString().trim();
    final nameAr = (json['nameAR'] ?? '').toString().trim();

    return Restaurant(
      id: id,
      nameFr: nameFr,
      nameAr: nameAr,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nameFR': nameFr,
        'nameAR': nameAr,
      };

  String get displayName {
    if (nameFr.isNotEmpty && nameAr.isNotEmpty && nameFr != nameAr) {
      return '$nameFr ($nameAr)';
    }
    return nameFr.isNotEmpty ? nameFr : (nameAr.isNotEmpty ? nameAr : 'Restaurant #$id');
  }

  String get shortName {
    if (nameFr.isNotEmpty) return nameFr;
    if (nameAr.isNotEmpty) return nameAr;
    return 'Depot $id';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Restaurant && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
