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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: const [
          _HeroCard(),
          SizedBox(height: 22),
          SectionTitle(text: '为什么会有这个 App'),
          _SectionCard(
            body:
                '火场里，安全员是最要紧也最紧张的岗位。进了多少人、进去多久了、谁的气瓶快空了——每一个数字都人命关天。'
                '但现场往往是这样：防护服、手套、对讲机的嘈杂声，烟雾里看不清纸笔，指挥员一句「报一下里面几个人」，'
                '靠的是一张被水打湿的名单和一个记在心里的时间。气瓶剩余时间要心算，人多了一乱就错。'
                '我们太清楚那种手忙脚乱的感觉了。\n\n'
                '安全员真的没时间翻记录本。我们做了这个 App，从头到尾只坚持一件事：让你张嘴说话，剩下的交给它。',
          ),
          SizedBox(height: 22),
          SectionTitle(text: '它是怎么用的'),
          _SectionCard(
            body:
                '安全员站在入口，队员进场时报一句「张三，24」：\n'
                '· App 自动听清人名和压力值，算好这瓶气能用多久\n'
                '· 谁进来、谁出去、还剩多少分钟，看板上实时滚动\n'
                '· 快没气了，App 会先说话提醒，再响警报\n'
                '· 退场时一句「张三退场」，记录自动归档\n\n'
                '全程不用敲一个字，戴着战术手套也按得动。底部就五个入口：日志、看板、语音、辅助、设置。'
                '中间那个橙色的麦克风就是最快的那只手——按住说话，文字会边说边出现，松手后快速定稿。单次录音最长 60 秒，最后 10 秒会提示，时间到自动结束并继续处理已录内容；云端异常时会保留录音并切到本机识别。\n\n'
                '同一成员可多设备同时登录，新设备登录不使旧设备下线；设置页用户操作可管理登录设备、核对离线冲突记录。新版本的人员操作带版本校验，旧读数冲突时保留记录，需人工核对后重新提交。\n\n'
                '多台设备加入同一场警情档案后，指挥员和安全员可以实时协同记录进退场、压力和火场日志；处置结束后，档案自动归档并保留完整复盘时间线。',
          ),
          SizedBox(height: 22),
          SectionTitle(text: '它能帮你什么'),
          _FeaturesCard(),
          SizedBox(height: 22),
          SectionTitle(text: '场景'),
          _SectionCard(
            body:
                '室内烟火特性训练、楼层火灾进攻、化工装置处置……'
                '凡是需要安全员盯着气瓶和人员的现场，都适用。训练场上练顺手了，真打火场才不慌。',
          ),
          SizedBox(height: 22),
          SectionTitle(text: '关于这个项目'),
          _SectionCard(
            body:
                '由一线消防员在工作之余开发，后端和 App 全部开源，以 MIT 许可证发布。联网时语音识别通过后端代理豆包实时流式 ASR，语义理解用 DeepSeek；'
                '云端异常或断网时自动切到本机 sherpa-onnx 识别和规则解析，两套兜底都备着，火场无信号也能用。\n\n'
                '我们不是软件公司，就是一群想让安全员轻松一点的战友。如果你的队伍也用得上，欢迎提需求、提 bug——'
                '每一个意见，都可能救下一个兄弟。项目网站：fireman119.xyz。',
          ),
          SizedBox(height: 22),
          SectionTitle(text: '开源许可'),
          _SectionCard(
            body:
                '本项目以 MIT 许可证开源：你可以自由使用、修改和分发，包括商业用途，只需保留版权声明与许可声明。\n\n'
                '第三方组件各自遵循其原始许可：本地语音识别使用 sherpa-onnx（Apache-2.0），界面与基础能力依赖 Flutter 生态（BSD/MIT/Apache-2.0）。'
                '完整清单见仓库根目录的 THIRD_PARTY_NOTICES.md。',
          ),
          SizedBox(height: 22),
          SectionTitle(text: '后端部署'),
          _SectionCard(
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

/// 顶部品牌卡：图标 + 名称 + 一句话简介（版本号不在本页展示）
class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s5),
      child: Column(
        children: [
          const FireControlLogo(size: 64),
          const SizedBox(height: AppSpacing.s3),
          Text(
            '火场智控',
            style: AppTextStyles.h2.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            '一款由消防员开发、给消防员用的 App',
            textAlign: TextAlign.center,
            style: AppTextStyles.label.copyWith(
              fontSize: 14,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
              height: 1.55,
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
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Text(
        body,
        style: AppTextStyles.bodyMd.copyWith(
          fontSize: 14,
          color: AppColors.textSecondary,
          height: 1.58,
        ),
      ),
    );
  }
}

/// 功能列表卡：图标 + 标题 + 描述
class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard();

  static const _items = [
    (
      Icons.mic_rounded,
      '语音录入',
      '进场、退场、压力值，一句话搞定；文字边说边出现，松手后再解析；云端失败保留录音并回退本机识别；单次最长 60 秒',
    ),
    (
      Icons.smart_toy_outlined,
      '辅助问答',
      '火场智囊「水元素」，浓烟里拿不准主意就问它：语音转写仅用于本页与 AI 交流，不发布到火场日志；支持拍照或相册图片分析，清晰的危化品运输标牌 UN 编号会自动联网查询对应物质及来源，模糊编号需补拍确认，图片临时上传至服务端和 DeepSeek-V4.1-Flash，默认不保存原图；默认联网检索，陌生危险化学品等问题可查找资料；按结论/立即行动/注意事项简洁支招；收到整段警情简报会主动研判风险、处置要点和待核实信息；对话历史只保存在本机',
    ),
    (
      Icons.receipt_long_outlined,
      '火场日志',
      '进场自动记录空气呼吸器压力，撤离自动记录为撤离救援现场；其他现场信息也可语音记入，按实战环节分类复盘',
    ),
    (Icons.calculate_outlined, '自动计算', '气瓶容量、压力、消耗率交给我们算，剩余 10 分钟提醒、5 分钟报警'),
    (Icons.dashboard_rounded, '实时看板', '在场谁、进去多久、还剩多久，一目了然；到点自动播报、响警报、锁屏也推通知'),
    (
      Icons.offline_bolt_outlined,
      '断网可用',
      '联网时通过后端代理豆包实时识别，文字边说边返回；云端失败或断网时语音识别与语义解析切到本机运行；名单、用户热词和内置消防术语会注入识别；本地 ASR 主模型约 75MB，另有可选的 9.8MB 降噪模型；模型下载和缓存启用前会校验完整性',
    ),
    (
      Icons.system_update_alt_rounded,
      '版本更新',
      '通过 ALI 更新服务器检查正式版本，下载后校验 SHA-256，再交由系统安装器完成更新；代码和 Release 备份保留在 GitHub',
    ),
    (
      Icons.folder_copy_outlined,
      '用户认证与游客模式',
      '首次打开支持一键开启游客模式单机体验全功能，顶部横幅随时转正，首页与设置页连接状态明确标识单机；正式加入支持双轨制，队员凭单位码提交申请，本单位站长、单位管理员及有平台管理员授权的本单位成员可在「设置 → 入队审批」共同处理，在线同步待办并每30秒校准，保留处理人与时间，加载失败可重试，不含离线系统推送；也可由管理员手动录入，姓名秒级同步单位 ASR 离线词库；语音名单只提升识别准确率、不授予登录权限，登录失败会区分「已在语音名单但尚未开通登录」与「姓名写法对不上」并给出近似姓名候选；认证后可选择现有警情、直接新建带时间戳名称的警情，或暂不选择警情直接进入 App；未选警情时首页显示“暂无正在处置的警情”，处警记录会引导选择或新建，其他功能可按需使用',
    ),
    (
      Icons.document_scanner_outlined,
      '重点单位资料',
      '资料由获得独立后台授权的人员在 https://fireman119.xyz/admin/ 维护。按单位基本情况范例直接填写分项表单，涵盖概况、毗邻道路、生产装置、消防设施及水源、工艺流程、重点提示、仓库库存、储罐和联系人；地图与预案按独立模块维护。无需填写信息出处或经过AI整理；保存仅更新草稿，发布后全平台已认证有效成员可在App查看，游客不可访问。App按分项字段展示已发布信息，不展示出处；地图文件选填，已关联地图可从“查看地图”打开。首页“现场工具 → 重点单位”进入，设置身份卡可扫码确认后台登录，后台授权与单位角色独立。草稿、已发布版本、历史引用和后台审计按原权限保留',
    ),
    (
      Icons.videocam_outlined,
      '视频资源与系统画中画',
      '首页「现场工具 → 视频资源」可查看本单位授权监控，播放后在行内、全屏、浮动三种呈现之间切换，共用同一路会话；播放期间切到后台或其它 App，画面以系统画中画（Android 8.0+，不额外申请悬浮窗权限）继续可见，回到 App 后恢复原页面；回到前台会重新挂载渲染目标，避免长时间后台后画面停在最后一帧；画中画里只渲染视频画面，不支持画中画的设备退化为普通后台行为',
    ),
    (
      Icons.document_scanner_outlined,
      '警情导入与常用队伍',
      '首页警情卡默认折叠，保留名称、类别和队伍数量，展开后可登记力量、信息导入和调整灾情等级；信息导入统一提供拍照、手机相册多选和文字通报，每批最多9张；云端分析后人工核对名称、地点、类型和力量再应用，未知数量保持待补充，不创建个人进场或计时。名录外队伍可登记并保存常用，已有共享名称、别名和停用由管理员维护；历史名称不随名录改动',
    ),
    (
      Icons.description_outlined,
      '警情资料与辅助背景',
      '已确认资料随警情同步归档，辅助问答使用当前警情背景，对话按单位和警情隔离；旧版对话在历史通用对话中查看。临时原图最长保留24小时，应用、取消或到期后清理，正式档案保留提取文字而非原图',
    ),
    (
      Icons.history_outlined,
      '离线补传与复盘',
      '现场操作断网持久化暂存，恢复网络后幂等补传；归档后按晚到早查看完整事件时间线',
    ),
    (
      Icons.group_outlined,
      '单位语音词库',
      '完成单位认证后自动加载本单位预置词和成员新增词条；所有已认证用户都可补充，退出单位后本机自动清空',
    ),
    (Icons.bar_chart_rounded, '数据统计', '每人的进出场次数、时长一清二楚，训练复盘心里有数'),
    (
      Icons.map_outlined,
      '重点单位地图',
      '从首页重点单位进入，按资料版本查看地图；瓦片按需加载，支持双指缩放、拖动和恢复全图。演示影像明确标识；图片坐标不提供经纬度定位',
    ),
    (
      Icons.fact_check_outlined,
      '标准化单位资料',
      '单位概况、毗邻道路、生产装置、消防设施与水源、工艺流程、重点提示、仓库库存、储罐和联系人分别维护；容积与实际储量分开，原文单位、约数和涉密说明保留。资料经后台人工核对发布后查阅，旧资料与历史版本保留',
    ),
    (
      Icons.videocam_outlined,
      '视频资源',
      '首页「视频资源」展示本单位管理员启用的监控与现场画面，资源名称旁用绿点表示地址可达、红点表示探测失败。管理员可在设置页新增、编辑或停用资源，普通成员不可见管理入口。点击资源后卡片就地竖屏展开并立即播放；播放器角上可切到自动横屏的全屏模式，或回到首页以竖屏浮窗继续播放，小窗内也能再次切回全屏。三种视图复用同一路连接，关闭按钮会停止播放并收起卡片或关闭窗口。首次建流保留加载态，非致命播放器噪声和短暂错误不会抢先显示失败；画面使用现有 media_kit 播放器直接播放授权 HTTP-FLV 地址，断线自动重试，视频地址只存数据库，不写入公开源码',
    ),
    (
      Icons.share_location_outlined,
      '定位分享',
      '首页「现场工具」在空闲和现场监控状态下始终显示四张工具卡。定位分享展示当前警情、单位、地址、定位时间、精度和 WGS84 坐标，可复制完整文案或调用系统分享；文案附带独立成行的高德查看位置与驾车导航 HTTPS 链接。后端先把 WGS84 转为 GCJ-02 再查询地址和生成路线，减少导航偏移；转换失败时仍保留 WGS84 查看位置并隐藏驾车导航。微信内目标是打开高德 H5 位置或路线页，不承诺直接唤起高德 App；不包含发送人姓名，不保存位置历史，也不上传接收方信息。定位超过 2 分钟提示核实，超过 5 分钟禁止直接分享并要求重新定位',
    ),
    (
      Icons.videocam_outlined,
      '水印相机',
      '从首页「水印相机」拍摄，在设置页「水印设置」配置文字与显示字段；可选择横屏完整视野或竖屏 16:9 中心裁切，默认横屏，两种模式成片均为横版 16:9；拍摄现场照片与小视频时，把单位、地址、天气、拍摄人和精确到秒的时间烧进画面，单段最长 60 秒。核对页只提供「保存并分享」和「仅保存」，两者都会把带水印版与无水印版成对保存到手机相册，任一份失败就整体回滚；保存并分享只分享带水印文件，不附带口述文字。App 内的拍摄文件仅用于核对，保存成功后会在后台清理，手机相册成为唯一保存位置；历史资料没有母版时明确降级为只保存带水印版。照片与视频不上传；开启联网识别时仅上传提取的音频转写，失败时回退本机识别。口述写入警情与相册保存相互独立',
    ),
    (Icons.touch_app_outlined, '火场友好', '屏幕常亮、后台保活、按键式录音，戴着手套、满场嘈杂也能用'),
  ];

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
      child: Column(
        children: [
          for (final (i, item) in _items.indexed) ...[
            if (i > 0)
              const Divider(
                height: 1,
                indent: AppSpacing.s4,
                endIndent: AppSpacing.s4,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s4,
                vertical: AppSpacing.s3,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      color: AppColors.surfaceSubtle,
                    ),
                    child: Icon(
                      item.$1,
                      size: 18,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$2,
                          style: AppTextStyles.bodyMd.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s1),
                        Text(
                          item.$3,
                          style: AppTextStyles.label.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
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
    );
  }
}
