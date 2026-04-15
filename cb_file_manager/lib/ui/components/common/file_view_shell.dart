import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cb_file_manager/helpers/core/user_preferences.dart';
import 'package:cb_file_manager/ui/screens/folder_list/folder_list_state.dart';
import 'package:cb_file_manager/ui/utils/grid_zoom_constraints.dart';

/// A wrapper widget that provides the full set of common file-view interactions
/// for any screen that displays a list/grid/details view of items.
///
/// Handles:
/// - **Ctrl+scroll** → adjust grid zoom (only when [viewMode] == [ViewMode.grid])
/// - **Mouse XButton1/XButton2** → optional back/forward navigation
/// - **Keyboard shortcuts** (only on desktop, only when no text-field is focused):
///   - `Escape`       → [onEscape]
///   - `F5` / `Ctrl+R` → [onRefresh]
///   - `Ctrl+A`       → [onSelectAll]
///   - `Delete`       → [onDelete]`(permanent: false)`
///   - `Shift+Delete` → [onDelete]`(permanent: true)`
///
/// Usage:
/// ```dart
/// body: FileViewShell(
///   viewMode: _viewMode,
///   onGridZoomDelta: _handleGridZoomDelta,
///   onRefresh: _loadItems,
///   onSelectAll: _selectAll,
///   onDelete: (_) => _deleteSelected(),
///   onEscape: isSelectionMode ? exitSelectionMode : null,
///   child: _buildBody(),
/// ),
/// ```
class FileViewShell extends StatefulWidget {
  final Widget child;

  // ── Grid zoom ──────────────────────────────────────────────────────────────
  /// Current view mode — Ctrl+scroll only activates in [ViewMode.grid].
  final ViewMode viewMode;

  /// Called with +1 (zoom in = fewer columns) or -1 (zoom out = more columns).
  /// The callback is responsible for clamping and persisting the new level.
  final void Function(int delta)? onGridZoomDelta;

  // ── Mouse navigation ───────────────────────────────────────────────────────
  /// Called when mouse XButton1 (back) is pressed. Pass `null` to disable.
  final VoidCallback? onMouseBack;

  /// Called when mouse XButton2 (forward) is pressed. Pass `null` to disable.
  final VoidCallback? onMouseForward;

  // ── Keyboard shortcuts ─────────────────────────────────────────────────────
  /// `Escape` — typically used to exit selection mode or close inline search.
  final VoidCallback? onEscape;

  /// `F5` / `Ctrl+R` — refresh the list.
  final VoidCallback? onRefresh;

  /// `Ctrl+A` — select all items.
  final VoidCallback? onSelectAll;

  /// `Delete` (permanent = false) / `Shift+Delete` (permanent = true).
  final void Function({required bool permanent})? onDelete;

  const FileViewShell({
    Key? key,
    required this.child,
    required this.viewMode,
    this.onGridZoomDelta,
    this.onMouseBack,
    this.onMouseForward,
    this.onEscape,
    this.onRefresh,
    this.onSelectAll,
    this.onDelete,
  }) : super(key: key);

  @override
  State<FileViewShell> createState() => _FileViewShellState();
}

class _FileViewShellState extends State<FileViewShell> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'file-view-shell');

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  // ── Pointer signal (Ctrl+scroll for grid zoom) ────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (widget.viewMode != ViewMode.grid) return;
    if (widget.onGridZoomDelta == null) return;
    if (event is! PointerScrollEvent) return;

    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrlHeld = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    if (!ctrlHeld) return;

    final direction = event.scrollDelta.dy > 0 ? 1 : -1;
    widget.onGridZoomDelta!(direction);
    GestureBinding.instance.pointerSignalResolver.resolve(event);
  }

  // ── Mouse side buttons (back / forward) ───────────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == 8) {
      widget.onMouseBack?.call();
    } else if (event.buttons == 16) {
      widget.onMouseForward?.call();
    }
  }

  // ── Keyboard shortcuts ────────────────────────────────────────────────────

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (!_isDesktop) return KeyEventResult.ignored;

    // Only react to key-down and key-repeat events.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Skip all shortcuts when a text field has keyboard focus.
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    // Escape ─────────────────────────────────────────────────────────────────
    if (key == LogicalKeyboardKey.escape && widget.onEscape != null) {
      widget.onEscape!();
      return KeyEventResult.handled;
    }

    // F5 / Ctrl+R ─────────────────────────────────────────────────────────────
    if (widget.onRefresh != null &&
        (key == LogicalKeyboardKey.f5 ||
            (isCtrl && key == LogicalKeyboardKey.keyR))) {
      widget.onRefresh!();
      return KeyEventResult.handled;
    }

    // Ctrl+A ──────────────────────────────────────────────────────────────────
    if (isCtrl &&
        key == LogicalKeyboardKey.keyA &&
        widget.onSelectAll != null) {
      widget.onSelectAll!();
      return KeyEventResult.handled;
    }

    // Delete / Shift+Delete ───────────────────────────────────────────────────
    if (key == LogicalKeyboardKey.delete && widget.onDelete != null) {
      widget.onDelete!(permanent: isShift);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerDown:
          (widget.onMouseBack != null || widget.onMouseForward != null)
              ? _onPointerDown
              : null,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: widget.child,
      ),
    );
  }
}

/// Convenience helper that computes the next grid zoom level given a delta,
/// clamps it to valid bounds, and returns the result.
///
/// Screens should call this inside their [onGridZoomDelta] callback:
/// ```dart
/// void _handleGridZoomDelta(int delta) {
///   final next = FileViewShell.clampGridZoom(context, _gridZoomLevel, delta);
///   if (next == _gridZoomLevel) return;
///   setState(() => _gridZoomLevel = next);
///   UserPreferences.instance.setTrashGridZoomLevel(next);
/// }
/// ```
extension FileViewShellHelpers on FileViewShell {
  static int clampGridZoom(BuildContext context, int current, int delta) {
    final maxZoom = GridZoomConstraints.maxGridSizeForContext(
      context,
      mode: GridSizeMode.referenceWidth,
    );
    return (current + delta)
        .clamp(UserPreferences.minGridZoomLevel, maxZoom)
        .toInt();
  }
}
