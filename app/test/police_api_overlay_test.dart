import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';

void main() {
  group('接警描述清洗', () {
    test('ExternalIncident.effectiveEventTitle 清洗长段接警通报与超长截断且保留常规短描述', () {
      const longDispatch = ExternalIncident(
        externalId: 'ext-clean-1',
        incidentNumber: '20261114101',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        crimeAddress: '示例省示例市示例县和平街9号',
        locationDisplay: '示例县和平街9号',
        incidentDescribe:
            '2026年11月13日22时45分，示例大队指挥中心接到群众报警称：位于示例省示例市示例县和平街9号发生两车追尾，驾驶员被困，无其他人员伤亡。接到报警后，示例路站出动2车（水罐车、抢险救援车）14人前往处置，官方状态: 出动',
        registerTime: 1786177140000,
      );
      expect(longDispatch.effectiveEventTitle, '发生两车追尾，驾驶员被困');

      const multiRoundAndTruncate = ExternalIncident(
        externalId: 'ext-clean-2',
        incidentNumber: '20261114102',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '抢险救援',
        crimeAddress: '示例县建设大道66号',
        incidentDescribe:
            '19:15许，示例支队指挥中心接110转警称，2026年11月13日19时15分，位于上述地址：一大型冷链物流货车在高速匝道发生侧翻并伴随燃油泄漏，示例路站出动1车7人赶赴现场。',
        registerTime: 1786177140000,
      );
      final title2 = multiRoundAndTruncate.effectiveEventTitle;
      expect(title2.length, 24);
      expect(title2, '一大型冷链物流货车在高速匝道发生侧翻并伴随燃油…');

      const shortNormal = ExternalIncident(
        externalId: 'ext-clean-3',
        incidentNumber: '20261114103',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '火灾扑救',
        crimeAddress: '示例县幸福小区1栋',
        incidentDescribe: '民房厨房油锅起火',
        registerTime: 1786177140000,
      );
      expect(shortNormal.effectiveEventTitle, '民房厨房油锅起火');

      const boilerplateOnly = ExternalIncident(
        externalId: 'ext-clean-4',
        incidentNumber: '20261114104',
        detachmentName: '示例支队',
        brigadeName: '示例大队',
        squadronName: '示例路站',
        districtName: '示例县',
        incidentType: '社会救助',
        disposalObjectName: '马蜂窝',
        crimeAddress: '示例县滨河路12号',
        incidentDescribe: '00时26分，示例大队接警称：暂无人员被困，官方状态: 出动',
        registerTime: 1786177140000,
      );
      expect(boilerplateOnly.effectiveEventTitle, '社会救助（马蜂窝）');
    });
  });
}
