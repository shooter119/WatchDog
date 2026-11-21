import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'settings_widgets.dart';

/// 关于我们：展示项目 README 核心信息（为什么做/怎么用/功能/场景/项目背景）。
///
/// 按约定版本号只在「我的」页版本更新条目展示，本页不显示任何硬编码版本号。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CommandScaffold(
      appBar: AppBar(title: const Text('关于我们')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.pageMargin,
          DsSpacing.md,
          DsSpacing.pageMargin,
          DsSpacing.xxl,
        ),
        children: const <Widget>[
          _BrandHeroCard(),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '为什么会有这个 App'),
          _ProseCard(
            body:
                '火场里，安全员是最要紧也最紧张的岗位。进了多少人、进去多久了、谁的气瓶快空了——每一个数字都人命关天。'
                '但现场往往是这样：防护服、手套、对讲机的嘈杂声，烟雾里看不清纸笔，指挥员一句「报一下里面几个人」，'
                '靠的是一张被水打湿的名单和一个记在心里的时间。气瓶剩余时间要心算，人多了一乱就错。'
                '我们太清楚那种手忙脚乱的感觉了。\n\n'
                '安全员真的没时间翻记录本。我们做了这个 App，从头到尾只坚持一件事：让你张嘴说话，剩下的交给它。',
          ),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '它是怎么用的'),
          _ProseCard(
            body:
                '安全员站在入口，队员进场时报一句「张三，24」：\n'
                '· App 自动听清人名和压力值，算好这瓶气能用多久\n'
                '· 谁进来、谁出去、还剩多少分钟，看板上实时滚动\n'
                '· 快没气了，App 会先说话提醒，再响警报\n'
                '· 退场时一句「张三退场」，记录自动归档\n\n'
                '全程不用敲一个字，戴着战术手套也按得动。底部采用「指挥台、现场监控、智能辅助、我的」4 Tab 加正中 64dp 语音指令键架构，火场日志与现场工具宫格集成于指挥台一键直达。按住底栏中置语音键即可直接说话处置录入；处于「智能辅助」页时，长按正中按钮即可就地向「水元素」语音提问（无需先选警情）。录音时文字边说边出现，松手后快速定稿。单次录音最长 60 秒，最后 10 秒会提示，时间到自动结束并继续处理已录内容；云端异常时会保留录音并切到本机识别。\n\n'
                '同一成员可多设备同时登录，新设备登录不使旧设备下线；在用户操作中可管理登录设备、核对离线冲突记录。人员操作带版本校验，旧读数冲突时保留记录，需人工核对后重新提交。\n\n'
                '多台设备加入同一场警情档案后，指挥员和安全员可以实时协同记录进退场、压力和火场日志；处置结束后，档案自动归档并保留完整复盘时间线。',
          ),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '它能帮你什么'),
          _FeaturesCard(),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '场景'),
          _ProseCard(
            body:
                '室内烟火特性训练、楼层火灾进攻、化工装置处置……'
                '凡是需要安全员盯着气瓶和人员的现场，都适用。训练场上练顺手了，真打火场才不慌。',
          ),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '关于这个项目'),
          _ProseCard(
            body:
                '由一线消防员在工作之余开发，后端和 App 全部开源，以 MIT 许可证发布。联网时语音识别通过后端代理豆包实时流式 ASR，语义理解用 DeepSeek；'
                '云端异常或断网时自动切到本机 sherpa-onnx 识别和规则解析，两套兜底都备着，火场无信号也能用。\n\n'
                '我们不是软件公司，就是一群想让安全员轻松一点的战友。如果你的队伍也用得上，欢迎提需求、提 bug——'
                '每一个意见，都可能救下一个兄弟。项目网站：fireman119.xyz。',
          ),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '开源许可'),
          _ProseCard(
            body:
                '本项目以 MIT 许可证开源：你可以自由使用、修改和分发，包括商业用途，只需保留版权声明与许可声明。\n\n'
                '第三方组件各自遵循其原始许可：本地语音识别使用 sherpa-onnx（Apache-2.0），界面与基础能力依赖 Flutter 生态（BSD/MIT/Apache-2.0）。'
                '完整清单见仓库根目录的 THIRD_PARTY_NOTICES.md。',
          ),
          SizedBox(height: DsSpacing.xxl),
          SettingsSectionTitle(text: '后端部署'),
          _ProseCard(
            body:
                '服务端使用 api.fireman119.xyz 提供 HTTPS 访问。后端使用标准 PostgreSQL 17。业务数据、审计事件和实时 Outbox 在同一事务中提交，'
                '通过 PostgreSQL LISTEN/NOTIFY 唤醒多实例，再由 WebSocket 推送给同单位在线 App。'
                '模型由后端 /models/ 目录分发，部署平台不作限定；AI 仍使用 DeepSeek 直连。',
          ),
        ],
      ),
    );
  }
}

