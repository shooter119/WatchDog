import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/app_version.dart';
import '../../../design_system/design_system.dart';
import '../state/settings_store.dart';
import 'about_page.dart';
import 'component_gallery_page.dart';
import 'op_log_page.dart';
import 'profile_identity_hero.dart';
import 'settings_appearance_section.dart';
import 'settings_calc_alert_section.dart';
import 'settings_server_update_section.dart';
import 'settings_widgets.dart';
import 'watermark_settings_page.dart';

export 'profile_identity_hero.dart' show ProfileHubRoutes;

/// Tab 3「我的」主页面：身份 Hero → 队站管理 → 系统设置。
class ProfileHubPage extends StatefulWidget {
  const ProfileHubPage({
    super.key,
    required this.store,
    this.routes = const ProfileHubRoutes(),
    this.autoLoad = true,
  });

  final SettingsStore store;
  final ProfileHubRoutes routes;
  final bool autoLoad;

  @override
  State<ProfileHubPage> createState() => _ProfileHubPageState();
}

class _ProfileHubPageState extends State<ProfileHubPage> {
  final TextEditingController _server = TextEditingController();
  final TextEditingController _full = TextEditingController();
  final TextEditingController _consumption = TextEditingController();
  final TextEditingController _warn = TextEditingController();
  final TextEditingController _alarm = TextEditingController();
  final FocusNode _serverFocus = FocusNode();
  final FocusNode _fullFocus = FocusNode();
  final FocusNode _consumptionFocus = FocusNode();
  final FocusNode _warnFocus = FocusNode();
  final FocusNode _alarmFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _serverSectionKey = GlobalKey();

  bool _calcExpanded = false, _voiceExpanded = false;
  bool _alertExpanded = false, _serverExpanded = false;
  bool _syncedLoadedInputs = false;

  List<FocusNode> get _focusNodes => <FocusNode>[
    _serverFocus,
    _fullFocus,
    _consumptionFocus,
    _warnFocus,
    _alarmFocus,
  ];

  @override
  void initState() {
    super.initState();
    for (final node in _focusNodes) {
      node.addListener(() {
        if (widget.store.loaded &&
            !node.hasFocus &&
            _focusNodes.every((n) => !n.hasFocus)) {
          _syncDrafts();
          unawaited(widget.store.autoSave());
        }
      });
    }
    widget.store.addListener(_onStoreChanged);
    _pullInputs();
    if (widget.autoLoad && !widget.store.loaded) unawaited(widget.store.load());
  }

