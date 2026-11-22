import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/incident_import_store.dart';

/// 警情导入阶段 3：结构化核对确认与出动力量编辑视图。
class IncidentImportConfirmView extends StatelessWidget {
  const IncidentImportConfirmView({
    super.key,
    required this.store,
    required this.titleController,
    required this.fieldControllers,
    required this.extraControllers,
    required this.contactsController,
    required this.onEditForce,
    required this.onPreviewTaskImage,
    required this.onRequestCancel,
    required this.onApply,
  });

  final IncidentImportStore store;
  final TextEditingController titleController;
  final Map<String, TextEditingController> fieldControllers;
  final Map<String, TextEditingController> extraControllers;
  final TextEditingController contactsController;
  final void Function(int index) onEditForce;
  final void Function(int page) onPreviewTaskImage;
  final VoidCallback onRequestCancel;
  final VoidCallback onApply;

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: SurfaceCard(
        level: DsSurfaceLevel.outlined,
        padding: const EdgeInsets.all(DsSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              title,
              style: ds.typography.title.copyWith(
                fontWeight: FontWeight.w700,
                color: ds.colors.textPrimary,
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(
    BuildContext context, {
    String? labelText,
    String? hintText,
    String? helperText,
  }) {
    final colors = context.ds.colors;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
      filled: true,
      fillColor: colors.surfaceMuted,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: DsRadius.borderMd,
        borderSide: BorderSide(color: colors.brand, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    if (store.pendingApply != null) {
      return SurfaceCard(
        key: const Key('import-pending-apply-card'),
        level: DsSurfaceLevel.outlined,
        padding: const EdgeInsets.all(DsSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            StatusPill(
              status: DsStatus.caution,
              label: '等待确认提交结果',
              icon: DsIcons.warning,
            ),
            const SizedBox(height: DsSpacing.md),
            Text(
              '上次提交结果尚未确认。为避免重复或提交不同内容，先重试原提交，或取消本次导入。',
              style: typo.body.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: DsSpacing.lg),
            CommandButton(
              key: const Key('import-retry-apply-btn'),
              label: '重试原提交（防重复）',
              variant: CommandButtonVariant.primary,
              size: CommandButtonSize.large,
              expanded: true,
              enabled: !store.busy,
              isLoading: store.busy,
              onPressed: onApply,
            ),
            const SizedBox(height: DsSpacing.sm),
            CommandButton(
              label: '取消本次导入',
              variant: CommandButtonVariant.ghost,
              size: CommandButtonSize.standard,
              expanded: true,
              enabled: !store.busy,
              onPressed: onRequestCancel,
            ),
          ],
        ),
      );
    }

    final conflicts = store.conflicts;
    final pages = store.pages;
    final currentData = store.currentDetails['data'] as Map?;
    final origCat = fieldControllers['original_category']?.text ?? '';
    final specType = fieldControllers['specific_type']?.text ?? '';
    final location = fieldControllers['location']?.text ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (conflicts.isNotEmpty) ...<Widget>[
          SurfaceCard(
            key: const Key('import-conflicts-banner'),
            level: DsSurfaceLevel.flat,
            backgroundColor: colors.statusColors(DsStatus.caution).pillBg,
            borderColor: colors.cautionFill.withValues(alpha: 0.4),
            padding: const EdgeInsets.all(DsSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(DsIcons.warning, size: 18, color: colors.cautionText),
                const SizedBox(width: DsSpacing.sm),
                Expanded(
                  child: Text(
                    '识别结果存在差异，请在下方逐项核对并勾选确认',
                    style: typo.caption.copyWith(
                      color: colors.cautionText,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.md),
        ],
        Text(
          '更新目标：${store.currentIncident.displayName}',
          style: typo.caption.copyWith(
            color: colors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: DsSpacing.md),
        if (store.multipleIncidents)
          _section(context, '识别到多起警情，请选择一页继续', <Widget>[
            DropdownButtonFormField<int>(
              key: const Key('import-multi-incident-dropdown'),
              initialValue: store.selectedPage,
              isExpanded: true,
              decoration: _inputDecoration(context, hintText: '请选择要导入的警情页'),
              items: <DropdownMenuItem<int>>[
                for (final p in pages.where((dynamic p) => p['status'] == 'succeeded'))
                  DropdownMenuItem<int>(
                    value: (p['index'] as num).toInt(),
                    child: Text(
                      '第${p['index']}页 · ${p['result']?['suggested_title'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (int? value) {
                if (value != null) store.selectMultiIncidentPage(value);
              },
            ),
          ]),
        _section(context, '建议警情名称', <Widget>[
          TextField(
            key: const Key('import-title-field'),
            controller: titleController,
            maxLength: 80,
            onChanged: store.setTitle,
            style: typo.body.copyWith(color: colors.textPrimary),
            decoration: _inputDecoration(context, hintText: '地点＋事件类型'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '应用此名称',
              style: typo.body.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            subtitle: Text(
              '当前：${store.currentIncident.displayName}',
              style: typo.caption.copyWith(color: colors.textSecondary),
            ),
            value: store.replaceTitle,
            onChanged: (bool? v) => store.setReplaceTitle(v == true),
          ),
        ]),
        _section(context, '警情资料', <Widget>[
          Text(
            '$origCat · $specType',
            style: typo.body.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            location.isEmpty ? '地点待补充' : location,
            style: typo.caption.copyWith(color: colors.textSecondary),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              '核对或修改详细资料',
              style: typo.body.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            children: <Widget>[
              for (final entry in fieldControllers.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                  child: TextField(
                    controller: entry.value,
                    minLines: 1,
                    maxLines: entry.key == 'situation' ? 4 : 2,
                    onChanged: (String v) => store.setFieldValue(entry.key, v),
                    style: typo.body.copyWith(color: colors.textPrimary),
                    decoration: _inputDecoration(
                      context,
                      labelText: incidentImportFieldLabels[entry.key],
                      hintText: entry.key == 'received_at'
                          ? '2026-10-17T18:01:00+08:00'
                          : '未提供，保留原值',
                      helperText: currentData?[entry.key]?.toString().isNotEmpty == true
                          ? '现有：${currentData![entry.key]}'
                          : null,
                    ),
                  ),
                ),
              if (store.draftDetails['specific_type_inferred'] == true)
                Padding(
                  padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                  child: Text(
                    '具体类型由描述推断，请核对。',
                    style: typo.caption.copyWith(color: colors.textSecondary),
                  ),
                ),
            ],
          ),
        ]),
        _section(context, '识别到的出动力量', <Widget>[
          for (var i = 0; i < store.forces.length; i++)
            Padding(
              key: Key('import-force-row-$i'),
              padding: const EdgeInsets.only(bottom: DsSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Checkbox(
                    value: store.forces[i]['selected'] == true,
                    onChanged: (bool? v) =>
                        store.toggleForceSelected(i, v == true),
                  ),
                  Expanded(
                    child: InkWell(
                      borderRadius: DsRadius.borderSm,
                      onTap: () => store.toggleForceSelected(
                        i,
                        store.forces[i]['selected'] != true,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: DsSpacing.xs,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              store.forces[i]['station_name'].toString(),
                              style: typo.body.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${store.forces[i]['vehicle_count'] == null ? '车辆待补充' : '${store.forces[i]['vehicle_count']}车'} · '
                              '${store.forces[i]['personnel_count'] == null ? '人数待补充' : '${store.forces[i]['personnel_count']}人'}\n'
                              '${store.forces[i]['target_force_id'] != null
                                  ? '匹配已登记队伍，将更新所选数量'
                                  : store.forces[i]['matched_name'] != null
                                  ? '匹配：${store.forces[i]['matched_name']}'
                                  : '未匹配，可直接登记新队伍'}',
                              style: typo.captionTabular.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('import-force-edit-$i'),
                    tooltip: '编辑与匹配',
                    constraints: const BoxConstraints(
                      minWidth: DsSizes.touchTarget,
                      minHeight: DsSizes.touchTarget,
                    ),
                    onPressed: () => onEditForce(i),
                    icon: Icon(DsIcons.edit, color: colors.textPrimary),
                  ),
                ],
              ),
            ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            '通报出动／调派不代表到场，不计入个人进场记录。',
            style: typo.caption.copyWith(color: colors.textTertiary),
          ),
        ]),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            '岗位人员、风险与通信装备',
            style: typo.body.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          children: <Widget>[
            TextField(
              controller: contactsController,
              minLines: 2,
              maxLines: 8,
              onChanged: store.setContactsText,
              style: typo.body.copyWith(color: colors.textPrimary),
              decoration: _inputDecoration(
                context,
                labelText: '岗位人员（每行：岗位|姓名|电话）',
              ),
            ),
            for (final entry in extraControllers.entries)
              Padding(
                padding: const EdgeInsets.only(top: DsSpacing.sm),
                child: TextField(
                  controller: entry.value,
                  minLines: 1,
                  maxLines: 6,
                  onChanged: (String v) => store.setExtraValue(entry.key, v),
                  style: typo.body.copyWith(color: colors.textPrimary),
                  decoration: _inputDecoration(
                    context,
                    labelText: incidentImportExtraLabels[entry.key],
                    helperText: '每行一项；将与现有内容合并',
                  ),
                ),
              ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            '原始通报与提取文字',
            style: typo.body.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          children: <Widget>[
            if (store.task?['source'] == 'images')
              Wrap(
                spacing: DsSpacing.sm,
                children: <Widget>[
                  for (final p in pages)
                    CommandButton(
                      label: '第${p['index']}页原图',
                      icon: DsIcons.photoLibrary,
                      variant: CommandButtonVariant.ghost,
                      size: CommandButtonSize.standard,
                      onPressed: () =>
                          onPreviewTaskImage((p['index'] as num).toInt()),
                    ),
                ],
              ),
            for (final p in pages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: DsSpacing.sm),
                child: SelectableText(
                  '第${p['index']}页\n${p['result']?['raw_text'] ?? p['text'] ?? '未识别'}',
                  style: typo.caption.copyWith(color: colors.textSecondary),
                ),
              ),
            CommandButton(
              key: const Key('import-refill-raw-btn'),
              label: '修改提取文字后重新分析',
              variant: CommandButtonVariant.ghost,
              size: CommandButtonSize.standard,
              enabled: !store.busy,
              onPressed: store.refillRawTextAndCancel,
            ),
          ],
        ),
        if (conflicts.isNotEmpty)
          _section(context, '识别存在差异，请核对', <Widget>[
            for (final c in conflicts)
              Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.xs),
                child: Text(
                  '第${c['page']}页 · ${incidentImportFieldLabels[c['field']] ?? c['field']}：${c['value']}',
                  style: typo.body.copyWith(color: colors.textPrimary),
                ),
              ),
            CheckboxListTile(
              key: const Key('import-conflicts-reviewed-checkbox'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                '已核对差异并修正上方资料',
                style: typo.body.copyWith(color: colors.textPrimary),
              ),
              value: store.reviewed,
              onChanged: (bool? v) => store.setReviewed(v == true),
            ),
          ]),
        if (store.task?['status'] == 'partial')
          CheckboxListTile(
            key: const Key('import-accept-incomplete-checkbox'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              '部分图片未识别，确认使用当前不完整资料',
              style: typo.body.copyWith(color: colors.textPrimary),
            ),
            value: store.acceptIncomplete,
            onChanged: (bool? v) => store.setAcceptIncomplete(v == true),
          ),
        if (store.hasFailedPages)
          CommandButton(
            label: '重试失败页',
            variant: CommandButtonVariant.ghost,
            size: CommandButtonSize.standard,
            enabled: !store.busy,
            onPressed: store.retryFailedPages,
          ),
        CommandButton(
          label: '刷新差异（重新载入识别草稿）',
          variant: CommandButtonVariant.ghost,
          size: CommandButtonSize.standard,
          enabled: !store.busy,
          onPressed: store.loadDraft,
        ),
        CommandButton(
          key: const Key('import-cancel-confirm-btn'),
          label: '取消导入',
          variant: CommandButtonVariant.ghost,
          size: CommandButtonSize.standard,
          enabled: !store.busy,
          onPressed: onRequestCancel,
        ),
      ],
    );
  }
}