class _BrandHeroCard extends StatelessWidget {
  const _BrandHeroCard();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.xl),
      child: Column(
        children: <Widget>[
          const _FireControlMark(size: 64),
          const SizedBox(height: DsSpacing.md),
          Text(
            '火场智控',
            style: ds.typography.headline.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(
            '一款由消防员开发、给消防员用的 App',
            textAlign: TextAlign.center,
            style: ds.typography.body.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ProseCard extends StatelessWidget {
  const _ProseCard({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Text(
        body,
        style: ds.typography.body.copyWith(
          color: ds.colors.textSecondary,
          height: 1.58,
        ),
      ),
    );
  }
}

class _FeatureGroup {
  const _FeatureGroup({required this.title, required this.items});

  final String title;
  final List<(IconData, String, String)> items;
}

class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard();

  static const List<_FeatureGroup> _groups = <_FeatureGroup>[
    _FeatureGroup(
      title: '现场记录',
      items: <(IconData, String, String)>[
        (
          Icons.mic_rounded,
          '语音录入',
          '进场、退场、压力值，一句话搞定；文字边说边出现，松手后再解析；云端失败保留录音并回退本机识别；单次最长 60 秒',
        ),
        (
          Icons.smart_toy_outlined,
          '辅助问答',
          '火场智囊「水元素」，处于「智能辅助」页时长按底栏中置语音键即可就地语音提问（无需先选警情）；支持拍照或相册图片视觉分析，清晰危化品运输标牌 UN 编号自动联网查询；默认以精炼「火场口令卡」流式回复，延伸问题独立展示；对话历史仅存本机',
        ),
        (
          Icons.receipt_long_outlined,
          '火场日志',
          '进场自动记录空气呼吸器压力，撤离自动记录为撤离救援现场；其他现场信息也可语音记入，按实战环节分类复盘',
        ),
        (
          Icons.share_location_outlined,
          '定位分享',
          '展示当前警情、单位、地址、定位时间、精度与 WGS84 坐标，可一键复制或系统分享单条高德位置链接；定位超过 2 分钟提示核实，超过 5 分钟要求重新定位',
        ),
        (
          Icons.route_outlined,
          '路况查询',
          '并行查询多种高德驾车路径选项，按耗时升序展示最多 4 条方案、拥堵路段、实时天气与昼夜趋势，支持复制路况简报与拉起高德导航',
        ),
        (
          Icons.phone_in_talk_outlined,
          '号码一键呼叫',
          '警情详情、火场日志等全局文本中的电话号码自动识别与零抖动内联高亮，点击直达拨号，长按快速复制',
        ),
        (
          Icons.videocam_outlined,
          '水印相机',
          '支持横屏完整视野或竖屏 16:9 中心裁切，成片均为横版 16:9；将单位、地址、天气、拍摄人和精确到秒的时间烧进画面，核对后带水印版与无水印母版成对保存至相册',
        ),
        (
          Icons.touch_app_outlined,
          '火场友好',
          '屏幕常亮、后台保活、按键式录音，戴着手套、满场嘈杂也能用；内置「昼白」「暗曜」「跟随系统」三种外观模式，可在「我的 → 界面外观」即时切换',
        ),
      ],
    ),
    _FeatureGroup(
      title: '监控与报警',
      items: <(IconData, String, String)>[
        (
          Icons.calculate_outlined,
          '自动计算',
          '气瓶容量、压力、消耗率交给我们算，剩余 10 分钟提醒、5 分钟报警',
        ),
        (
          Icons.dashboard_rounded,
          '实时看板',
          '在场谁、进去多久、还剩多久，一目了然；到点自动播报、响警报、锁屏也推通知',
        ),
        (
          Icons.picture_in_picture_alt_outlined,
          '视频资源与系统画中画',
          '查看本单位授权监控，支持行内、全屏与悬浮窗三种呈现共用同一路会话；切后台自动进入 Android 系统画中画，回前台自动重挂渲染目标',
        ),
      ],
    ),
    _FeatureGroup(
      title: '资料与协同',
      items: <(IconData, String, String)>[
        (
          Icons.document_scanner_outlined,
          '重点单位资料',
          '授权人员在 https://fireman119.xyz/admin/ 按九类标准化字段维护单位概况、毗邻道路、生产装置、消防设施及水源、工艺流程、重点提示、仓库库存、储罐与联系人，支持平面地图与 360° 多机位全景漫游',
        ),
        (
          Icons.satellite_alt_outlined,
          '现场实时卫星地图',
          '基于高德 JS API 2.0 安全代理提供卫星+路网 / 纯卫星 / 标准图切换，端侧 WGS-84 至 GCJ-02 纠偏，自动标注事发地与直线距离',
        ),
        (
          Icons.water_drop_outlined,
          '周边水源',
          '按大队隔离共享的自建水源库，在卫星底图与距离升序列表中查找市政消火栓、天然水源与水泵接合器，支持十字准星选点维护与 60 秒软删撤销',
        ),
        (
          Icons.description_outlined,
          '警情导入与辅助背景',
          '支持拍照、相册多选（最多 9 张）与文字通报智能提取，人工核对后应用并同步归档；已确认资料自动作为辅助问答上下文',
        ),
        (
          Icons.science_outlined,
          '危化品应急速查',
          '内置 65+ 种常见危化品离线词库并持久化至 SQLite，断网输入 UN 编号或品名即可秒出电台战术复诵卡，支持一键复制处置要点',
        ),
      ],
    ),
    _FeatureGroup(
      title: '设置与数据',
      items: <(IconData, String, String)>[
        (
          Icons.offline_bolt_outlined,
          '断网可用',
          '联网时通过后端代理豆包实时识别；断网或异常时自动切至本机 sherpa-onnx 识别与规则解析（主模型约 75MB，可选 9.8MB 降噪模型），下载与启用前均校验完整性',
        ),
        (
          Icons.group_outlined,
          '单位语音词库',
          '完成单位认证后自动加载本单位预置词和成员新增词条；所有已认证用户都可补充，退出单位后本机自动清空',
        ),
        (
          Icons.history_outlined,
          '离线补传与复盘',
          '现场操作断网持久化暂存，恢复网络后幂等补传；归档后按晚到早查看完整事件时间线',
        ),
        (Icons.bar_chart_rounded, '数据统计', '每人的进出场次数、时长一清二楚，训练复盘心里有数'),
        (
          Icons.folder_copy_outlined,
          '用户认证与游客模式',
          '支持一键开启游客模式单机体验全功能；正式加入支持双轨制审批与多设备并行登录，统一警情列表区分自建与官方派警并支持快速认领协同',
        ),
        (
          Icons.system_update_alt_rounded,
          '版本更新',
          '通过 ALI 更新服务器检查正式版本，下载后强制校验 SHA-256，再交由系统安装器完成更新；代码和 Release 备份保留在 GitHub',
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
      child: Column(
        children: <Widget>[
          for (final (groupIndex, group) in _groups.indexed) ...<Widget>[
            if (groupIndex > 0)
              Divider(
                height: 1,
                indent: DsSpacing.lg,
                endIndent: DsSpacing.lg,
                color: colors.border,
              ),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: groupIndex == 0,
                shape: const Border(),
                collapsedShape: const Border(),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.lg,
                ),
                childrenPadding: EdgeInsets.zero,
                iconColor: colors.textSecondary,
                collapsedIconColor: colors.textSecondary,
                title: Container(
                  constraints: const BoxConstraints(
                    minHeight: DsSizes.touchTarget,
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    group.title,
                    style: ds.typography.title.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                children: <Widget>[
                  for (final item in group.items) ...<Widget>[
                    Divider(
                      height: 1,
                      indent: DsSpacing.lg,
                      endIndent: DsSpacing.lg,
                      color: colors.border,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DsSpacing.lg,
                        vertical: DsSpacing.md,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SettingsIconBox(icon: item.$1),
                          const SizedBox(width: DsSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  item.$2,
                                  style: ds.typography.body.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: DsSpacing.xs),
                                Text(
                                  item.$3,
                                  style: ds.typography.caption.copyWith(
                                    color: colors.textSecondary,
                                    height: 1.56,
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
            ),
          ],
        ],
      ),
    );
  }
}

/// 渲染标准 `fire-control-mark.svg` 几何标志，自适应 Design System v3.0 语义色。
class _FireControlMark extends StatelessWidget {
  const _FireControlMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return Semantics(
      label: '火场智控标志',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _FireControlMarkPainter(
            background: colors.brand,
            foreground: colors.onBrand,
          ),
        ),
      ),
    );
  }
}

class _FireControlMarkPainter extends CustomPainter {
  const _FireControlMarkPainter({
    required this.background,
    required this.foreground,
  });

  final Color background;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 512;
    canvas
      ..save()
      ..translate((size.width - 512 * scale) / 2, (size.height - 512 * scale) / 2)
      ..scale(scale);
    final paint = Paint()..style = PaintingStyle.fill;
    paint.color = background;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24, 24, 464, 464),
        const Radius.circular(108),
      ),
      paint,
    );
    final frame = Path()
      ..moveTo(120, 120)..lineTo(236, 120)..lineTo(236, 164)..lineTo(164, 164)..lineTo(164, 236)..lineTo(120, 236)..close()
      ..moveTo(392, 120)..lineTo(392, 236)..lineTo(348, 236)..lineTo(348, 164)..lineTo(276, 164)..lineTo(276, 120)..close()
      ..moveTo(120, 392)..lineTo(120, 276)..lineTo(164, 276)..lineTo(164, 348)..lineTo(236, 348)..lineTo(236, 392)..close()
      ..moveTo(392, 392)..lineTo(276, 392)..lineTo(276, 348)..lineTo(348, 348)..lineTo(348, 276)..lineTo(392, 276)..close();
    final core = Path()
      ..moveTo(256, 196)..lineTo(316, 256)..lineTo(256, 316)..lineTo(196, 256)..close();
    paint.color = foreground;
    canvas
      ..drawPath(frame, paint)
      ..drawPath(core, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _FireControlMarkPainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}
