import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';

/// ============================================================
/// 底部导航图标集，统一使用 Remix Icon。
/// 未选中态使用线性图标，选中态切换为实心填充图标以强化视觉反馈。
/// ============================================================

enum NavGlyph { log, board, voice, assist, settings }

/// 语义化图标控件：glyph 决定形状，selected 决定线性/填充，color 随选中态着色
class NavIcon extends StatelessWidget {
  final NavGlyph glyph;
  final Color color;
  final double size;
  final bool selected;

  const NavIcon({
    super.key,
    required this.glyph,
    required this.color,
    this.size = 24,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      switch (glyph) {
        NavGlyph.log =>
          selected ? RemixIcons.file_list_3_fill : RemixIcons.file_list_3_line,
        NavGlyph.board =>
          selected ? RemixIcons.dashboard_3_fill : RemixIcons.dashboard_3_line,
        NavGlyph.voice =>
          selected ? RemixIcons.mic_2_fill : RemixIcons.mic_2_line,
        NavGlyph.assist =>
          selected ? RemixIcons.chat_3_fill : RemixIcons.chat_3_line,
        NavGlyph.settings =>
          selected ? RemixIcons.settings_3_fill : RemixIcons.settings_3_line,
      },
      size: size,
      color: color,
    );
  }
}
