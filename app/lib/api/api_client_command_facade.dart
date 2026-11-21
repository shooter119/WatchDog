part of 'api_client.dart';

mixin _CommandApiFacade on _ApiClientBase {
  // ---- IncidentRepository (14) ----

  Future<void> createIncidentObservation({
    required String transcript,
    required String sourceType,
    required int capturedAt,
    String mediaRef = '',
    Map<String, Object?> structured = const {},
  }) => _incident.createIncidentObservation(
    transcript: transcript,
    sourceType: sourceType,
    capturedAt: capturedAt,
    mediaRef: mediaRef,
    structured: structured,
  );

  Future<List<Incident>> fetchIncidents({String? status}) =>
      _incident.fetchIncidents(status: status);

  Future<Incident> createIncident({required String realName, String? opId}) =>
      _incident.createIncident(realName: realName, opId: opId);

  Future<List<ExternalIncident>> fetchExternalIncidents({
    bool refresh = false,
  }) => _incident.fetchExternalIncidents(refresh: refresh);

  Future<List<ExternalIncident>> reorganizeExternalIncidents({
    List<String>? externalIds,
  }) => _incident.reorganizeExternalIncidents(externalIds: externalIds);

  Future<Incident> claimExternalIncident(
    ExternalIncident incident, {
    required String realName,
    String? opId,
  }) => _incident.claimExternalIncident(
    incident,
    realName: realName,
    opId: opId,
  );

  Future<Incident> fetchIncident(String id) => _incident.fetchIncident(id);

  Future<Incident> updateIncidentTitle(
    String id,
    String? title, {
    required int expectedVersion,
  }) => _incident.updateIncidentTitle(
    id,
    title,
    expectedVersion: expectedVersion,
  );

  Future<Incident> archiveIncident(String id) => _incident.archiveIncident(id);

  Future<List<IncidentForce>> fetchIncidentForces({String? forIncidentId}) =>
      _incident.fetchIncidentForces(forIncidentId: forIncidentId);

  Future<Map<String, dynamic>> mergeIncidentForces(
    Map<String, dynamic> body,
    String opId,
  ) => _incident.mergeIncidentForces(body, opId);

  Future<IncidentForce> saveIncidentForce({
    String? forceId,
    required String stationName,
    String? stationId,
    String? unitStationId,
    required int vehicleCount,
    required int personnelCount,
    bool vehicleCountKnown = true,
    bool personnelCountKnown = true,
    int? expectedVersion,
  }) => _incident.saveIncidentForce(
    forceId: forceId,
    stationName: stationName,
    stationId: stationId,
    unitStationId: unitStationId,
    vehicleCount: vehicleCount,
    personnelCount: personnelCount,
    vehicleCountKnown: vehicleCountKnown,
    personnelCountKnown: personnelCountKnown,
    expectedVersion: expectedVersion,
  );

  Future<void> deleteIncidentForce(String forceId) =>
      _incident.deleteIncidentForce(forceId);

  Future<List<IncidentEvent>> fetchTimeline(String id, {int limit = 2000}) =>
      _incident.fetchTimeline(id, limit: limit);

  // ---- IncidentImportRepository (9) ----

  Future<Map<String, dynamic>> fetchIncidentDetails() =>
      _incidentImport.fetchIncidentDetails();

  Future<Map<String, dynamic>> updateIncidentDetails(
    Map<String, dynamic> data,
    int version,
    String opId,
  ) => _incidentImport.updateIncidentDetails(data, version, opId);

  Future<Map<String, dynamic>> createIncidentImport({
    String? text,
    List<Uint8List> images = const [],
  }) => _incidentImport.createIncidentImport(text: text, images: images);

  Future<Uint8List> fetchImportImage(String id, int page) =>
      _incidentImport.fetchImportImage(id, page);

  Future<Map<String, dynamic>> fetchIncidentImport(String id) =>
      _incidentImport.fetchIncidentImport(id);

  Future<Map<String, dynamic>> retryIncidentImport(
    String id,
    List<int> pages,
  ) => _incidentImport.retryIncidentImport(id, pages);

  Future<Map<String, dynamic>> cancelIncidentImport(String id) =>
      _incidentImport.cancelIncidentImport(id);

  Future<Map<String, dynamic>> applyIncidentImport(
    String id,
    Map<String, dynamic> body,
    String opId,
  ) => _incidentImport.applyIncidentImport(id, body, opId);

  Future<List<Map<String, dynamic>>> fetchIncidentImports() =>
      _incidentImport.fetchIncidentImports();

  // ---- NotesRepository (4) ----

  Future<List<Note>> fetchNotes() => _notes.fetchNotes();

  Future<Note> createNote({
    required String text,
    String? category,
    String? opId,
    String? author,
  }) => _notes.createNote(
    text: text,
    category: category,
    opId: opId,
    author: author,
  );

  Future<Note> updateNote({
    required String id,
    String? text,
    String? category,
  }) => _notes.updateNote(id: id, text: text, category: category);

  Future<void> deleteNote(String id) => _notes.deleteNote(id);

  // ---- VoiceRepository (5; realtimeAsrUri stays polymorphic on ApiClient) ----

  List<Uri> realtimeAsrUris() => _voice.realtimeAsrUris();

  Map<String, String> realtimeAsrHeaders({String? opId}) =>
      _voice.realtimeAsrHeaders(opId: opId);

  Future<String> transcribe(Uint8List audioBytes, {String? opId}) =>
      _voice.transcribe(audioBytes, opId: opId);

  Future<String> transcribeMedia(Uint8List audioBytes, {String? opId}) =>
      _voice.transcribeMedia(audioBytes, opId: opId);

  Future<ParseResult> parse(String text, {String? opId}) =>
      _voice.parse(text, opId: opId);

  // ---- CopilotRepository (5) ----

  Future<List<ChatMessage>> fetchChatMessages() => _copilot.fetchChatMessages();

  Future<ChatMessage> sendChatMessage(
    String message, {
    String? opId,
    List<ChatMessage> history = const [],
  }) => _copilot.sendChatMessage(message, opId: opId, history: history);

  Future<String> sendChatMessageStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) => _copilot.sendChatMessageStream(
    message,
    onChunk: onChunk,
    opId: opId,
    history: history,
  );

  Future<VisionAnalysis> analyzeVision(
    Uint8List bytes, {
    required String mimeType,
    String message = '',
    String? opId,
  }) => _copilot.analyzeVision(
    bytes,
    mimeType: mimeType,
    message: message,
    opId: opId,
  );

  Future<void> clearChatMessages() => _copilot.clearChatMessages();
}
