import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'dart:math' show min, max;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:cb_file_manager/models/objectbox/album.dart';
import 'package:cb_file_manager/services/album_service.dart';
import 'package:cb_file_manager/ui/utils/base_screen.dart';
import 'package:cb_file_manager/ui/screens/media_gallery/image_viewer_screen.dart';
import 'package:cb_file_manager/ui/utils/route.dart';
import 'package:cb_file_manager/ui/widgets/app_progress_indicator.dart';
import 'package:cb_file_manager/config/languages/app_localizations.dart';
import 'create_album_dialog.dart';
import 'batch_add_dialog.dart';
import 'package:path/path.dart' as pathlib;
import 'package:cb_file_manager/helpers/core/user_preferences.dart';
import 'package:cb_file_manager/ui/components/common/shared_action_bar.dart';
import 'package:cb_file_manager/services/smart_album_service.dart';
import 'package:cb_file_manager/services/album_auto_rule_service.dart';
import 'auto_rules_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:cb_file_manager/ui/screens/folder_list/components/file_grid_item.dart';
import 'package:cb_file_manager/helpers/media/video_thumbnail_helper.dart';
import 'package:cb_file_manager/helpers/files/file_type_registry.dart';
import 'package:cb_file_manager/ui/utils/grid_zoom_constraints.dart';
import 'package:cb_file_manager/ui/components/common/breadcrumb_address_bar.dart';
import 'package:cb_file_manager/ui/components/common/file_view_shell.dart';
import 'package:cb_file_manager/ui/screens/folder_list/folder_list_state.dart';
import 'package:cb_file_manager/ui/widgets/selection_summary_tooltip.dart';

// Selection BLoC + drag-selection
import 'package:cb_file_manager/bloc/selection/selection_bloc.dart';
import 'package:cb_file_manager/bloc/selection/selection_event.dart';
import 'package:cb_file_manager/bloc/selection/selection_state.dart';
import 'album_drag_selection_controller.dart';

class AlbumDetailScreen extends StatefulWidget {
  final Album album;

  const AlbumDetailScreen({
    Key? key,
    required this.album,
  }) : super(key: key);

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final AlbumService _albumService = AlbumService.instance;

  // ── File data ──────────────────────────────────────────────────────────────
  List<File> _imageFiles = [];
  List<File> _originalImageFiles = [];
  bool _isLoading = true;
  // Grid zoom level — uses the SAME key, range, and column-count formula
  // as the main file browser so that the same setting produces identical
  // column density on every screen.
  int _gridZoomLevel = UserPreferences.defaultGridZoomLevel;
  String? _searchQuery;
  bool _isShuffled = false;
  late UserPreferences _preferences;

  // ── Scroll-aware preloading ──────────────────────────────
  final ScrollController _gridScrollController = ScrollController();
  static const int _preloadBatchSize = 6;
  static const int _preloadAheadItems = 24;
  static const int _preloadBehindItems = 8;
  bool _isPreloading = false;
  final ListQueue<String> _preloadQueue = ListQueue<String>();
  final Set<String> _queuedPreloadPaths = <String>{};

  // ── Smart album state ──────────────────────────────────────────────────────
  bool _isSmartAlbum = false;
  bool _cancelSmartScan = false;
  // Tracks whether cached files were loaded so we skip redundant scans on revisit.
  // Since SmartAlbumService now has an in-memory scan cache, re-entering the
  // screen can populate files from cache without any disk I/O.
  bool _cachedFilesLoaded = false;
  Timer? _autoRescanTimer;
  int _activeRulesCount = 0;
  int _sourceFoldersCount = 0;
  DateTime? _lastScanTime;

  // ── Stream subscriptions ───────────────────────────────────────────────────
  StreamSubscription<int>? _albumUpdateSub;
  StreamSubscription<Map<String, dynamic>>? _progressSub;
  Timer? _refreshDebounce;

  // ── Background progress ────────────────────────────────────────────────────
  bool _isBackgroundProcessing = false;
  int _currentProgress = 0;
  int _totalProgress = 0;
  String _progressStatus = '';
  Timer? _progressDebounce;

  // ── Selection — using the shared SelectionBloc + drag controller ──────────
  late SelectionBloc _selectionBloc;
  late AlbumDragSelectionController _dragController;

  // ---------------------------------------------------------------------------
  // Life-cycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _selectionBloc = SelectionBloc();
    _dragController =
        AlbumDragSelectionController(selectionBloc: _selectionBloc);
    _preferences = UserPreferences.instance;
    _loadGridPreference();
    _initSmartStateAndLoad();
    _gridScrollController.addListener(_onGridScroll);

    _albumUpdateSub = AlbumService.instance.albumUpdatedStream
        .where((id) => id == widget.album.id)
        .listen((_) => _scheduleAlbumReload());

