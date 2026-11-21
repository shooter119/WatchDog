import 'package:flutter/foundation.dart';

/// 标准 6.8L 气瓶容积（默认型号）。
const double kDefaultCylinderVolumeL = 6.8;

/// 9L 大容量气瓶容积。
const double kLargeCylinderVolumeL = 9.0;

/// 当前支持的固定气瓶容积档位（升）。
const List<double> kAllowedCylinderVolumesL = <double>[
  kDefaultCylinderVolumeL,
  kLargeCylinderVolumeL,
];

/// 允许的气瓶压力上限（MPa）。
const double kMaxValidPressureMpa = 40.0;

/// 校验气瓶容积是否为允许型号（6.8L 或 9.0L）。
bool isAllowedCylinderVolume(double volumeL) =>
    (volumeL - kDefaultCylinderVolumeL).abs() < 0.01 ||
    (volumeL - kLargeCylinderVolumeL).abs() < 0.01;

/// 将容积数值标准化为 9.0L 或 6.8L（默认回退 6.8L）。
double normalizeCylinderVolume(double volumeL) =>
    (volumeL - kLargeCylinderVolumeL).abs() < 0.01
    ? kLargeCylinderVolumeL
    : kDefaultCylinderVolumeL;

/// 格式化容积文本（如 `6.8` / `9.0`）。
String formatCylinderVolume(double volumeL) =>
    normalizeCylinderVolume(volumeL).toStringAsFixed(1);

/// 容积芯片展示文案（`6.8L` / `9L`）。
String cylinderVolumeChipLabel(double volumeL) =>
    (volumeL - kLargeCylinderVolumeL).abs() < 0.01 ? '9L' : '6.8L';

/// 容积芯片语义 Key 后缀（`6.8` / `9`）。
String cylinderVolumeKeyTag(double volumeL) =>
    (volumeL - kLargeCylinderVolumeL).abs() < 0.01 ? '9' : '6.8';

final RegExp _volumePattern = RegExp(
  r'([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十]+)\s*(?:公升|升)',
);

/// 解析简单中文数字（一..十、十一..九十九），不支持时返回 null。
double? parseSimpleChineseNumber(String raw) {
  const digits = <String, int>{
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (digits.containsKey(trimmed)) return digits[trimmed]!.toDouble();
  if (trimmed.contains('十')) {
    final parts = trimmed.split('十');
    if (parts.length != 2) return null;
    final tens = parts[0].isEmpty ? 1 : digits[parts[0]];
    final ones = parts[1].isEmpty ? 0 : digits[parts[1]];
    if (tens == null || ones == null) return null;
    return (tens * 10 + ones).toDouble();
  }
  return null;
}

/// 从语音文本中提取气瓶容积升数（如"9升"/"九升"/"6.8升"）；未提及或非允许型号返回 null。
double? extractCylinderVolumeL(String text) {
  final match = _volumePattern.firstMatch(text);
  if (match == null) return null;
  final raw = match.group(1)!;
  final value = double.tryParse(raw) ?? parseSimpleChineseNumber(raw);
  if (value == null || !isAllowedCylinderVolume(value)) return null;
  return normalizeCylinderVolume(value);
}

/// 姓名是否在已知消防员名单内（名单为空时不拦截，避免误清空）。
bool isKnownRosterName(String name, Iterable<String> rosterNames) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  var hasRoster = false;
  for (final candidate in rosterNames) {
    final clean = candidate.trim();
    if (clean.isEmpty) continue;
    hasRoster = true;
    if (clean == trimmed) return true;
  }
  return !hasRoster;
}

/// 轻量气瓶可用时长计算参数（避免 voice 模块依赖 monitor 模型）。
@immutable
class VoiceCalcParams {
  const VoiceCalcParams({
    this.cylinderVolL = kDefaultCylinderVolumeL,
    this.fullPressureMpa = 30.0,
    this.consumptionLpm = 80.0,
    this.warnMin = 10,
    this.alarmMin = 5,
  });

