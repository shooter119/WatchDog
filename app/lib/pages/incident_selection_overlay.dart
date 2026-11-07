import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/settings.dart';
import '../theme/app_widgets.dart';

/// 启动时的认证/警情选择层。
///
/// 首次安装先显示单位认证，认证成功后在同一个浮层切换为警情选择。
/// 支持选择现有警情、新建警情或直接进入 App；游客可先行体验单机功能。
class IncidentSelectionOverlay extends StatefulWidget {
  final bool authenticationRequired;
  final List<Incident> activeIncidents;
  final List<ExternalIncident> externalIncidents;
  final bool loading;
  final bool externalLoading;
  final VoidCallback? onEnterWithoutIncident;
  final Future<void> Function(Incident incident) onSelect;
  final Future<void> Function() onCreate;
  final Future<void> Function(ExternalIncident incident)? onClaimExternal;
  final Future<void> Function({bool forceRefresh})? onRefreshExternal;
  final Future<void> Function(
    String unitName,
    String realName,
    String unitCode,
  )?
  onAuthenticate;
  final Future<void> Function()? onEnterGuestMode;
  final Future<Map<String, dynamic>> Function(
    String unitName,
    String realName,
    String unitCode, {
    String? stationName,
    String? phone,
    String? applyReason,
  })?
  onApply;

  const IncidentSelectionOverlay({
    super.key,
    this.authenticationRequired = false,
    required this.activeIncidents,
    this.externalIncidents = const [],
    required this.loading,
    this.externalLoading = false,
    required this.onSelect,
    required this.onCreate,
    this.onClaimExternal,
    this.onRefreshExternal,
    this.onAuthenticate,
    this.onEnterGuestMode,
    this.onApply,
    this.onEnterWithoutIncident,
  });

  @override
  State<IncidentSelectionOverlay> createState() =>
      _IncidentSelectionOverlayState();
}

