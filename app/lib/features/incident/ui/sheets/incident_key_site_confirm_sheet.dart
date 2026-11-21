import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';

/// 重点单位关联/解除的实时鉴权感知确认 [CommandSheet]。
///
/// 弹窗打开期间实时监听 [accessListenable]：一旦 `canReadKeySites()` 失效或
/// `protectedDataEpoch()` 推进，立即隐藏单位名称并禁用确认按钮。
Future<bool?> showKeySiteAuthAwareConfirmSheet(
  BuildContext context, {
  required Listenable accessListenable,
  required bool Function() canReadKeySites,
  required int Function() protectedDataEpoch,
  required int expectedEpoch,
  required bool remove,
  required String siteName,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) {
      return ListenableBuilder(
        listenable: accessListenable,
        builder: (BuildContext ctx, Widget? _) {
          final valid =
              canReadKeySites() && expectedEpoch == protectedDataEpoch();
          if (!valid) {
            return CommandSheet(
              title: '认证已失效',
              actions: <Widget>[
                CommandButton(
                  label: '关闭',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.large,
                  onPressed: () => Navigator.of(ctx).pop(false),
                ),
              ],
              child: Text(
                '认证已失效，请重新认证',
                style: ctx.ds.typography.body.copyWith(
                  color: ctx.ds.colors.alarmText,
                ),
              ),
            );
          }
          return CommandSheet(
            title: remove ? '解除重点单位关联' : '核对重点单位',
            actions: <Widget>[
              CommandButton(
                label: '取消',
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.large,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
              CommandButton(
                label: '确认',
                variant: remove
                    ? CommandButtonVariant.danger
                    : CommandButtonVariant.primary,
                size: CommandButtonSize.large,
                requireConfirmation: false,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
            child: Text(
              remove ? '解除后仍保留警情历史引用和操作记录。' : '确认关联“$siteName”？',
              style: ctx.ds.typography.body.copyWith(
                color: ctx.ds.colors.textSecondary,
              ),
            ),
          );
        },
      );
    },
  );
}
