/**
 * 气瓶空气量换算
 * 可用时间(分钟) = 气瓶容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
 * 例：6.8L 气瓶，20MPa，消耗率 40L/min → 6.8 × 20 × 10 ÷ 40 = 34 分钟
 */
function durationMinutes({ cylinderVolL = 6.8, pressureMpa, consumptionLpm = 40 }) {
  if (!pressureMpa || pressureMpa <= 0) return 0;
  return (cylinderVolL * pressureMpa * 10) / consumptionLpm;
}

function exitAtMs({ entryAtMs, cylinderVolL, pressureMpa, consumptionLpm }) {
  const mins = durationMinutes({ cylinderVolL, pressureMpa, consumptionLpm });
  return entryAtMs + Math.round(mins * 60 * 1000);
}

module.exports = { durationMinutes, exitAtMs };
