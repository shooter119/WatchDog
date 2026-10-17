import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:watchdog/services/incident_import_images.dart';

void main() {
  test('导入图片保留长图文字分辨率，并支持旋转', () {
    final original = img.Image(width: 180, height: 1600);
    final bytes = Uint8List.fromList(img.encodePng(original));
    final prepared = prepareIncidentImage({'bytes': bytes});
    final decoded = img.decodeJpg(prepared)!;
    expect(decoded.width, 180);
    expect(decoded.height, 1600);
    final rotated = img.decodeJpg(
      prepareIncidentImage({'bytes': prepared, 'turns': 1}),
    )!;
    expect(rotated.width, 1600);
    expect(rotated.height, 180);
  });
  test('损坏图片被拒绝而非伪造识别输入', () {
    expect(
      () => prepareIncidentImage({
        'bytes': Uint8List.fromList([1, 2, 3]),
      }),
      throwsFormatException,
    );
  });
}
