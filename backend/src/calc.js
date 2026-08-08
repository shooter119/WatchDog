/**
 * 气瓶空气量换算
 * 可用时间(分钟) = 气瓶容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
 * 例：6.8L 气瓶，20MPa，消耗率 80L/min → 6.8 × 20 × 10 ÷ 80 = 17 分钟
 */
function durationMinutes({ cylinderVolL = 6.8, pressureMpa, consumptionLpm = 80 }) {
  if (!pressureMpa || pressureMpa <= 0) return 0;
  return (cylinderVolL * pressureMpa * 10) / consumptionLpm;
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

module.exports = { durationMinutes, exitAtMs, measuredConsumptionLpm };
