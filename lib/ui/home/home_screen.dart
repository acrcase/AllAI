import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../data/services_store.dart';
import '../../models/ai_service.dart';
import '../../usage/usage_models.dart';
import '../../usage/usage_repository.dart';
import '../usage/usage_corner.dart';
import '../viewer/viewer_layer.dart';
import 'tile_grid.dart';
import '../../l10n/l10n.dart';

/// Ana ekran: başlık, kart ızgarası, sağ altta kullanım limitleri.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.revealed,
    required this.reveal,
    required this.gridKey,
    required this.onOpen,
    this.hideIcons = false,
    this.hiddenId,
    this.onHover,
    required this.editing,
    this.dive,
  });

  /// Başlık ve köşe öğeleri süzülerek gelsin (açılışta simgeler uçmaya başlayınca).
  final bool revealed;

  /// Açılış denetleyicisi: kartlar kendi simgeleri inerken belirir.
  final Animation<double> reveal;
  final bool hideIcons;
  final GlobalKey<TileGridState> gridKey;
  final void Function(AiService service, Rect from) onOpen;
  final String? hiddenId;
  final ValueChanged<AiService?>? onHover;

  /// Düzenleme kipi (başlıktaki "Düzenle" düğmesi açar; üst çubuk RootScreen'de).
  final ValueNotifier<bool> editing;

  /// Kart açılırken/kapanırken ana ekranın "içine dalma" geçişi; başlık (açık sekmeler) bunun dışında
  /// yerinde kalır.
  final Widget Function(Widget child)? dive;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _headerHeight = ViewerLayerState.barHeight;

  @override
  Widget build(BuildContext context) {
    final store = ServicesStore.instance;
    final usage = UsageRepository.instance;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            widget.editing.value = false,
      },
      child: ListenableBuilder(
        listenable: Listenable.merge([store, usage, widget.editing]),
        builder: (context, _) {
          final services = store.services;
          final body = Stack(
            children: [
              Column(
                children: [
                  const SizedBox(height: _headerHeight),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(40, 8, 40, 0),
                      child: services.isEmpty
                          ? _empty()
                          : TileGrid(
                              key: widget.gridKey,
                              services: services,
                              reveal: widget.reveal,
                              hideIcons: widget.hideIcons,
                              editing: widget.editing.value,
                              hiddenId: widget.hiddenId,
                              onOpen: widget.onOpen,
                              onHover: widget.onHover,
                              onReorder: store.applyOrder,
                              onRemove: (s) => store.remove(s.id),
                              onToggleMode: (s) => store.setMode(
                                s.id,
                                s.mode == OpenMode.app
                                    ? OpenMode.web
                                    : OpenMode.app,
                              ),
                              usageOf: (s) {
                                final r = usage.reports[s.usageKey];
                                return r?.status == UsageStatus.ok
                                    ? r!.lowestRemaining
                                    : null;
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 92),
                ],
              ),
              Positioned(
                left: 28,
                bottom: 30,
                child: _reveal(
                  0.5,
                  Text(
                    widget.editing.value
                        ? t('home.hint_edit')
                        : (Platform.isMacOS
                              ? t('home.hint_keys')
                              : ''),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textFaint,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: _reveal(
                  0.6,
                  UsageCorner(
                    serviceIcons: {
                      for (final s in services)
                        if (s.icon != null) s.usageKey: s.icon!,
                    },
                  ),
                ),
              ),
            ],
          );
          return widget.dive?.call(body) ?? body;
        },
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t('home.empty'),
            style: const TextStyle(fontSize: 18, color: AppColors.textDim),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: ServicesStore.instance.resetDefaults,
            child: Text(t('home.restore')),
          ),
        ],
      ),
    );
  }

  /// Başlık ve köşe öğeleri kartlardan sonra süzülerek gelir.
  Widget _reveal(double delay, Widget child) {
    return AnimatedOpacity(
      opacity: widget.revealed ? 1 : 0,
      duration: Duration(milliseconds: 600 + (delay * 600).round()),
      curve: Interval(delay * 0.5, 1, curve: Curves.easeOut),
      child: AnimatedSlide(
        offset: widget.revealed ? Offset.zero : const Offset(0, -0.15),
        duration: Duration(milliseconds: 700 + (delay * 600).round()),
        curve: Interval(delay * 0.5, 1, curve: Motion.decelerate),
        child: child,
      ),
    );
  }
}
