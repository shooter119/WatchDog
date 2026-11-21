import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/video_resource_probe.dart';
import '../data/models/video_resource.dart';
import '../data/video_repository.dart';

typedef VideoRepositoryProvider = VideoRepository? Function();
typedef VideoBoolProvider = bool Function();
typedef PipHintReader = Future<bool> Function();
typedef PipHintWriter = Future<void> Function();

/// 视频监控资源列表、可达性探测与管理员可见性状态容器。
///
/// 职责边界：
/// - 通过 [VideoRepository] 拉取当前单位可见视频源及管理员能力；
/// - 通过冻结的 [VideoResourceProbe] 并发探测视频流可达性（绿/红状态判定）；
/// - 维护单次画中画耗电提示持久化键 `pip_hint_shown_v1` 与当前展开条目；
/// - 严禁依赖旧层或跨 Feature Store。
class VideoResourcesStore extends ChangeNotifier {
  /// 画中画会持续解码，属于“看不见但一直耗电”的用法，仅提示一次。
  static const String pipHintKey = 'pip_hint_shown_v1';
  static const String pipHintMessage =
      '切到后台会以系统画中画继续播放；视频解码会持续耗电，不用时请关闭浮窗。';

  VideoResourcesStore({
    VideoRepository? repository,
    VideoRepositoryProvider? repositoryProvider,
    VideoBoolProvider? isGuestProvider,
    VideoBoolProvider? needsAuthenticationProvider,
    Listenable? authListenable,
    VideoResourceAvailabilityChecker availabilityChecker =
        VideoResourceProbe.check,
    PipHintReader? readPipHintShown,
    PipHintWriter? writePipHintShown,
  }) : _repositoryProvider = repositoryProvider ?? (() => repository),
       _isGuestProvider = isGuestProvider,
       _needsAuthenticationProvider = needsAuthenticationProvider,
       _authListenable = authListenable,
       _availabilityChecker = availabilityChecker,
       _readPipHintShown = readPipHintShown ?? _defaultReadPipHintShown,
       _writePipHintShown = writePipHintShown ?? _defaultWritePipHintShown {
    _authListenable?.addListener(_handleAuthChanged);
  }

  final VideoRepositoryProvider _repositoryProvider;
  final VideoBoolProvider? _isGuestProvider;
  final VideoBoolProvider? _needsAuthenticationProvider;
  final Listenable? _authListenable;
  final VideoResourceAvailabilityChecker _availabilityChecker;
  final PipHintReader _readPipHintShown;
  final PipHintWriter _writePipHintShown;

  List<VideoResource> _resources = const <VideoResource>[];
  bool _canManage = false;
  bool _loading = true;
  String? _error;
  final Map<String, bool> _availability = <String, bool>{};
  String? _expandedResourceId;
  bool _pipHintShown = true;
  int _loadGeneration = 0;
  bool _initialized = false;
  bool _disposed = false;

  VideoRepository? get currentRepository => _repositoryProvider();

  bool get isGuest => _isGuestProvider?.call() ?? false;

  bool get needsAuthentication =>
      _needsAuthenticationProvider?.call() ?? false;

  bool get isAuthenticated =>
      !isGuest && !needsAuthentication && currentRepository != null;

  List<VideoResource> get resources =>
      List<VideoResource>.unmodifiable(_resources);

  bool get canManage => _canManage;

  bool get loading => _loading;

  String? get error => _error;

  String? get expandedResourceId => _expandedResourceId;

  bool get pipHintShown => _pipHintShown;

  Map<String, bool> get availability =>
      Map<String, bool>.unmodifiable(_availability);

  bool? availabilityOf(String resourceId) => _availability[resourceId];

  /// 校验视频地址：仅允许无凭据、无锚点的 HTTPS 地址。
  static bool isValidStreamUrl(String streamUrl) {
    final uri = Uri.tryParse(streamUrl);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment;
  }

