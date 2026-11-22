import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'auth_ui_parts.dart';

/// 模糊姓名建议弹窗中的用户选择结果。
@immutable
class NameSuggestionChoice {
  const NameSuggestionChoice._({this.selectedName, this.applyAnyway = false});
  const NameSuggestionChoice.selected(String name) : this._(selectedName: name);
  const NameSuggestionChoice.applyAnyway() : this._(applyAnyway: true);

  final String? selectedName;
  final bool applyAnyway;
}

/// 主动发起入队申请的表单草稿。
@immutable
class MembershipApplyDraft {
  const MembershipApplyDraft({
    required this.unitName,
    required this.realName,
    required this.unitCode,
    this.stationName,
    this.phone,
    this.applyReason,
  });

  final String unitName;
  final String realName;
  final String unitCode;
  final String? stationName;
  final String? phone;
  final String? applyReason;
}

/// 弹出“仅在语音名单中、尚无登录权限”的入队申请确认面板。
Future<bool?> showRosterOnlyApplySheet(
  BuildContext context, {
  required String unitName,
  required String realName,
}) {
  return showCommandSheet<bool>(
    context: context,
    title: '该姓名还没有登录权限',
    subtitle: unitName.trim().isNotEmpty ? unitName.trim() : null,
    builder: (_) => AuthNoticeBanner(
      status: DsStatus.caution,
      icon: Icons.badge_outlined,
      message:
          '「$realName」已在语音识别名单中，但还没有登录权限。请提交入队申请，管理员在「我的 → 入队审批」批准后即可登录。',
    ),
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '返回修改',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      CommandButton(
        label: '提交入队申请',
        variant: CommandButtonVariant.primary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
}

/// 弹出“未找到精确姓名”的模糊候选建议面板。
Future<NameSuggestionChoice?> showNameSuggestionsSheet(
  BuildContext context, {
  required String realName,
  required List<String> suggestions,
}) {
  return showCommandSheet<NameSuggestionChoice>(
    context: context,
    title: '没有找到这个姓名',
    subtitle: '已输入「$realName」，可点选相近姓名填入或直接申请入队',
    builder: (BuildContext sheetContext) {
      final ds = sheetContext.ds;
      final colors = ds.colors;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '你要找的是不是：',
            style: ds.typography.body.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          for (var i = 0; i < suggestions.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: DsSpacing.sm),
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              borderColor: colors.border,
              borderRadius: DsRadius.borderMd,
              padding: const EdgeInsets.all(DsSpacing.md),
              onTap: () => Navigator.of(
                sheetContext,
              ).pop(NameSuggestionChoice.selected(suggestions[i])),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 28),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.person_outline_rounded,
                      size: DsSizes.iconMd,
                      color: colors.brandText,
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Expanded(
                      child: Text(
                        suggestions[i],
                        style: ds.typography.title.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: DsSizes.iconMd,
                      color: colors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: DsSpacing.md),
          Text(
            '点击候选姓名会自动填入输入框，不会立即提交认证。',
            style: ds.typography.caption.copyWith(color: colors.textTertiary),
          ),
        ],
      );
    },
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '返回修改',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(),
      ),
      CommandButton(
        label: '仍要提交入队申请',
        variant: CommandButtonVariant.primary,
        size: CommandButtonSize.large,
        onPressed: () =>
            Navigator.of(ctx).pop(const NameSuggestionChoice.applyAnyway()),
      ),
    ],
  );
}

/// 弹出“未加入单位正式名单”的入队申请二次确认面板。
Future<bool?> showMembershipApplyConfirmSheet(
  BuildContext context, {
  required String unitName,
  required String realName,
}) {
  return showCommandSheet<bool>(
    context: context,
    title: '未加入单位名单',
    subtitle: unitName.trim().isNotEmpty ? unitName.trim() : null,
    builder: (BuildContext ctx) => Text(
      '姓名「$realName」尚未加入「$unitName」的正式队员名单。\n\n是否立即向站长提交入队申请？',
      style: ctx.ds.typography.body.copyWith(
        color: ctx.ds.colors.textSecondary,
      ),
    ),
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '返回修改',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      CommandButton(
        label: '提交入队申请',
        variant: CommandButtonVariant.primary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
}

/// 弹出主动入队申请表单面板（支持预填单位、姓名、验证码及可选队站/电话/说明）。
Future<MembershipApplyDraft?> showMembershipApplyFormSheet(
  BuildContext context, {
  String initialUnitName = '',
  String initialRealName = '',
  String initialUnitCode = '',
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);
  return showModalBottomSheet<MembershipApplyDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext routeContext) => Theme(
      data: capturedTheme,
      child: MediaQuery(
        data: capturedMediaQuery.copyWith(
          viewInsets: MediaQuery.viewInsetsOf(routeContext),
          padding: MediaQuery.paddingOf(routeContext),
          viewPadding: MediaQuery.viewPaddingOf(routeContext),
        ),
        child: _MembershipApplyFormSheet(
          initialUnitName: initialUnitName,
          initialRealName: initialRealName,
          initialUnitCode: initialUnitCode,
        ),
      ),
    ),
  );
}

