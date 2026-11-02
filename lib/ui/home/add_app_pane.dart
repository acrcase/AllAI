import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../data/installed_apps.dart';
import '../../data/services_store.dart';
import '../../l10n/l10n.dart';
import '../common/service_icon.dart';

/// "Ekle" penceresinin Uygulamalar sekmesi: kurulu uygulamalar (arama kutulu) ve "Başka bir uygulama seç…".
class AddAppPane extends StatefulWidget {
  const AddAppPane({super.key, required this.apps});

  final InstalledApps apps;

  @override
  State<AddAppPane> createState() => _AddAppPaneState();
}

class _AddAppPaneState extends State<AddAppPane> {
  final _query = TextEditingController();
  late final Future<List<InstalledApp>> _scan = widget.apps.scan();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Simgeyi üretip kartı ekler, pencereyi kapatır.
  Future<void> _add(InstalledApp app) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final icon = await widget.apps.icon(app);
    if (!mounted) return;
    final added = ServicesStore.instance.addApp(
      app,
      icon: icon?.path,
      color: icon?.color,
      accent: icon?.accent,
    );
    if (added) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = t('home.apps_dup');
      });
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    final app = await widget.apps.pick(t('home.apps_pick_title'));
    if (app != null && mounted) await _add(app);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (Platform.isWindows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              t('home.apps_win_note'),
              style: const TextStyle(fontSize: 12, color: AppColors.textDim),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: t('home.apps_search'),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppColors.textDim,
                  ),
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
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.folder_open_rounded, size: 16),
              label: Text(t('home.apps_pick')),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.strokeHi),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(color: AppColors.bad, fontSize: 12),
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          height: 360,
          child: FutureBuilder<List<InstalledApp>>(
            future: _scan,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final store = ServicesStore.instance;
              final q = _query.text.trim().toLowerCase();
              final free = [
                for (final a in snap.data!)
                  if (!store.hasApp(a)) a,
              ];
              final shown = [
                for (final a in free)
                  if (q.isEmpty || a.name.toLowerCase().contains(q)) a,
              ];
              final added = snap.data!.length - free.length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: shown.isEmpty
                        ? Center(
                            child: Text(
                              t('home.apps_none'),
                              style: const TextStyle(color: AppColors.textDim),
                            ),
                          )
                        : ListView.builder(
                            itemCount: shown.length,
                            itemExtent: 58,
                            itemBuilder: (context, i) => _AppRow(
                              key: ValueKey(shown[i].id),
                              app: shown[i],
                              apps: widget.apps,
                              onTap: () => _add(shown[i]),
                            ),
                          ),
                  ),
                  if (added > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        t('home.apps_added_n', {'n': '$added'}),
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AppRow extends StatefulWidget {
  const _AppRow({
    super.key,
    required this.app,
    required this.apps,
    required this.onTap,
  });

  final InstalledApp app;
  final InstalledApps apps;
  final VoidCallback onTap;

  @override
  State<_AppRow> createState() => _AppRowState();
}

class _AppRowState extends State<_AppRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.fast,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: _hover
                  ? AppColors.surface.withValues(alpha: 1)
                  : Colors.transparent,
              border: Border.all(
                color: _hover ? AppColors.strokeHi : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                FutureBuilder<AppIcon?>(
                  future: widget.apps.icon(app),
                  builder: (context, snap) => ServiceIcon(
                    app.toService(
                      icon: snap.data?.path,
                      color: snap.data?.color,
                      accent: snap.data?.accent,
                    ),
                    size: 38,
                    showBadge: false,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        app.windows ? app.path : app.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.add_circle_outline_rounded,
                  size: 18,
                  color: _hover ? AppColors.text : AppColors.textFaint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
