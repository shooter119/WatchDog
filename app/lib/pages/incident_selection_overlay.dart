import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_widgets.dart';

/// 启动时的强制认证/警情选择层。
///
/// 首次安装先显示单位认证，认证成功后在同一个浮层切换为警情选择。
/// 该层覆盖整个应用（包括底部导航），并通过不可关闭的 ModalBarrier
/// 拦截背景操作。具体的新建/加入流程由 HomePage 复用，保证冲突处理一致。
class IncidentSelectionOverlay extends StatefulWidget {
  final bool authenticationRequired;
  final List<Incident> activeIncidents;
  final bool loading;
  final Future<void> Function(Incident incident) onSelect;
  final Future<void> Function() onCreate;
  final Future<void> Function(
    String unitName,
    String realName,
    String unitCode,
    String apiToken,
  )?
  onAuthenticate;

  const IncidentSelectionOverlay({
    super.key,
    this.authenticationRequired = false,
    required this.activeIncidents,
    required this.loading,
    required this.onSelect,
    required this.onCreate,
    this.onAuthenticate,
  });

  @override
  State<IncidentSelectionOverlay> createState() =>
      _IncidentSelectionOverlayState();
}

class _IncidentSelectionOverlayState extends State<IncidentSelectionOverlay> {
  bool _busy = false;
  String? _error;
  final TextEditingController _unitName = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final TextEditingController _unitCode = TextEditingController();
  final TextEditingController _apiToken = TextEditingController();

  @override
  void dispose() {
    _unitName.dispose();
    _realName.dispose();
    _unitCode.dispose();
    _apiToken.dispose();
    super.dispose();
  }

  Future<void> _select(Incident incident) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSelect(incident);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() => _busy = true);
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
    final token = _apiToken.text.trim();
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
    if (token.isEmpty) {
      await _showAuthenticationError('请输入管理员提供的访问令牌');
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
      // 令牌是本次认证事务的一部分；认证失败时不落盘，避免错误令牌把
      // 用户带入“已认证但所有业务请求均 401”的不可恢复状态。
      await callback(unitName, name, code, token);
    } catch (error) {
      if (mounted) await _showAuthenticationError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                        color: AppColors.voice.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.verified_user_outlined,
                        color: AppColors.voice,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
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
                const SizedBox(height: 24),
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
                const SizedBox(height: 12),
                TextField(
                  key: const Key('auth-real-name'),
                  controller: _realName,
                  enabled: !_busy,
                  autofocus: true,
                  maxLength: 20,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '真实姓名',
                    hintText: '请输入姓名，用于现场记录署名',
                    prefixIcon: Icon(Icons.person_outline),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
                TextField(
                  key: const Key('auth-api-token'),
                  controller: _apiToken,
                  enabled: !_busy,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _authenticate(),
                  decoration: const InputDecoration(
                    labelText: '访问令牌',
                    hintText: '请输入管理员提供的 API_TOKEN',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    key: const Key('auth-error'),
                    style: const TextStyle(
                      color: AppColors.alarm,
                      fontSize: 13,
                    ),
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
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.arrow_forward_rounded),
          label: const Text('认证并继续'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: AppColors.voice,
            foregroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '首次认证成功后，本机将记住当前单位和姓名。',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final incidents = widget.activeIncidents;
    return Semantics(
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: widget.authenticationRequired ? '用户认证' : '选择警情',
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 首帧或键盘切换时约束可能暂时小于边距，不能把负值传给
                // SizedBox，否则会触发红屏：BoxConstraints(-32, -32)。
                final width = math.max(
                  1.0,
                  math.min(constraints.maxWidth - 32, 560.0),
                );
                final height = math.max(
                  1.0,
                  math.min(constraints.maxHeight - 32, 640.0),
                );
                return Center(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Material(
                      key: const Key('incident-selection-overlay'),
                      color: AppColors.surface,
                      elevation: 12,
                      shadowColor: Colors.black.withValues(alpha: 0.3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.xl),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                        child: widget.authenticationRequired
                            ? _buildAuthentication()
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: AppColors.voice.withValues(
                                            alpha: 0.13,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.local_fire_department_outlined,
                                          color: AppColors.voice,
                                          size: 26,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      const Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '先选择一份警情',
                                              style: TextStyle(
                                                fontSize: 21,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              '请选择新建或加入现有警情，现场记录才会归档到正确的位置。',
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
                                  if (widget.loading) ...[
                                    const SizedBox(height: 14),
                                    const Row(
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
                                  const SizedBox(height: 16),
                                  Expanded(
                                    child: incidents.isEmpty
                                        ? const _EmptyIncidentState()
                                        : ListView.separated(
                                            key: const Key(
                                              'incident-selection-list',
                                            ),
                                            padding: EdgeInsets.zero,
                                            itemCount: incidents.length,
                                            separatorBuilder: (_, __) =>
                                                const Divider(height: 1),
                                            itemBuilder: (context, index) {
                                              final incident = incidents[index];
                                              return _IncidentOption(
                                                incident: incident,
                                                enabled: !_busy,
                                                onTap: () => _select(incident),
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
                                      minimumSize: const Size.fromHeight(52),
                                      backgroundColor: AppColors.voice,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    incidents.isEmpty
                                        ? '当前没有进行中的警情，可以创建一份新的现场档案。'
                                        : '如果列表中没有目标警情，也可以新建一份现场档案。',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: AppColors.textTertiary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                );
              },
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
          const Text(
            '如果你是第一位到达的用户，可以新建警情。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _IncidentOption extends StatelessWidget {
  final Incident incident;
  final bool enabled;
  final VoidCallback onTap;

  const _IncidentOption({
    required this.incident,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasManualTitle = (incident.title ?? '').trim().isNotEmpty;
    return Material(
      color: AppColors.surface,
      child: InkWell(
        excludeFromSemantics: true,
        onTap: enabled ? onTap : null,
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
                  color: AppColors.voice.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.local_fire_department_outlined,
                  color: AppColors.voice,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.displayName,
                      // 警情名称可能来自现场自动建议或人工补充，不能用单行省略号
                      // 截断关键信息；列表本身可滚动，名称按实际长度自然换行。
                      softWrap: true,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasManualTitle ? '${incident.number} · 处置中' : '处置中',
                      style: const TextStyle(
                        color: AppColors.voice,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: enabled ? onTap : null,
                icon: const Icon(Icons.arrow_forward, size: 17),
                label: const Text('加入'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.voice,
                  minimumSize: const Size(72, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