class _MembershipApplyFormSheet extends StatefulWidget {
  const _MembershipApplyFormSheet({
    required this.initialUnitName,
    required this.initialRealName,
    required this.initialUnitCode,
  });

  final String initialUnitName;
  final String initialRealName;
  final String initialUnitCode;

  @override
  State<_MembershipApplyFormSheet> createState() =>
      _MembershipApplyFormSheetState();
}

class _MembershipApplyFormSheetState extends State<_MembershipApplyFormSheet> {
  late final TextEditingController _unitName = TextEditingController(
    text: widget.initialUnitName,
  );
  late final TextEditingController _realName = TextEditingController(
    text: widget.initialRealName,
  );
  late final TextEditingController _unitCode = TextEditingController(
    text: widget.initialUnitCode,
  );
  final TextEditingController _stationName = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  String? _validationError;

  @override
  void dispose() {
    _unitName.dispose();
    _realName.dispose();
    _unitCode.dispose();
    _stationName.dispose();
    _phone.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _clearValidation() {
    if (_validationError != null) setState(() => _validationError = null);
  }

  void _submit() {
    final unit = _unitName.text.trim();
    final name = _realName.text.trim();
    final code = _unitCode.text.trim();
    if (unit.isEmpty) {
      setState(() => _validationError = '请输入单位名称');
      return;
    }
    if (name.isEmpty) {
      setState(() => _validationError = '请输入真实姓名');
      return;
    }
    if (code.isEmpty) {
      setState(() => _validationError = '请输入单位验证码');
      return;
    }
    String? optional(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.of(context).pop(
      MembershipApplyDraft(
        unitName: unit,
        realName: name,
        unitCode: code,
        stationName: optional(_stationName),
        phone: optional(_phone),
        applyReason: optional(_reason),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final textStyle = ds.typography.body.copyWith(color: ds.colors.textPrimary);
    return CommandSheet(
      title: '提交入队申请',
      subtitle: '提交后由本单位管理员在「我的 → 入队审批」审核通过',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CommandButton(
          key: const Key('apply-sheet-submit'),
          label: '提交申请',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            key: const Key('apply-unit-name'),
            controller: _unitName,
            maxLength: 120,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _clearValidation(),
            style: textStyle,
            decoration: authInputDecoration(
              context,
              label: '单位名称 *',
              hint: '请输入所属消防救援单位全称',
              icon: Icons.business_outlined,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('apply-real-name'),
            controller: _realName,
            maxLength: 20,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _clearValidation(),
            style: textStyle,
            decoration: authInputDecoration(
              context,
              label: '真实姓名 *',
              hint: '请输入本人真实姓名',
              icon: Icons.person_outline_rounded,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('apply-unit-code'),
            controller: _unitCode,
            maxLength: 12,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _clearValidation(),
            style: textStyle,
            decoration: authInputDecoration(
              context,
              label: '单位验证码 *',
              hint: '向站长或管理员获取',
              icon: Icons.password_outlined,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('apply-station-name'),
            controller: _stationName,
            maxLength: 40,
            textInputAction: TextInputAction.next,
            style: textStyle,
            decoration: authInputDecoration(
              context,
              label: '所属队站（选填）',
              hint: '如：示例路消防救援站',
              icon: Icons.local_fire_department_outlined,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('apply-phone'),
            controller: _phone,
            maxLength: 20,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            style: textStyle,
            decoration: authInputDecoration(
              context,
              label: '联系电话（选填）',
              hint: '便于站长核实身份',
              icon: Icons.phone_outlined,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          TextField(
            key: const Key('apply-reason'),
            controller: _reason,
            maxLength: 80,
            maxLines: 2,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            style: textStyle,
            decoration: authInputDecoration(
              context,
              label: '申请说明（选填）',
              hint: '如：新调入战斗一班',
              icon: Icons.notes_rounded,
            ),
          ),
          if (_validationError != null) ...<Widget>[
            const SizedBox(height: DsSpacing.md),
            AuthNoticeBanner(message: _validationError!),
          ],
        ],
      ),
    );
  }
}
