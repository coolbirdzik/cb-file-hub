import '../../../bloc/selection/selection.dart';
import '../../tab_manager/components/index.dart' as tab_components;
import 'package:flutter/material.dart';

class ScreenScaffold extends StatelessWidget {
  final SelectionState selectionState;
  final Widget body;
  final bool isNetworkPath;

  // Selection mode params
  final VoidCallback onClearSelection;
  final void Function(BuildContext) showRemoveTagsDialog;
  final void Function(BuildContext) showManageAllTagsDialog;
  final void Function(BuildContext) showDeleteConfirmationDialog;
  final Widget? selectionModeFloatingActionButton;
  final bool isDesktop;

  // Normal mode params
  final bool showAppBar;
  final bool showSearchBar;
  final Widget searchBar;
  final Widget pathNavigationBar;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  const ScreenScaffold({
    Key? key,
    required this.selectionState,
    required this.body,
    required this.isNetworkPath,
    required this.onClearSelection,
    required this.showRemoveTagsDialog,
    required this.showManageAllTagsDialog,
    required this.showDeleteConfirmationDialog,
    this.selectionModeFloatingActionButton,
    this.isDesktop = false,
    required this.showAppBar,
    required this.showSearchBar,
    required this.searchBar,
    required this.pathNavigationBar,
    required this.actions,
    this.floatingActionButton,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool useSelectionAppBar =
        selectionState.isSelectionMode && !isDesktop;
    final Widget? fab = selectionState.isSelectionMode
        ? selectionModeFloatingActionButton
        : floatingActionButton;

    if (useSelectionAppBar) {
      return Scaffold(
        backgroundColor: isDesktop ? Colors.transparent : null,
        appBar: tab_components.SelectionAppBar(
          selectedCount: selectionState.selectedCount,
          selectedFileCount: selectionState.selectedFilePaths.length,
          selectedFolderCount: selectionState.selectedFolderPaths.length,
          onClearSelection: onClearSelection,
          selectedFilePaths: selectionState.selectedFilePaths.toList(),
          selectedFolderPaths: selectionState.selectedFolderPaths.toList(),
          showRemoveTagsDialog: showRemoveTagsDialog,
          showManageAllTagsDialog: showManageAllTagsDialog,
          showDeleteConfirmationDialog: showDeleteConfirmationDialog,
          isNetworkPath: isNetworkPath,
        ),
        body: body,
        floatingActionButton: fab,
      );
    }

    return Scaffold(
      backgroundColor: isDesktop ? Colors.transparent : null,
      appBar: showAppBar
          ? AppBar(
              backgroundColor: isDesktop ? Colors.transparent : null,
              elevation: isDesktop ? 0 : null,
              title: showSearchBar ? searchBar : pathNavigationBar,
              actions: actions,
            )
          : null,
      body: body,
      floatingActionButton: fab,
    );
  }
}
