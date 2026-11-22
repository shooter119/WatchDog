import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';

/// 一键定位反地理编码结果。
@immutable
class IncidentLocatedAddress {
  const IncidentLocatedAddress({
    this.address = '',
    this.latitude,
    this.longitude,
    this.errorMessage,
  });

  final String address;
  final double? latitude;
  final double? longitude;
  final String? errorMessage;

  bool get hasAddress => address.trim().isNotEmpty;
  bool get hasCoordinates => latitude != null && longitude != null;
}

/// 由外壳层注入的「定位当前位置并解析街道地址」回调，保持 Feature 间零交叉耦合。
typedef IncidentAddressLocator = Future<IncidentLocatedAddress> Function();

/// 可复用的「事发地点输入 + 定位当前位置自动填入」字段区块。
class IncidentAddressFieldSection extends StatefulWidget {
  const IncidentAddressFieldSection({
    super.key,
    required this.controller,
    this.fieldKey,
    this.labelText = '事发地点',
    this.hintText = '如：示例大道88号工业园',
    this.helperLabel,
    this.onLocateAddress,
    this.onCoordinatesChanged,
    this.maxLength = 500,
    this.minLines = 1,
    this.maxLines = 3,
  });

  final TextEditingController controller;
  final Key? fieldKey;
  final String labelText;
  final String hintText;
  final String? helperLabel;
  final IncidentAddressLocator? onLocateAddress;
  final void Function(double? latitude, double? longitude)?
      onCoordinatesChanged;
  final int maxLength;
  final int minLines;
  final int maxLines;

  @override
  State<IncidentAddressFieldSection> createState() =>
      _IncidentAddressFieldSectionState();
}

class _IncidentAddressFieldSectionState
    extends State<IncidentAddressFieldSection> {
  bool _locating = false;
  bool _hasLocatedCoords = false;
  String? _statusText;
  bool _isError = false;

  Future<void> _handleLocate() async {
    final locator = widget.onLocateAddress;
    if (locator == null || _locating) return;
    setState(() {
      _locating = true;
      _statusText = null;
      _isError = false;
    });
    try {
      final res = await locator();
      if (!mounted) return;
      final addr = res.address.trim();
      if (addr.isNotEmpty) {
        widget.controller.value = TextEditingValue(
          text: addr,
          selection: TextSelection.collapsed(offset: addr.length),
        );
      }
      if (res.hasCoordinates) {
        _hasLocatedCoords = true;
        widget.onCoordinatesChanged?.call(res.latitude, res.longitude);
      }
      final err = res.errorMessage?.trim();
      setState(() {
        if (err != null && err.isNotEmpty) {
          _statusText = err;
          _isError = true;
        } else if (res.hasCoordinates) {
          _statusText = '已填入当前位置坐标，保存后同步地图与周边水源';
          _isError = false;
        } else if (addr.isNotEmpty) {
          _statusText = '已填入当前位置';
          _isError = false;
        } else {
          _statusText = '暂未获取到街道名称，请手动输入';
          _isError = true;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusText = '定位失败：$error';
        _isError = true;
      });
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (BuildContext context, TextEditingValue value, _) {
            return TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              maxLength: widget.maxLength,
              onChanged: (String text) {
                if (text.trim().isEmpty && _hasLocatedCoords) {
                  setState(() {
                    _hasLocatedCoords = false;
                    _statusText = null;
                    _isError = false;
                  });
                  widget.onCoordinatesChanged?.call(null, null);
                }
              },
              style: typo.body.copyWith(color: colors.textPrimary),
              cursorColor: colors.brand,
              decoration: InputDecoration(
                labelText: widget.labelText,
                hintText: widget.hintText,
                hintStyle: typo.body.copyWith(color: colors.textTertiary),
                helperText: widget.helperLabel,
                helperMaxLines: 2,
                filled: true,
                fillColor: colors.surfaceMuted,
                border: border,
                enabledBorder: border,
                focusedBorder: OutlineInputBorder(
                  borderRadius: DsRadius.borderMd,
                  borderSide: BorderSide(color: colors.brand, width: 1.5),
                ),
                suffixIcon: value.text.isNotEmpty
                    ? IconButton(
                        tooltip: '清除地点',
                        icon: Icon(
                          DsIcons.closeCircle,
                          size: 18,
                          color: colors.textTertiary,
                        ),
                        onPressed: () {
                          widget.controller.clear();
                          if (_hasLocatedCoords || _statusText != null) {
                            setState(() {
                              _hasLocatedCoords = false;
                              _statusText = null;
                              _isError = false;
                            });
                            widget.onCoordinatesChanged?.call(null, null);
                          }
                        },
                      )
                    : null,
              ),
            );
          },
        ),
        if (widget.onLocateAddress != null) ...<Widget>[
          const SizedBox(height: DsSpacing.xs),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              CommandButton(
                key: const Key('incident-locate-btn'),
                label: _locating ? '正在定位…' : '定位当前位置',
                icon: DsIcons.myLocation,
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.standard,
                isLoading: _locating,
                onPressed: _handleLocate,
              ),
              if (_statusText != null)
                Text(
                  _statusText!,
                  key: const Key('incident-locate-status'),
                  style: typo.caption.copyWith(
                    color: _isError ? colors.alarmText : colors.brandText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