  @override
  void didUpdateWidget(covariant ProfileHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
      _syncedLoadedInputs = false;
      _pullInputs();
    }
  }

  void _onStoreChanged() {
    if (!mounted) return;
    if (widget.store.loaded && !_syncedLoadedInputs) {
      _syncedLoadedInputs = true;
      _pullInputs();
    }
    setState(() {});
  }

  void _pullInputs() {
    final s = widget.store;
    if (!_serverFocus.hasFocus) _server.text = s.serverUrl;
    if (!_fullFocus.hasFocus) _full.text = s.fullPressureText;
    if (!_consumptionFocus.hasFocus) _consumption.text = s.consumptionText;
    if (!_warnFocus.hasFocus) _warn.text = s.warnText;
    if (!_alarmFocus.hasFocus) _alarm.text = s.alarmText;
  }

  void _syncDrafts({bool notify = false}) => widget.store.updateDraftInputs(
    serverUrl: _server.text,
    fullPressureText: _full.text,
    consumptionText: _consumption.text,
    warnText: _warn.text,
    alarmText: _alarm.text,
    notify: notify,
  );

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _scrollController.dispose();
    _server.dispose();
    _full.dispose();
    _consumption.dispose();
    _warn.dispose();
    _alarm.dispose();
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _inspectServerConnection() {
    if (!_serverExpanded) setState(() => _serverExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _serverSectionKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.12,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _handleConnectionTap() async {
    final conn = widget.store.connection;
    if (!conn.isGuest && (conn.syncError != null || conn.connectionLost)) {
      unawaited(widget.store.refreshConnection());
    }
    _inspectServerConnection();
  }

  Future<void> _handleLeaveUnit() async {
    final ok = await SettingsUpdateSheets.showLeaveUnitConfirm(
      context,
      unitName: widget.store.identity.unitName,
    );
    if (ok && mounted) await widget.store.leaveUnit();
  }

  Future<void> _handleAdminScan() async {
    if (await widget.store.prepareAdminScan() && mounted) {
      await widget.routes.onOpenAdminScanner?.call(context);
    }
  }

  Future<void> _handleToggleAsrCloud(bool value) async {
    if (!value) {
      final installed = await widget.store.ensureModelInstalledStatus();
      if (!mounted) return;
      if (!installed) {
        final go = await SettingsUpdateSheets.showOfflineModelConfirm(context);
        if (!mounted || !go || !(await _downloadModel())) return;
      }
    }
    if (!mounted) return;
    _syncDrafts();
    await widget.store.setAsrCloudEnabled(value);
  }

  Future<bool> _downloadModel() async {
    final outcome = await widget.store.downloadModel();
    if (!mounted) return false;
    if (outcome.insufficientStorageBytes != null) {
      final open = await SettingsUpdateSheets.showStorageRecovery(
        context,
        availableBytes: outcome.insufficientStorageBytes!,
      );
      if (open) await widget.store.openStorageSettings();
    }
    return outcome.ok;
  }

  void _open(Future<void> Function(BuildContext)? custom, Widget fallback) {
    if (custom != null) {
      unawaited(custom(context));
    } else {
      Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => fallback));
    }
  }

  void _invokeRoute(Future<void> Function(BuildContext)? route) {
    if (route != null) unawaited(route(context));
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final id = store.identity;
    final pendingUpdate = store.isDebugMode ? null : store.update.pendingUpdate;
    final displayVer = store.displayVersion(appVersion);
    final versionSummary = store.checkingUpdate
        ? '检查中 · v$displayVer'
        : pendingUpdate != null
        ? '有新版 · v$displayVer'
        : store.isDebugMode
        ? '测试版 · v$displayVer'
        : 'v$displayVer';

    return CommandScaffold(
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(DsSpacing.pageMargin, DsSpacing.md, DsSpacing.pageMargin, 36),
        children: <Widget>[
          _buildTopHeader(context.ds),
          const SizedBox(height: DsSpacing.md),
          ProfileIdentityHeroCard(
            identity: id,
            onDevices: () => widget.routes.onOpenLoginDevices?.call(context),
            onReview: () => widget.routes.onOpenOfflineReview?.call(context),
            onLeave: _handleLeaveUnit,
            onJoin: () => unawaited(store.leaveUnit()),
            onScan: _handleAdminScan,
          ),
          const SizedBox(height: DsSpacing.xl),
          const SettingsSectionTitle(text: '现场与采集'),
          SettingsGroupCard(
            children: <Widget>[
              SettingsNavRow(
                icon: DsIcons.watermark,
                title: '水印设置',
                onTap: () => _open(widget.routes.onOpenWatermarkSettings, const WatermarkSettingsPage()),
              ),
              if (id.canManageVideoResources)
                SettingsNavRow(
                  rowKey: const Key('video-resource-settings'),
                  icon: DsIcons.video,
                  title: '视频资源管理',
                  enabled: id.hasApi && widget.routes.onOpenVideoAdmin != null,
                  onTap: () => _invokeRoute(widget.routes.onOpenVideoAdmin),
                ),
            ],
          ),
          const SizedBox(height: DsSpacing.xl),
          const SettingsSectionTitle(text: '队站管理'),
          SettingsGroupCard(
            children: <Widget>[
              if (id.canReviewMembers || id.memberReviewError != null)
                SettingsNavRow(
                  icon: DsIcons.memberApprove,
                  title: '入队审批',
                  badge: id.pendingMemberCount > 0,
                  subtitle: id.memberReviewError != null
                      ? '审批信息加载失败，点击重试'
                      : id.pendingMemberCount > 0
                      ? '${id.pendingMemberCount} 条待处理 · 本单位管理员共同审批'
                      : null,
                  onTap: () => _invokeRoute(widget.routes.onOpenMemberReview),
                ),
              SettingsNavRow(
                icon: DsIcons.roster,
                title: '人员与热词',
                subtitle: id.pendingMemberCount > 0 ? '${id.pendingMemberCount} 名队员待审批' : null,
                badge: id.pendingMemberCount > 0,
                onTap: () => _invokeRoute(widget.routes.onOpenRoster),
              ),
              SettingsNavRow(
                icon: DsIcons.stations,
                title: '单位常用队伍',
                enabled: id.hasApi && widget.routes.onOpenUnitStations != null,
                onTap: () => _invokeRoute(widget.routes.onOpenUnitStations),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xl),
          const SettingsSectionTitle(text: '数据与记录'),
          SettingsGroupCard(
            children: <Widget>[
              SettingsNavRow(
                icon: DsIcons.archive,
                title: '归档警情',
                onTap: () => _invokeRoute(widget.routes.onOpenArchivedIncidents),
              ),
              SettingsNavRow(
                icon: DsIcons.stats,
                title: '数据统计',
                onTap: () => _invokeRoute(widget.routes.onOpenStats),
              ),
              SettingsNavRow(
                icon: DsIcons.opLog,
                title: '操作日志',
                onTap: () => _open(
                  widget.routes.onOpenOpLog,
                  OpLogPage(onFlush: widget.routes.onFlushOpLogs),
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xl),
          const SettingsSectionTitle(text: '系统设置'),
          SettingsGroupCard(
            children: <Widget>[
              SettingsExpandRow(
                icon: DsIcons.calculator,
                title: '计算参数',
                summary: store.calcSummary,
                expanded: _calcExpanded,
                onToggle: () => setState(() => _calcExpanded = !_calcExpanded),
                child: SettingsCalcBody(
                  cylinderVolL: store.cylinderVolL,
                  onCylinderVolChanged: (v) {
                    _syncDrafts();
                    unawaited(store.setCylinderVolL(v));
                  },
                  fullPressureController: _full,
                  consumptionController: _consumption,
                  warnController: _warn,
                  alarmController: _alarm,
                  fullPressureFocus: _fullFocus,
                  consumptionFocus: _consumptionFocus,
                  warnFocus: _warnFocus,
                  alarmFocus: _alarmFocus,
                  onThresholdTextChanged: () => _syncDrafts(notify: true),
                ),
              ),
              SettingsExpandRow(
                icon: DsIcons.voiceLine,
                title: '语音识别',
                summary: store.voiceSummary,
                expanded: _voiceExpanded,
                onToggle: () => setState(() => _voiceExpanded = !_voiceExpanded),
                child: SettingsVoiceBody(
                  asrCloudEnabled: store.asrCloudEnabled,
                  parseCloudEnabled: store.parseCloudEnabled,
                  hasLocalAsr: store.hasLocalAsr,
                  modelInstalled: store.modelInstalled,
                  downloadingModel: store.downloadingModel,
                  downloadProgress: store.downloadProgress,
                  downloadError: store.downloadError,
                  onToggleAsrCloud: (v) => unawaited(_handleToggleAsrCloud(v)),
                  onToggleParseCloud: (v) {
                    _syncDrafts();
                    unawaited(store.setParseCloudEnabled(v));
                  },
                  onDownloadModel: () => unawaited(_downloadModel()),
                  onRemoveModel: () => unawaited(store.removeModel()),
                ),
              ),
              SettingsExpandRow(
                icon: DsIcons.alerts,
                title: '提醒方式',
                summary: store.alertSummary,
                expanded: _alertExpanded,
                onToggle: () => setState(() => _alertExpanded = !_alertExpanded),
                child: SettingsAlertBody(
                  ttsEnabled: store.ttsEnabled,
                  alarmSoundEnabled: store.alarmSoundEnabled,
                  keepScreenOn: store.keepScreenOn,
                  keepAliveEnabled: store.keepAliveEnabled,
                  exactAlarmAvailable: store.alarmCaps.exactAlarmAvailable,
                  policyAccessGranted: store.alarmCaps.policyAccessGranted,
                  fullScreenIntentEnabled: store.alarmCaps.fullScreenIntentEnabled,
                  onToggleTts: (v) {
                    _syncDrafts();
                    unawaited(store.setTtsEnabled(v));
                  },
                  onToggleAlarmSound: (v) {
                    _syncDrafts();
                    unawaited(store.setAlarmSoundEnabled(v));
                  },
                  onToggleKeepScreenOn: (v) {
                    _syncDrafts();
                    unawaited(store.setKeepScreenOn(v));
                  },
                  onToggleKeepAlive: (v) => unawaited(store.toggleKeepAlive(v)),
                  onOpenAlarmsSettings: () => unawaited(store.openAlarmsSettings()),
                  onOpenPolicySettings: () => unawaited(store.openPolicySettings()),
                  onOpenNotificationSettings: () => unawaited(store.openNotificationSettings()),
                ),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xl),
          const SettingsSectionTitle(text: '界面外观'),
          SettingsAppearanceSection(
            currentThemeId: store.themeId,
            onSelectThemeId: store.selectTheme,
          ),
          const SizedBox(height: DsSpacing.xl),
          const SettingsSectionTitle(text: '连接与维护'),
          SettingsGroupCard(
            children: <Widget>[
              SettingsExpandRow(
                key: _serverSectionKey,
                icon: DsIcons.server,
                title: '服务连接',
                summary: store.serverSummary,
                expanded: _serverExpanded,
                onToggle: () => setState(() => _serverExpanded = !_serverExpanded),
                child: SettingsServerBody(serverController: _server, serverFocus: _serverFocus),
              ),
              SettingsNavRow(
                icon: store.checkingUpdate ? DsIcons.sync : DsIcons.update,
                title: '版本更新',
                badge: pendingUpdate != null && !store.checkingUpdate,
                trailingText: versionSummary,
                trailingHighlight: pendingUpdate != null && !store.checkingUpdate,
                enabled: !store.checkingUpdate,
                onTap: () => unawaited(SettingsUpdateSheets.runCheckUpdateFlow(context, store)),
              ),
              SettingsNavRow(
                icon: DsIcons.info,
                title: '关于项目',
                onTap: () => _open(widget.routes.onOpenAbout, const AboutPage()),
              ),
              if (kDebugMode)
                SettingsNavRow(
                  icon: DsIcons.appearance,
                  title: 'UI 规范与组件画廊（调试）',
                  onTap: () => _open(widget.routes.onOpenComponentGallery, const ComponentGalleryPage()),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeader(DsTheme ds) {
    final conn = widget.store.connection;
    final Widget? pill = conn.isGuest
        ? Semantics(
            button: true,
            label: '单机模式，点击查看服务连接',
            child: InkWell(
              key: const Key('profile-connection-pill'),
              borderRadius: DsRadius.borderPill,
              onTap: _inspectServerConnection,
              child: const StatusPill(
                status: DsStatus.neutral,
                icon: DsIcons.user,
                label: '单机模式',
              ),
            ),
          )
        : (conn.syncing || conn.connectionLost || conn.syncError != null)
        ? ConnectionPill(
            key: const Key('profile-connection-pill'),
            state: conn.syncing
                ? DsConnectionState.reconnecting
                : DsConnectionState.offline,
            pendingCount: conn.pendingOfflineCount,
            onTap: () => unawaited(_handleConnectionTap()),
          )
        : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              Text('我的', style: ds.typography.display.copyWith(color: ds.colors.textPrimary)),
              const SizedBox(width: DsSpacing.sm),
              Flexible(child: SettingsSaveStatusBadge(state: widget.store.saveState)),
            ],
          ),
        ),
        if (pill != null) ...<Widget>[
          const SizedBox(width: DsSpacing.sm),
          pill,
        ],
      ],
    );
  }
}
