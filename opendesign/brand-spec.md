# 火场智控视觉基线

本文件用于 Open Design 的辅助设计对齐；运行时实现仍以 App 主题代码为准。

来源：`app/lib/theme/app_widgets.dart` 与 `fire-rescue-safety-app-ui-spec-v0.2.md`。本文件记录已上线 Flutter 界面的设计 token，供后续页面、插图和原型对齐；实现仍以 `AppColors`、`AppSpacing`、`AppRadius`、`AppShadow` 为唯一代码来源。

```css
:root {
  --bg: oklch(96.65% 0.005 258.3);      /* #F2F4F7 */
  --surface: oklch(100% 0 89.9);         /* #FFFFFF */
  --fg: oklch(17.76% 0 89.9);            /* #111111 */
  --muted: oklch(44.61% 0.026 256.8);    /* #4B5563 */
  --border: oklch(89.53% 0.013 255.5);   /* #D7DDE5 */
  --accent: oklch(76.52% 0.175 62.6);    /* #FF9500 */
}
```

字体：显示与正文均使用 `PingFang SC, Noto Sans CJK SC, Microsoft YaHei, sans-serif`；倒计时、压力、时间使用 `DIN Alternate, SF Mono, Roboto Mono, ui-monospace, monospace`，并启用等宽数字。

视觉规则：

1. 浅灰背景、白色表面、深色线性图标构成高可视工业界面；阴影只用于分离可触达表面。
2. 橙色仅代表语音动作；绿、黄、红和深红只代表人员安全状态，不作普通装饰。
3. 底部采用五等分导航，四个常规入口只以深浅与字重表达选中态，不使用选中圆底；中央语音按钮保持最高层级但完整落在栏体内。
4. 火场智控标志以四向场域框围合菱形判断核心，表达现场锁定后进入处置判断；图形不使用字母、机器人、面部、聊天气泡、火焰或手绘卡通。
5. 状态必须同时由文字、图标、位置与倒计时表达；快速闪烁、霓虹、玻璃拟态和装饰性渐变均不使用。
