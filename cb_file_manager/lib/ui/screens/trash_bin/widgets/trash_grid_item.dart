import 'package:flutter/material.dart';
import 'package:cb_file_manager/helpers/files/trash_manager.dart';
import 'package:cb_file_manager/ui/components/common/item_shell.dart';
import 'trash_list_item.dart';

/// Grid item widget for trash bin - displays trash item in grid view
class TrashGridItem extends StatelessWidget {
  final TrashItem item;
  final bool isSelected;
  final bool isSelectionMode;
  final bool isDesktop;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelectionMode;
  final void Function(Offset) onContextMenu;

  const TrashGridItem({
    Key? key,
    required this.item,
    required this.isSelected,
    required this.isSelectionMode,
    required this.isDesktop,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
    required this.onContextMenu,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GridItemShell(
      isSelected: isSelected,
      isSelectionMode: isSelectionMode,
      isDesktopMode: isDesktop,
      onToggleSelection: onToggleSelection,
      onEnterSelectionMode: onEnterSelectionMode,
      onSecondaryTapUp: (d) => onContextMenu(d.globalPosition),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Thumbnail area — Windows Explorer style: fills available space
          Expanded(
            child: Center(
              child: TrashItemIcon(originalPath: item.originalPath, size: 56),
            ),
          ),
          // Filename below icon
          Padding(
            padding: const EdgeInsets.only(top: 4.0, left: 4.0, right: 4.0),
            child: Text(
              item.displayNameValue,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
