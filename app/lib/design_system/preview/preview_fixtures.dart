import 'package:flutter/material.dart';

import '../components/connection_pill.dart';
import '../components/incident_header.dart';
import '../components/timeline_list.dart';
import '../components/tool_grid.dart';
import '../tokens/ds_colors.dart';
import '../tokens/ds_icons.dart';

/// 指挥台与现场监控原型使用的脱敏警情摘要。
@immutable
class PreviewIncidentInfo {
  const PreviewIncidentInfo({
    required this.name,
    required this.category,
    required this.elapsedText,
    required this.connectionState,
    required this.pendingSyncCount,
    required this.forceSummary,
    required this.briefSummary,
  });

  final String name;
  final DsIncidentCategory category;
  final String elapsedText;
  final DsConnectionState connectionState;
  final int pendingSyncCount;
  final String forceSummary;
  final String briefSummary;
}

/// 现场监控原型使用的脱敏单兵空呼状态模型。
@immutable
class PreviewPersonMonitor {
  const PreviewPersonMonitor({
    required this.id,
    required this.name,
    required this.station,
    required this.group,
    required this.entryTimeText,
    required this.pressureMpa,
    required this.remainingSeconds,
    required this.status,
  });

  final String id;
  final String name;
  final String station;
  final String group;
  final String entryTimeText;
  final double pressureMpa;
  final int remainingSeconds;
  final DsStatus status;
}

/// Design System v3.0 原型页面专用静态脱敏数据集。
///
/// 严格零业务依赖、零本地存储/网络访问，仅使用规范约定的脱敏占位信息。
abstract final class PreviewFixtures {
  static const PreviewIncidentInfo incident = PreviewIncidentInfo(
    name: '示例县示例路仓库火灾',
    category: DsIncidentCategory.fire,
    elapsedText: '00:42:15',
    connectionState: DsConnectionState.online,
    pendingSyncCount: 0,
    forceSummary: '3 车 18 人',
    briefSummary:
        '起火建筑为单层钢结构仓储库房，过火面积约 600 平方米。内攻一组、内攻二组分别从东侧、北侧通道推进搜救与控火，供水保障链路稳定。',
  );

  /// 按风险等级降序排列的在场 6 名内攻人员（覆盖全部 4 种有效状态）。
  static const List<PreviewPersonMonitor> personnel = <PreviewPersonMonitor>[
    PreviewPersonMonitor(
      id: 'p1',
      name: '张三',
      station: '示例路站',
      group: '内攻一组',
      entryTimeText: '14:02',
      pressureMpa: 5.8,
      remainingSeconds: -84,
      status: DsStatus.timeout,
    ),
    PreviewPersonMonitor(
      id: 'p2',
      name: '李四',
      station: '示例路站',
      group: '内攻一组',
      entryTimeText: '14:06',
      pressureMpa: 9.2,
      remainingSeconds: 245,
      status: DsStatus.alarm,
    ),
    PreviewPersonMonitor(
      id: 'p3',
      name: '王五',
      station: '示例路站',
      group: '内攻二组',
      entryTimeText: '14:12',
      pressureMpa: 16.4,
      remainingSeconds: 612,
      status: DsStatus.caution,
    ),
    PreviewPersonMonitor(
      id: 'p4',
      name: '赵六',
      station: '示例路站',
      group: '内攻二组',
      entryTimeText: '14:14',
      pressureMpa: 18.0,
      remainingSeconds: 728,
      status: DsStatus.caution,
    ),
    PreviewPersonMonitor(
      id: 'p5',
      name: '钱七',
      station: '示例路站',
      group: '内攻一组',
      entryTimeText: '14:18',
      pressureMpa: 24.6,
      remainingSeconds: 1340,
      status: DsStatus.safe,
    ),
    PreviewPersonMonitor(
      id: 'p6',
      name: '孙八',
      station: '示例路站',
      group: '内攻二组',
      entryTimeText: '14:20',
      pressureMpa: 27.2,
      remainingSeconds: 1620,
      status: DsStatus.safe,
    ),
  ];

  /// 根据人员清单统计各风险等级人数，保证汇总条与列表完全一致。
  static Map<DsStatus, int> countByStatus([
    List<PreviewPersonMonitor> list = personnel,
  ]) {
    final counts = <DsStatus, int>{
      DsStatus.timeout: 0,
      DsStatus.alarm: 0,
      DsStatus.caution: 0,
      DsStatus.safe: 0,
    };
    for (final person in list) {
      counts[person.status] = (counts[person.status] ?? 0) + 1;
    }
    return counts;
  }

  /// 返回当前在场人员的最高风险状态。
  static DsStatus highestRiskStatus([
    List<PreviewPersonMonitor> list = personnel,
  ]) {
    const priority = <DsStatus>[
      DsStatus.timeout,
      DsStatus.alarm,
      DsStatus.caution,
      DsStatus.safe,
    ];
    for (final status in priority) {
      if (list.any((person) => person.status == status)) {
        return status;
      }
    }
    return DsStatus.neutral;
  }

