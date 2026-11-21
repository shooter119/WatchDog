import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/camera_session_store.dart';

/// 相机圆形图标按钮（取景黑底上统一 >= 48dp 触控区）。
class CameraRoundIconButton extends StatelessWidget {
  const CameraRoundIconButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white, size: DsSizes.iconLg),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black38,
        minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
      ),
    );
  }
}

/// 相机控制区：横屏右侧栏 / 竖屏底部 280dp 控制区，支持大字号滚动防溢出。
class CameraControlDeck extends StatelessWidget {
  const CameraControlDeck({
    super.key,
    required this.store,
    required this.vertical,
    required this.onShutterTap,
    required this.onToggleTorch,
    required this.onSwitchCamera,
    required this.onRetryPendingRender,
    required this.onReconcileRecording,
  });

  final CameraSessionStore store;
  final bool vertical;
  final VoidCallback onShutterTap;
  final VoidCallback onToggleTorch;
  final VoidCallback onSwitchCamera;
  final VoidCallback onRetryPendingRender;
  final VoidCallback onReconcileRecording;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final torchButton = CameraRoundIconButton(
      icon: store.torch ? Icons.flash_on : Icons.flash_off,
      tooltip: store.torch ? '关闭手电筒' : '打开手电筒',
      onTap: store.isTorchDisabled ? null : onToggleTorch,
    );
    final switchButton = CameraRoundIconButton(
      icon: Icons.cameraswitch_outlined,
      tooltip: '切换镜头',
      onTap: store.isControlLocked ? null : onSwitchCamera,
    );
    final shutter = _CameraShutterButton(
      mode: store.mode,
      recording: store.recording,
      busy: store.isShutterBusy,
      alarmColor: colors.alarmFill,
      onTap: onShutterTap,
    );
    final modeSwitch = _CameraModeSwitch(
      mode: store.mode,
      locked: store.isControlLocked,
      alarmColor: colors.alarmFill,
      onChanged: store.setMode,
    );

    return Container(
      width: double.infinity,
      padding: vertical
          ? const EdgeInsets.fromLTRB(
              DsSpacing.sm,
              DsSpacing.xxl,
              DsSpacing.sm,
              DsSpacing.xxl,
            )
          : const EdgeInsets.fromLTRB(
              DsSpacing.xl,
              14,
              DsSpacing.xl,
              DsSpacing.lg,
            ),
      decoration: BoxDecoration(
        color: DsColors.night.surface,
        border: Border(
          top: vertical
              ? BorderSide.none
              : BorderSide(color: DsColors.night.border),
          left: vertical
              ? BorderSide(color: DsColors.night.border)
              : BorderSide.none,
        ),
      ),
      child: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  key: const Key('camera-controls'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (store.stateUnknown)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size(
                            DsSizes.touchTarget,
                            DsSizes.touchTarget,
                          ),
                        ),
                        onPressed: onReconcileRecording,
                        child: const Text('重试确认'),
                      ),
                    if (store.pendingRender != null && !store.processing)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: colors.cautionFill,
                          minimumSize: const Size(0, DsSizes.touchTarget),
                        ),
                        onPressed: onRetryPendingRender,
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: DsSizes.iconMd,
                        ),
                        label: const Text('重新生成水印版'),
                      ),
                    if (!vertical) modeSwitch,
                    const SizedBox(height: 14),
                    if (store.statusText != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                        child: Text(
                          store.statusText!,
                          style: typo.caption.copyWith(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (store.processing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                        child: LinearProgressIndicator(
                          value: store.processingProgress <= 0
                              ? null
                              : store.processingProgress,
                          minHeight: 3,
                          color: colors.cautionFill,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    if (vertical) ...[
                      modeSwitch,
                      const SizedBox(height: 18),
                      shutter,
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          torchButton,
                          const SizedBox(width: DsSpacing.md),
                          switchButton,
                        ],
                      ),
                    ] else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [torchButton, shutter, switchButton],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraModeSwitch extends StatelessWidget {
  const _CameraModeSwitch({
    required this.mode,
    required this.locked,
    required this.alarmColor,
    required this.onChanged,
  });

  final CameraCaptureMode mode;
  final bool locked;
  final Color alarmColor;
  final ValueChanged<CameraCaptureMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final typo = context.ds.typography;

    Widget item(CameraCaptureMode target, String label, IconData icon) {
      final selected = mode == target;
      final Color bgColor;
      final Color fgColor;
      if (selected) {
        bgColor = target == CameraCaptureMode.photo ? Colors.white : alarmColor;
        fgColor = target == CameraCaptureMode.photo
            ? Colors.black87
            : Colors.white;
      } else {
        bgColor = Colors.transparent;
        fgColor = Colors.white70;
      }

      return Expanded(
        child: Semantics(
          button: true,
          label: '$label模式',
          value: selected ? '已选择' : '未选择',
          selected: selected,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: locked ? null : () => onChanged(target),
            child: AnimatedContainer(
              duration: DsMotion.resolve(context, DsMotion.fast),
              constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
              padding: const EdgeInsets.symmetric(vertical: DsSpacing.sm),
              margin: const EdgeInsets.all(DsSpacing.xs),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: DsRadius.borderXl,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: DsSizes.iconSm, color: fgColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.caption.copyWith(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                        color: fgColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: DsRadius.borderPill,
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          item(CameraCaptureMode.photo, '拍照', Icons.photo_camera_outlined),
          item(CameraCaptureMode.video, '录像', Icons.videocam_outlined),
        ],
      ),
    );
  }
}

class _CameraShutterButton extends StatelessWidget {
  const _CameraShutterButton({
    required this.mode,
    required this.recording,
    required this.busy,
    required this.alarmColor,
    required this.onTap,
  });

  final CameraCaptureMode mode;
  final bool recording;
  final bool busy;
  final Color alarmColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final typo = context.ds.typography;
    final video = mode == CameraCaptureMode.video;
    final active = video && recording;

    final (
      Color ringColor,
      Color innerColor,
      IconData shutterIcon,
      Color iconColor,
      double iconSize,
      String labelText,
      Color capsuleBorderColor,
      Color capsuleBgColor,
    ) = !video
        ? (
            Colors.white,
            Colors.white,
            Icons.camera_alt_rounded,
            Colors.black87,
            30.0,
            '点击拍照',
            Colors.white24,
            Colors.black54,
          )
        : !active
        ? (
            Colors.white,
            alarmColor,
            Icons.videocam_rounded,
            Colors.white,
            32.0,
            '点击开始录像',
            alarmColor,
            Colors.black54,
          )
        : (
            alarmColor,
            Colors.transparent,
            Icons.stop_rounded,
            alarmColor,
            36.0,
            '点击停止',
            alarmColor,
            alarmColor.withValues(alpha: 0.2),
          );

    return Semantics(
      button: true,
      enabled: !busy,
      value: busy ? '处理中' : (active ? '录制中' : '就绪'),
      label: video ? (active ? '停止录像' : '开始录像') : '拍照',
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: DsMotion.resolve(context, DsMotion.fast),
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: innerColor,
                border: Border.all(color: ringColor, width: 4),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(shutterIcon, color: iconColor, size: iconSize),
            ),
            const SizedBox(height: DsSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: capsuleBgColor,
                borderRadius: DsRadius.borderPill,
                border: Border.all(color: capsuleBorderColor, width: 1.2),
              ),
              child: Text(
                labelText,
                style: typo.caption.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
