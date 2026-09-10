import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../../../config/translation_helper.dart';
import '../../../design_system/cb_design_system.dart';
import '../../screens/folder_list/folder_list_state.dart';
import '../../widgets/adaptive_file_list.dart';

/// Two-mode collections (hosts, devices, etc.) share the browser's layout.
class GridListViewController extends ChangeNotifier {
  GridListViewController({this.load, this.save});

  final Future<ViewMode> Function()? load;
  final Future<void> Function(ViewMode)? save;
  ViewMode _mode = ViewMode.grid;
  ViewMode get mode => _mode;
  bool _changed = false, _disposed = false, _initialized = false;
  Future<void> _writes = Future.value();

  static ViewMode normalize(ViewMode mode) =>
      mode == ViewMode.list ? ViewMode.list : ViewMode.grid;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final restored = await load?.call();
    if (_disposed || _changed || restored == null) return;
    _mode = normalize(restored);
    notifyListeners();
  }

  Future<void> select(ViewMode mode) {
    _changed = true;
    _mode = normalize(mode);
    notifyListeners();
    final selected = _mode;
    // Keep quick consecutive switches in order, including a failed prior save.
    _writes = _writes.then(
      (_) => save?.call(selected),
      onError: (Object _, StackTrace _) => save?.call(selected),
    );
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class GridListViewToggle extends StatelessWidget {
  const GridListViewToggle({
    super.key,
    required this.mode,
    required this.onChanged,
  });
  final ViewMode mode;
  final ValueChanged<ViewMode> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final option in [ViewMode.grid, ViewMode.list])
        Semantics(
          selected: option == mode,
          child: CbButton.icon(
            key: ValueKey('collection-view-${option.name}'),
            icon: option == ViewMode.grid
                ? PhosphorIconsLight.squaresFour
                : PhosphorIconsLight.list,
            tooltip: option == ViewMode.grid
                ? context.tr.viewModeGrid
                : context.tr.viewModeList,
            variant: option == mode
                ? CbButtonVariant.subtle
                : CbButtonVariant.ghost,
            onPressed: () => onChanged(option),
          ),
        ),
    ],
  );
}

class GridListCollection<T> extends StatefulWidget {
  const GridListCollection({
    super.key,
    required this.mode,
    required this.items,
    required this.isDesktop,
    required this.identity,
    required this.itemBuilder,
    required this.onRefresh,
  });
  final ViewMode mode;
  final List<T> items;
  final bool isDesktop;
  final String Function(T) identity;
  final Widget Function(BuildContext, T, ViewMode) itemBuilder;
  final Future<void> Function() onRefresh;

  @override
  State<GridListCollection<T>> createState() => _GridListCollectionState<T>();
}

class _GridListCollectionState<T> extends State<GridListCollection<T>> {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = math.max(
        1.0,
        MediaQuery.textScalerOf(context).scale(14) / 14,
      );
      final columns = math.max(
        1,
        ((constraints.maxWidth - 16 + 8) / (280 * scale + 8)).floor(),
      );
      final width = (constraints.maxWidth - 16 - 8 * (columns - 1)) / columns;
      final gridHeight = (width / 1.9).clamp(128.0 * scale, 156.0 * scale);
      final mode = GridListViewController.normalize(widget.mode);
      return AnimatedSwitcher(
        duration: CbDurations.fast,
        child: mode == ViewMode.grid
            ? RefreshIndicator(
                key: const ValueKey('grid-list-collection-grid'),
                onRefresh: widget.onRefresh,
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  physics: const ClampingScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    mainAxisExtent: gridHeight,
                  ),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) => KeyedSubtree(
                    key: ValueKey(
                      'grid-${widget.identity(widget.items[index])}',
                    ),
                    child: widget.itemBuilder(
                      context,
                      widget.items[index],
                      ViewMode.grid,
                    ),
                  ),
                ),
              )
            : RefreshIndicator(
                key: const ValueKey('grid-list-collection-list'),
                onRefresh: widget.onRefresh,
                child: AdaptiveFileList(
                  isDesktop: widget.isDesktop,
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) => KeyedSubtree(
                    key: ValueKey(
                      'list-${widget.identity(widget.items[index])}',
                    ),
                    child: widget.itemBuilder(
                      context,
                      widget.items[index],
                      ViewMode.list,
                    ),
                  ),
                ),
              ),
      );
    },
  );
}
