import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/water_sources_store.dart';

/// 弹出水源新增/编辑表单底栏（Design System v3.0 `CommandSheet`）。
Future<void> showWaterSourceEditorSheet(
  BuildContext context, {
  required WaterSourcesStore store,
  required void Function(String message) onToast,
  WaterSource? existing,
  double? initialLat,
  double? initialLng,
  bool allowManualCoords = false,
}) async {
  final isEdit = existing != null;
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final noteCtrl = TextEditingController(text: existing?.note ?? '');
  final latCtrl = TextEditingController(
    text: (initialLat ?? existing?.lat)?.toStringAsFixed(6) ?? '',
  );
  final lngCtrl = TextEditingController(
    text: (initialLng ?? existing?.lng)?.toStringAsFixed(6) ?? '',
  );

  var category = existing?.category ?? WaterSourceCategory.hydrant;
  var status = existing?.status ?? WaterSourceStatus.available;
  final selectedMethods = <WaterIntakeMethod>{
    ...(existing?.intakeMethods ?? const []),
  };
  String? inlineError;
  var saving = false;

  try {
    await showCommandSheet<void>(
      context: context,
      title: isEdit ? '编辑水源点位' : '新增水源点位',
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final ds = ctx.ds;
            final colors = ds.colors;
            final alarmPair = colors.statusColors(DsStatus.alarm);

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('water-form-name'),
                  controller: nameCtrl,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: '点位简称 *',
                    hintText: '例如：示范路北口消火栓、示例水厂消防水池',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (inlineError != null) {
                      setSheetState(() => inlineError = null);
                    }
                  },
                ),
                const SizedBox(height: DsSpacing.sm),
                _SectionLabel('水源类别'),
                const SizedBox(height: DsSpacing.xs),
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.xs,
                  children: [
                    for (final c in WaterSourceCategory.values)
                      ChoiceChip(
                        key: Key('water-form-cat-${c.apiValue}'),
                        label: Text(c.label),
                        selected: category == c,
                        onSelected: (_) {
                          setSheetState(() {
                            category = c;
                            inlineError = null;
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: DsSpacing.md),
                _SectionLabel('可用状态'),
                const SizedBox(height: DsSpacing.xs),
                Wrap(
                  spacing: DsSpacing.sm,
                  children: [
                    for (final s in WaterSourceStatus.values)
                      ChoiceChip(
                        key: Key('water-form-status-${s.apiValue}'),
                        label: Text(s.label),
                        selected: status == s,
                        onSelected: (_) {
                          setSheetState(() => status = s);
                        },
                      ),
                  ],
                ),
                if (category == WaterSourceCategory.natural) ...[
                  const SizedBox(height: DsSpacing.md),
                  _SectionLabel('取水方式（至少选 1 项）'),
                  const SizedBox(height: DsSpacing.xs),
                  Wrap(
                    spacing: DsSpacing.sm,
                    runSpacing: DsSpacing.xs,
                    children: [
                      for (final m in WaterIntakeMethod.values)
                        FilterChip(
                          key: Key('water-form-intake-${m.apiValue}'),
                          label: Text(m.label),
                          selected: selectedMethods.contains(m),
                          onSelected: (checked) {
                            setSheetState(() {
                              if (checked) {
                                selectedMethods.add(m);
                              } else {
                                selectedMethods.remove(m);
                              }
                              inlineError = null;
                            });
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: DsSpacing.md),
                TextField(
                  key: const Key('water-form-note'),
                  controller: noteCtrl,
                  maxLines: 3,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: '备注（选填）',
                    hintText: '可填写缺闷盖、水压偏低、水池容量、对应楼栋等',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: DsSpacing.sm),
                if (allowManualCoords)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('water-form-lat'),
                          controller: latCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '纬度 (GCJ-02)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: DsSpacing.sm),
                      Expanded(
                        child: TextField(
                          key: const Key('water-form-lng'),
                          controller: lngCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '经度 (GCJ-02)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    '选定坐标 (GCJ-02)：${latCtrl.text}, ${lngCtrl.text}',
                    style: ds.typography.captionTabular.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                if (inlineError != null) ...[
                  const SizedBox(height: DsSpacing.sm),
                  SurfaceCard(
                    accentStatus: DsStatus.alarm,
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.md,
                      vertical: DsSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          DsIcons.warning,
                          size: DsSizes.iconMd,
                          color: alarmPair.text,
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Expanded(
                          child: Text(
                            inlineError!,
                            style: ds.typography.caption.copyWith(
                              color: alarmPair.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: DsSpacing.lg),
                CommandButton(
                  key: const Key('water-form-submit'),
                  label: saving ? '保存中...' : (isEdit ? '保存修改' : '保存点位'),
                  size: CommandButtonSize.large,
                  expanded: true,
                  isLoading: saving,
                  enabled: !saving,
                  onPressed: () async {
                    final trimmedName = nameCtrl.text.trim();
                    if (trimmedName.isEmpty) {
                      setSheetState(() => inlineError = '请填写点位简称');
                      return;
                    }
                    if (category == WaterSourceCategory.natural &&
                        selectedMethods.isEmpty) {
                      setSheetState(() => inlineError = '天然水源至少选择一项取水方式');
                      return;
                    }
                    final lat = double.tryParse(latCtrl.text.trim());
                    final lng = double.tryParse(lngCtrl.text.trim());
                    if (lat == null ||
                        lng == null ||
                        lat < 3 ||
                        lat > 55 ||
                        lng < 73 ||
                        lng > 136) {
                      setSheetState(
                        () => inlineError = '坐标无效，请先在地图选点或填写有效经纬度',
                      );
                      return;
                    }

                    final normalizedMethods =
                        category == WaterSourceCategory.natural
                        ? WaterIntakeMethod.values
                              .where(selectedMethods.contains)
                              .toList(growable: false)
                        : const <WaterIntakeMethod>[];

                    setSheetState(() {
                      saving = true;
                      inlineError = null;
                    });

                    try {
                      final saved = isEdit
                          ? await store.updateWaterSource(
                              existing.id,
                              category: category,
                              name: trimmedName,
                              lat: lat,
                              lng: lng,
                              status: status,
                              intakeMethods: normalizedMethods,
                              note: noteCtrl.text.trim(),
                            )
                          : await store.createWaterSource(
                              category: category,
                              name: trimmedName,
                              lat: lat,
                              lng: lng,
                              status: status,
                              intakeMethods: normalizedMethods,
                              note: noteCtrl.text.trim(),
                            );
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      onToast(
                        isEdit ? '已更新「${saved.name}」' : '已新增「${saved.name}」',
                      );
                    } catch (e) {
                      if (!ctx.mounted) return;
                      setSheetState(() {
                        saving = false;
                        inlineError = store.friendlyError(e);
                      });
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameCtrl.dispose();
      noteCtrl.dispose();
      latCtrl.dispose();
      lngCtrl.dispose();
    });
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Text(
      text,
      style: ds.typography.caption.copyWith(
        color: ds.colors.textSecondary,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
