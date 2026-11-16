import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/settings.dart';
import '../theme/app_widgets.dart';
import '../widgets/incident_category_badge.dart';

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
    this.userUnitName,
  });

  final String? userUnitName;

  @override
  State<IncidentSelectionOverlay> createState() =>
      _IncidentSelectionOverlayState();
}

class _IncidentSelectionOverlayState extends State<IncidentSelectionOverlay>
    with WidgetsBindingObserver {
  bool _busy = false;
  String? _error;
  bool _obscureUnitCode = true;
  Map<String, String>? _pendingApp;
  final TextEditingController _unitName = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final TextEditingController _unitCode = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  String _searchKeyword = '';
  String? _currentUserUnitName;

  void _clearError() {
    if (_error != null) {
      setState(() => _error = null);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreIdentityDefaults();
    _checkLocalPending();
    _loadUserUnitName();
    if (!widget.authenticationRequired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onRefreshExternal?.call(forceRefresh: false);
        }
      });
    }
  }

  Future<void> _loadUserUnitName() async {
    final name = await Settings.unitName;
    if (mounted && name.isNotEmpty) {
      setState(() => _currentUserUnitName = name);
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
        backgroundColor: AppColors.surface,
        title: Text(
          '该姓名还没有登录权限',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          '「$realName」已在语音识别名单中，但还没有登录权限。请提交入队申请，管理员在「设置 → 入队审批」批准后即可登录。',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.actionPrimary,
            ),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.actionPrimary,
              foregroundColor: AppColors.onPrimary,
            ),
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
        backgroundColor: AppColors.surface,
        title: Text(
          '没有找到这个姓名',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '你要找的是不是：',
              style: TextStyle(color: AppColors.textSecondary),
            ),
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
            style: TextButton.styleFrom(
              foregroundColor: AppColors.actionPrimary,
            ),
            child: const Text('返回修改'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'apply'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.actionPrimary,
            ),
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
        backgroundColor: AppColors.surface,
        title: Text(
          '未加入单位名单',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          '姓名「$realName」尚未加入「$unitName」的正式队员名单。\n\n是否立即向站长提交入队申请？',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.actionPrimary,
            ),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.actionPrimary,
              foregroundColor: AppColors.onPrimary,
            ),
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
    setState(() {
      _error = message;
      _busy = false;
    });
  }

  Widget _buildNormalHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.noteInfo.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(
            Icons.verified_user_outlined,
            color: AppColors.noteInfo,
            size: 26,
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '先完成用户认证',
                style: AppTextStyles.h1.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: AppSpacing.s1),
              AntiOrphanText(
                text: '认证后才能查看和记录本单位的现场警情。',
                style: AppTextStyles.bodyMd.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildKeyboardHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        const SizedBox(height: AppSpacing.s3),
        Text(
          '用户认证',
          style: AppTextStyles.h2.copyWith(
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          '使用单位账号继续',
          style: AppTextStyles.bodyMd.copyWith(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildAuthentication(double maxHeight) {
    final hasKeyboard = MediaQuery.viewInsetsOf(context).bottom > 80;
    final isExtremeShort = maxHeight < 280;

    final formFields = [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: hasKeyboard
            ? KeyedSubtree(
                key: const ValueKey('auth-keyboard-header'),
                child: _buildKeyboardHeader(),
              )
            : KeyedSubtree(
                key: const ValueKey('auth-normal-header'),
                child: _buildNormalHeader(),
              ),
      ),
      SizedBox(height: isExtremeShort ? AppSpacing.s2 : AppSpacing.s4),
      TextField(
        key: const Key('auth-unit-name'),
        controller: _unitName,
        enabled: !_busy,
        maxLength: 120,
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearError(),
        style: AppTextStyles.bodyMd.copyWith(color: AppColors.textPrimary),
        cursorColor: AppColors.actionPrimary,
        decoration: InputDecoration(
          labelText: '单位名称',
          hintText: '请输入所属消防救援单位全称',
          labelStyle: TextStyle(color: AppColors.textSecondary),
          hintStyle: TextStyle(color: AppColors.textTertiary, fontSize: 13),
          prefixIcon: Icon(
            Icons.business_outlined,
            color: AppColors.textTertiary,
          ),
          filled: true,
          fillColor: AppColors.surface,
          counterText: '',
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('auth-real-name'),
        controller: _realName,
        enabled: !_busy,
        maxLength: 20,
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearError(),
        style: AppTextStyles.bodyMd.copyWith(color: AppColors.textPrimary),
        cursorColor: AppColors.actionPrimary,
        decoration: InputDecoration(
          labelText: '真实姓名',
          hintText: '请输入姓名，用于现场记录署名',
          labelStyle: TextStyle(color: AppColors.textSecondary),
          hintStyle: TextStyle(color: AppColors.textTertiary, fontSize: 13),
          prefixIcon: Icon(Icons.person_outline, color: AppColors.textTertiary),
          filled: true,
          fillColor: AppColors.surface,
          counterText: '',
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('auth-unit-code'),
        controller: _unitCode,
        enabled: !_busy,
        maxLength: 12,
        obscureText: _obscureUnitCode,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _authenticate(),
        onChanged: (_) => _clearError(),
        style: AppTextStyles.bodyMd.copyWith(color: AppColors.textPrimary),
        cursorColor: AppColors.actionPrimary,
        decoration: InputDecoration(
          labelText: '单位验证码',
          hintText: '请输入单位验证码',
          labelStyle: TextStyle(color: AppColors.textSecondary),
          hintStyle: TextStyle(color: AppColors.textTertiary, fontSize: 13),
          prefixIcon: Icon(
            Icons.password_outlined,
            color: AppColors.textTertiary,
          ),
          filled: true,
          fillColor: AppColors.surface,
          counterText: '',
          suffixIcon: IconButton(
            key: const Key('auth-code-visibility-toggle'),
            icon: Icon(
              _obscureUnitCode
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 20,
              color: AppColors.textTertiary,
            ),
            tooltip: _obscureUnitCode ? '显示验证码' : '隐藏验证码',
            onPressed: () {
              setState(() => _obscureUnitCode = !_obscureUnitCode);
            },
          ),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: AppSpacing.s2),
        AppNotice(
          key: const Key('auth-error'),
          kind: AppNoticeKind.error,
          text: _error!,
        ),
      ],
    ];

    final submitButton = FilledButton.icon(
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
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: AppColors.actionPrimary,
        foregroundColor: AppColors.onPrimary,
        disabledBackgroundColor: AppColors.surfaceSubtle,
        disabledForegroundColor: AppColors.textTertiary,
      ),
    );

    if (isExtremeShort) {
      return SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        clipBehavior: Clip.hardEdge,
        padding: const EdgeInsets.only(top: 8, bottom: AppSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...formFields,
            const SizedBox(height: AppSpacing.s3),
            submitButton,
            if (!hasKeyboard && widget.onEnterGuestMode != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('auth-guest-mode'),
                onPressed: _busy ? null : widget.onEnterGuestMode,
                icon: const Icon(Icons.explore_outlined, size: 18),
                label: const Text('先以游客身份体验（单机可用）'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            clipBehavior: Clip.hardEdge,
            padding: const EdgeInsets.only(top: 8, bottom: AppSpacing.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: formFields,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        submitButton,
        if (!hasKeyboard && widget.onEnterGuestMode != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('auth-guest-mode'),
            onPressed: _busy ? null : widget.onEnterGuestMode,
            icon: const Icon(Icons.explore_outlined, size: 18),
            label: const Text('先以游客身份体验（单机可用）'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: AppColors.textPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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

  Widget _buildPendingApprovalView(double maxHeight) {
    final pending = _pendingApp!;
    final isExtremeShort = maxHeight < 320;

    final content = [
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
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '入队申请审核中',
                  style: AppTextStyles.h1.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: AppSpacing.s1),
                AntiOrphanText(
                  text: '申请已提交，等待站长或安全员审批通过。',
                  style: AppTextStyles.bodyMd.copyWith(
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
      const SizedBox(height: AppSpacing.s4),
      AppCard(
        color: AppColors.surfaceSubtle,
        radius: AppRadius.md,
        padding: const EdgeInsets.all(AppSpacing.cardInner),
        side: BorderSide(color: AppColors.border),
        child: Column(
          children: [
            _buildInfoRow('申请单位', pending['unit_name'] ?? '-'),
            Divider(height: 20, color: AppColors.border),
            _buildInfoRow('申请队员', pending['real_name'] ?? '-'),
            if ((pending['station_name'] ?? '').isNotEmpty) ...[
              Divider(height: 20, color: AppColors.border),
              _buildInfoRow('所属队站', pending['station_name']!),
            ],
            if ((pending['phone'] ?? '').isNotEmpty) ...[
              Divider(height: 20, color: AppColors.border),
              _buildInfoRow('联系电话', pending['phone']!),
            ],
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.s3),
      AppNotice(
        kind: AppNoticeKind.info,
        icon: Icons.lightbulb_outline_rounded,
        text: '站长在手机 App【设置 → 入队审批】中点击同意后，切回本页面或点击下方按钮即可自动完成登录。',
      ),
      if (_error != null) ...[
        const SizedBox(height: AppSpacing.s2),
        AppNotice(
          key: const Key('pending-error'),
          kind: AppNoticeKind.error,
          text: _error!,
        ),
      ],
    ];

    final checkStatusButton = FilledButton.icon(
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
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: AppColors.actionPrimary,
        foregroundColor: AppColors.onPrimary,
        disabledBackgroundColor: AppColors.surfaceSubtle,
        disabledForegroundColor: AppColors.textTertiary,
      ),
    );

    final guestButton = widget.onEnterGuestMode != null
        ? OutlinedButton.icon(
            key: const Key('pending-guest-mode'),
            onPressed: widget.onEnterGuestMode,
            icon: const Icon(Icons.explore_outlined, size: 18),
            label: const Text('先以游客身份体验'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: AppColors.textPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          )
        : null;

    final cancelButton = TextButton(
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
    );

    if (isExtremeShort) {
      return SingleChildScrollView(
        clipBehavior: Clip.hardEdge,
        padding: const EdgeInsets.only(bottom: AppSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...content,
            const SizedBox(height: AppSpacing.s3),
            checkStatusButton,
            if (guestButton != null) ...[
              const SizedBox(height: AppSpacing.s2),
              guestButton,
            ],
            const SizedBox(height: AppSpacing.s1),
            cancelButton,
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            clipBehavior: Clip.hardEdge,
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: content,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        checkStatusButton,
        if (guestButton != null) ...[
          const SizedBox(height: AppSpacing.s2),
          guestButton,
        ],
        const SizedBox(height: AppSpacing.s1),
        cancelButton,
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.bodyMd.copyWith(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            softWrap: true,
            style: AppTextStyles.bodyMd.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  static final RegExp _districtPattern = RegExp(
    r'([\u4e00-\u9fa5]{2,6}?(?:区|县|县级市|旗|高新区|经开区|新区|保税区|示范区))',
  );

  static String _resolveDistrict(ExternalIncident ext) {
    final rawDist = ext.districtName.trim();
    if (rawDist.isNotEmpty &&
        rawDist != '市辖区' &&
        rawDist != '本级' &&
        rawDist != '市辖县') {
      return rawDist;
    }

    final addr = ext.crimeAddress;
    final brigade = ext.brigadeName;
    final squadron = ext.squadronName;

    for (final source in [addr, brigade, squadron]) {
      if (source.isEmpty) continue;
      final match = _districtPattern.firstMatch(source);
      if (match != null) {
        return match.group(1)!;
      }
    }

    if (ext.detachmentName.trim().isNotEmpty) {
      return ext.detachmentName.trim();
    }
    return '本辖区';
  }

  static bool _matchesUnit(ExternalIncident ext, String? userUnitName) {
    if (userUnitName == null || userUnitName.trim().isEmpty) return true;
    final unit = userUnitName.trim();
    if (unit.contains('支队') || unit.contains('总队') || unit.contains('指挥中心')) {
      return true; // 支队及以上查看全辖区
    }

    String? matchedKeyword;
    final cleanedUnit = unit
        .replaceFirst(RegExp(r'^[\u4e00-\u9fa5]{2,5}(?:省|自治区)'), '')
        .replaceFirst(
          RegExp(r'^[\u4e00-\u9fa5]{2,5}市(?=[\u4e00-\u9fa5]{1,6}(?:区|县|旗|市))'),
          '',
        );
    final match = RegExp(
      r'([\u4e00-\u9fa5]{2,6}?(?:区|县|县级市|旗|高新区|经开区|新区|示范区))(?:消防救援)?(?:大队|站|中队)?',
    ).firstMatch(cleanedUnit);
    if (match != null) {
      matchedKeyword = match.group(1);
    }

    if (matchedKeyword == null || matchedKeyword.isEmpty) return true;

    final district = _resolveDistrict(ext);
    final kw = matchedKeyword;
    return district.contains(kw) ||
        ext.locationDisplay.contains(kw) ||
        ext.brigadeName.contains(kw) ||
        ext.squadronName.contains(kw) ||
        ext.districtName.contains(kw) ||
        ext.crimeAddress.contains(kw) ||
        ext.dispatchedForces.any((f) => f.stationName.contains(kw)) ||
        ext.incidentDescribe.contains(kw);
  }

  List<_UnifiedIncidentItem> _buildUnifiedIncidentItems() {
    final customItems = <_UnifiedIncidentItem>[];
    for (final inc in widget.activeIncidents) {
      final hasExternal = inc.info['external_id'] != null ||
          widget.externalIncidents.any((e) =>
              e.incidentNumber == inc.number || e.claimedIncidentId == inc.id);
      if (!hasExternal) {
        final cardData = IncidentCardData.fromIncident(inc);
        final cleanedLoc = cardData.hasRealLocation
            ? cardData.locationText
            : '';
        final terminalLabel = cardData.officialStatus.isNotEmpty
            ? cardData.officialStatus
            : '已归队';
        final fallbackLoc = cardData.isTerminalStatus
            ? terminalLabel
            : (inc.unresolvedActiveCount > 0
                  ? '${inc.unresolvedActiveCount}人处置中'
                  : '内部自建现场');
        final locationText = cleanedLoc.isNotEmpty ? cleanedLoc : fallbackLoc;
        final customHighlights =
            cardData.isTerminalStatus && cleanedLoc.isNotEmpty
            ? <String>[terminalLabel]
            : const <String>[];
        final timeText = IncidentCardData.formatTimestampMs(inc.createdAt);

        customItems.add(_UnifiedIncidentItem(
          key: 'custom_${inc.id}',
          category: cardData.category,
          eventTitle: inc.displayName,
          districtTag: '自建',
          districtBg: AppColors.cautionSurface,
          districtFg: AppColors.cautionText,
          locationText: locationText,
          timeText: timeText,
          forceTags: const [],
          factHighlights: customHighlights,
          searchCorpus: [
            inc.number,
            locationText,
            ...customHighlights,
          ].where((e) => e.trim().isNotEmpty).join(' '),
          badgeText: '进入',
          badgeBg: AppColors.actionPrimary.withValues(alpha: 0.12),
          badgeFg: AppColors.actionPrimary,
          isClaimed: true,
          isCustom: true,
          onTap: () => _select(inc),
        ));
      }
    }

    final effectiveUnit = widget.userUnitName ?? _currentUserUnitName;
    final externalItems = <_UnifiedIncidentItem>[];
    for (final ext in widget.externalIncidents) {
      if (!_matchesUnit(ext, effectiveUnit)) {
        continue;
      }
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
      final eventTitle = ext.effectiveEventTitle;
      final district = _resolveDistrict(ext);
      final locationText = ext.effectiveLocation;
      final timeText = IncidentCardData.formatTimestampMs(ext.registerTime);
      final category = IncidentCategory.classify(
        disasterCategory: ext.disasterCategory,
        category: ext.incidentType,
        specificType: ext.specificType.isNotEmpty
            ? ext.specificType
            : ext.disposalObjectName,
        situation: ext.situationSummary,
        title: eventTitle,
      );
      final forceTags = ext.compactForceTags;
      final sanitizedOfficial = IncidentCardData.sanitizeOfficialStatus(
        ext.officialStatus,
      );
      final officialStatus = sanitizedOfficial.isNotEmpty
          ? sanitizedOfficial
          : IncidentCardData.sanitizeOfficialStatus(ext.incidentStatus);
      final matchedCardData = matched != null
          ? IncidentCardData.fromIncident(matched)
          : null;
      final effectiveOfficialStatus = officialStatus.isNotEmpty
          ? officialStatus
          : (matchedCardData?.officialStatus ?? '');
      final isReturned =
          IncidentCardData.isTerminalOfficialStatus(effectiveOfficialStatus) ||
          (matchedCardData?.isTerminalStatus ?? false);

      final highlights = <String>[];
      final candidates = ext.factHighlights.isNotEmpty
          ? ext.factHighlights
          : <String>[
              if (ext.incidentLevel.trim().isNotEmpty) ext.incidentLevel.trim(),
              if (effectiveOfficialStatus.isNotEmpty) effectiveOfficialStatus,
            ];
      for (final raw in candidates) {
        final item = raw.trim();
        if (item.isEmpty || item == '其他' || item == '处置中') continue;
        if (isReturned && item.contains('处置')) continue;
        if (eventTitle.contains(item) || highlights.contains(item)) continue;
        highlights.add(item);
        if (highlights.length >= 3) break;
      }

      if (isReturned) {
        highlights.removeWhere((t) => t.contains('处置'));
        final terminalLabel =
            (effectiveOfficialStatus.isNotEmpty &&
                !effectiveOfficialStatus.contains('处置'))
            ? effectiveOfficialStatus
            : (matchedCardData != null &&
                      matchedCardData.officialStatus.isNotEmpty &&
                      !matchedCardData.officialStatus.contains('处置'))
                  ? matchedCardData.officialStatus
                  : '已归队';
        highlights.remove(terminalLabel);
        highlights.insert(0, terminalLabel);
      } else if (isClaimed) {
        highlights.remove('处置中');
        highlights.insert(0, '处置中');
      }

      externalItems.add(_UnifiedIncidentItem(
        key: 'ext_${ext.externalId}',
        category: category,
        eventTitle: eventTitle,
        districtTag: district,
        districtBg: AppColors.surfaceSubtle,
        districtFg: AppColors.textSecondary,
        locationText: locationText,
        timeText: timeText,
        forceTags: forceTags,
        factHighlights: highlights,
        searchCorpus: [
          ext.incidentNumber,
          ext.crimeAddress,
          ext.incidentType,
          ext.specificType,
          ext.disposalObjectName,
          ext.squadronName,
          ext.brigadeName,
          ext.incidentDescribe,
          ext.situationSummary,
          ...forceTags,
          ...highlights,
        ].where((e) => e.trim().isNotEmpty).join(' '),
        badgeText: '进入',
        badgeBg: AppColors.actionPrimary.withValues(alpha: 0.12),
        badgeFg: AppColors.actionPrimary,
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
      return item.eventTitle.toLowerCase().contains(query) ||
          item.locationText.toLowerCase().contains(query) ||
          item.districtTag.toLowerCase().contains(query) ||
          item.searchCorpus.toLowerCase().contains(query) ||
          item.badgeText.toLowerCase().contains(query);
    }).toList();
  }

  Widget _buildFullScreenHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.s4, AppSpacing.s3, AppSpacing.s4, AppSpacing.s2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.actionPrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              Icons.local_fire_department_outlined,
              color: AppColors.actionPrimary,
              size: 22,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '选择警情或直接进入',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final busyOrLoading = _busy || widget.externalLoading;
    final actionIconStyle = IconButton.styleFrom(
      backgroundColor: AppColors.surfaceSubtle,
      foregroundColor: AppColors.textPrimary,
      disabledBackgroundColor: AppColors.surfaceSubtle.withValues(alpha: 0.5),
      disabledForegroundColor: AppColors.textTertiary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: AppColors.border),
      ),
      minimumSize: const Size(42, 42),
    );

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 42,
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchKeyword = v),
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              cursorColor: AppColors.actionPrimary,
              decoration: InputDecoration(
                hintText: '搜索灾情事件、地点、出动队站或编号…',
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textTertiary,
                ),
                prefixIcon: Icon(
                  Icons.search,
                  size: 20,
                  color: AppColors.textTertiary,
                ),
                suffixIcon: _searchKeyword.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          size: 18,
                          color: AppColors.textTertiary,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchKeyword = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: AppColors.actionPrimary,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: '刷新派警列表',
          icon: widget.externalLoading
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.actionPrimary,
                  ),
                )
              : const Icon(Icons.refresh, size: 20),
          onPressed: busyOrLoading ? null : _refreshExternal,
          style: actionIconStyle,
        ),
      ],
    );
  }

  Widget _buildFullScreenBottomActions(List<Incident> incidents) {
    final hasKeyboard = MediaQuery.viewInsetsOf(context).bottom > 80;
    if (hasKeyboard) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.add),
            label: const Text('新建警情'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: AppColors.actionPrimary,
              foregroundColor: AppColors.onPrimary,
              disabledBackgroundColor: AppColors.surfaceSubtle,
              disabledForegroundColor: AppColors.textTertiary,
            ),
          ),
          if (widget.onEnterWithoutIncident != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : widget.onEnterWithoutIncident,
                icon: const Icon(Icons.arrow_forward_outlined),
                label: const Text('直接进入 App'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: AppColors.textPrimary,
                ),
              ),
            ),
          const SizedBox(height: 6),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final incidents = widget.activeIncidents;

    if (widget.authenticationRequired) {
      return Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: '用户认证',
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: ColoredBox(
                  color: AppColors.palette.floatShadow.first.color.withValues(
                    alpha: AppColors.palette.brightness == Brightness.dark
                        ? 0.55
                        : 0.35,
                  ),
                ),
              ),
            ),
            const ModalBarrier(dismissible: false, color: Colors.transparent),
            SafeArea(
              child: Padding(
                padding: MediaQuery.viewInsetsOf(context),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final hasKeyboard =
                        MediaQuery.viewInsetsOf(context).bottom > 80;
                    final isShortViewport = constraints.maxHeight < 460;
                    final isExtremeShort = constraints.maxHeight < 320;
                    final isMicroShort = constraints.maxHeight < 280;

                    final double verticalMargin;
                    if (hasKeyboard || isShortViewport) {
                      if (isMicroShort) {
                        verticalMargin = 4.0;
                      } else if (isExtremeShort) {
                        verticalMargin = 8.0;
                      } else {
                        verticalMargin = 12.0;
                      }
                    } else {
                      verticalMargin = 24.0;
                    }

                    final width = math.max(
                      1.0,
                      math.min(constraints.maxWidth - 32, 520.0),
                    );
                    final height = math.max(
                      1.0,
                      math.min(
                        constraints.maxHeight - verticalMargin,
                        640.0,
                      ),
                    );
                    final keyboardWidth = math.max(
                      1.0,
                      math.min(constraints.maxWidth, 560.0),
                    );

                    final topPadding = (hasKeyboard || isShortViewport)
                        ? (isExtremeShort ? AppSpacing.s2 : AppSpacing.s3)
                        : AppSpacing.s6;
                    final bottomPadding = (hasKeyboard || isShortViewport)
                        ? (isExtremeShort ? AppSpacing.s2 : AppSpacing.s3)
                        : AppSpacing.s5;
                    final hPadding = constraints.maxWidth < 340
                        ? AppSpacing.s3
                        : AppSpacing.s5;

                    final cardConstraints = hasKeyboard
                        ? BoxConstraints(
                            minWidth: keyboardWidth,
                            maxWidth: keyboardWidth,
                            maxHeight: height,
                          )
                        : BoxConstraints(
                            minWidth: width,
                            maxWidth: width,
                            maxHeight: height,
                          );
                    final innerContentMaxHeight = math.max(
                      1.0,
                      height - topPadding - bottomPadding,
                    );

                    return Align(
                      alignment: hasKeyboard
                          ? Alignment.bottomCenter
                          : Alignment.center,
                      child: Padding(
                        padding: EdgeInsets.zero,
                        child: ConstrainedBox(
                          constraints: cardConstraints,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            decoration: BoxDecoration(
                              borderRadius: hasKeyboard
                                  ? const BorderRadius.vertical(
                                      top: Radius.circular(AppRadius.xl),
                                    )
                                  : BorderRadius.circular(AppRadius.xl),
                              boxShadow: AppShadow.float,
                            ),
                            child: Material(
                              key: const Key('incident-selection-overlay'),
                              color: AppColors.surface,
                              elevation: 0,
                              shadowColor: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: hasKeyboard
                                    ? const BorderRadius.vertical(
                                        top: Radius.circular(AppRadius.xl),
                                      )
                                    : BorderRadius.circular(AppRadius.xl),
                                side: BorderSide(
                                  color: AppColors.border.withValues(alpha: 0.9),
                                  width: 1.0,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  hPadding,
                                  topPadding,
                                  hPadding,
                                  bottomPadding,
                                ),
                                child: _pendingApp != null
                                    ? _buildPendingApprovalView(
                                        innerContentMaxHeight,
                                      )
                                    : _buildAuthentication(
                                        innerContentMaxHeight,
                                      ),
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

    return Semantics(
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: '选择警情或直接进入',
      child: Material(
        key: const Key('incident-selection-overlay'),
        color: AppColors.background,
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildFullScreenHeader(context),
                  if (widget.loading) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.s4, AppSpacing.s2, AppSpacing.s4, 0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.actionPrimary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '正在同步现有警情…',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.s4, AppSpacing.s2, AppSpacing.s4, 0),
                      child: AppNotice(
                        key: const Key('incident-selection-error'),
                        kind: AppNoticeKind.error,
                        text: _error!,
                      ),
                    ),
                  ],
                  if (widget.externalLoading) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.s4, AppSpacing.s2, AppSpacing.s4, 0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.actionPrimary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '正在获取已调派警情…',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.s4, AppSpacing.s3, AppSpacing.s4, AppSpacing.s2),
                    child: _buildSearchBar(),
                  ),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final items = _buildUnifiedIncidentItems();
                        if (items.isEmpty) {
                          return const _EmptyIncidentState();
                        }
                        return ListView.separated(
                          key: const Key('incident-selection-list'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.s4,
                            vertical: AppSpacing.s2,
                          ),
                          itemCount: items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
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
                  _buildFullScreenBottomActions(incidents),
                ],
              ),
              if (_busy)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(color: Colors.transparent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyIncidentState extends StatelessWidget {
  const _EmptyIncidentState();

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_copy_outlined,
              size: 64,
              color: AppColors.textTertiary.withValues(alpha: 0.9),
            ),
            const SizedBox(height: 12),
            Text(
              '当前没有进行中的警情',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '如果你是第一位到达的用户，可以新建警情；也可以直接进入 App。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}


class _UnifiedIncidentItem {
  final String key;
  final IncidentCategory category;
  final String eventTitle;
  final String districtTag;
  final Color? districtBg;
  final Color? districtFg;
  final String locationText;
  final String timeText;
  final List<String> forceTags;
  final List<String> factHighlights;
  final String searchCorpus;
  final String badgeText;
  final Color badgeBg;
  final Color badgeFg;
  final bool isClaimed;
  final bool isCustom;
  final VoidCallback onTap;

  _UnifiedIncidentItem({
    required this.key,
    required this.category,
    required this.eventTitle,
    required this.districtTag,
    this.districtBg,
    this.districtFg,
    required this.locationText,
    required this.timeText,
    required this.forceTags,
    required this.factHighlights,
    required this.searchCorpus,
    required this.badgeText,
    required this.badgeBg,
    required this.badgeFg,
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

  static final RegExp _warningHighlightPattern = RegExp(
    r'被困|伤|危|泄漏|燃气|煤气|爆炸',
  );

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final hasExtraChips =
        item.forceTags.isNotEmpty || item.factHighlights.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        excludeFromSemantics: true,
        onTap: enabled ? item.onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: AppColors.border,
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第 1 层（最突出）：事件/灾情核心标题 + 三分类徽标 + 状态操作胶囊
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IncidentCategoryBadge(
                    key: Key(
                      'ext-category-badge-${item.key}-${item.category.name}',
                    ),
                    category: item.category,
                    size: 38,
                    iconSize: 21,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AntiOrphanText(
                      text: item.eventTitle,
                      style: AppTextStyles.bodyLg.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3.5,
                    ),
                    decoration: BoxDecoration(
                      color: item.badgeBg,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.badgeText,
                          style: TextStyle(
                            color: item.badgeFg,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 15,
                          color: item.badgeFg,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 第 2 层（次级）：行政区/自建标记 + 事发地点 + 接警时间
              Row(
                children: [
                  if (item.districtTag.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5.5,
                        vertical: 1.5,
                      ),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: item.districtBg ?? AppColors.surfaceSubtle,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.districtTag,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: item.districtFg ?? AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.locationText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (item.timeText.isNotEmpty)
                          Text(
                            ' · ${item.timeText}',
                            maxLines: 1,
                            style: TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 12,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              // 第 3 层（条件展示）：出动力量与关键事实胶囊，无信息时不占位
              if (hasExtraChips) ...[
                const SizedBox(height: 6),
                Wrap(
                  key: Key('ext-forces-wrap-${item.key}'),
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final forceTag in item.forceTags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSubtle,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.75,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.local_shipping_outlined,
                              size: 13,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              forceTag,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    for (final highlight in item.factHighlights)
                      Builder(
                        builder: (_) {
                          final isInProgress = highlight == '处置中';
                          final isWarning =
                              !isInProgress &&
                              _warningHighlightPattern.hasMatch(highlight);
                          final Color pillBg;
                          final Color pillBorder;
                          final Color pillText;
                          final double borderWidth;
                          final FontWeight fontWeight;
                          if (isInProgress) {
                            pillBg = AppColors.safeSurface;
                            pillBorder = AppColors.safe.withValues(alpha: 0.3);
                            pillText = AppColors.safeText;
                            borderWidth = 1.0;
                            fontWeight = FontWeight.w700;
                          } else if (isWarning) {
                            pillBg = AppColors.noticeWarningBg;
                            pillBorder = AppColors.caution.withValues(alpha: 0.45);
                            pillText = AppColors.noticeWarningFg;
                            borderWidth = 0.75;
                            fontWeight = FontWeight.w700;
                          } else {
                            pillBg = AppColors.surfaceSubtle;
                            pillBorder = AppColors.border;
                            pillText = AppColors.textSecondary;
                            borderWidth = 0.75;
                            fontWeight = FontWeight.w500;
                          }
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: pillBg,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: pillBorder,
                                width: borderWidth,
                              ),
                            ),
                            child: Text(
                              highlight,
                              style: TextStyle(
                                color: pillText,
                                fontSize: 11,
                                fontWeight: fontWeight,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
