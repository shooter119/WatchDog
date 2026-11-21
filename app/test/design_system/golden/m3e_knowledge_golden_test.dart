@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/hazmat/data/models/hazmat.dart';
import 'package:watchdog/features/hazmat/ui/hazmat_tactical_card.dart';
import 'package:watchdog/features/key_sites/data/models/key_sites.dart';
import 'package:watchdog/features/key_sites/ui/key_site_detail_page.dart';

const HazmatItem _goldenHazmatItem = HazmatItem(
  id: 'seed-un1428',
  nameCn: '金属钠',
  nameEn: 'Sodium',
  aliases: <String>['钠', '工业金属钠'],
  unNumber: '1428',
  casNumber: '7440-23-5',
  dangerCategory: '第4.3类 遇湿易燃物品',
  dangerSignColor: 'blue',
  waterReactivity: 'forbidden',
  dangerSummary: '遇水或潮湿空气剧烈反应放出易燃氢气并释放大量热量，极易引发燃爆与强碱灼伤。',
  forbiddenAgents: '严禁用水、泡沫、二氧化碳、卤代烷灭火剂，严禁潮湿砂土覆盖！',
  extinguishingAgents: '干燥石墨粉、干燥氯化钠粉末（D类干粉）、干燥纯碱或干燥细砂覆盖窒息。',
  firefightingTips: '上风向处置，保持现场绝对干燥，先控火势防飞溅，严禁任何水流进入着火区。',
  protectiveLevel: '全套防火隔热服 + 正压式空气呼吸器 + 防碱护目镜与耐碱手套。',
  isolationDistance: '初期隔离 50m；下风向白天疏散 200m，夜间 500m。',
  leakHandling: '切断水源与火源，使用干燥无火花工具收集入盛有煤油或矿物油的密闭铁桶。',
  firstAid: '皮肤接触先用干布拭去残粒，再用大量清水彻底冲洗并立即就医。',
  appearance: '银白色软质金属，断面有金属光泽，常浸存于煤油中。',
  flashPoint: '不适用（遇湿自燃）',
  explosionLimit: '产氢极限 4.0% - 75.6%',
  vaporDensity: '0.07（析出氢气轻于空气）',
  notes: '钠遇水必爆，宁干勿湿，D类干粉压覆盖。',
  source: 'seed',
);

final KeySiteVersion _goldenKeySite = KeySiteVersion(
  siteId: 'site-demo-01',
  version: 2,
  latestVersion: 3,
  publishedAt: DateTime(2026, 6, 1, 9, 30).millisecondsSinceEpoch,
  active: true,
  profile: const <String, dynamic>{
    'name': '示例市精细化工仓储基地',
    'address': '示例省示例市示例区石化大道 108 号',
    'district': '高新示范区',
    'site_type': '甲类化工仓储',
  },
  content: const <String, List<KeySiteEntry>>{
    'cards': <KeySiteEntry>[
      KeySiteEntry(title: '储罐区联锁与关阀要点', body: '北侧紧急切断阀位于 2 号值班室西墙'),
      KeySiteEntry(title: '消防水源与增压泵参数', body: '消防水池总容积 1200m³'),
    ],
    'maps': <KeySiteEntry>[
      KeySiteEntry(title: '厂区总平面与消防车道图'),
      KeySiteEntry(title: '甲类罐区消防栓布置图'),
    ],
    'plans': <KeySiteEntry>[
      KeySiteEntry(title: '甲类储罐流淌火处置预案'),
      KeySiteEntry(title: '危化品装卸区泄漏围堵预案'),
      KeySiteEntry(title: '厂区全员紧急疏散预案'),
    ],
    'organization': <KeySiteEntry>[
      KeySiteEntry(title: '企业应急指挥部与工艺专家名单'),
    ],
    'hazards': <KeySiteEntry>[
      KeySiteEntry(title: '乙醇储罐 T-101'),
      KeySiteEntry(title: '丙酮储罐 T-102'),
      KeySiteEntry(title: '甲苯储罐 T-103'),
      KeySiteEntry(title: '甲类原料仓库'),
    ],
  },
  attachments: const <Map<String, dynamic>>[],
);

Future<void> _pumpGoldenSurface(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required Widget child,
  Size surfaceSize = const Size(390, 844),
}) async {
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(key: captureKey, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3e 危化品战术卡 ($themeTag)', (tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenSurface(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: CommandScaffold(
          appBar: AppBar(title: const Text('危化品应急速查')),
          body: const SingleChildScrollView(
            padding: EdgeInsets.all(DsSpacing.pageMargin),
            child: HazmatTacticalCard(item: _goldenHazmatItem),
          ),
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3e_hazmat_tactical_card_$themeTag.png'),
      );
    });

    testWidgets('M3e 重点单位详情页 ($themeTag)', (tester) async {
      final captureKey = GlobalKey();
      await _pumpGoldenSurface(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        child: CommandScaffold(
          appBar: AppBar(title: const Text('单位资料')),
          body: KeySiteDetailContent(
            site: _goldenKeySite,
            onOpenModule: (_) {},
          ),
        ),
      );

      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3e_key_site_detail_$themeTag.png'),
      );
    });
  }
}
