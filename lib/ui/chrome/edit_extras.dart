import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../data/profile_store.dart';
import '../../data/reset.dart';
import '../../l10n/l10n.dart';

String greetingHello() {
  final h = DateTime.now().hour;
  return t(
    h >= 5 && h < 12
        ? 'core.greet.morning'
        : h >= 12 && h < 18
        ? 'core.greet.afternoon'
        : h >= 18 && h < 23
        ? 'core.greet.evening'
        : 'core.greet.night',
  );
}

/// Karşılama satırı: "Good morning, NAME. Which one…". Düzenleme kipinde ad sallanır ve dokununca yazılır.
class GreetingLine extends StatelessWidget {
  const GreetingLine({super.key, required this.editing});

  final ValueListenable<bool> editing;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([ProfileStore.instance, L10n.instance, editing]),
    builder: (context, _) {
      const style = TextStyle(fontSize: 14, color: AppColors.textDim);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${greetingHello()}, ', maxLines: 1, style: style),
          NameChip(editing: editing.value),
          Flexible(
            child: Text('. ${t('core.greet.question')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
        ],
      );
    },
  );
}

class NameChip extends StatefulWidget {
  const NameChip({super.key, required this.editing});

  final bool editing;

  @override
  State<NameChip> createState() => _NameChipState();
}

class _NameChipState extends State<NameChip> with SingleTickerProviderStateMixin {
  late final AnimationController _wiggle = AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
  final _focus = FocusNode();
  final _text = TextEditingController();
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _typing) _commit();
    });
    _sync();
  }

  @override
  void didUpdateWidget(NameChip old) {
    super.didUpdateWidget(old);
    if (!widget.editing && _typing) _commit();
    _sync();
  }

  // Ticker yalnız düzenleme kipinde ve yazmıyorken çalışır.
  void _sync() {
    final dance = widget.editing && !_typing;
    if (dance && !_wiggle.isAnimating) {
      _wiggle.repeat();
    } else if (!dance && _wiggle.isAnimating) {
      _wiggle.stop();
      _wiggle.value = 0;
    }
  }

  void _start() {
    _text.text = ProfileStore.instance.name;
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    setState(() => _typing = true);
    _sync();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _commit() {
    if (!_typing) return;
    ProfileStore.instance.setName(_text.text);
    setState(() => _typing = false);
    _sync();
  }

  @override
  void dispose() {
    _wiggle.dispose();
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = ProfileStore.instance.name;
    final empty = name.isEmpty;
    final label = empty ? t('core.your_name') : name;
    final color = widget.editing ? AppColors.text : (empty ? AppColors.textFaint : AppColors.textDim);
    final textStyle = TextStyle(
      fontSize: 14,
      fontWeight: widget.editing ? FontWeight.w700 : FontWeight.w400,
      fontStyle: empty ? FontStyle.italic : FontStyle.normal,
      color: color,
    );
    Widget child;
    if (_typing) {
      child = SizedBox(
        width: math.max(110.0, 14.0 * (_text.text.length + 2)),
        child: TextField(
          controller: _text,
          focusNode: _focus,
          maxLength: 24,
          maxLines: 1,
          cursorColor: AppColors.text,
          style: textStyle.copyWith(fontStyle: FontStyle.normal),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _commit(),
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: t('core.your_name'),
            hintStyle: textStyle.copyWith(color: AppColors.textFaint),
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.strokeHi)),
            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.text)),
          ),
        ),
      );
    } else {
      child = AnimatedContainer(
        duration: Motion.fast,
        padding: EdgeInsets.symmetric(horizontal: widget.editing ? 9 : 0, vertical: 2),
        decoration: BoxDecoration(
          color: widget.editing ? AppColors.surfaceHi : const Color(0x00000000),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: widget.editing ? AppColors.strokeHi : const Color(0x00000000)),
        ),
        child: Text(label, maxLines: 1, style: textStyle),
      );
      if (widget.editing) {
        child = Tooltip(
          message: t('core.name_tip'),
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _start, child: child),
          ),
        );
      }
    }
    return AnimatedBuilder(
      animation: _wiggle,
      child: child,
      builder: (context, child) => Transform.rotate(
        angle: math.sin(_wiggle.value * 2 * math.pi) * 0.035,
        child: child,
      ),
    );
  }
}

/// Düzenleme kipinde üst çubukta açılan dil ve sıfırla düğmeleri (kayarak gelir).
class EditExtras extends StatelessWidget {
  const EditExtras({super.key, required this.editing, required this.language, required this.reset});

  final bool editing;
  final Widget language;
  final Widget reset;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: editing ? 1 : 0),
    duration: Motion.medium,
    curve: Motion.emphasized,
    builder: (context, v, child) => v <= 0.001
        ? const SizedBox.shrink()
        : ClipRect(
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: v,
              child: Opacity(
                opacity: v.clamp(0.0, 1.0),
                child: Transform.translate(offset: Offset((1 - v) * 24, 0), child: child),
              ),
            ),
          ),
    child: IgnorePointer(
      ignoring: !editing,
      child: Row(mainAxisSize: MainAxisSize.min, children: [language, const SizedBox(width: 10), reset, const SizedBox(width: 10)]),
    ),
  );
}

/// Kırmızı, tehlikeli eylem düğmesi.
class DangerButton extends StatefulWidget {
  const DangerButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<DangerButton> createState() => _DangerButtonState();
}

class _DangerButtonState extends State<DangerButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        transform: Matrix4.translationValues(0, _hover ? -1.5 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          color: AppColors.bad.withValues(alpha: _hover ? 0.32 : 0.18),
          border: Border.all(color: AppColors.bad.withValues(alpha: _hover ? 0.9 : 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 16, color: AppColors.bad),
            const SizedBox(width: 6),
            Text(widget.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.bad)),
          ],
        ),
      ),
    ),
  );
}

Future<void> showLanguageDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: L10n.instance,
    builder: (context, _) => Dialog(
      backgroundColor: AppColors.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.stroke),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Text(
                  t('core.language.title'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text),
                ),
              ),
              for (final l in L10n.languages)
                _LanguageRow(
                  name: l.name,
                  selected: l.code == L10n.instance.code,
                  onTap: () {
                    L10n.instance.setLanguage(l.code);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);

class _LanguageRow extends StatefulWidget {
  const _LanguageRow({required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LanguageRow> createState() => _LanguageRowState();
}

class _LanguageRowState extends State<_LanguageRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: widget.selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : (_hover ? AppColors.surfaceHi : const Color(0x00000000)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.name,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
                  color: AppColors.text,
                ),
              ),
            ),
            if (widget.selected) const Icon(Icons.check_rounded, size: 18, color: AppColors.text),
          ],
        ),
      ),
    ),
  );
}

Future<void> showResetDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: AppColors.bgElevated,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: AppColors.bad.withValues(alpha: 0.4)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: AppColors.bad, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t('core.reset.title'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(t('core.reset.body'), style: const TextStyle(fontSize: 13, height: 1.45, color: AppColors.textDim)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t('core.cancel'), style: const TextStyle(color: AppColors.textDim)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.bad, foregroundColor: AppColors.bg),
                  onPressed: () {
                    Navigator.of(context).pop();
                    wipeAllDataAndQuit();
                  },
                  child: Text(t('core.reset.confirm'), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ),
);
