import 'package:flutter/material.dart';

import '../theme/app_widgets.dart';

/// 关于我们：展示项目 README 核心信息（为什么做/怎么用/功能/场景/项目背景）。
/// 与名单热词/数据统计同款 AppBar + 卡片排版。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// 与 app/pubspec.yaml 的 version 保持一致
  static const appVersion = '0.2.1+5';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('关于我们')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: const [
          _HeroCard(),
          SizedBox(height: 18),
          SectionTitle(text: '为什么会有这个 App'),
          _SectionCard(
            body: '火场里，安全员是最要紧也最紧张的岗位。进了多少人、进去多久了、谁的气瓶快空了——每一个数字都人命关天。'
                '但现场往往是这样：防护服、手套、对讲机的嘈杂声，烟雾里看不清纸笔，指挥员一句「报一下里面几个人」，'
                '靠的是一张被水打湿的名单和一个记在心里的时间。气瓶剩余时间要心算，人多了一乱就错。\n\n'
                '安全员真的没时间翻记录本。我们做了这个 App，让安全员只做一件事：张嘴说。',
          ),
          SizedBox(height: 18),
          SectionTitle(text: '它是怎么用的'),
          _SectionCard(
            body: '安全员站在入口，队员进场时报一句「张三，24」：\n'
                '· App 自动听清人名和压力值，算好这瓶气能用多久\n'
                '· 谁进来、谁出去、还剩多少分钟，全部实时显示在看板上\n'
                '· 快没气了，App 会提醒、会响警报、会大声喊出来\n'
                '· 退场时一句「张三退场」，记录自动归档\n\n'
                '全程不用敲一个字，戴着战术手套也能操作。几台手机连上同一个场景码，'
                '指挥员和多个安全员看到的是同一块看板，数据实时同步。',
          ),
          SizedBox(height: 18),
          SectionTitle(text: '它能帮你什么'),
          _FeaturesCard(),
          SizedBox(height: 18),
          SectionTitle(text: '场景'),
          _SectionCard(
            body: '室内烟火特性训练、楼层火灾进攻、化工装置处置……'
                '凡是需要安全员盯着气瓶和人员的现场，都适用。',
          ),
          SizedBox(height: 18),
          SectionTitle(text: '关于这个项目'),
          _SectionCard(
            body: '由一线消防员在工作之余开发，用了豆包语音识别和 DeepSeek 语义理解做语音解析，后端和 App 全部开源。'
                '断网时自动切换本机 sherpa-onnx 语音识别与规则解析，火场无信号也能用。\n\n'
                '如果你的队伍也用得上，欢迎提需求、提 bug，一起让它变得更好用。',
          ),
        ],
      ),
    );
  }
}

/// 顶部品牌卡：图标 + 名称 + 版本 + 一句话简介
class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.actionPrimary,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: AppShadow.card,
            ),
            child: const Icon(Icons.shield_outlined, size: 32, color: Colors.white),
          ),
          const SizedBox(height: 14),
          const Text('安全员助手 WatchDog', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text('v${AboutPage.appVersion}', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          const Text(
            '一款由消防员开发、给消防员用的 App',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 普通段落卡片：统一正文排版
class _SectionCard extends StatelessWidget {
  final String body;

  const _SectionCard({required this.body});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Text(
        body,
        style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.65),
      ),
    );
  }
}

/// 功能列表卡：图标 + 标题 + 描述
class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard();

  static const _items = [
    (Icons.mic_rounded, '语音录入', '进场、退场、压力值，一句话搞定，自动识别人名和气瓶压力'),
    (Icons.offline_bolt_outlined, '断网可用', '语音识别与语义解析支持本机运行，火场没信号也能录'),
    (Icons.calculate_outlined, '自动计算', '气瓶容量、压力、消耗率交给我们算，10 分钟、5 分钟双阈值预警'),
    (Icons.dashboard_rounded, '实时看板', '在场谁、进去多久、还剩多久，一目了然；到点自动播报、闹钟提醒'),
    (Icons.group_outlined, '名单与热词', '把班组名单录进去，语音识别对你的人名更准'),
    (Icons.touch_app_outlined, '火场友好', '屏幕常亮、后台保活、按键式录音，戴着手套、满场嘈杂也能用'),
  ];

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final (i, item) in _items.indexed) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.surfaceSubtle,
                    ),
                    child: Icon(item.$1, size: 18, color: AppColors.textPrimary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.$2, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text(item.$3, style: const TextStyle(fontSize: 12.5, color: AppColors.textTertiary, height: 1.45)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
