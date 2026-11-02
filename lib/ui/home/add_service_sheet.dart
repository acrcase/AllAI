import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/widgets/glass.dart';
import '../../data/installed_apps.dart';
import '../../data/services_store.dart';
import '../../data/site_icon.dart';
import '../../models/ai_service.dart';
import '../../platform/app_dock.dart';
import '../common/service_icon.dart';
import 'add_app_pane.dart';
import '../../l10n/l10n.dart';

/// "Başka hesapla ekle" bu kartta sunulur mu: macOS'ta, ayrı veri klasörüyle ikinci örnek
/// açılabilen (Electron) uygulama.
Future<bool> canAddAccount(AiService s) async =>
    Platform.isMacOS &&
    s.canApp &&
    await AppDock.instance.supportsProfiles(s.macBundleId!);

/// Başka hesap kartı kaldırılmadan önce sorar. Onaylanırsa o hesabın örneği kapanır, oturumu ve
/// veri klasörü silinir; true döner, kartı kaldırmak çağırana kalır. Öteki kartlarda hemen true.
Future<bool> confirmDeleteAccount(BuildContext context, AiService s) async {
  if (!s.separateProfile) return true;
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black45,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.stroke),
      ),
      title: Text(
        t('home.remove_title', {'name': s.name, 'sub': s.displaySubtitle}),
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      content: Text(
        t('home.remove_body'),
        style: const TextStyle(fontSize: 13.5, color: AppColors.textDim),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: AppColors.textDim),
          child: Text(t('home.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.bad,
            foregroundColor: AppColors.bg,
          ),
          child: Text(t('home.remove_btn')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  AppDock.instance.deleteProfile(s.id);
  return true;
}

/// "+ Ekle": hazır kartlar, özel bağlantı ve (macOS/Windows'ta) kurulu uygulama.
/// [apps] yalnız testte değiştirilir.
Future<void> showAddServiceSheet(
  BuildContext context, {
  @visibleForTesting InstalledApps? apps,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: t('home.close'),
    barrierColor: Colors.black45,
    transitionDuration: Motion.slow,
    pageBuilder: (context, a, b) => _AddSheet(apps ?? InstalledApps.instance),
    transitionBuilder: (context, a, b, child) {
      final v = Motion.springOut.transform(a.value);
      return Opacity(
        opacity: a.value.clamp(0, 1),
        child: Transform.scale(scale: 0.9 + 0.1 * v, child: child),
      );
    },
  );
}

class _AddSheet extends StatefulWidget {
  const _AddSheet(this.apps);

  final InstalledApps apps;

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  String? _error;

  /// 0: kartlar ve özel bağlantı, 1: kurulu uygulamalar (yalnız destekleyen platformda).
  int _tab = 0;

  // Ana ekrandaki uygulamalardan başka hesapla eklenebilenler.
  late final Future<List<AiService>> _accounts = () async {
    final list = <AiService>[];
    for (final s in ServicesStore.instance.services) {
      if (!s.separateProfile && await canAddAccount(s)) list.add(s);
    }
    return list;
  }();

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  bool _busy = false;

  Future<void> _addCustom() async {
    if (_busy) return;
    var url = _url.text.trim();
    final name = _name.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = t('home.err_required'));
      return;
    }
    if (!url.startsWith('http')) url = 'https://$url';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      setState(() => _error = t('home.err_url'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Simge ve marka rengi sitenin kendisinden gelir; bulunamazsa addan türetilen renk.
    final found = await SiteIcon.fetch(uri);
    if (!mounted) return;
    final hue = (name.hashCode % 360).toDouble();
    ServicesStore.instance.add(
      AiService(
        id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        subtitle: uri.host,
        icon: found?.path,
        color: found?.color ?? HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor(),
        accent:
            found?.accent ??
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.8, 0.72).toColor(),
        webUrl: url,
        usageKey: 'custom-${uri.host}',
        custom: true,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final presets = ServicesStore.instance.addable;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 690),
        child: Material(
          type: MaterialType.transparency,
          child: GlassPanel(
            radius: 24,
            tint: const Color(0xCC10121A),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t('home.add_title'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.textDim,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (widget.apps.supported) ...[
                  _Tabs(tab: _tab, onChanged: (i) => setState(() => _tab = i)),
                  const SizedBox(height: 14),
                ],
                if (_tab == 1 && widget.apps.supported)
                  Flexible(child: AddAppPane(apps: widget.apps))
                else ...[
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (presets.isEmpty)
                            Text(
                              t('home.presets_empty'),
                              style: const TextStyle(color: AppColors.textDim),
                            )
                          else
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final p in presets)
                                  _PresetChip(service: p),
                              ],
                            ),
                          FutureBuilder<List<AiService>>(
                            future: _accounts,
                            builder: (context, snap) {
                              final list = snap.data ?? const <AiService>[];
                              if (list.isEmpty) return const SizedBox.shrink();
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 22),
                                  Text(
                                    t('home.account_add'),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    t('home.account_note'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textDim,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      for (final s in list)
                                        _PresetChip(
                                          key: ValueKey('account-${s.id}'),
                                          service: s,
                                          subtitle: t('home.account_sub'),
                                          icon: Icons.person_add_alt_1_rounded,
                                          onAdd: () => ServicesStore.instance
                                              .addAccount(s),
                                        ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    t('home.custom_title'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: _Field(
                          controller: _name,
                          hint: t('home.field_name'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 4,
                        child: _Field(
                          controller: _url,
                          hint: 'https://…',
                          onSubmit: _addCustom,
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _busy ? null : _addCustom,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                        ),
                        child: Text(
                          _busy ? t('home.fetching_icon') : t('home.add'),
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: AppColors.bad,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.onChanged});

  final int tab;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, String label, IconData icon) {
      final on = tab == i;
      return GestureDetector(
        onTap: () => onChanged(i),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: Motion.fast,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              color: on
                  ? AppColors.accent.withValues(alpha: 0.22)
                  : Colors.transparent,
              border: Border.all(
                color: on
                    ? AppColors.accent.withValues(alpha: 0.7)
                    : AppColors.stroke,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: on ? AppColors.text : AppColors.textDim,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: on ? AppColors.text : AppColors.textDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        item(0, t('home.tab_cards'), Icons.dashboard_customize_rounded),
        const SizedBox(width: 8),
        item(1, t('home.tab_apps'), Icons.apps_rounded),
      ],
    );
  }
}

class _PresetChip extends StatefulWidget {
  const _PresetChip({
    super.key,
    required this.service,
    this.subtitle,
    this.icon,
    this.onAdd,
  });

  final AiService service;
  final String? subtitle;
  final IconData? icon;

  /// Yoksa hazır kart olduğu gibi eklenir.
  final VoidCallback? onAdd;

  @override
  State<_PresetChip> createState() => _PresetChipState();
}

class _PresetChipState extends State<_PresetChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () {
          widget.onAdd == null
              ? ServicesStore.instance.add(s)
              : widget.onAdd!();
          Navigator.of(context).pop();
        },
        child: AnimatedContainer(
          duration: Motion.fast,
          width: 248,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _hover ? s.color.withValues(alpha: 0.22) : AppColors.surface,
            border: Border.all(
              color: _hover
                  ? s.accent.withValues(alpha: 0.6)
                  : AppColors.stroke,
            ),
          ),
          child: Row(
            children: [
              ServiceIcon(s, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      widget.subtitle ?? s.displaySubtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                widget.icon ?? Icons.add_circle_outline_rounded,
                size: 18,
                color: _hover ? AppColors.text : AppColors.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.hint, this.onSubmit});

  final TextEditingController controller;
  final String hint;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onSubmitted: onSubmit == null ? null : (_) => onSubmit!(),
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.accent),
        ),
      ),
    );
  }
}
