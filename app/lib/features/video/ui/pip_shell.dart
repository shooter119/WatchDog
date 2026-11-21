import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/video_playback_session.dart';
import 'video_playback_surface.dart';

/// 系统画中画（Android PiP）专用外壳，Design System v3.0 洁净替代旧版 `PipShell`。
///
/// 仅渲染 16:9 视频画面，不包含导航栏与多余业务文案；内置独立 [Overlay] 确保
/// 播放失败态中的 [Tooltip]/[IconButton] 在无 [Navigator] 环境下安全挂载。
class CommandPipShell extends StatelessWidget {
  const CommandPipShell({super.key, required this.session});

  final VideoPlaybackSession session;

  @override
  Widget build(BuildContext context) {
    final hasDsTheme = DsTheme.maybeOf(context) != null;

    Widget surfaceHost = Material(
      color: Colors.black,
      child: SizedBox.expand(
        child: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (BuildContext overlayContext) =>
                      VideoPlaybackSurface(session: session, compact: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!hasDsTheme) {
      surfaceHost = Theme(
        data: buildCommandTheme(Brightness.dark),
        child: surfaceHost,
      );
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: surfaceHost,
    );
  }
}
