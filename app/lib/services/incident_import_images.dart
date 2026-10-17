import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Runs in an isolate. Inspect dimensions before allocating decoded pixels;
/// preserve long screenshot resolution instead of blindly shrinking its width.
Uint8List prepareIncidentImage(Map<String, dynamic> input) {
  try { return _prepareIncidentImage(input); }
  on FormatException { rethrow; }
  catch (_) { throw const FormatException('图片损坏或格式不支持，请重新选择'); }
}

Uint8List _prepareIncidentImage(Map<String, dynamic> input) {
  final bytes = input['bytes'] as Uint8List;
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null) throw const FormatException('无法读取图片，请转为JPEG或PNG后重试');
  if (info.width * info.height > 40000000 ||
      info.width > 30000 ||
      info.height > 30000) {
    throw const FormatException('图片像素过大，请裁切或分段后导入');
  }
  var image = decoder!.decodeFrame(0);
  if (image == null) throw const FormatException('图片损坏，请重新选择');
  image = img.bakeOrientation(image);
  final turns = input['turns'] as int? ?? 0;
  if (turns % 4 != 0) image = img.copyRotate(image, angle: 90 * (turns % 4));
  image.exif = img.ExifData();
  image.iccProfile = null;
  // Landscape photos can be reduced; narrow long screenshots retain their text.
  if (image.width > 3000 && image.height / image.width < 3) {
    image = img.copyResize(image, width: 3000);
  }
  for (final quality in [92, 85, 78]) {
    final result = Uint8List.fromList(img.encodeJpg(image, quality: quality));
    if (result.length <= 5 * 1024 * 1024) return result;
  }
  throw const FormatException('图片内容过长，请裁切或分段，避免文字压缩不清');
}
