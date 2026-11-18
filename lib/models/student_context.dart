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
}