    _progressSub = AlbumService.instance.progressStream
        .where((p) => p['albumId'] == widget.album.id)
        .listen(_handleProgressUpdate);
  }

  @override
  void dispose() {
    _selectionBloc.close();
    _dragController.dispose();
    _gridScrollController
      ..removeListener(_onGridScroll)
      ..dispose();
    _albumUpdateSub?.cancel();
    _progressSub?.cancel();
    _refreshDebounce?.cancel();
    _progressDebounce?.cancel();
    _autoRescanTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Selection helpers — mirrors SelectionCoordinator logic
  // ---------------------------------------------------------------------------

  /// Toggle a file with full Shift/Ctrl support + range selection.
  void _toggleFileSelection(
    String filePath, {
    bool shiftSelect = false,
    bool ctrlSelect = false,
  }) {
    if (!shiftSelect) {
      _selectionBloc.add(ToggleFileSelection(
        filePath,
        shiftSelect: false,
        ctrlSelect: ctrlSelect,
      ));
      return;
    }

    // Shift+click: range selection over the visible _imageFiles list.
    final sel = _selectionBloc.state;
    if (sel.lastSelectedPath == null) {
      _selectionBloc.add(ToggleFileSelection(
        filePath,
        shiftSelect: false,
        ctrlSelect: ctrlSelect,
      ));
      return;
    }

    final allPaths = _imageFiles.map((f) => f.path).toList();
    final curIdx = allPaths.indexOf(filePath);
    final lastIdx = allPaths.indexOf(sel.lastSelectedPath!);

    if (curIdx != -1 && lastIdx != -1) {
      final start = min(curIdx, lastIdx);
      final end = max(curIdx, lastIdx);
      _selectionBloc.add(SelectItemsInRect(
        folderPaths: const {},
        filePaths: allPaths.sublist(start, end + 1).toSet(),
        isCtrlPressed: ctrlSelect,
        isShiftPressed: true,
      ));
    }
  }

  void _clearSelection() => _selectionBloc.add(ClearSelection());

  void _selectAll() {
    _selectionBloc.add(SelectAll(
      allFilePaths: _imageFiles.map((f) => f.path).toList(),
      allFolderPaths: const [],
    ));
  }

  // ---------------------------------------------------------------------------
  // Album-specific actions
  // ---------------------------------------------------------------------------

  Future<void> _removeSelectedFiles(Set<String> selectedPaths) async {
    if (selectedPaths.isEmpty || !mounted) return;

    final count = selectedPaths.length;
    final confirmed = await RouteUtils.showAcrylicDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $count ${count == 1 ? 'image' : 'images'}?'),
        content: const Text(
            'Remove selected images from this album? The original files will not be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      int successCount = 0;
      for (final filePath in selectedPaths) {
        if (await _albumService.removeFileFromAlbum(
            widget.album.id, filePath)) {
          successCount++;
        }
      }
      _clearSelection();
      await _loadAlbumFiles();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Removed $successCount ${successCount == 1 ? 'image' : 'images'} from album'),
        ));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Initialization helpers
  // ---------------------------------------------------------------------------

  Future<void> _initSmartStateAndLoad() async {
    try {
      _isSmartAlbum =
          await SmartAlbumService.instance.isSmartAlbum(widget.album.id);
    } catch (_) {
      _isSmartAlbum = false;
    }
    if (mounted) {
      if (_isSmartAlbum) {
        await _refreshSmartStatus();
        await _loadCachedSmartImages();
        _startAutoRescan();
      }
      _loadAlbumFiles(initial: true);
    }
  }

  Future<void> _refreshSmartStatus() async {
    try {
      final allRules = await AlbumAutoRuleService.instance.loadRules();
      final rules = allRules
          .where((r) => r.albumId == widget.album.id && r.isActive)
          .toList();
      final roots =
          await SmartAlbumService.instance.getScanRoots(widget.album.id);
      final last =
          await SmartAlbumService.instance.getLastScanTime(widget.album.id);
      if (mounted) {
        setState(() {
          _activeRulesCount = rules.length;
          _sourceFoldersCount = roots.length;
          _lastScanTime = last;
        });
      }
    } catch (_) {}
  }

  String _smartStatusText() {
    final last = _lastScanTime != null
        ? DateFormat('HH:mm dd/MM').format(_lastScanTime!)
        : 'Never';
    return '$_activeRulesCount rules • $_sourceFoldersCount sources • Last: $last';
  }

  Future<void> _loadGridPreference() async {
    try {
      await _preferences.init();
      // Use the shared gridZoomLevel key so album and file browser
      // stay in sync (same preference, same default, same range).
      final level = await _preferences.getGridZoomLevel();
      if (mounted) setState(() => _gridZoomLevel = level);
    } catch (_) {}
  }

  void _handleProgressUpdate(Map<String, dynamic> progress) {
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      setState(() {
        _isBackgroundProcessing =
            progress['status'] != 'completed' && progress['status'] != 'error';
        _currentProgress = progress['current'] ?? 0;
        _totalProgress = progress['total'] ?? 0;
        switch (progress['status']) {
          case 'scanning':
            _progressStatus = 'Scanning files...';
            break;
          case 'processing':
            _progressStatus =
                'Adding files... ($_currentProgress/$_totalProgress)';
            break;
          case 'completed':
            _progressStatus = 'Completed!';
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) setState(() => _isBackgroundProcessing = false);
            });
            break;
          case 'error':
            _progressStatus = 'Error: ${progress['error'] ?? 'Unknown error'}';
            break;
        }
      });
    });
  }

  Future<void> _loadAlbumFiles({bool initial = false}) async {
    if (initial) setState(() => _isLoading = true);
    try {
      if (_isSmartAlbum) {
        // For smart albums, only run a full scan if we don't have cached files yet.
        // SmartAlbumService.getCachedFiles already returns in-memory cached
        // results (instant) — no need to scan again on revisit.
        if (_cachedFilesLoaded) {
          if (mounted) setState(() => _isLoading = false);
          return;
        }
        await _scanSmartAlbumImages();
        return;
      }
      final albumFiles = await _albumService.getAlbumFiles(widget.album.id);
      final imageFiles = <File>[];
      for (final af in albumFiles) {
        final file = File(af.filePath);
        if (await file.exists()) imageFiles.add(file);
      }
      if (mounted) {
        setState(() {
          _originalImageFiles = List<File>.from(imageFiles);
          _applyFiltersAndOrder();
          _isLoading = false;
        });
        _preloadVideoThumbnails();
        _preloadPhotoThumbnails();
      }
    } catch (e) {
      debugPrint('Error loading album files: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _preloadVideoThumbnails() async {
    try {
      final videoFiles = _imageFiles.where((file) {
        final ext = pathlib.extension(file.path).toLowerCase();
        return FileTypeRegistry.getCategory(ext) == FileCategory.video;
      }).toList();
      if (videoFiles.isEmpty) return;
      const batchSize = 5;
      for (var i = 0; i < videoFiles.length; i += batchSize) {
        final batch = videoFiles.skip(i).take(batchSize).toList();
        await Future.wait(batch.map((file) =>
            VideoThumbnailHelper.generateThumbnail(file.path, isPriority: false)
                .catchError((_) => null)));
        if (i + batchSize < videoFiles.length) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (_) {}
  }

  /// Pre-warm Flutter’s ImageCache for the first [count] images using the
  /// native platform JPEG decoder (ResizeImage at 512 px).
  ///
  /// [precacheImage] runs the decode in a background isolate and puts the
  /// result into Flutter’s ImageCache, so when the grid renders those items
  /// for the first time there is zero decode work on the raster thread.
  // ── Scroll-aware viewport-priority preloading ───────────────────────

  /// Build an index list in the order the USER is most likely to need:
  /// 1) currently visible items
  /// 2) items just below the viewport
  /// 3) a few items above the viewport (for quick reverse scroll)
  ///
  /// This fixes the old behaviour where preloading ran linearly from the file
  /// list and wasted work on items far away from the current scroll position.
  List<int> _buildViewportPriorityIndices() {
    if (_imageFiles.isEmpty) return const [];

    final width = MediaQuery.of(context).size.width;
    final cols = GridZoomConstraints.columnCountForZoom(_gridZoomLevel, width);
    const spacing = GridZoomConstraints.fileGridSpacing;
    final usableWidth = width - (spacing * 2) - (spacing * (cols - 1));
    final itemExtent = cols > 0 ? (usableWidth / cols) : width;
    final rowExtent = itemExtent + spacing;

    final viewportHeight = _gridScrollController.hasClients
        ? _gridScrollController.position.viewportDimension
        : MediaQuery.of(context).size.height;
    final scrollOffset =
        _gridScrollController.hasClients ? _gridScrollController.offset : 0.0;

    final firstVisibleRow =
        (scrollOffset / rowExtent).floor().clamp(0, 1 << 20);
    final visibleRows = (viewportHeight / rowExtent).ceil() + 1;

    final visibleStart = (firstVisibleRow * cols).clamp(0, _imageFiles.length);
    final visibleEnd =
        ((firstVisibleRow + visibleRows) * cols).clamp(0, _imageFiles.length);

    final aheadEnd =
        (visibleEnd + _preloadAheadItems).clamp(0, _imageFiles.length);
    final behindStart =
        (visibleStart - _preloadBehindItems).clamp(0, _imageFiles.length);

    final ordered = <int>[];
    // Visible first
    for (int i = visibleStart; i < visibleEnd; i++) {
      ordered.add(i);
    }
    // Then below viewport
    for (int i = visibleEnd; i < aheadEnd; i++) {
      ordered.add(i);
    }
    // Then slightly above viewport
    for (int i = behindStart; i < visibleStart; i++) {
      ordered.add(i);
    }
    return ordered;
  }

  void _enqueueViewportPreload() {
    if (!mounted || _imageFiles.isEmpty) return;
    final ordered = _buildViewportPriorityIndices();
    for (final index in ordered) {
      final file = _imageFiles[index];
      final ext = pathlib.extension(file.path).toLowerCase();
      if (FileTypeRegistry.getCategory(ext) != FileCategory.image) continue;
      if (_queuedPreloadPaths.add(file.path)) {
        _preloadQueue.add(file.path);
      }
    }
    if (!_isPreloading) {
      unawaited(_drainPreloadQueue());
    }
  }

  void _onGridScroll() {
    // IMPORTANT: do NOT return when _isPreloading=true.
    // The queue must keep reprioritizing around the USER'S current viewport.
    if (!mounted) return;
    _enqueueViewportPreload();
  }

  Future<void> _drainPreloadQueue() async {
    if (_isPreloading || !mounted) return;
    _isPreloading = true;
    try {
      while (_preloadQueue.isNotEmpty && mounted) {
        final batch = <String>[];
        while (batch.length < _preloadBatchSize && _preloadQueue.isNotEmpty) {
          batch.add(_preloadQueue.removeFirst());
        }

        await Future.wait(
          batch.map(
            (path) => precacheImage(
              ResizeImage(
                FileImage(File(path)),
                width: 512,
                allowUpscaling: false,
                policy: ResizeImagePolicy.fit,
              ),
              context,
            ).catchError((_) {}),
          ),
        );

        // Allow the event loop / raster thread to breathe.
        await Future.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      if (mounted) _isPreloading = false;
    }
  }

  /// Public entry-point called after album files are loaded / updated.
  /// Rebuild the priority queue from the CURRENT viewport.
  Future<void> _preloadPhotoThumbnails() async {
    _preloadQueue.clear();
    _queuedPreloadPaths.clear();
    _enqueueViewportPreload();
  }

  Future<void> _scanSmartAlbumImages() async {
    final allRules = await AlbumAutoRuleService.instance.loadRules();
    final rules = allRules
        .where((r) => r.albumId == widget.album.id && r.isActive)
        .toList();
    if (mounted) {
      if (rules.isNotEmpty && _originalImageFiles.isNotEmpty) {
        _originalImageFiles = _originalImageFiles.where((f) {
          final base = pathlib.basename(f.path);
          return rules.any((r) => r.matches(base));
        }).toList();
        _applyFiltersAndOrder();
      }
      setState(() {
        _cancelSmartScan = false;
        _isBackgroundProcessing = true;
        _isLoading = false;
        _progressStatus = 'Scanning...';
        _currentProgress = 0;
        _totalProgress = 0;
      });
    }

    final roots =
        await SmartAlbumService.instance.getScanRoots(widget.album.id);
    if (roots.isEmpty) {
      if (mounted) {
        setState(() {
          _isBackgroundProcessing = false;
          _progressStatus = 'No scan locations configured';
        });
      }
      return;
    }

    int matched = 0;
    int processed = 0;
    final mediaExts = {
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.tif',
      '.tiff',
      '.mp4',
      '.mkv',
      '.avi',
      '.mov',
      '.wmv',
      '.flv',
      '.webm',
      '.m4v',
      '.3gp',
      '.ts',
      '.mts',
      '.m2ts',
    };

    Future<void> scanDir(Directory dir) async {
      try {
        await for (final entity
            in dir.list(recursive: false, followLinks: false)) {
          if (_cancelSmartScan) return;
          if (entity is File) {
            processed++;
            final ext = pathlib.extension(entity.path).toLowerCase();
            if (mediaExts.contains(ext)) {
              final name = pathlib.basename(entity.path);
              if (rules.isEmpty || rules.any((r) => r.matches(name))) {
                matched++;
                if (mounted) {
                  if (!_originalImageFiles.any((f) => f.path == entity.path)) {
                    _originalImageFiles.add(entity);
                  }
                  if (matched % 10 == 0 || processed % 100 == 0) {
                    setState(() {
                      _applyFiltersAndOrder();
                      _progressStatus = 'Scanning... found $matched';
                    });
                    // Incrementally preload newly discovered images so
                    // they appear in the grid already decoded.
                    if (matched % 20 == 0) _preloadPhotoThumbnails();
                  }
                }
              }
            }
          } else if (entity is Directory) {
            await scanDir(entity);
          }
        }
      } catch (_) {}
    }

    for (final rootPath in roots) {
      if (_cancelSmartScan) break;
      await scanDir(Directory(rootPath));
    }

    if (mounted) {
      setState(() {
        _applyFiltersAndOrder();
        _isLoading = false;
        _isBackgroundProcessing = false;
        _progressStatus = 'Completed! Found $matched files';
      });
      _preloadVideoThumbnails();
      _preloadPhotoThumbnails();
    }

    try {
      await SmartAlbumService.instance.setCachedFiles(
          widget.album.id, _originalImageFiles.map((f) => f.path).toList());
    } catch (_) {}
  }

  Future<void> _loadCachedSmartImages() async {
    try {
      final cached =
          await SmartAlbumService.instance.getCachedFiles(widget.album.id);
      if (cached.isNotEmpty && mounted) {
        final allRules = await AlbumAutoRuleService.instance.loadRules();
        final rules = allRules
            .where((r) => r.albumId == widget.album.id && r.isActive)
            .toList();
        final files = <File>[];
        for (final p in cached) {
          final f = File(p);
          if (!f.existsSync()) continue;
          if (rules.isEmpty) {
            // No active rules — show all cached files (unfiltered).
            files.add(f);
          } else {
            // Filter by rules.
            final base = pathlib.basename(p);
            if (rules.any((r) => r.matches(base))) files.add(f);
          }
        }
        if (files.isNotEmpty) {
          setState(() {
            _originalImageFiles = files;
            _applyFiltersAndOrder();
            _isLoading = false;
          });
          _cachedFilesLoaded = true;
          _preloadVideoThumbnails();
          _preloadPhotoThumbnails();
        }
      }
    } catch (_) {}
  }

  void _startAutoRescan() {
    _autoRescanTimer?.cancel();
    _autoRescanTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!_isBackgroundProcessing) _scanSmartAlbumImages();
    });
  }

  Future<void> _showManageSourcesDialog() async {
    final service = SmartAlbumService.instance;
    List<String> roots = await service.getScanRoots(widget.album.id);
    if (!mounted) return;
    await RouteUtils.showAcrylicDialog(
      context: context,
      builder: (context) {
        List<String> localRoots = List.from(roots);
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Scan Locations'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (localRoots.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        'No locations selected. Add folders to scan for this album.',
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: localRoots.length,
                      itemBuilder: (context, index) {
                        final p = localRoots[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(PhosphorIconsLight.folder),
                          title: Text(p,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: Icon(PhosphorIconsLight.trash,
                                color: Theme.of(context).colorScheme.error),
                            onPressed: () =>
                                setState(() => localRoots.removeAt(index)),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final dir =
                            await FilePicker.platform.getDirectoryPath();
                        if (dir != null && dir.isNotEmpty) {
                          setState(() {
                            if (!localRoots.contains(dir)) localRoots.add(dir);
                          });
                        }
                      },
                      icon: const Icon(PhosphorIconsLight.plus),
                      label: const Text('Add folder'),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  await service.setScanRoots(widget.album.id, localRoots);
                  if (mounted) {
                    try {
                      navigator.pop();
                    } catch (_) {}
                  }
                  if (mounted && _isSmartAlbum) {
                    await _refreshSmartStatus();
                    _scanSmartAlbumImages();
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _scheduleAlbumReload() {
    if (mounted) _loadAlbumFiles();
  }

  void _handleGridZoomDelta(int delta) {
    final next = FileViewShellHelpers.clampGridZoom(
      context,
      _gridZoomLevel,
      delta,
    );
    if (next == _gridZoomLevel) return;
    _applyGridSize(next);
  }

  Future<void> _applyGridSize(int size) async {
    setState(() => _gridZoomLevel = size);
    try {
      await _preferences.setGridZoomLevel(size);
    } catch (_) {}
  }

  void _applyFiltersAndOrder() {
    List<File> files = List<File>.from(_originalImageFiles);
    if (_searchQuery != null && _searchQuery!.trim().isNotEmpty) {
      final q = _searchQuery!.toLowerCase();
      files = files
          .where((f) => pathlib.basename(f.path).toLowerCase().contains(q))
          .toList();
    }
    if (_isShuffled) files.shuffle();
    _imageFiles = files;
    // Clear stale item positions whenever the file list changes.
    _dragController.clearItemPositions();
  }

  void _toggleShuffle() {
    setState(() {
      _isShuffled = !_isShuffled;
      _applyFiltersAndOrder();
    });
  }

  void _showSearchDialog() {
    String query = _searchQuery ?? '';
    RouteUtils.showAcrylicDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Search in Album'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter image name...',
            prefixIcon: Icon(PhosphorIconsLight.magnifyingGlass),
          ),
          controller: TextEditingController(text: query),
          onChanged: (value) => query = value,
          onSubmitted: (_) {
            RouteUtils.safePopDialog(context);
            setState(() {
              _searchQuery = query.trim().isEmpty ? null : query.trim();
              _applyFiltersAndOrder();
            });
          },
        ),
        actions: [
          TextButton(
            onPressed: () => RouteUtils.safePopDialog(context),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () {
              RouteUtils.safePopDialog(context);
              setState(() {
                _searchQuery = query.trim().isEmpty ? null : query.trim();
                _applyFiltersAndOrder();
              });
            },
            child: const Text('Search'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddFilesMenu() async {
    if (!mounted) return;
    final result = await RouteUtils.showAcrylicDialog(
      context: context,
      builder: (context) => BatchAddDialog(albumId: widget.album.id),
    );
    if (result != null && mounted) {
      String message;
      if (result is Map<String, dynamic>) {
        if (result.containsKey('error')) {
          message = 'Error: ${result['error']}';
        } else if (result.containsKey('background')) {
          message = 'Adding files in background...';
        } else {
          final added = result['added'] ?? 0;
          final total = result['total'] ?? 0;
          message = 'Added $added out of $total files';
        }
      } else {
        message = 'Files added successfully';
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      if (result is Map<String, dynamic> && !result.containsKey('background')) {
        _loadAlbumFiles();
      }
    }
  }

  Future<void> _editAlbum() async {
    if (!mounted) return;
    await RouteUtils.showAcrylicDialog<Album>(
      context: context,
      builder: (context) => CreateAlbumDialog(editingAlbum: widget.album),
    );
    if (mounted) setState(() {});
  }

  // _resolveGridColumns() removed — column count is now computed inside
  // _buildGrid() with a LayoutBuilder so it can use the actual available
  // width, matching the file-browser formula exactly.

  Widget _buildAddressBar(BuildContext context) {
    final count = _imageFiles.length;
    return BreadcrumbAddressBar(
      segments: [
        BreadcrumbSegment(
          label: 'Albums',
          icon: PhosphorIconsLight.images,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        BreadcrumbSegment(
          label: widget.album.name,
          badge: count > 0 ? '$count' : null,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // AppBar action builders
  // ---------------------------------------------------------------------------

  /// Actions for the normal (non-selection) AppBar.
  /// On desktop, also contains the "Remove from album" button (enabled when
  /// items are selected), matching the file-browser pattern of not switching
  /// the AppBar on desktop selection mode.
  List<Widget> _buildNormalActions(
      BuildContext context, SelectionState sel, bool isDesktop) {
    final hasSelection = sel.selectedFilePaths.isNotEmpty;
    return [
      // ── Album-specific: remove selected items ─────────────────────────────
      // Visible on desktop when in selection mode (mirrors file-browser: no
      // AppBar change on desktop, actions stay visible but enabled/disabled).
      if (isDesktop && hasSelection)
        IconButton(
          icon: const Icon(PhosphorIconsLight.minusCircle),
          tooltip: 'Remove from album',
          onPressed: () => _removeSelectedFiles(sel.selectedFilePaths),
        ),

      // ── Standard album actions ────────────────────────────────────────────
      IconButton(
        icon: const Icon(PhosphorIconsLight.magnifyingGlass),
        tooltip: 'Search',
        onPressed: _showSearchDialog,
      ),
      if (Platform.isAndroid || Platform.isIOS)
        IconButton(
          icon: const Icon(PhosphorIconsLight.squaresFour),
          tooltip: 'Grid Size',
          onPressed: () => SharedActionBar.showGridSizeDialog(
            context,
            currentGridSize: _gridZoomLevel,
            onApply: _applyGridSize,
            sizeMode: GridSizeMode.referenceWidth,
            minGridSize: UserPreferences.minGridZoomLevel,
            maxGridSize: UserPreferences.maxGridZoomLevel,
          ),
        )
      else
        PopupMenuButton<void>(
          icon: const Icon(PhosphorIconsLight.squaresFour),
          tooltip: 'Grid Size',
          offset: const Offset(0, 50),
          itemBuilder: (context) => [
            PopupMenuItem<void>(
              enabled: false,
              padding: EdgeInsets.zero,
              child: GridSizeSliderMenu(
                currentValue: _gridZoomLevel,
                minValue: UserPreferences.minGridZoomLevel,
                maxValue: GridZoomConstraints.maxGridSizeForContext(
                  context,
                  mode: GridSizeMode.referenceWidth,
                  minValue: UserPreferences.minGridZoomLevel,
                  maxValue: UserPreferences.maxGridZoomLevel,
                ),
                onChanged: _applyGridSize,
              ),
            ),
          ],
        ),
      IconButton(
        icon: const Icon(PhosphorIconsLight.shuffle),
        color: _isShuffled ? Theme.of(context).colorScheme.primary : null,
        tooltip: _isShuffled ? 'Unshuffle' : 'Shuffle',
        onPressed: _toggleShuffle,
      ),
      IconButton(
        icon: const Icon(PhosphorIconsLight.plus),
        onPressed: _showAddFilesMenu,
        tooltip: 'Add images',
      ),
      PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'edit':
              _editAlbum();
              break;
            case 'select':
              _selectionBloc.add(const ToggleSelectionMode(forceValue: true));
              break;
            case 'shuffle':
              _toggleShuffle();
              break;
            case 'clear_search':
              setState(() {
                _searchQuery = null;
                _applyFiltersAndOrder();
              });
              break;
            case 'manage_rules':
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AutoRulesScreen(
                    scopedAlbumId: widget.album.id,
                    scopedAlbumName: widget.album.name,
                  ),
                ),
              );
              if (mounted && _isSmartAlbum) {
                await _loadCachedSmartImages();
                _scanSmartAlbumImages();
              }
              break;
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'edit',
            child: Row(children: [
              Icon(PhosphorIconsLight.pencilSimple),
              SizedBox(width: 8),
              Text('Edit Album'),
            ]),
          ),
          const PopupMenuItem(
            value: 'select',
            child: Row(children: [
              Icon(PhosphorIconsLight.checks),
              SizedBox(width: 8),
              Text('Select Images'),
            ]),
          ),
          const PopupMenuItem(
            value: 'shuffle',
            child: Row(children: [
              Icon(PhosphorIconsLight.shuffle),
              SizedBox(width: 8),
              Text('Shuffle'),
            ]),
          ),
          const PopupMenuItem(
            value: 'clear_search',
            child: Row(children: [
              Icon(PhosphorIconsLight.x),
              SizedBox(width: 8),
              Text('Clear Search'),
            ]),
          ),
          if (_isSmartAlbum)
            const PopupMenuItem(
              value: 'manage_rules',
              child: Row(children: [
                Icon(PhosphorIconsLight.faders),
                SizedBox(width: 8),
                Text('Manage Rules'),
              ]),
            ),
        ],
      ),
    ];
  }

  /// Mobile-only AppBar actions shown when in selection mode.
  List<Widget> _buildMobileSelectionActions(
      BuildContext context, SelectionState sel) {
    final count = sel.selectedFilePaths.length;
    final total = _imageFiles.length;
    return [
      IconButton(
        icon: const Icon(PhosphorIconsLight.minusCircle),
        tooltip: 'Remove from album',
        onPressed: count == 0
            ? null
            : () => _removeSelectedFiles(sel.selectedFilePaths),
      ),
      IconButton(
        icon: const Icon(PhosphorIconsLight.checkSquare),
        tooltip: count == total ? 'Deselect all' : 'Select all',
        onPressed: () {
          if (count == total) {
            _clearSelection();
          } else {
            _selectAll();
          }
        },
      ),
      IconButton(
        icon: const Icon(PhosphorIconsLight.x),
        tooltip: 'Cancel selection',
        onPressed: _clearSelection,
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    return BlocProvider.value(
      value: _selectionBloc,
      child: BlocBuilder<SelectionBloc, SelectionState>(
        builder: (context, sel) {
          final inSel = sel.isSelectionMode;
          final selectedCount = sel.selectedFilePaths.length;

          // Mobile shows a dedicated selection AppBar; desktop keeps the
          // normal AppBar (with "Remove" button enabled when items selected).
          final bool useMobileSelectionBar = inSel && !isDesktop;

          return BaseScreen(
            // Desktop: always show normal title/addressbar.
            // Mobile-selection: show "N selected" as plain title.
            title: useMobileSelectionBar
                ? '$selectedCount selected'
                : widget.album.name,
            titleWidget:
                useMobileSelectionBar ? null : _buildAddressBar(context),
            automaticallyImplyLeading: !useMobileSelectionBar,
            actions: useMobileSelectionBar
                ? _buildMobileSelectionActions(context, sel)
                : _buildNormalActions(context, sel, isDesktop),
            body: FileViewShell(
              viewMode: ViewMode.grid,
              onGridZoomDelta: _handleGridZoomDelta,
              onEscape: inSel ? _clearSelection : null,
              onSelectAll: _selectAll,
              child: Stack(
                key: _dragController.stackKey,
                children: [
                  Column(
                    children: [
                      if (isDesktop) const SizedBox(height: kToolbarHeight),

                      // Smart album banner
                      if (_isSmartAlbum)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              const Icon(PhosphorIconsLight.sparkle, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                        'Smart Album (dynamic by rules)'),
                                    const SizedBox(height: 2),
                                    Text(_smartStatusText(),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                  ],
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _showManageSourcesDialog,
                                icon: const Icon(PhosphorIconsLight.folderOpen),
                                label: const Text('Sources'),
                              ),
                              if (_isBackgroundProcessing)
                                TextButton.icon(
                                  onPressed: () => setState(() {
                                    _cancelSmartScan = true;
                                    _isBackgroundProcessing = false;
                                    _progressStatus = 'Canceled';
                                  }),
                                  icon: const Icon(PhosphorIconsLight.x),
                                  label: const Text('Cancel'),
                                ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: () {
                                  if (!_isBackgroundProcessing) {
                                    setState(() => _isLoading = true);
                                    _scanSmartAlbumImages();
                                  }
                                },
                                icon: const Icon(
                                    PhosphorIconsLight.arrowsClockwise),
                                label: const Text('Rescan'),
                              ),
                              TextButton.icon(
                                onPressed: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => AutoRulesScreen(
                                        scopedAlbumId: widget.album.id,
                                        scopedAlbumName: widget.album.name,
                                      ),
                                    ),
                                  );
                                  if (mounted && _isSmartAlbum) {
                                    await _loadCachedSmartImages();
                                    _scanSmartAlbumImages();
                                    await _refreshSmartStatus();
                                  }
                                },
                                icon: const Icon(PhosphorIconsLight.faders),
                                label: const Text('Rules'),
                              ),
                            ],
                          ),
                        ),

                      // Search chip
                      if (_searchQuery != null && _searchQuery!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                const Icon(PhosphorIconsLight.magnifyingGlass,
                                    size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text('Search: "$_searchQuery"')),
                                IconButton(
                                  icon: const Icon(PhosphorIconsLight.x,
                                      size: 18),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => setState(() {
                                    _searchQuery = null;
                                    _applyFiltersAndOrder();
                                  }),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Background-scan progress
                      if (_isBackgroundProcessing)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_progressStatus,
                                  style: Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: 4),
                              AppProgressIndicator(
                                value: _totalProgress > 0
                                    ? _currentProgress / _totalProgress
                                    : null,
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                    .withValues(alpha: 0.2),
                              ),
                            ],
                          ),
                        ),

                      // ── Main grid (+ tap-deselect + drag-selection) ────────
                      Expanded(
                        // GestureDetector wraps the grid content — same
                        // pattern as file_list_view_builder.dart so taps on
                        // empty space (grid padding / below items) deselect,
                        // and left-button drag starts rubber-band selection.
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          // Tap on empty grid area → deselect
                          onTap: inSel ? _clearSelection : null,
                          // Desktop pan → rubber-band drag selection.
                          // Before starting, we force a setState so that the
                          // grid rebuilds with isDragging=true and registers
                          // all item positions via addPostFrameCallback.
                          onPanStart: isDesktop
                              ? (d) {
                                  final focused =
                                      FocusManager.instance.primaryFocus;
                                  final isText = focused?.context?.widget
                                          is EditableText ||
                                      focused?.context
                                              ?.findAncestorWidgetOfExactType<
                                                  EditableText>() !=
                                          null;
                                  if (!isText) {
                                    // isDragging becomes true → next build
                                    // registers all item positions.
                                    _dragController.start(d.localPosition);
                                    // Force rebuild so LayoutBuilder runs
                                    // addPostFrameCallback for each item.
                                    setState(() {});
                                  }
                                }
                              : null,
                          onPanUpdate: isDesktop
                              ? (d) => _dragController.update(d.localPosition)
                              : null,
                          onPanEnd:
                              isDesktop ? (_) => _dragController.end() : null,
                          child: _imageFiles.isEmpty && !_isLoading
                              ? _buildEmptyState()
                              : _buildGrid(context, sel, inSel, isDesktop),
                        ),
                      ),
                    ],
                  ),

                  // Rubber-band selection overlay
                  _dragController.buildOverlay(),

                  // Desktop: SelectionSummaryTooltip at the bottom — exactly
                  // like the file browser (no AppBar change on desktop).
                  if (isDesktop && sel.selectedFilePaths.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SelectionSummaryTooltip(
                        selectedFileCount: sel.selectedFilePaths.length,
                        selectedFolderCount: 0,
                        selectedFilePaths: sel.selectedFilePaths.toList(),
                        selectedFolderPaths: const [],
                      ),
                    ),

                  // Slim bottom progress bar — same style as folder list screen.
                  // Shown during initial load and background scan.
                  // Does NOT displace the grid layout (Positioned overlay).
                  if (_isLoading || _isBackgroundProcessing)
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _AlbumStatusBar(),
                    ),
                ],
              ),
            ),
            floatingActionButton: inSel
                ? null
                : FloatingActionButton(
                    onPressed: _showAddFilesMenu,
                    tooltip: 'Add images',
                    child: const Icon(PhosphorIconsLight.plus),
                  ),
          );
        },
      ),
    );
  }

  /// Grid view with drag-selection position registration — mirrors
  /// [FileListViewBuilder._buildGridView] item-position logic.
  Widget _buildGrid(
    BuildContext context,
    SelectionState sel,
    bool inSel,
    bool isDesktop,
  ) {
    // Wrap in LayoutBuilder so the column count reflects the ACTUAL available
    // width, using the same formula as FileListViewBuilder.
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = GridZoomConstraints.columnCountForZoom(
          _gridZoomLevel,
          constraints.maxWidth,
        );
        return GridView.builder(
          controller: _gridScrollController,
          padding: const EdgeInsets.all(GridZoomConstraints.fileGridSpacing),
          // Match file-browser GridView settings for consistent perf.
          physics: const ClampingScrollPhysics(),
          cacheExtent: isDesktop ? 600 : 400,
          // Keep thumbnail item states alive while near the viewport so
          // scrolling back does not recreate them immediately.
          addAutomaticKeepAlives: true,
          addRepaintBoundaries: true,
          addSemanticIndexes: false,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: GridZoomConstraints.fileGridSpacing,
            mainAxisSpacing: GridZoomConstraints.fileGridSpacing,
          ),
          itemCount: _imageFiles.length,
          itemBuilder: (context, index) {
            final file = _imageFiles[index];
            final isSelected = sel.selectedFilePaths.contains(file.path);
            return LayoutBuilder(
              builder: (context, _) {
                // Register bounding-box for drag-selection hit-testing.
                // Guard: only register when drag is potentially active (user is
                // in selection mode or a drag is already happening). Skipping
                // this during normal browsing eliminates N addPostFrameCallback
                // calls per build frame — the main source of per-frame overhead.
                if (isDesktop && (inSel || _dragController.isDragging.value)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    try {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null && box.hasSize && box.attached) {
                        final origin = box.localToGlobal(Offset.zero);
                        _dragController.registerItemPosition(
                          file.path,
                          Rect.fromLTWH(
                            origin.dx,
                            origin.dy,
                            box.size.width,
                            box.size.height,
                          ),
                        );
                      }
                    } catch (_) {}
                  });
                }
                return RepaintBoundary(
                  child: FileGridItem(
                    key: ValueKey('album-grid-${file.path}'),
                    file: file,
                    isSelected: isSelected,
                    isSelectionMode: inSel,
                    isDesktopMode: isDesktop,
                    toggleFileSelection: (path,
                        {shiftSelect = false, ctrlSelect = false}) {
                      _toggleFileSelection(path,
                          shiftSelect: shiftSelect, ctrlSelect: ctrlSelect);
                    },
                    toggleSelectionMode: () {
                      // FileGridItem calls this from onDoubleTap (desktop)
                      // immediately before onFileTap. Changing BLoC state here
                      // would emit a new SelectionState mid-animation and force
                      // a full BlocBuilder rebuild while the route transition is
                      // playing — causing visible jank on the way into the viewer
                      // AND on return. We intentionally do nothing here:
                      //   • Selection persists while viewing (correct UX for album)
                      //   • No BLoC emission → no grid rebuild during animation
                      //   • User exits selection via Escape / Cancel button
                    },
                    onFileTap: (file, isVideo) {
                      // FileGridItem already ensures onFileTap is only called
                      // at the right time:
                      //   desktop  → double-click only (single-click = select)
                      //   mobile   → single-click only when NOT in selection mode
                      // rootNavigator: true → animation chạy ở ROOT overlay,
                      // album screen KHÔNG trong animation path → build() không
                      // bị gọi mỗi frame.
                      //
                      // opaque: false → Flutter BẮT BUỘC giữ album screen trong
                      // compositing chain ngay cả khi bị che → GPU textures của
                      // thumbnail KHÔNG bị evict → không re-rasterize khi back.
                      // (ImageViewerScreen có backgroundColor: Colors.black nên
                      // album screen không nhìn thấy được qua viewer.)
                      Navigator.of(context, rootNavigator: true).push(
                        PageRouteBuilder(
                          opaque: false,
                          barrierColor: Colors.black,
                          fullscreenDialog: true,
                          pageBuilder: (_, __, ___) => ImageViewerScreen(
                            file: file,
                            imageFiles: _imageFiles,
                            initialIndex: index,
                          ),
                          transitionsBuilder: (_, animation, __, child) =>
                              FadeTransition(
                            opacity: CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOut,
                            ),
                            child: child,
                          ),
                          transitionDuration: const Duration(milliseconds: 180),
                          reverseTransitionDuration:
                              const Duration(milliseconds: 150),
                        ),
                      );
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            PhosphorIconsLight.images,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery == null || _searchQuery!.isEmpty
                ? 'No images in this album'
                : 'No images match your search',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add images to start building your album',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showAddFilesMenu,
            icon: const Icon(PhosphorIconsLight.images),
            label: const Text('Add Images'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Slim 3px indeterminate progress bar overlaid at the bottom of the screen.
/// Matches the `_RefreshStatusBar` style used in the main folder list screen
/// so all loading indicators are visually consistent.
class _AlbumStatusBar extends StatelessWidget {
  const _AlbumStatusBar();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 3,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      ),
      child: LinearProgressIndicator(
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation<Color>(
          colorScheme.primary.withValues(alpha: 0.8),
        ),
        minHeight: 3,
      ),
    );
  }
}
