part of 'app_controller.dart';

mixin _AppControllerNotesChatMixin on _AppControllerBase {
  @override
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    final cat = category ?? NoteCategory.fromText(text);
    final author = await Settings.realName;
    final incident = currentIncident;
    final operationApi = api;
    final owner = <String, String>{
      'unit_id': operationApi?.unitId ?? '',
      'member_id': await Settings.memberId,
    };
    Note note;
    try {
      note = await operationApi!.createNote(
        text: text,
        category: cat,
        opId: opId,
        author: author,
      );
    } catch (error) {
      if (error is ApiException &&
          [
            'VERSION_CONFLICT',
            'ENTRY_EXITED',
            'STALE_PRESSURE',
          ].contains(error.code)) {
        await sync();
        rethrow;
      }
      if (!_isNetworkError(error) || incident == null) rethrow;
      final at = DateTime.now().millisecondsSinceEpoch;
      final noteId = 'offline-note-${DateTime.now().microsecondsSinceEpoch}';
      await OfflineQueue.instance.enqueue(
        owner: owner,
        incidentId: incident.id,
        type: 'note',
        occurredAt: at,
        clientOpId: opId ?? noteId,
        payload: {'note_id': noteId, 'text': text, 'category': cat},
      );
      note = Note(
        id: noteId,
        text: text,
        category: cat,
        author: author,
        createdAt: at,
        updatedAt: at,
      );
    }
    // 创建请求返回与实时 note.created 事件可能以任意顺序到达；按服务端
    // note.id 合并，避免同一条日志在本地列表中显示两次。
    if (api != operationApi) return note;
    notes = [note, ...notes.where((item) => item.id != note.id)];
    _notify();
    return note;
  }

  /// 进出场确认同步写入火场日志，使用现场记录中的规范化作业表述。
  Future<Note> addActionLog({
    required Iterable<String> names,
    required String action,
    required String category,
    Map<String, double>? pressuresMpa,
    String? opId,
  }) {
    final cleanNames = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (cleanNames.isEmpty) throw StateError('缺少火场日志人员');
    final text = switch (action) {
      '进场' =>
        cleanNames
            .map((name) {
              final pressure = pressuresMpa?[name];
              final pressureText = pressure == null
                  ? ''
                  : '，空气呼吸器压力${_formatPressureMpa(pressure)}兆帕';
              return '$name进入救援现场$pressureText';
            })
            .join('、'),
      '出场' => cleanNames.map((name) => '$name撤离救援现场').join('、'),
      _ => cleanNames.map((name) => '$name$action').join('、'),
    };
    // 超长派生操作号按完整内容生成固定长度摘要，重试仍使用同一幂等键。
    final actionOpId = opId != null && opId.length > 64
        ? sha256.convert(utf8.encode(opId)).toString()
        : opId;
    return addNote(text, category: category, opId: actionOpId);
  }

  Future<Note> updateNote(String id, {String? text, String? category}) async {
    final updated = await api!.updateNote(
      id: id,
      text: text,
      category: category,
    );
    notes = notes.map((n) => n.id == id ? updated : n).toList();
    _notify();
    return updated;
  }

  /// 智能体问答：读取本机历史（旧→新），不依赖警情或云端。
  String get assistantScope {
    final a = api;
    if (a == null || a.unitId.isEmpty) return '';
    return '${a.baseUrl}|${a.unitId}|${a.actorName.isNotEmpty ? a.actorName : a.deviceId}|${currentIncident?.id ?? 'general'}';
  }

  Future<List<ChatMessage>> fetchChatHistory() =>
      ChatHistory.load(scope: assistantScope);

  Future<VisionAnalysis> analyzeVision(
    Uint8List bytes, {
    required String mimeType,
    String message = '',
    String? opId,
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
    final historyScope = assistantScope;
    _assistantPending++;
    try {
      final analysis = await a.analyzeVision(
        bytes,
        mimeType: mimeType,
        message: message,
        opId: opId,
      );
      await ChatHistory.appendExchange(
        scope: historyScope,
        question: '图片分析：$message',
        reply: [
          ...analysis.facts,
          ...analysis.risks,
          ...analysis.toConfirm,
          ...analysis.suggestions,
        ].join('\n'),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      return analysis;
    } finally {
      _assistantPending--;
    }
  }

  /// 智能体问答：提问并返回完整 AI 回复。
  Future<ChatMessage> askAssistant(
    String message, {
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
    final historyScope = assistantScope;
    _assistantPending++;
    try {
      final reply = await a.sendChatMessage(
        message,
        opId: opId,
        history: history,
      );
      await ChatHistory.appendExchange(
        scope: historyScope,
        question: message,
        reply: reply.content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      return reply;
    } finally {
      _assistantPending--;
    }
  }

  /// 流式提问：辅助页使用此路径，让首个 token 到达后立即显示。
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) async {
    final a = api;
    if (a == null) throw StateError('AI 服务未连接');
    final historyScope = assistantScope;
    _assistantPending++;
    try {
      final reply = await a.sendChatMessageStream(
        message,
        onChunk: onChunk,
        opId: opId,
        history: history,
      );
      if (reply.trim().isEmpty) {
        throw StateError('辅助回复为空，请重试');
      }
      // 持久化不阻塞首屏回复；ChatHistory 内部队列保证追加/清空按入队顺序执行。
      unawaited(
        ChatHistory.appendExchange(
          scope: historyScope,
          question: message,
          reply: reply,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ).catchError((_) {}),
      );
      return reply;
    } finally {
      _assistantPending--;
    }
  }

  /// 释放辅助问答的底层 socket；Future 超时本身不等于取消网络请求。
  void cancelAssistantRequest() => api?.cancelChatRequest();

  /// 清空本机辅助问答记录
  Future<void> clearChatHistory() async {
    await ChatHistory.clear(scope: assistantScope);
  }

  Future<void> deleteNote(String id) async {
    await api!.deleteNote(id);
    notes = notes.where((n) => n.id != id).toList();
    _notify();
  }

  /// 当前认证单位的名单/热词本地缓存。缓存必须绑定 unitId，不能跨单位复用。
}