  /// 初始化：读取画中画单次提示标记并加载视频资源列表。
  Future<void> initialize() async {
    if (_disposed) return;
    if (!_initialized) {
      _initialized = true;
      unawaited(loadPipHintShown());
    }
    await load();
  }

  Future<void> loadPipHintShown() async {
    try {
      final shown = await _readPipHintShown();
      if (_disposed) return;
      if (_pipHintShown != shown) {
        _pipHintShown = shown;
        _notify();
      }
    } catch (_) {
      // 读取失败时保持“已提示”，避免每次进入页面重复弹窗。
    }
  }

  Future<void> load() async {
    if (_disposed) return;
    final repo = currentRepository;
    if (!isAuthenticated || repo == null) {
      _loadGeneration++;
      _resources = const <VideoResource>[];
      _canManage = false;
      _availability.clear();
      _expandedResourceId = null;
      _error = null;
      _loading = false;
      _notify();
      return;
    }

    final generation = ++_loadGeneration;
    _loading = true;
    _error = null;
    _notify();

    try {
      var canManage = false;
      try {
        final access = await repo.videoResourceAccess();
        canManage = access['can_manage'] == true;
      } catch (_) {
        // 旧版部署可能尚未暴露 /access 接口，列表仍应正常加载。
        canManage = false;
      }

      final fetched = await repo.fetchVideoResources();
      if (_disposed || generation != _loadGeneration) return;

      _resources = List<VideoResource>.of(fetched);
      _canManage = canManage;
      _availability.clear();
      if (_expandedResourceId != null &&
          !_resources.any((item) => item.id == _expandedResourceId)) {
        _expandedResourceId = null;
      }
      _loading = false;
      _notify();

      unawaited(_checkAvailability(_resources, generation));
    } catch (err) {
      if (_disposed || generation != _loadGeneration) return;
      _error = '$err';
      _loading = false;
      _notify();
    }
  }

  Future<void> _checkAvailability(
    List<VideoResource> targets,
    int generation,
  ) async {
    await Future.wait(
      targets.map((resource) async {
        var reachable = false;
        try {
          reachable = await _availabilityChecker(resource);
        } catch (_) {
          reachable = false;
        }
        if (_disposed || generation != _loadGeneration) return;
        _availability[resource.id] = reachable;
        _notify();
      }),
    );
  }

  /// 选中并展开某个视频源；地址非法时返回 `false`。
  bool selectExpanded(VideoResource resource) {
    if (!isValidStreamUrl(resource.streamUrl)) {
      return false;
    }
    if (_expandedResourceId != resource.id) {
      _expandedResourceId = resource.id;
      _notify();
    }
    return true;
  }

  /// 收起展开中的视频源。传入 [resourceId] 时仅在匹配时收起。
  void clearExpanded([String? resourceId]) {
    if (resourceId != null && _expandedResourceId != resourceId) return;
    if (_expandedResourceId == null) return;
    _expandedResourceId = null;
    _notify();
  }

  /// 消费单次画中画耗电提示：首次返回 `true` 并异步落盘，后续返回 `false`。
  bool consumePipHintIfNeeded() {
    if (_pipHintShown) return false;
    _pipHintShown = true;
    unawaited(_persistPipHintShown());
    _notify();
    return true;
  }

  Future<void> _persistPipHintShown() async {
    try {
      await _writePipHintShown();
    } catch (_) {
      // 写入失败只影响下次是否重复提示，不影响播放。
    }
  }

  void _handleAuthChanged() {
    if (_disposed) return;
    if (!isAuthenticated) {
      unawaited(load());
    } else {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadGeneration++;
    _authListenable?.removeListener(_handleAuthChanged);
    super.dispose();
  }

  static Future<bool> _defaultReadPipHintShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(pipHintKey) ?? false;
  }

  static Future<void> _defaultWritePipHintShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(pipHintKey, true);
  }
}
