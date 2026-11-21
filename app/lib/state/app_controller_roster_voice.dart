part of 'app_controller.dart';

const String _kCachedFirefighters = 'cached_firefighters';
const String _kCachedHotwords = 'cached_hotwords';
const String _kCachedStations = 'cached_stations';
const String _kCachedRosterUnitId = 'cached_roster_unit_id';

mixin _AppControllerRosterVoiceMixin on _AppControllerBase {
  @override
  Future<void> loadRoster() {
    if (_disposed) return Future<void>.value();
    final existing = _loadRosterFuture;
    if (existing != null) return existing;
    final future = _loadRosterInternal();
    _loadRosterFuture = future;
    future.then<void>(
      (_) {
        if (identical(_loadRosterFuture, future)) _loadRosterFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_loadRosterFuture, future)) _loadRosterFuture = null;
      },
    );
    return future;
  }

  Future<void> _loadRosterInternal() async {
    if (_disposed || api == null) return;
    final configuredUnitId = await Settings.unitId;
    final unitId = configuredUnitId.isNotEmpty ? configuredUnitId : api!.unitId;
    if (unitId.isEmpty) {
      firefighters = [];
      hotwords = [];
      stations = [];
      _notify();
      return;
    }
    await _restoreCachedRoster(unitId);
    if (_disposed || api == null) return;
    final a = api!;
    final generation = _sessionGeneration;
    try {
      final f = await a.fetchFirefighters();
      final h = await a.fetchHotwords();
      if (_disposed || generation != _sessionGeneration || !identical(api, a)) {
        return;
      }
      // 空数组是当前单位的合法词库状态，不能恢复其他单位或旧版本缓存。
      firefighters = f;
      hotwords = h;
      try {
        final fetchedStations = await a.fetchStations();
        if (_disposed || generation != _sessionGeneration || !identical(api, a)) {
          return;
        }
        stations = fetchedStations;
      } catch (_) {
        // 消防站接口失败时保留已恢复的本组织缓存，名单热词仍采用本次成功结果。
      }
      _notify();
      await _cacheRoster(unitId);
    } catch (_) {
      if (_disposed || generation != _sessionGeneration || !identical(api, a)) {
        return;
      }
      await _restoreCachedRoster(unitId);
    }
  }

  @override
  Future<void> _cacheRoster(String unitId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kCachedRosterUnitId, unitId);
      await sp.setString(
        _kCachedFirefighters,
        jsonEncode(firefighters.map((f) => f.name).toList()),
      );
      await sp.setString(
        _kCachedHotwords,
        jsonEncode(hotwords.map((h) => h.word).toList()),
      );
      await sp.setString(_kCachedStations, jsonEncode(orgDirectory.stationCache));
      final activeApi = api;
      if (activeApi != null && activeApi.cacheScope.isNotEmpty) {
        await ScopedJsonCache.write(
          activeApi.cacheScope,
          'org-stations',
          orgDirectory.stationCache,
        );
      }
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  Future<void> _restoreCachedRoster(String unitId) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getString(_kCachedRosterUnitId) != unitId) {
        firefighters = [];
        hotwords = [];
        stations = [];
        _notify();
        return;
      }
      final fNames =
          (jsonDecode(sp.getString(_kCachedFirefighters) ?? '[]') as List)
              .map((e) => e.toString())
              .toList();
      final hWords =
          (jsonDecode(sp.getString(_kCachedHotwords) ?? '[]') as List)
              .map((e) => e.toString())
              .toList();
      firefighters = fNames.map((n) => Firefighter(id: '', name: n)).toList();
      hotwords = hWords.map((w) => Hotword(id: '', word: w)).toList();
      final rawStations = sp.getString(_kCachedStations);
      orgDirectory.restoreStationCache(
        rawStations == null ? const [] : jsonDecode(rawStations),
      );
      _notify();
    } catch (_) {
      // 缓存损坏时也回退内置默认
      _loadBuiltinDefaults();
    }
  }

  @override
  Future<void> _ensureLocalRoster() async {
    if (!_authenticated) {
      firefighters = [];
      hotwords = [];
      stations = [];
      await _clearRosterCache();
      return;
    }
    final unitId = await Settings.unitId;
    if (unitId.isEmpty) return;
    await _restoreCachedRoster(unitId);
  }

  /// 未认证状态不加载任何单位姓名或单位词，避免把真实数据打进安装包。
  void _loadBuiltinDefaults() {
    firefighters = [];
    hotwords = [];
    stations = [];
    _notify();
  }

  @override
  Future<void> _clearRosterCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kCachedRosterUnitId);
      await sp.remove(_kCachedFirefighters);
      await sp.remove(_kCachedHotwords);
      await sp.remove(_kCachedStations);
      // 删除旧版本未绑定单位的缓存，避免认证切换时误用。
      await sp.remove('builtin_roster_initialized_v1');
    } catch (_) {}
  }

  /// 转写：云端优先（开关开时），失败/关闭开关时强制本地 sherpa-onnx
  Future<String> transcribeAudio(Uint8List bytes, {String? opId}) async {
    if (asrCloudEnabled && api != null) {
      try {
        final text = await api!.transcribe(bytes, opId: opId);
        if (text.trim().isNotEmpty) return text;
      } catch (e) {
        if (localAsr == null) rethrow;
        OpLogService.instance.record(
          opId ?? '',
          'transcribe_fallback',
          '云端转写失败，切换本地识别: $e',
          level: 'warn',
        );
      }
    }
    return _localTranscribe(bytes, opId: opId);
  }

  /// 实时云端会话失败后的本地识别入口，避免回退时再次请求云端。
  Future<String> transcribeAudioLocal(Uint8List bytes, {String? opId}) async {
    return _localTranscribe(bytes, opId: opId);
  }

  /// 水印视频口述识别：复用与实时录音相同的热词注入与串行队列，
  /// 额外返回分段毫秒时间戳，用于把文字定位回视频画面。
  Future<LocalAsrResult> transcribeMediaAudio(
    Uint8List wavBytes, {
    String? opId,
  }) async {
    if (asrCloudEnabled && api != null) {
      try {
        final text = await api!.transcribeMedia(wavBytes, opId: opId);
        return LocalAsrResult(text: text.trim());
      } catch (_) {
        OpLogService.instance.record(
          opId ?? '',
          'media_asr_fallback',
          '在线语音识别失败，尝试本地识别',
          level: 'warn',
        );
      }
    }
    final asr = localAsr;
    if (asr == null) throw StateError('未配置本地语音识别');
    final hotwords = orgDirectory.asrTerms;
    OpLogService.instance.record(
      opId ?? '',
      'media_asr_hotwords',
      '现场口述识别热词 ${hotwords.length} 个',
      data: {'count': hotwords.length, 'sample': hotwords.take(8).toList()},
    );
    return asr.transcribeDetailed(wavBytes, hotwords: hotwords);
  }

  Future<String> _localTranscribe(Uint8List bytes, {String? opId}) async {
    final asr = localAsr;
    if (asr == null) throw StateError('未配置本地语音识别');
    final hotwords = orgDirectory.asrTerms;
    // 热词注入埋点：可验证名单/术语是否真正进入本地识别（排查同音错字问题）
    OpLogService.instance.record(
      opId ?? '',
      'local_asr_hotwords',
      '本地识别热词 ${hotwords.length} 个',
      data: {'count': hotwords.length, 'sample': hotwords.take(8).toList()},
    );
    final text = await asr.transcribe(bytes, hotwords: hotwords);
    if (text.trim().isEmpty) {
      throw StateError('本地识别未听清，请再说一遍');
    }
    return text;
  }

  /// 语义解析：云端优先（开关开时），失败/关闭开关时强制本地规则解析
  Future<ParseResult> parseText(String text, {String? opId}) async {
    if (parseCloudEnabled && api != null) {
      try {
        return await api!.parse(text, opId: opId);
      } catch (e) {
        OpLogService.instance.record(
          opId ?? '',
          'parse_fallback',
          '云端解析失败，切换本地解析: $e',
          level: 'warn',
        );
      }
    }
    return localParser.parse(text, firefighters: orgDirectory.parserNames);
  }


  @override
  Future<void> refreshPendingMembersCount() {
    if (_disposed ||
        !_authenticated ||
        api == null ||
        _isGuest ||
        _protectedDataRevoked) {
      return Future.value();
    }
    if (_memberReviewFuture != null) {
      _memberReviewAgain = true;
      return _memberReviewFuture!;
    }
    final generation = _memberReviewGeneration;
    Future<void> drain() async {
      try {
        do {
          _memberReviewAgain = false;
          await _refreshMemberReview();
        } while (_memberReviewAgain &&
            !_disposed &&
            generation == _memberReviewGeneration);
      } finally {
        if (generation == _memberReviewGeneration) _memberReviewFuture = null;
      }
    }

    final future = drain();
    _memberReviewFuture = future;
    return future;
  }

  Future<void> _refreshMemberReview() async {
    final activeApi = api!;
    final epoch = protectedDataEpoch;
    final generation = _memberReviewGeneration;
    bool current() =>
        !_disposed &&
        _authenticated &&
        !_isGuest &&
        !_protectedDataRevoked &&
        api == activeApi &&
        epoch == protectedDataEpoch &&
        generation == _memberReviewGeneration;
    memberReviewLoading = true;
    _notify();
    try {
      final allowed = await activeApi.fetchMemberReviewCapability();
      if (!current()) return;
      canReviewMembers = allowed;
      if (!allowed) {
        pendingMembers = [];
        memberReviewHistory = [];
        pendingMemberCount = 0;
        memberReviewError = null;
        return;
      }
      final unitName = await Settings.unitName;
      final pending = await activeApi.fetchPendingMembers();
      final history = await activeApi.fetchMemberReviewHistory();
      if (!current()) return;
      memberReviewUnitName = unitName;
      pendingMembers = pending;
      pendingMemberCount = pending.length;
      memberReviewHistory = history;
      memberReviewError = null;
    } catch (error) {
      if (!current()) return;
      memberReviewError = error.toString();
      // Never retain personal data after authorization fails or becomes uncertain.
      if (error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        canReviewMembers = false;
        pendingMembers = [];
        memberReviewHistory = [];
        pendingMemberCount = 0;
      }
    } finally {
      if (current()) {
        memberReviewLoading = false;
        _notify();
      }
    }
  }

}
