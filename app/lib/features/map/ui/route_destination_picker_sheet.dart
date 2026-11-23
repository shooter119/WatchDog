import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/route_models.dart';

/// 弹出多处同名地点候选确认弹窗（Design System v3.0 `CommandSheet`）。
Future<RouteDestinationCandidate?> showRouteDestinationPickerSheet(
  BuildContext context, {
  required List<RouteDestinationCandidate> candidates,
  required RouteDestinationCandidate? selectedCandidate,
  String title = '发现多处同名地点，请确认目的地',
  String itemKeyPrefix = 'route-candidate-item',
}) {
  return showCommandSheet<RouteDestinationCandidate>(
    context: context,
    title: title,
    builder: (sheetContext) {
      final ds = sheetContext.ds;
      final colors = ds.colors;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < candidates.length; index++) ...[
            if (index > 0) const SizedBox(height: DsSpacing.sm),
            _CandidateTile(
              key: Key('$itemKeyPrefix-$index'),
              candidate: candidates[index],
              isSelected:
                  selectedCandidate?.formattedAddress ==
                      candidates[index].formattedAddress ||
                  (selectedCandidate == null && index == 0),
              onTap: () => Navigator.of(sheetContext).pop(candidates[index]),
            ),
          ],
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: DsSpacing.lg),
              child: Text(
                '暂无可选地点',
                textAlign: TextAlign.center,
                style: ds.typography.body.copyWith(color: colors.textSecondary),
              ),
            ),
        ],
      );
    },
  );
}

class _CandidateTile extends StatelessWidget {
  final RouteDestinationCandidate candidate;
  final bool isSelected;
  final VoidCallback onTap;

  const _CandidateTile({
    super.key,
    required this.candidate,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      borderColor: isSelected ? colors.brand : colors.border,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DsSizes.touchTarget - 16),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? DsIcons.checkCircleFill
                  : DsIcons.radioUnchecked,
              color: isSelected ? colors.brand : colors.textSecondary,
              size: DsSizes.iconMd,
            ),
            const SizedBox(width: DsSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.name,
                    style: ds.typography.body.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    candidate.displayAddress,
                    style: ds.typography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (candidate.district.isNotEmpty) ...[
              const SizedBox(width: DsSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.sm,
                  vertical: DsSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: DsRadius.borderSm,
                ),
                child: Text(
                  candidate.district,
                  style: ds.typography.micro.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
