import 'dart:math';

/// 场景码（任务码）规范：两字常见水果名，便于对讲机口述与记忆。
///
/// 词表必须与后端 `backend/src/db.js` 的 `FRUIT_NAMES` 保持一致，
/// 否则 App 端核验与服务器分配的新码会出现不一致。
const kFruitSceneNames = <String>[
  '苹果', '香蕉', '葡萄', '橙子', '草莓', '西瓜', '桃子', '梨子', '樱桃', '芒果',
  '柚子', '柠檬', '菠萝', '椰子', '石榴', '柿子', '李子', '杏子', '蓝莓', '山竹',
  '荔枝', '杨梅', '枇杷', '甘蔗', '山楂', '橄榄', '榴莲', '枣子', '蜜桃', '蜜橘',
];

/// 历史默认场景码（旧版本默认场景，核验时兼容放行，避免老设备被锁死）
const kLegacyDefaultScene = 'default';

/// 场景码格式核验：合法 = 水果词表内（trim 后）或历史 default。
/// 乱码/任意输入一律拒绝，防止切换后设备失联。
bool isValidSceneCode(String input) {
  final code = input.trim();
  if (code.isEmpty) return false;
  return code == kLegacyDefaultScene || kFruitSceneNames.contains(code);
}

final Random _random = Random();

/// 生成一个随机水果场景码（首装默认场景码，与服务器分配的新码同一词表）
String generateSceneCode() {
  return kFruitSceneNames[_random.nextInt(kFruitSceneNames.length)];
}