  final double cylinderVolL;
  final double fullPressureMpa;
  final double consumptionLpm;
  final int warnMin;
  final int alarmMin;

  /// 可用时间（分钟）= 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)。
  double durationMinFor(
    double pressureMpa, {
    double? cylinderVolL,
    double? consumptionLpm,
  }) =>
      (cylinderVolL ?? this.cylinderVolL) *
      pressureMpa *
      10 /
      (consumptionLpm ?? this.consumptionLpm);
}

/// 语音进场待确认人员草稿（纯不可变值对象）。
@immutable
class VoiceDraftPerson {
  const VoiceDraftPerson({
    required this.id,
    this.name = '',
    this.sourceName,
    this.pressureText = '',
    this.volumeL = kDefaultCylinderVolumeL,
  });

  /// 稳定草稿标识（用于列表项复用与控制器同步）。
  final String id;

  /// 当前编辑框中的姓名。
  final String name;

  /// 语音识别出的原始姓名（不在名单内时姓名栏留空，保留此值提示用户手动补全）。
  final String? sourceName;

  /// 当前编辑框中的压力文本。
  final String pressureText;

  /// 已选气瓶容积（升），通常为 6.8 或 9.0。
  final double volumeL;

  /// 去除首尾空白后的姓名。
  String get trimmedName => name.trim();

  /// 解析后的气瓶压力（MPa）；为空或无法解析时返回 null。
  double? get pressureMpa => double.tryParse(pressureText.trim());

  /// 压力是否处于有效范围 (0, 40]。
  bool get hasValidPressure {
    final p = pressureMpa;
    return p != null && p > 0 && p <= kMaxValidPressureMpa;
  }

  /// 是否属于「非名单内姓名被自动清空」状态。
  bool get hasUnmatchedSourceName =>
      trimmedName.isEmpty && sourceName != null && sourceName!.trim().isNotEmpty;

  /// 将可空压力值格式化为输入框文本。
  static String formatPressureInput(double? pressureMpa) =>
      pressureMpa == null ? '' : pressureMpa.toString();

  /// 校验单名待确认人员，返回错误文案；`null` 表示校验通过。
  String? validate() {
    final cleanName = trimmedName;
    if (cleanName.isEmpty) return '缺少姓名';
    final p = pressureMpa;
    if (p == null) return '「$cleanName」缺少气瓶压力';
    if (p <= 0 || p > kMaxValidPressureMpa) return '「$cleanName」压力数值异常';
    if (!isAllowedCylinderVolume(volumeL)) {
      return '「$cleanName」气瓶容积只能选择 6.8L 或 9L';
    }
    return null;
  }

  VoiceDraftPerson copyWith({
    String? id,
    String? name,
    String? sourceName,
    bool clearSourceName = false,
    String? pressureText,
    double? volumeL,
  }) {
    return VoiceDraftPerson(
      id: id ?? this.id,
      name: name ?? this.name,
      sourceName: clearSourceName ? null : (sourceName ?? this.sourceName),
      pressureText: pressureText ?? this.pressureText,
      volumeL: volumeL ?? this.volumeL,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VoiceDraftPerson &&
        other.id == id &&
        other.name == name &&
        other.sourceName == sourceName &&
        other.pressureText == pressureText &&
        (other.volumeL - volumeL).abs() < 0.001;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, sourceName, pressureText, volumeL.toStringAsFixed(1));
}

/// 批量校验全部待确认人员，返回带序号的错误列表（空列表表示全部通过）。
List<String> validateVoiceDrafts(List<VoiceDraftPerson> drafts) {
  final problems = <String>[];
  for (var i = 0; i < drafts.length; i++) {
    final problem = drafts[i].validate();
    if (problem != null) {
      problems.add('${i + 1}. $problem');
    }
  }
  return problems;
}
