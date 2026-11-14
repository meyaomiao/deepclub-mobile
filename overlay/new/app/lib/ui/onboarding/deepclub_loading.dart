import 'dart:async';

import 'package:flutter/material.dart';

import '../features/feature_kit.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Delays visible work by 300 ms, then holds it for at least 500 ms. Timers
/// belong to this presentation only; they never start or retry an operation.
class DeepClubLoading extends StatefulWidget {
  const DeepClubLoading({super.key, required this.active, required this.builder});

  final bool active;
  final Widget Function(BuildContext context, bool visible) builder;

  @override
  State<DeepClubLoading> createState() => _DeepClubLoadingState();
}

class _DeepClubLoadingState extends State<DeepClubLoading> {
  Timer? _delay, _minimum;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(DeepClubLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _update();
  }

  void _update() {
    if (widget.active) {
      if (_visible || _delay != null) return;
      _delay = Timer(const Duration(milliseconds: 300), () {
        _delay = null;
        setState(() => _visible = true);
        _minimum = Timer(const Duration(milliseconds: 500), () {
          _minimum = null;
          if (!widget.active) setState(() => _visible = false);
        });
      });
    } else {
      _delay?.cancel();
      _delay = null;
      if (_minimum == null) _visible = false;
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _minimum?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _visible);
}

/// Keeps the button/row's icon slot stable. Reduced motion uses a static icon
/// with the surrounding operation label, never an indeterminate animation.
class DeepClubBusyIcon extends StatelessWidget {
  const DeepClubBusyIcon({super.key, required this.visible, required this.idle, this.button = false});

  final bool visible;
  final IconData idle;
  final bool button;

  @override
  Widget build(BuildContext context) {
    final size = button ? AppSpace.lg : AppSpace.xl;
    return SizedBox.square(
      dimension: size,
      child: !visible
          ? Icon(idle, size: size)
          : AppMotion.reduced(context)
          ? Icon(AppIcons.loading, size: size, color: DshColors.of(context).textTertiary)
          : FittedBox(child: const QuietSpinner(padding: EdgeInsets.zero)),
    );
  }
}
