class StudentContext {
  final String uuid;
  final String studentName;
  final int? anneeAcademiqueId;
  final int? diaId;
  final dynamic wilayaId;
  final dynamic residenceId;

  StudentContext({
    required this.uuid,
    required this.studentName,
    this.anneeAcademiqueId,
    this.diaId,
    this.wilayaId,
    this.residenceId,
  });

  bool get isHoused => residenceId != null;

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'studentName': studentName,
        'anneeAcademiqueId': anneeAcademiqueId,
        'diaId': diaId,
        'wilayaId': wilayaId,
        'residenceId': residenceId,
      };

  factory StudentContext.fromJson(Map<String, dynamic> json) => StudentContext(
        uuid: json['uuid'] as String,
        studentName: json['studentName'] as String,
        anneeAcademiqueId: json['anneeAcademiqueId'] as int?,
        diaId: json['diaId'] as int?,
        wilayaId: json['wilayaId'],
        residenceId: json['residenceId'],
      );
}
