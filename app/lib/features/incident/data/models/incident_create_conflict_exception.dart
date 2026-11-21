import 'incident.dart';

class IncidentCreateConflictException implements Exception {
  final String message;
  final Incident existing;

  IncidentCreateConflictException(this.message, this.existing);

  @override
  String toString() => message;
}
