import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';

/// 弹出警情改名 [CommandSheet]。
///
/// 由内置 [StatefulWidget] 独立持有并跟随退出动画结束销毁 [TextEditingController]，
/// 避免弹窗退场期间或焦点释放时提前 `dispose` 触发帧异常。
Future<String?> showIncidentRenameSheet(
  BuildContext context, {
  String initialTitle = '',
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<String>(
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
        child: _IncidentRenameSheet(initialTitle: initialTitle),
      ),
    ),
  );
}

class _IncidentRenameSheet extends StatefulWidget {
  const _IncidentRenameSheet({required this.initialTitle});

  final String initialTitle;

  @override
  State<_IncidentRenameSheet> createState() => _IncidentRenameSheetState();
}

class _IncidentRenameSheetState extends State<_IncidentRenameSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return CommandSheet(
      title: '修改警情名称',
      subtitle: '留空将恢复默认警情编号',
      actions: <Widget>[
        CommandButton(
          label: '稍后',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => _close(),
        ),
        CommandButton(
          key: const Key('incident-rename-save-btn'),
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => _close(_ctrl.text.trim()),
        ),
      ],
      child: TextField(
        key: const Key('incident-rename-field'),
        controller: _ctrl,
        autofocus: true,
        maxLength: 120,
        style: ds.typography.body.copyWith(color: ds.colors.textPrimary),
        decoration: InputDecoration(
          hintText: '如：幸福小区住宅火灾',
          filled: true,
          fillColor: ds.colors.surfaceMuted,
          border: OutlineInputBorder(
            borderRadius: DsRadius.borderMd,
            borderSide: BorderSide(color: ds.colors.border),
          ),
        ),
      ),
    );
  }
}

/// 弹出退出当前警情二次确认 [CommandSheet]。
Future<bool> showIncidentExitConfirmSheet(BuildContext context) async {
  final confirmed = await showCommandSheet<bool>(
    context: context,
    title: '退出当前警情',
    builder: (BuildContext ctx) => Text(
      '退出后不会归档警情，仍可从正在处置的警情列表重新加入。',
      style: ctx.ds.typography.body.copyWith(
        color: ctx.ds.colors.textSecondary,
      ),
    ),
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '取消',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      CommandButton(
        key: const Key('incident-exit-confirm-btn'),
        label: '确认退出',
        variant: CommandButtonVariant.primary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
  return confirmed == true;
}

/// 弹出归档警情危险操作二次确认 [CommandSheet]，保留 `Key('incident-archive-confirm-btn')`。
Future<bool> showIncidentArchiveConfirmSheet(BuildContext context) async {
  final confirmed = await showCommandSheet<bool>(
    context: context,
    title: '归档警情',
    builder: (BuildContext ctx) => Text(
      '归档后现场数据只读，名称仍可在归档警情列表中修改。请确认处置已经结束。',
      style: ctx.ds.typography.body.copyWith(
        color: ctx.ds.colors.textSecondary,
      ),
    ),
    actionsBuilder: (BuildContext ctx) => <Widget>[
      CommandButton(
        label: '取消',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.large,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      CommandButton(
        key: const Key('incident-archive-confirm-btn'),
        label: '确认归档',
        variant: CommandButtonVariant.danger,
        size: CommandButtonSize.large,
        requireConfirmation: false,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
  return confirmed == true;
}
