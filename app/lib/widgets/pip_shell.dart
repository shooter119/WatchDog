import 'package:flutter/material.dart';

import '../pages/video_playback_surface.dart';
import '../services/video_playback_session.dart';

class PipShell extends StatelessWidget {
  final VideoPlaybackSession session;

  const PipShell({
    super.key,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.black,
        child: SizedBox.expand(
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              // PiP 里没有 Navigator，播放失败态等组件会用 Tooltip/IconButton，
              // 它们要求上层存在 Overlay，否则会直接报错并顶掉视频画面。
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (context) => VideoPlaybackSurface(
                      session: session,
                      compact: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