  /// 将剩余/超时秒数格式化为等宽 `mm:ss` 文本。
  static String formatCountdown(int seconds) {
    final abs = seconds.abs();
    final minutes = (abs ~/ 60).toString().padLeft(2, '0');
    final secs = (abs % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  /// 构建指挥台 8 项现场工具入口。
  static List<DsToolItem> buildHomeTools({
    ValueChanged<DsToolItem>? onToolTap,
  }) {
    final specs = <({
      String id,
      IconData icon,
      String label,
      String? badge,
      DsStatus badgeStatus,
      bool enabled,
    })>[
      (
        id: 'map',
        icon: DsIcons.toolSceneMap,
        label: '地图',
        badge: null,
        badgeStatus: DsStatus.alarm,
        enabled: true,
      ),
      (
        id: 'watermark_camera',
        icon: DsIcons.camera,
        label: '水印相机',
        badge: null,
        badgeStatus: DsStatus.alarm,
        enabled: true,
      ),
      (
        id: 'video',
        icon: DsIcons.video,
        label: '视频监控',
        badge: '2',
        badgeStatus: DsStatus.alarm,
        enabled: true,
      ),
      (
        id: 'key_sites',
        icon: DsIcons.toolKeySites,
        label: '重点单位',
        badge: null,
        badgeStatus: DsStatus.alarm,
        enabled: true,
      ),
      (
        id: 'hazmat',
        icon: DsIcons.toolHazmat,
        label: '危化品',
        badge: '1',
        badgeStatus: DsStatus.caution,
        enabled: true,
      ),
      (
        id: 'traffic',
        icon: DsIcons.traffic,
        label: '路况',
        badge: null,
        badgeStatus: DsStatus.alarm,
        enabled: true,
      ),
      (
        id: 'orthophoto',
        icon: DsIcons.satellite,
        label: '正射图',
        badge: null,
        badgeStatus: DsStatus.alarm,
        enabled: true,
      ),
      (
        id: 'location_share',
        icon: DsIcons.toolLocationShare,
        label: '位置共享',
        badge: null,
        badgeStatus: DsStatus.alarm,
        enabled: false,
      ),
    ];

    return specs
        .map(
          (spec) => DsToolItem(
            id: spec.id,
            icon: spec.icon,
            label: spec.label,
            badge: spec.badge,
            badgeStatus: spec.badgeStatus,
            enabled: spec.enabled,
            onTap: onToolTap == null
                ? null
                : () => onToolTap(
                      DsToolItem(
                        id: spec.id,
                        icon: spec.icon,
                        label: spec.label,
                        badge: spec.badge,
                        badgeStatus: spec.badgeStatus,
                        enabled: spec.enabled,
                      ),
                    ),
          ),
        )
        .toList(growable: false);
  }

  /// 构建火场日志 5 条示例记录（含同分钟 `14:22` 两条连续记录以展示合并效果）。
  static List<DsTimelineEntry> buildTimelineEntries({
    ValueChanged<String>? onEntryTap,
  }) {
    final items = <({
      DateTime timestamp,
      IconData icon,
      String title,
      String subtitle,
      DsStatus status,
      String categoryLabel,
    })>[
      (
        timestamp: DateTime(2026, 11, 21, 14, 22, 48),
        icon: DsIcons.statusTimeout,
        title: '张三空呼计时超时 01:24，请立即核实位置并安排接应',
        subtitle: '示例路站 · 内攻一组 · 剩余压力 5.8 MPa',
        status: DsStatus.timeout,
        categoryLabel: '超时告警',
      ),
      (
        timestamp: DateTime(2026, 11, 21, 14, 22, 12),
        icon: DsIcons.statusAlarm,
        title: '李四报压 9.2 MPa，已触发余气告警阈值',
        subtitle: '示例路站 · 内攻一组 · 语音自动解析',
        status: DsStatus.alarm,
        categoryLabel: '压降提醒',
      ),
      (
        timestamp: DateTime(2026, 11, 21, 14, 18, 30),
        icon: DsIcons.categoryFireLine,
        title: '东侧排烟口已打开，库房顶部温度明显下降',
        subtitle: '现场指令随手记 · 指挥员确认',
        status: DsStatus.caution,
        categoryLabel: '态势记录',
      ),
      (
        timestamp: DateTime(2026, 11, 21, 14, 12, 5),
        icon: DsIcons.userAdd,
        title: '王五进场、赵六进场（内攻二组北侧通道）',
        subtitle: '已开启同步空呼倒计时与安全员复核',
        status: DsStatus.safe,
        categoryLabel: '进场登记',
      ),
      (
        timestamp: DateTime(2026, 11, 21, 14, 2, 15),
        icon: DsIcons.flag,
        title: '张三进场、李四进场（内攻一组东侧通道）',
        subtitle: '参战力量 3 车 18 人已就位并建立前方供水',
        status: DsStatus.neutral,
        categoryLabel: '初期部署',
      ),
    ];

    return items
        .map(
          (item) => DsTimelineEntry(
            timestamp: item.timestamp,
            icon: item.icon,
            title: item.title,
            subtitle: item.subtitle,
            status: item.status,
            categoryLabel: item.categoryLabel,
            onTap: onEntryTap == null ? null : () => onEntryTap(item.title),
          ),
        )
        .toList(growable: false);
  }
}
