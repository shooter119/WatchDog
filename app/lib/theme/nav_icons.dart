import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';

/// ============================================================
/// 底部导航图标集，统一使用 Remix Icon 的线性图标。
/// Remix Icon 的图标均基于 24×24 网格，适合在导航栏的小尺寸场景中保持清晰。
/// ============================================================

enum NavGlyph { log, board, voice, assist, settings }

/// 语义化图标控件：glyph 决定形状，color 随选中态着色
class NavIcon extends StatelessWidget {
  final NavGlyph glyph;
  final Color color;
  final double size;

  const NavIcon({
    super.key,
    required this.glyph,
    required this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      switch (glyph) {
        NavGlyph.log => RemixIcons.file_list_3_line,
        NavGlyph.board => RemixIcons.dashboard_3_line,
        NavGlyph.voice => RemixIcons.mic_2_line,
        NavGlyph.assist => RemixIcons.chat_3_line,
        NavGlyph.settings => RemixIcons.settings_3_line,
      },
      size: size,
      color: color,
    );
  }
}
