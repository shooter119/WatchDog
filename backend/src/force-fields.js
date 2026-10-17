// Shared by PostgreSQL and the legacy SQLite test adapter. Missing flags from
// older clients must not silently turn an unknown placeholder zero into fact.
function forceError(message, code = 'INVALID_FORCE', status = 400) {
  return Object.assign(new Error(message), { code, status });
}

function forceQuantity(value, known, previousValue, previousKnown) {
  if (known !== undefined && typeof known !== 'boolean') {
    throw forceError('数量是否已知必须为布尔值');
  }
  if (known === false) return { value: 0, known: false };
  if (value === undefined) {
    if (known === true && previousKnown === false) throw forceError('请填写已知数量');
    return { value: previousValue ?? 0, known: previousKnown !== false };
  }
  if (value === null || value === '' || typeof value === 'boolean') throw forceError('数量无效，请填写整数或标记待补充');
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0 || number > 999) throw forceError('参战车辆或人员数量须为0至999的整数');
  return { value: number, known: known ?? !(previousKnown === false && number === 0) };
}

function forceFields(args, current) {
  const vehicle = forceQuantity(args.vehicleCount, args.vehicleCountKnown, current?.vehicle_count, current?.vehicle_count_known !== false && current?.vehicle_count_known !== 0);
  const personnel = forceQuantity(args.personnelCount, args.personnelCountKnown, current?.personnel_count, current?.personnel_count_known !== false && current?.personnel_count_known !== 0);
  return { vehicle_count: vehicle.value, vehicle_count_known: vehicle.known, personnel_count: personnel.value, personnel_count_known: personnel.known };
}

function forceQuantityLabel(payload) {
  const vehicles = payload.vehicle_count_known === false || payload.vehicle_count_known === 0 ? '车辆待补充' : `${payload.vehicle_count ?? 0}车`;
  const people = payload.personnel_count_known === false || payload.personnel_count_known === 0 ? '人数待补充' : `${payload.personnel_count ?? 0}人`;
  return `${vehicles} ${people}`;
}

module.exports = { forceError, forceFields, forceQuantity, forceQuantityLabel };
