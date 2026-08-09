import 'package:flutter/material.dart';

import '../theme/fire_control_logo.dart';
import '../theme/app_widgets.dart';

/// 关于我们：展示项目 README 核心信息（为什么做/怎么用/功能/场景/项目背景）。
/// 与名单热词/数据统计同款 AppBar + 卡片排版。版本号只在设置页底部展示，这里不显示。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
            body:
                '火场里，安全员是最要紧也最紧张的岗位。进了多少人、进去多久了、谁的气瓶快空了——每一个数字都人命关天。'
                '但现场往往是这样：防护服、手套、对讲机的嘈杂声，烟雾里看不清纸笔，指挥员一句「报一下里面几个人」，'
                '靠的是一张被水打湿的名单和一个记在心里的时间。气瓶剩余时间要心算，人多了一乱就错。'
                '我们太清楚那种手忙脚乱的感觉了。\n\n'
                '安全员真的没时间翻记录本。我们做了这个 App，从头到尾只坚持一件事：让你张嘴说话，剩下的交给它。',
          ),
          SizedBox(height: 18),
          SectionTitle(text: '它是怎么用的'),
          _SectionCard(
            body:
                '安全员站在入口，队员进场时报一句「张三，24」：\n'
                '· App 自动听清人名和压力值，算好这瓶气能用多久\n'
                '· 谁进来、谁出去、还剩多少分钟，看板上实时滚动\n'
                '· 快没气了，App 会先说话提醒，再响警报\n'
                '· 退场时一句「张三退场」，记录自动归档\n\n'
                '全程不用敲一个字，戴着战术手套也按得动。底部就五个入口：日志、看板、语音、辅助、设置。'
                '中间那个橙色的麦克风就是最快的那只手——按住说话，松手完事。\n\n'
                '多台设备加入同一场警情档案后，指挥员和安全员可以实时协同记录进退场、压力和火场日志；处置结束后，档案自动归档并保留完整复盘时间线。',
          ),
          SizedBox(height: 18),
          SectionTitle(text: '它能帮你什么'),
          _FeaturesCard(),
          SizedBox(height: 18),
          SectionTitle(text: '场景'),
          _SectionCard(
            body:
                '室内烟火特性训练、楼层火灾进攻、化工装置处置……'
                '凡是需要安全员盯着气瓶和人员的现场，都适用。训练场上练顺手了，真打火场才不慌。',
          ),
          SizedBox(height: 18),
          SectionTitle(text: '关于这个项目'),
          _SectionCard(
            body:
                '由一线消防员在工作之余开发，后端和 App 全部开源。语音识别用豆包，语义理解用 DeepSeek，'
                '断网时自动切到本机 sherpa-onnx 识别和规则解析，两套兜底都备着，火场无信号也能用。\n\n'
                '我们不是软件公司，就是一群想让安全员轻松一点的战友。如果你的队伍也用得上，欢迎提需求、提 bug——'
                '每一个意见，都可能救下一个兄弟。',
          ),
        ],
      ),
    );
  }
}

/// 顶部品牌卡：图标 + 名称 + 一句话简介（版本号不在本页展示）
class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const FireControlLogo(size: 64),
          const SizedBox(height: 14),
          const Text(
            '火场智控',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '一款由消防员开发、给消防员用的 App',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
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
        style: const TextStyle(
          fontSize: 14,
          color: AppColors.textSecondary,
          height: 1.65,
        ),
      ),
    );
  }
}

/// 功能列表卡：图标 + 标题 + 描述
class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard();

  static const _items = [
    (Icons.mic_rounded, '语音录入', '进场、退场、压力值，一句话搞定；多人一次报完一次确认，单人气瓶容量可单独改'),
    (
      Icons.smart_toy_outlined,
      '辅助问答',
      '火场智囊「水元素」，浓烟里拿不准主意就问它：按结论/立即行动/注意事项支招，回答会联网检索最新规范与器材资料，拿不准时不瞎编，追问一点就发',
    ),
    (Icons.receipt_long_outlined, '火场日志', '说一句「搜救出一人」自动记进日志时间线，按实战环节分类，回头好复盘'),
    (Icons.calculate_outlined, '自动计算', '气瓶容量、压力、消耗率交给我们算，剩余 10 分钟提醒、5 分钟报警'),
    (Icons.dashboard_rounded, '实时看板', '在场谁、进去多久、还剩多久，一目了然；到点自动播报、响警报、锁屏也推通知'),
    (Icons.offline_bolt_outlined, '断网可用', '语音识别与语义解析支持本机运行，火场没信号也能录'),
    (Icons.folder_copy_outlined, '警情档案', '多台设备加入同一场警情协同记录；名称、参战消防站和力量数量可共同维护'),
    (Icons.history_outlined, '离线补传与复盘', '现场操作断网持久化暂存，恢复网络后幂等补传；归档后按晚到早查看完整事件时间线'),
    (Icons.group_outlined, '名单与热词', '把班组名单录进去，语音识别对你的人名和叫法更准'),
    (Icons.bar_chart_rounded, '数据统计', '每人的进出场次数、时长一清二楚，训练复盘心里有数'),
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
                    child: Icon(
                      item.$1,
                      size: 18,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$2,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.$3,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textTertiary,
                            height: 1.45,
                          ),
                        ),
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