class _IncidentSelectionOverlayState extends State<IncidentSelectionOverlay>
    with WidgetsBindingObserver {
  bool _busy = false;
  String? _error;
  Map<String, String>? _pendingApp;
  final TextEditingController _unitName = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final TextEditingController _unitCode = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  String _searchKeyword = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreIdentityDefaults();
    _checkLocalPending();
    if (!widget.authenticationRequired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onRefreshExternal?.call(forceRefresh: false);
        }
      });
    }
  }

  @override
  void didUpdateWidget(IncidentSelectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authenticationRequired && !widget.authenticationRequired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onRefreshExternal?.call(forceRefresh: false);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingApp != null && !_busy) {
      _checkPendingStatus(silent: true);
    }
  }

  Future<void> _checkLocalPending() async {
    final pending = await Settings.pendingApplication;
    if (mounted) {
      setState(() => _pendingApp = pending);
    }
  }

  Future<void> _restoreIdentityDefaults() async {
    final unitName = await Settings.unitName;
    final realName = await Settings.realName;
    if (!mounted) return;
    if (_unitName.text.isEmpty && unitName.trim().isNotEmpty) {
      _unitName.text = unitName.trim();
    }
    if (_realName.text.isEmpty && realName.trim().isNotEmpty) {
      _realName.text = realName.trim();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unitName.dispose();
    _realName.dispose();
    _unitCode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _select(Incident incident) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSelect(incident);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim(ExternalIncident incident) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.onClaimExternal != null) {
        await widget.onClaimExternal!(incident);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshExternal() async {
    if (_busy) return;
    try {
      await widget.onRefreshExternal?.call(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authenticate() async {
    if (_busy) return;
    final unitName = _unitName.text.trim();
    final name = _realName.text.trim();
    final code = _unitCode.text.trim();
    if (unitName.isEmpty) {
      await _showAuthenticationError('请输入单位名称');
      return;
    }
    if (name.isEmpty) {
      await _showAuthenticationError('请输入真实姓名');
      return;
    }
    if (code.isEmpty) {
      await _showAuthenticationError('请输入单位验证码');
      return;
    }
    final callback = widget.onAuthenticate;
    if (callback == null) {
      await _showAuthenticationError('认证服务未就绪，请稍后重试');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await callback(unitName, name, code);
      await Settings.clearPendingApplication();
      if (mounted) setState(() => _pendingApp = null);
    } catch (error) {
      if (!mounted) return;
      if (error is ApiException) {
        if (error.code == 'MEMBER_APPLICATION_PENDING') {
          await Settings.setPendingApplication(
            unitName: unitName,
            unitCode: code,
            realName: name,
          );
          if (mounted) {
            setState(() {
              _pendingApp = {
                'unit_name': unitName,
                'unit_code': code,
                'real_name': name,
                'submitted_at': DateTime.now().toIso8601String(),
              };
            });
          }
          return;
        } else if (error.code == 'MEMBER_APPLICATION_REJECTED') {
          await Settings.clearPendingApplication();
          if (mounted) {
            setState(() => _pendingApp = null);
            await _showAuthenticationError('您的入队申请已被站长驳回，请联系管理员或重新填写申请。');
          }
          return;
        } else if (error.code == 'MEMBER_ROSTER_ONLY') {
          await _promptRosterOnlyApplication(unitName, name, code);
          return;
        } else if (error.code == 'MEMBER_NOT_ALLOWED') {
          if (error.suggestions.isNotEmpty) {
            await _promptNameSuggestions(
              unitName,
              name,
              code,
              error.suggestions,
            );
          } else {
            await _promptSubmitApplication(unitName, name, code);
          }
          return;
        }
      }
      await _showAuthenticationError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _promptRosterOnlyApplication(
    String unitName,
    String realName,
    String unitCode,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('该姓名还没有登录权限'),
        content: Text(
          '「$realName」已在语音识别名单中，但还没有登录权限。请提交入队申请，管理员在「设置 → 入队审批」批准后即可登录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('提交入队申请'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _submitApplication(unitName, realName, unitCode);
    }
  }

  Future<void> _promptNameSuggestions(
    String unitName,
    String realName,
    String unitCode,
    List<String> suggestions,
  ) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('没有找到这个姓名'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('你要找的是不是：'),
            const SizedBox(height: AppSpacing.s2),
            for (final candidate in suggestions)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                child: Material(
                  color: AppColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.pop(ctx, 'select:$candidate'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s3,
                        vertical: AppSpacing.s3,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: AppSpacing.s2),
                          Expanded(
                            child: Text(
                              candidate,
                              style: AppTextStyles.bodyMd.copyWith(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: AppColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('返回修改'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'apply'),
            child: const Text('仍要提交入队申请'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action.startsWith('select:')) {
      final selected = action.substring('select:'.length);
      _realName.text = selected;
      _realName.selection = TextSelection.collapsed(offset: selected.length);
      return;
    }
    if (action == 'apply') {
      await _promptSubmitApplication(unitName, realName, unitCode);
    }
  }

  Future<void> _promptSubmitApplication(
    String unitName,
    String realName,
    String unitCode,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未加入单位名单'),
        content: Text('姓名「$realName」尚未加入「$unitName」的正式队员名单。\n\n是否立即向站长提交入队申请？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('提交入队申请'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _submitApplication(unitName, realName, unitCode);
    }
  }

  Future<void> _submitApplication(
    String unitName,
    String realName,
    String unitCode,
  ) async {
    final applyCallback = widget.onApply;
    if (applyCallback == null) {
      await _showAuthenticationError('申请服务未就绪，请稍后重试');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await applyCallback(unitName, realName, unitCode);
      final pending = await Settings.pendingApplication;
      if (mounted) {
        setState(() => _pendingApp = pending);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已提交至$unitName，等待管理员审批')));
      }
    } catch (e) {
      if (mounted) await _showAuthenticationError('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkPendingStatus({bool silent = false}) async {
    final pending = _pendingApp;
    if (pending == null) return;
    final callback = widget.onAuthenticate;
    if (callback == null) return;
    if (!silent) {
      setState(() => _busy = true);
    }
    try {
      await callback(
        pending['unit_name'] ?? '',
        pending['real_name'] ?? '',
        pending['unit_code'] ?? '',
      );
      await Settings.clearPendingApplication();
      if (mounted) {
        setState(() => _pendingApp = null);
      }
    } catch (e) {
      if (!silent && mounted) {
        if (e is ApiException && e.code == 'MEMBER_APPLICATION_PENDING') {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('站长尚未审批，请稍候再试')));
        } else if (e is ApiException &&
            e.code == 'MEMBER_APPLICATION_REJECTED') {
          await Settings.clearPendingApplication();
          setState(() => _pendingApp = null);
          await _showAuthenticationError('您的申请已被驳回，请重新申请');
        } else {
          await _showAuthenticationError('$e');
        }
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _showAuthenticationError(String message) async {
    if (!mounted) return;
    setState(() => _error = message);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('认证失败'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthentication() {
    final hasKeyboard = MediaQuery.viewInsetsOf(context).bottom > 80;
    return Column(
      mainAxisSize: hasKeyboard ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          fit: hasKeyboard ? FlexFit.loose : FlexFit.tight,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!hasKeyboard) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.actionPrimary.withValues(
                            alpha: 0.13,
                          ),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Icon(
                          Icons.verified_user_outlined,
                          color: AppColors.actionPrimary,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '先完成用户认证',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '认证后才能查看和记录本单位的现场警情。',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ] else ...[
                  Center(
                    child: Container(
                      key: const Key('auth-sheet-handle'),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.textTertiary.withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '用户认证',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '使用单位账号继续',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  key: const Key('auth-unit-name'),
                  controller: _unitName,
                  enabled: !_busy,
                  maxLength: 120,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '单位名称',
                    hintText: '请输入所属消防救援单位全称',
                    prefixIcon: Icon(Icons.business_outlined),
                    counterText: '',
                  ),
                ),
                SizedBox(height: hasKeyboard ? 10 : 12),
                TextField(
                  key: const Key('auth-real-name'),
                  controller: _realName,
                  enabled: !_busy,
                  maxLength: 20,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '真实姓名',
                    hintText: '请输入姓名，用于现场记录署名',
                    prefixIcon: Icon(Icons.person_outline),
                    counterText: '',
                  ),
                ),
                SizedBox(height: hasKeyboard ? 10 : 12),
                TextField(
                  key: const Key('auth-unit-code'),
                  controller: _unitCode,
                  enabled: !_busy,
                  maxLength: 12,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _authenticate(),
                  decoration: const InputDecoration(
                    labelText: '单位验证码',
                    hintText: '请输入 4 位验证码',
                    prefixIcon: Icon(Icons.password_outlined),
                    counterText: '',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  AppNotice(
                    key: const Key('auth-error'),
                    kind: AppNoticeKind.error,
                    text: _error!,
                  ),
                ],
              ],
            ),
          ),
        ),
        FilledButton.icon(
          key: const Key('auth-submit'),
          onPressed: _busy ? null : _authenticate,
          icon: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.onPrimary,
                  ),
                )
              : const Icon(Icons.arrow_forward_rounded),
          label: const Text('认证并继续'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        ),
        if (!hasKeyboard && widget.onEnterGuestMode != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('auth-guest-mode'),
            onPressed: _busy ? null : widget.onEnterGuestMode,
            icon: const Icon(Icons.explore_outlined, size: 18),
            label: const Text('先以游客身份体验（单机可用）'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              foregroundColor: AppColors.textPrimary,
            ),
          ),
        ],
        if (!hasKeyboard) ...[
          const SizedBox(height: 8),
          Text(
            '首次认证成功后，本机将记住当前单位和姓名。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildPendingApprovalView() {
    final pending = _pendingApp!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.noticeWarningBg,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Icon(
                        Icons.hourglass_top_rounded,
                        color: AppColors.noticeWarningFg,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '入队申请审核中',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '申请已提交，等待站长或安全员审批通过。',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSubtle,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow('申请单位', pending['unit_name'] ?? '-'),
                      const Divider(height: 20),
                      _buildInfoRow('申请队员', pending['real_name'] ?? '-'),
                      if ((pending['station_name'] ?? '').isNotEmpty) ...[
                        const Divider(height: 20),
                        _buildInfoRow('所属队站', pending['station_name']!),
                      ],
                      if ((pending['phone'] ?? '').isNotEmpty) ...[
                        const Divider(height: 20),
                        _buildInfoRow('联系电话', pending['phone']!),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '💡 站长在手机 App【设置 → 入队审批】中点击同意后，切回本页面或点击下方按钮即可自动完成登录。',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        FilledButton.icon(
          key: const Key('pending-check-status'),
          onPressed: _busy ? null : () => _checkPendingStatus(silent: false),
          icon: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.onPrimary,
                  ),
                )
              : const Icon(Icons.refresh_rounded),
          label: const Text('检查审批状态'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        if (widget.onEnterGuestMode != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('pending-guest-mode'),
            onPressed: widget.onEnterGuestMode,
            icon: const Icon(Icons.explore_outlined, size: 18),
            label: const Text('先以游客身份体验'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ],
        const SizedBox(height: 6),
        TextButton(
          key: const Key('pending-cancel-app'),
          onPressed: _busy
              ? null
              : () async {
                  await Settings.clearPendingApplication();
                  if (mounted) setState(() => _pendingApp = null);
                },
          child: Text(
            '撤销申请并重新填写',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
      ],
    );
  }

  List<_UnifiedIncidentItem> _buildUnifiedIncidentItems() {
    final customItems = <_UnifiedIncidentItem>[];
    for (final inc in widget.activeIncidents) {
      final hasExternal = inc.info['external_id'] != null ||
          widget.externalIncidents.any((e) =>
              e.incidentNumber == inc.number || e.claimedIncidentId == inc.id);
      if (!hasExternal) {
        customItems.add(_UnifiedIncidentItem(
          key: 'custom_${inc.id}',
          title: inc.displayName,
          subtitle: inc.unresolvedActiveCount > 0
              ? '${inc.unresolvedActiveCount}人处置中'
              : '内部自建警情',
          badgeText: '自建',
          badgeBg: const Color(0xFFF39C12).withValues(alpha: 0.15),
          badgeFg: const Color(0xFFD35400),
          actionText: '加入',
          isClaimed: true,
          isCustom: true,
          onTap: () => _select(inc),
        ));
      }
    }

    final externalItems = <_UnifiedIncidentItem>[];
    for (final ext in widget.externalIncidents) {
      Incident? matched;
      for (final local in widget.activeIncidents) {
        if (local.id == ext.claimedIncidentId ||
            local.number == ext.incidentNumber ||
            local.info['external_id'] == ext.externalId) {
          matched = local;
          break;
        }
      }
      final isClaimed = ext.claimed || matched != null;
      final timeStr = _formatIncidentTime(ext.registerTime);
      final subtitleParts = <String>[
        if (ext.districtName.isNotEmpty) ext.districtName,
        if (ext.incidentType.isNotEmpty) ext.incidentType,
        if (timeStr.isNotEmpty) timeStr,
      ];

      externalItems.add(_UnifiedIncidentItem(
        key: 'ext_${ext.externalId}',
        title: ext.crimeAddress.isNotEmpty ? ext.crimeAddress : ext.incidentNumber,
        subtitle: subtitleParts.join(' · '),
        badgeText: isClaimed ? '处置中' : '待认领',
        badgeBg: isClaimed
            ? AppColors.actionPrimary.withValues(alpha: 0.12)
            : const Color(0xFF27AE60).withValues(alpha: 0.14),
        badgeFg: isClaimed ? AppColors.actionPrimary : const Color(0xFF1E8449),
        actionText: isClaimed ? '加入' : '认领建档',
        isClaimed: isClaimed,
        isCustom: false,
        onTap: () {
          if (isClaimed) {
            if (matched != null) {
              _select(matched);
            } else {
              _claim(ext);
            }
          } else {
            _claim(ext);
          }
        },
      ));
    }

    final allItems = [...customItems, ...externalItems];
    final query = _searchKeyword.trim().toLowerCase();
    if (query.isEmpty) return allItems;

    return allItems.where((item) {
      return item.title.toLowerCase().contains(query) ||
          item.subtitle.toLowerCase().contains(query) ||
          item.badgeText.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final incidents = widget.activeIncidents;
    return Semantics(
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: widget.authenticationRequired ? '用户认证' : '选择警情或直接进入',
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
            ),
          ),
          const ModalBarrier(dismissible: false, color: Colors.transparent),
          SafeArea(
            child: AnimatedPadding(
              padding: MediaQuery.viewInsetsOf(context),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final hasKeyboard =
                      MediaQuery.viewInsetsOf(context).bottom > 80;
                  // 首帧或键盘切换时约束可能暂时小于边距，不能把负值传给
                  // SizedBox，否则会触发红屏：BoxConstraints(-32, -32)。
                  final width = math.max(
                    1.0,
                    math.min(constraints.maxWidth - 32, 560.0),
                  );
                  final height = math.max(
                    1.0,
                    math.min(
                      constraints.maxHeight - (hasKeyboard ? 16 : 20),
                      640.0,
                    ),
                  );
                  final keyboardAuth =
                      widget.authenticationRequired && hasKeyboard;
                  final keyboardWidth = math.max(
                    1.0,
                    math.min(constraints.maxWidth, 560.0),
                  );
                  return Align(
                    alignment: keyboardAuth
                        ? Alignment.bottomCenter
                        : Alignment.center,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: keyboardAuth ? 8 : 0),
                      child: ConstrainedBox(
                        constraints: keyboardAuth
                            ? BoxConstraints(
                                minWidth: keyboardWidth,
                                maxWidth: keyboardWidth,
                                maxHeight: height,
                              )
                            : BoxConstraints.tightFor(
                                width: width,
                                height: height,
                              ),
                        child: Material(
                          key: const Key('incident-selection-overlay'),
                          color: AppColors.surface,
                          elevation: keyboardAuth ? 16 : 12,
                          shadowColor: Colors.black.withValues(alpha: 0.3),
                          shape: RoundedRectangleBorder(
                            borderRadius: keyboardAuth
                                ? const BorderRadius.vertical(
                                    top: Radius.circular(AppRadius.xl),
                                  )
                                : BorderRadius.circular(AppRadius.xl),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              20,
                              keyboardAuth ? 10 : (hasKeyboard ? 14 : 22),
                              20,
                              hasKeyboard ? 12 : 18,
                            ),
                            child: widget.authenticationRequired
                                ? (_pendingApp != null
                                      ? _buildPendingApprovalView()
                                      : _buildAuthentication())
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            width: 44,
                                            height: 44,
                                            decoration: BoxDecoration(
                                              color: AppColors.actionPrimary
                                                  .withValues(alpha: 0.13),
                                              borderRadius:
                                                  BorderRadius.circular(AppRadius.md),
                                            ),
                                            child: Icon(
                                              Icons
                                                  .local_fire_department_outlined,
                                              color: AppColors.actionPrimary,
                                              size: 26,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '选择警情或直接进入',
                                                  style: TextStyle(
                                                    fontSize: 21,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                SizedBox(height: 4),
                                                Text(
                                                  '需要处置时再选择或新建警情；也可以先进入 App 使用其他功能。',
                                                  style: TextStyle(
                                                    color:
                                                        AppColors.textSecondary,
                                                    fontSize: 13,
                                                    height: 1.35,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (widget.loading) ...[
                                        const SizedBox(height: 14),
                                        Row(
                                          children: [
                                            SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              '正在同步现有警情…',
                                              style: TextStyle(
                                                color: AppColors.textSecondary,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (_error != null) ...[
                                        const SizedBox(height: 12),
                                        AppNotice(
                                          key: const Key(
                                            'incident-selection-error',
                                          ),
                                          kind: AppNoticeKind.error,
                                          text: _error!,
                                        ),
                                      ],
                                      if (widget.externalLoading) ...[
                                        const SizedBox(height: 10),
                                        Row(
                                          children: [
                                            const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '正在获取衢州官方派警…',
                                              style: TextStyle(
                                                color: AppColors.textSecondary,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      const SizedBox(height: 14),
                                      // 搜索与手动刷新栏
                                      Row(
                                        children: [
                                          Expanded(
                                            child: SizedBox(
                                              height: 38,
                                              child: TextField(
                                                controller: _searchController,
                                                onChanged: (v) => setState(() => _searchKeyword = v),
                                                style: const TextStyle(fontSize: 13),
                                                decoration: InputDecoration(
                                                  hintText: '搜索地址、类型或编号…',
                                                  hintStyle: TextStyle(
                                                    fontSize: 13,
                                                    color: AppColors.textTertiary,
                                                  ),
                                                  prefixIcon: const Icon(Icons.search, size: 18),
                                                  suffixIcon: _searchKeyword.isNotEmpty
                                                      ? IconButton(
                                                          icon: const Icon(Icons.clear, size: 16),
                                                          onPressed: () {
                                                            _searchController.clear();
                                                            setState(() => _searchKeyword = '');
                                                          },
                                                        )
                                                      : null,
                                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                                                  filled: true,
                                                  fillColor: AppColors.surfaceSubtle,
                                                  border: OutlineInputBorder(
                                                    borderRadius: BorderRadius.circular(AppRadius.sm),
                                                    borderSide: BorderSide.none,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          IconButton(
                                            tooltip: '刷新派警列表',
                                            icon: widget.externalLoading
                                                ? const SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child: CircularProgressIndicator(strokeWidth: 2),
                                                  )
                                                : const Icon(Icons.refresh, size: 20),
                                            onPressed: (_busy || widget.externalLoading) ? null : _refreshExternal,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Expanded(
                                        child: Builder(
                                          builder: (context) {
                                            final items = _buildUnifiedIncidentItems();
                                            if (items.isEmpty) {
                                              return const _EmptyIncidentState();
                                            }
                                            return ListView.separated(
                                              key: const Key('incident-selection-list'),
                                              padding: EdgeInsets.zero,
                                              itemCount: items.length,
                                              separatorBuilder: (_, __) => const Divider(height: 1),
                                              itemBuilder: (context, index) {
                                                final item = items[index];
                                                return _UnifiedIncidentOption(
                                                  item: item,
                                                  enabled: !_busy,
                                                );
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      FilledButton.icon(
                                        onPressed: _busy ? null : _create,
                                        icon: const Icon(Icons.add),
                                        label: const Text('新建警情'),
                                        style: FilledButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                        ),
                                      ),
                                      if (widget.onEnterWithoutIncident != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                          ),
                                          child: OutlinedButton.icon(
                                            onPressed: _busy
                                                ? null
                                                : widget.onEnterWithoutIncident,
                                            icon: const Icon(
                                              Icons.arrow_forward_outlined,
                                            ),
                                            label: const Text('直接进入 App'),
                                            style: OutlinedButton.styleFrom(
                                              minimumSize:
                                                  const Size.fromHeight(52),
                                            ),
                                          ),
                                        ),
                                      const SizedBox(height: 4),
                                      Text(
                                        incidents.isEmpty
                                            ? '当前没有进行中的警情。新建警情会自动使用时间戳名称。'
                                            : '如果列表中没有目标警情，可新建；系统会自动使用时间戳名称。',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: AppColors.textTertiary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (_busy)
            const Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Colors.transparent),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyIncidentState extends StatelessWidget {
  const _EmptyIncidentState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_copy_outlined,
            size: 72,
            color: AppColors.textTertiary.withValues(alpha: 0.9),
          ),
          const SizedBox(height: 14),
          const Text(
            '当前没有进行中的警情',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '如果你是第一位到达的用户，可以新建警情；也可以直接进入 App。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}


class _UnifiedIncidentItem {
  final String key;
  final String title;
  final String subtitle;
  final String badgeText;
  final Color badgeBg;
  final Color badgeFg;
  final String actionText;
  final bool isClaimed;
  final bool isCustom;
  final VoidCallback onTap;

  _UnifiedIncidentItem({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.badgeText,
    required this.badgeBg,
    required this.badgeFg,
    required this.actionText,
    required this.isClaimed,
    required this.isCustom,
    required this.onTap,
  });
}

class _UnifiedIncidentOption extends StatelessWidget {
  final _UnifiedIncidentItem item;
  final bool enabled;

  const _UnifiedIncidentOption({
    required this.item,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: InkWell(
        excludeFromSemantics: true,
        onTap: enabled ? item.onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: item.badgeBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  item.isCustom
                      ? Icons.flag_outlined
                      : Icons.local_fire_department_outlined,
                  color: item.badgeFg,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: item.badgeBg,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.badgeText,
                            style: TextStyle(
                              color: item.badgeFg,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            item.title,
                            softWrap: true,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.subtitle,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              item.isClaimed
                  ? TextButton.icon(
                      onPressed: enabled ? item.onTap : null,
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: Text(item.actionText),
                      style: TextButton.styleFrom(
                        foregroundColor: item.badgeFg,
                        minimumSize: const Size(64, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    )
                  : FilledButton.tonal(
                      onPressed: enabled ? item.onTap : null,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: Text(
                        item.actionText,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatIncidentTime(int timestampMs) {
  if (timestampMs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$m-$d $h:$min';
}
