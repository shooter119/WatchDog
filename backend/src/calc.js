const EVACUATION_RESERVE_PRESSURE_MPA = 5.5;

/**
 * 气瓶空气量换算
 * 物理总可用时间(分钟) = 气瓶容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
 * 例：6.8L 气瓶，20MPa，消耗率 80L/min → 6.8 × 20 × 10 ÷ 80 = 17 分钟
 */
function durationMinutes({ cylinderVolL = 6.8, pressureMpa, consumptionLpm = 80 }) {
  if (!pressureMpa || pressureMpa <= 0) return 0;
  return (cylinderVolL * pressureMpa * 10) / consumptionLpm;
}

/**
 * 内攻工作可用时间(分钟，扣除法定安全撤离余量)
 * 依据 GB/T 16556《正压式消防空气呼吸器》警报器动作压力(5.5±0.5MPa)与 NFPA 1404 安全撤离余量原则
 */
function workDurationMinutes({ cylinderVolL = 6.8, pressureMpa, consumptionLpm = 80, reservePressureMpa = EVACUATION_RESERVE_PRESSURE_MPA }) {
  if (!pressureMpa || pressureMpa <= 0) return 0;
  const effectivePressure = Math.max(0, pressureMpa - reservePressureMpa);
  return (cylinderVolL * effectivePressure * 10) / consumptionLpm;
}

function exitAtMs({ entryAtMs, cylinderVolL, pressureMpa, consumptionLpm }) {
  const mins = durationMinutes({ cylinderVolL, pressureMpa, consumptionLpm });
  return entryAtMs + Math.round(mins * 60 * 1000);
}

/**
 * 实测耗气率（动态耗气率）：
 * 两次报数压力差 × 容量 × 10 ÷ 间隔分钟
 * 例：20→15MPa，5 分钟，6.8L 瓶 → 5 × 6.8 × 10 ÷ 5 = 68 L/min
 * 压力未下降/时间无效 → null（无法估算）
 */
function measuredConsumptionLpm({ cylinderVolL = 6.8, prevPressureMpa, newPressureMpa, intervalMs, min = 5, max = 300 }) {
  if (!prevPressureMpa || !newPressureMpa) return null;
  if (!intervalMs || intervalMs <= 0) return null;
  const pressureDrop = prevPressureMpa - newPressureMpa;
  if (pressureDrop <= 0) return null;
  const intervalMin = intervalMs / 60000;
  const lpm = (pressureDrop * cylinderVolL * 10) / intervalMin;
  if (lpm < min || lpm > max) return null;
  return Math.round(lpm * 10) / 10;
}

module.exports = {
  durationMinutes,
  workDurationMinutes,
  exitAtMs,
  measuredConsumptionLpm,
  EVACUATION_RESERVE_PRESSURE_MPA,
};
