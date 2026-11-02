import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/widgets/glass.dart';
import '../../usage/usage_repository.dart';
import 'usage_strings.dart';
import 'usage_widgets.dart';

/// Sağ alttaki cam hap: halka gösterge + "Kullanım limitleri".
class UsageButton extends StatefulWidget {
  const UsageButton({super.key, required this.open, required this.onTap});

  static const height = 44.0;

  final bool open;
  final VoidCallback onTap;

  @override
  State<UsageButton> createState() => _UsageButtonState();
}

class _UsageButtonState extends State<UsageButton> with TickerProviderStateMixin {
  final _repo = UsageRepository.instance;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: Motion.expand + Motion.slow,
  );
  late final AnimationController _pulse = AnimationController(vsync: this, duration: Motion.expand);

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onRepo);
    _syncTickers();
  }

  void _onRepo() {
    _syncTickers();
    setState(() {});
  }

  // Ticker yalnız yenilenirken çalışır; boşta kare harcanmaz.
  void _syncTickers() {
    final busy = _repo.refreshing.isNotEmpty;
    if (busy && !_spin.isAnimating) {
      _spin.repeat();
      _pulse.repeat(reverse: true);
    } else if (!busy && _spin.isAnimating) {
      _spin.stop();
      _pulse.reverse();
    }
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepo);
    _spin.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final low = lowestOverall(_repo.reports.values);
    final busy = _repo.refreshing.isNotEmpty;
    final ringColor = AppColors.forRemaining(low);
    return Pressable(
      onTap: widget.onTap,
      label: UsageStrings.title,
      expanded: widget.open,
      builder: (context, hovered, pressed, focused) {
        final lit = hovered || widget.open;
        return AnimatedSlide(
          offset: Offset(0, hovered && !pressed ? -0.05 : 0),
          duration: Motion.fast,
          curve: Motion.emphasized,
          child: AnimatedScale(
            scale: pressed ? 0.96 : 1,
            duration: Motion.fast,
            curve: Motion.emphasized,
            child: AnimatedContainer(
              duration: Motion.medium,
              curve: Motion.emphasized,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(UsageButton.height / 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.bg.withValues(alpha: 0.55),
                    blurRadius: lit ? 22 : 14,
                    offset: Offset(0, lit ? 10 : 6),
                  ),
                  BoxShadow(
                    color: (low == null ? AppColors.accent : ringColor).withValues(
                      alpha: hovered ? 0.42 : 0,
                    ),
                    blurRadius: 28,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: GlassPanel(
                radius: UsageButton.height / 2,
                tint: AppColors.bgElevated.withValues(alpha: lit ? 0.88 : 0.80),
                border: focused
                    ? AppColors.accent
                    : widget.open
                    ? AppColors.accent.withValues(alpha: 0.55)
                    : (hovered ? AppColors.strokeHi : AppColors.stroke),
                child: SizedBox(
                  height: UsageButton.height,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 13, right: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: Listenable.merge([_spin, _pulse]),
                          builder: (context, _) => UsageRing(
                            fraction: low,
                            size: 20,
                            stroke: 2.6,
                            spin: busy ? _spin.value : null,
                            glow: _pulse.value,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          UsageStrings.title,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                            color: lit ? AppColors.text : AppColors.text.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(width: 6),
                        AnimatedRotation(
                          turns: widget.open ? 0.5 : 0,
                          duration: Motion.medium,
                          curve: Motion.emphasized,
                          child: Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 18,
                            color: lit ? AppColors.textDim : AppColors.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
