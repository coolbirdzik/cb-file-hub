import 'dart:async';
import 'dart:io';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as pathlib;
import 'package:cb_file_manager/helpers/files/folder_sort_manager.dart';
import 'package:cb_file_manager/helpers/core/filesystem_sorter.dart';
import 'package:cb_file_manager/helpers/core/text_utils.dart';
import 'package:cb_file_manager/helpers/media/video_thumbnail_helper.dart';
import 'package:cb_file_manager/services/directory_watcher_service.dart';
import 'package:cb_file_manager/services/permission_state_service.dart';
import 'package:cb_file_manager/ui/utils/file_type_utils.dart';

import 'package:cb_file_manager/utils/app_logger.dart';

import 'file_navigation_event.dart';
import 'file_navigation_state.dart';
import 'package:cb_file_manager/ui/screens/folder_list/folder_list_state.dart';

class FileNavigationBloc
    extends Bloc<FileNavigationEvent, FileNavigationState> {
  StreamSubscription<String>? _directoryWatcherSubscription;
  final DirectoryWatcherService _directoryWatcher =
      DirectoryWatcherService.instance;
  int _activeSortRequestId = 0;

  static const int _searchResultsPageSize = 200;
  List<FileSystemEntity> _pendingSearchResults = [];

  FileNavigationBloc() : super(FileNavigationState.initial('/')) {
    // ── Lifecycle ───────────────────────────────────────────────
    on<FileNavigationInit>(_onInit);
    on<FileNavigationLoad>(_onLoad);
    on<FileNavigationRefresh>(_onRefresh);
    on<FileNavigationReloadCurrentFolder>(_onReloadCurrentFolder);
    on<FileNavigationLoadDrives>(_onLoadDrives);

    // ── Filtering & Sorting ────────────────────────────────────
    on<FileNavigationFilter>(_onFilter);
    on<FileNavigationSetSortOption>(_onSetSortOption);

    // ── View Mode ──────────────────────────────────────────────
    on<FileNavigationSetViewMode>(_onSetViewMode);
    on<FileNavigationSetGridZoom>(_onSetGridZoom);

    // ── Search ──────────────────────────────────────────────────
    on<FileNavigationSearchByFileName>(_onSearchByFileName);
    on<FileNavigationClearSearchAndFilters>(_onClearSearchAndFilters);
    on<FileNavigationLoadMoreSearchResults>(_onLoadMoreSearchResults);

    // ── Directory watching ─────────────────────────────────────
    _directoryWatcherSubscription = _directoryWatcher.onDirectoryRefresh.listen(
      (path) {
        if (path == state.currentPath.path) {
          add(FileNavigationRefresh(path));
        }
      },
    );
  }

  @override
  Future<void> close() {
    _directoryWatcherSubscription?.cancel();
    _directoryWatcher.stopWatching();
    return super.close();
  }

  // ─────────────────────────────────────────────────────────────
  // Lifecycle handlers
  // ─────────────────────────────────────────────────────────────

  void _onInit(
    FileNavigationInit event,
    Emitter<FileNavigationState> emit,
  ) {
    emit(state.copyWith(isLoading: true));
  }

  Future<void> _onLoad(
    FileNavigationLoad event,
    Emitter<FileNavigationState> emit,
  ) async {
    final totalSw = Stopwatch()..start();
    AppLogger.perf('Starting folder load path=${event.path}');
    emit(state.copyWith(isLoading: true, currentPath: Directory(event.path)));

    if (event.path.isEmpty && Platform.isWindows) {
      emit(state.copyWith(isLoading: false, folders: [], files: []));
      AppLogger.perf('Empty path total=${totalSw.elapsedMilliseconds}ms');
      return;
    }

    if (_isDrivesPath(event.path)) {
      emit(state.copyWith(isLoading: false, folders: [], files: []));
      AppLogger.perf('Drives path total=${totalSw.elapsedMilliseconds}ms');
      return;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    try {
      final directory = Directory(event.path);
      if (!await directory.exists()) {
        emit(state.copyWith(
          isLoading: false,
          error: 'Directory does not exist: ${event.path}',
        ));
        return;
      }

      // Permission check
      final permService = PermissionStateService.instance;
      if (!await permService.hasStorageOrPhotosPermission()) {
        final granted = await permService.requestStorageOrPhotos();
        if (!granted) {
          emit(state.copyWith(
            isLoading: false,
            error: 'Storage permission required',
          ));
          return;
        }
      }

      // Sort option for this folder
      final folderSortManager = FolderSortManager();
      final folderSortOption = await _safeCall(
        () => folderSortManager.getFolderSortOption(event.path),
      );
      final sortOption = folderSortOption ?? state.sortOption;

      // Collect entities with streaming + batch emission
      final List<Directory> folders = [];
      final List<File> files = [];
      final Map<String, FileStat> statsCache = {};
      const batchSize = 50;

      await for (final entity in directory.list()) {
        try {
          statsCache[entity.path] = await entity.stat();
        } catch (_) {}

        if (entity is Directory) {
          folders.add(entity);
        } else if (entity is File) {
          if (!_isSkippedFile(entity.path)) {
            files.add(entity);
          }
        }

        if ((folders.length + files.length) % batchSize == 0) {
          final sortedFolders = await FileSystemSorter.sortDirectories(
            folders,
            sortOption,
            fileStatsCache: statsCache,
          );
          final sortedFiles = await FileSystemSorter.sortFiles(
            files,
            sortOption,
            fileStatsCache: statsCache,
          );
          emit(state.copyWith(
            isLoading: true,
            folders: sortedFolders,
            files: sortedFiles,
            fileStatsCache: Map.from(statsCache),
            sortOption: sortOption,
          ));
        }
      }

      // Final sort
      final sortedFolders = await FileSystemSorter.sortDirectories(
        folders,
        sortOption,
        fileStatsCache: statsCache,
      );
      final sortedFiles = await FileSystemSorter.sortFiles(
        files,
        sortOption,
        fileStatsCache: statsCache,
      );

      emit(state.copyWith(
        isLoading: false,
        folders: sortedFolders,
        files: sortedFiles,
        fileStatsCache: Map.from(statsCache),
        sortOption: sortOption,
      ));

      AppLogger.perf('UI ready total=${totalSw.elapsedMilliseconds}ms');

      // Proactive thumbnail generation
      _prefetchThumbnails(sortedFiles, event.path);

      // Start directory watching
      await _directoryWatcher.startWatching(event.path);

      AppLogger.perf('Complete total=${totalSw.elapsedMilliseconds}ms');
    } catch (e) {
      _emitPermissionError(emit, e, event.path);
    }
  }

  Future<void> _onRefresh(
    FileNavigationRefresh event,
    Emitter<FileNavigationState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));

    if (_isDrivesPath(event.path) || event.path.startsWith('#')) {
      emit(state.copyWith(isLoading: false));
      return;
    }

    try {
      final directory = Directory(event.path);
      if (!await directory.exists()) {
        emit(state.copyWith(
          isLoading: false,
          error: 'Directory does not exist',
        ));
        return;
      }

      final contents = await directory.list().toList();
      final folderSortManager = FolderSortManager();
      final folderSortOption = await _safeCall(
        () => folderSortManager.getFolderSortOption(event.path),
      );
      final sortOption = folderSortOption ?? state.sortOption;

      final List<FileSystemEntity> folders = [];
      final List<FileSystemEntity> files = [];
      for (final entity in contents) {
        if (entity is Directory) {
          folders.add(entity);
        } else if (entity is File && !_isSkippedFile(entity.path)) {
          files.add(entity);
        }
      }

      final sortedFolders = await FileSystemSorter.sortDirectories(
        folders.cast<Directory>(),
        sortOption,
      );
      final sortedFiles = await FileSystemSorter.sortFiles(
        files.cast<File>(),
        sortOption,
      );

      emit(state.copyWith(
        isLoading: false,
        folders: sortedFolders,
        files: sortedFiles,
        currentPath: Directory(event.path),
        sortOption: sortOption,
        error: null,
      ));

      // Thumbnail prefetch
      if (event.forceRegenerateThumbnails) {
        VideoThumbnailHelper.regenerateThumbnailsForDirectory(event.path);
      } else {
        _prefetchThumbnails(sortedFiles, event.path);
      }
    } catch (e) {
      _emitPermissionError(emit, e, event.path);
    }
  }

  void _onReloadCurrentFolder(
    FileNavigationReloadCurrentFolder event,
    Emitter<FileNavigationState> emit,
  ) {
    if (state.currentPath.path.isNotEmpty) {
      add(FileNavigationRefresh(state.currentPath.path));
    }
  }

  void _onLoadDrives(
    FileNavigationLoadDrives event,
    Emitter<FileNavigationState> emit,
  ) {
    // Drives are loaded by DriveView's FutureBuilder
    // This event exists for consistent BLoC state management
  }

  // ─────────────────────────────────────────────────────────────
  // Filter & Sort handlers
  // ─────────────────────────────────────────────────────────────

  void _onFilter(
    FileNavigationFilter event,
    Emitter<FileNavigationState> emit,
  ) {
    if (event.fileType == null) {
      emit(state.copyWith(currentFilter: null, filteredFiles: []));
      return;
    }
    emit(state.copyWith(isLoading: true, currentFilter: event.fileType));
    final filtered = _filterFilesByType(state.files, event.fileType!);
    emit(state.copyWith(isLoading: false, filteredFiles: filtered));
  }

  Future<void> _onSetSortOption(
    FileNavigationSetSortOption event,
    Emitter<FileNavigationState> emit,
  ) async {
    final requestId = ++_activeSortRequestId;
    bool isStale() => isClosed || requestId != _activeSortRequestId;

    emit(state.copyWith(isLoading: true));

    try {
      final folderSortManager = FolderSortManager();
      await _safeCall(() => folderSortManager.saveFolderSortOption(
            state.currentPath.path,
            event.sortOption,
          ));

      if (isStale()) return;

      final targetPath = state.currentPath.path;
      Map<String, FileStat> statsCache = {};

      Future<void> cacheStats(List<FileSystemEntity> entities) async {
        for (final e in entities) {
          if (!statsCache.containsKey(e.path)) {
            try {
              statsCache[e.path] = await e.stat();
            } catch (_) {}
          }
        }
      }

      await Future.wait([
        cacheStats(state.folders),
        cacheStats(state.files),
        cacheStats(state.filteredFiles),
        cacheStats(state.searchResults),
      ]);
      if (isStale()) return;

      final cmp = _buildCompareFunction(event.sortOption, statsCache);

      List<FileSystemEntity> sortedFolders = List.from(state.folders)
        ..sort(cmp);
      List<FileSystemEntity> sortedFiles = List.from(state.files)..sort(cmp);
      List<FileSystemEntity> sortedFiltered = List.from(state.filteredFiles)
        ..sort(cmp);
      List<FileSystemEntity> sortedSearch = List.from(state.searchResults)
        ..sort(cmp);

      // Rebase if newer content arrived while sorting
      final hasNewerContent = state.currentPath.path == targetPath &&
          (state.folders.isNotEmpty || state.files.isNotEmpty) &&
          sortedFolders.isEmpty &&
          sortedFiles.isEmpty;
      if (hasNewerContent) {
        sortedFolders = List.from(state.folders)..sort(cmp);
        sortedFiles = List.from(state.files)..sort(cmp);
        sortedFiltered = List.from(state.filteredFiles)..sort(cmp);
        sortedSearch = List.from(state.searchResults)..sort(cmp);
        await Future.wait([
          cacheStats(sortedFolders),
          cacheStats(sortedFiles),
          cacheStats(sortedFiltered),
          cacheStats(sortedSearch),
        ]);
        if (isStale()) return;
        sortedFolders.sort(cmp);
        sortedFiles.sort(cmp);
        sortedFiltered.sort(cmp);
        sortedSearch.sort(cmp);
      }

      emit(state.copyWith(
        isLoading: false,
        sortOption: event.sortOption,
        folders: sortedFolders,
        files: sortedFiles,
        filteredFiles: sortedFiltered,
        searchResults: sortedSearch,
        fileStatsCache: statsCache,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Error sorting: ${e.toString()}',
      ));
    }
  }

  // ─────────────────────────────────────────────────────────────
  // View Mode handlers
  // ─────────────────────────────────────────────────────────────

  void _onSetViewMode(
    FileNavigationSetViewMode event,
    Emitter<FileNavigationState> emit,
  ) {
    emit(state.copyWith(viewMode: event.viewMode));
  }

  void _onSetGridZoom(
    FileNavigationSetGridZoom event,
    Emitter<FileNavigationState> emit,
  ) {
    emit(state.copyWith(gridZoomLevel: event.zoomLevel));
  }

  // ─────────────────────────────────────────────────────────────
  // Search handlers
  // ─────────────────────────────────────────────────────────────

  Future<void> _onSearchByFileName(
    FileNavigationSearchByFileName event,
    Emitter<FileNavigationState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));

    try {
      final query = event.query.toLowerCase();
      RegExp? regex;
      if (event.useRegex) {
        try {
          regex = RegExp(event.query, caseSensitive: false, unicode: true);
        } on FormatException catch (e) {
          emit(state.copyWith(
            isLoading: false,
            error: 'Invalid regex: ${e.message}',
          ));
          return;
        }
      }

      final List<FileSystemEntity> results = [];

      if (event.recursive) {
        await _recursiveSearch(
          Directory(state.currentPath.path),
          query,
          results,
          regex,
        );
      } else {
        for (final file in state.files) {
          if (_matchesQuery(pathlib.basename(file.path), query, regex)) {
            results.add(file);
          }
        }
        for (final folder in state.folders) {
          if (_matchesQuery(pathlib.basename(folder.path), query, regex)) {
            results.add(folder);
          }
        }
      }

      final grouped = <FileSystemEntity>[
        ...results.whereType<Directory>(),
        ...results.where((e) => e is! Directory && e is! File),
        ...results.whereType<File>(),
      ];

      emit(state.copyWith(
        isLoading: false,
        searchResults: grouped,
        currentSearchQuery: event.query,
        searchRecursive: event.recursive,
        isSearchByName: true,
        error: grouped.isEmpty ? 'No files found matching "$query"' : null,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Search error: ${e.toString()}',
      ));
    }
  }

  void _onClearSearchAndFilters(
    FileNavigationClearSearchAndFilters event,
    Emitter<FileNavigationState> emit,
  ) {
    _pendingSearchResults = [];
    emit(state.copyWith(
      currentSearchQuery: null,
      currentFilter: null,
      searchResults: [],
      filteredFiles: [],
      isSearchByName: false,
      searchRecursive: false,
      hasMoreSearchResults: false,
      isLoadingMoreSearchResults: false,
      searchResultsTotal: null,
      error: null,
    ));
  }

  void _onLoadMoreSearchResults(
    FileNavigationLoadMoreSearchResults event,
    Emitter<FileNavigationState> emit,
  ) {
    if (_pendingSearchResults.isEmpty) {
      emit(state.copyWith(
        hasMoreSearchResults: false,
        isLoadingMoreSearchResults: false,
      ));
      return;
    }
    if (state.isLoadingMoreSearchResults) return;

    emit(state.copyWith(isLoadingMoreSearchResults: true));

    final nextCount = _pendingSearchResults.length > _searchResultsPageSize
        ? _searchResultsPageSize
        : _pendingSearchResults.length;
    final nextChunk = _pendingSearchResults.take(nextCount).toList();
    _pendingSearchResults = _pendingSearchResults.skip(nextCount).toList();

    final currentResults = List<FileSystemEntity>.from(state.searchResults);
    for (final entity in nextChunk) {
      if (!currentResults.any((e) => e.path == entity.path)) {
        currentResults.add(entity);
      }
    }

    emit(state.copyWith(
      searchResults: currentResults,
      hasMoreSearchResults: _pendingSearchResults.isNotEmpty,
      isLoadingMoreSearchResults: false,
    ));
  }

  // ─────────────────────────────────────────────────────────────
  // Private helpers
  // ─────────────────────────────────────────────────────────────

  bool _isDrivesPath(String path) {
    return path.isEmpty ||
        path == '#drives' ||
        path.startsWith('#drives/') ||
        path == '#network' ||
        path == '#trash';
  }

  bool _isSkippedFile(String path) {
    return path.endsWith('.tags') ||
        pathlib.basename(path) == '.cbfile_config.json';
  }

  bool _matchesQuery(String name, String query, RegExp? regex) {
    return regex != null
        ? regex.hasMatch(name)
        : TextUtils.matchesVietnamese(name, query);
  }

  List<FileSystemEntity> _filterFilesByType(
    List<FileSystemEntity> files,
    String fileType,
  ) {
    return files.where((file) {
      if (file is File) {
        switch (fileType) {
          case 'image':
            return FileTypeUtils.isImageFile(file.path);
          case 'video':
            return FileTypeUtils.isVideoFile(file.path);
          case 'audio':
            return FileTypeUtils.isAudioFile(file.path);
          case 'document':
            return FileTypeUtils.isDocumentFile(file.path) ||
                FileTypeUtils.isSpreadsheetFile(file.path) ||
                FileTypeUtils.isPresentationFile(file.path);
          default:
            return true;
        }
      }
      return false;
    }).toList();
  }

  int Function(FileSystemEntity, FileSystemEntity) _buildCompareFunction(
    SortOption option,
    Map<String, FileStat> statsCache,
  ) {
    DateTime modifiedFor(FileSystemEntity entity) =>
        statsCache[entity.path]?.modified ??
        DateTime.fromMillisecondsSinceEpoch(0);

    DateTime changedFor(FileSystemEntity entity) =>
        statsCache[entity.path]?.changed ??
        DateTime.fromMillisecondsSinceEpoch(0);

    int sizeFor(FileSystemEntity entity) => statsCache[entity.path]?.size ?? -1;

    String attributesFor(FileSystemEntity entity) {
      final stat = statsCache[entity.path];
      if (stat == null) {
        return '';
      }
      return '${stat.mode},${stat.type}';
    }

    switch (option) {
      case SortOption.nameAsc:
        return (a, b) => pathlib
            .basename(a.path)
            .toLowerCase()
            .compareTo(pathlib.basename(b.path).toLowerCase());
      case SortOption.nameDesc:
        return (a, b) => pathlib
            .basename(b.path)
            .toLowerCase()
            .compareTo(pathlib.basename(a.path).toLowerCase());
      case SortOption.dateAsc:
        return (a, b) => modifiedFor(a).compareTo(modifiedFor(b));
      case SortOption.dateDesc:
        return (a, b) => modifiedFor(b).compareTo(modifiedFor(a));
      case SortOption.sizeAsc:
        return (a, b) => sizeFor(a).compareTo(sizeFor(b));
      case SortOption.sizeDesc:
        return (a, b) => sizeFor(b).compareTo(sizeFor(a));
      case SortOption.typeAsc:
      case SortOption.extensionAsc:
        return (a, b) => pathlib
            .extension(a.path)
            .toLowerCase()
            .compareTo(pathlib.extension(b.path).toLowerCase());
      case SortOption.typeDesc:
      case SortOption.extensionDesc:
        return (a, b) => pathlib
            .extension(b.path)
            .toLowerCase()
            .compareTo(pathlib.extension(a.path).toLowerCase());
      case SortOption.dateCreatedAsc:
        return (a, b) => changedFor(a).compareTo(changedFor(b));
      case SortOption.dateCreatedDesc:
        return (a, b) => changedFor(b).compareTo(changedFor(a));
      case SortOption.attributesAsc:
        return (a, b) => attributesFor(a).compareTo(attributesFor(b));
      case SortOption.attributesDesc:
        return (a, b) => attributesFor(b).compareTo(attributesFor(a));
    }
  }

  Future<void> _recursiveSearch(
    Directory dir,
    String query,
    List<FileSystemEntity> results,
    RegExp? regex,
  ) async {
    try {
      await for (final entity
          in dir.list(recursive: false, followLinks: false)) {
        try {
          final name = pathlib.basename(entity.path);
          if (_matchesQuery(name, query, regex)) {
            results.add(entity);
          }
          if (entity is Directory) {
            await _recursiveSearch(entity, query, results, regex);
          }
        } catch (_) {
          // Skip inaccessible entities
        }
      }
    } catch (_) {
      // Skip inaccessible directories
    }
  }

  void _prefetchThumbnails(List<FileSystemEntity> files, String dirPath) {
    if (dirPath.startsWith('#')) return;
    final videoPaths = files
        .whereType<File>()
        .where((f) => FileTypeUtils.isVideoFile(f.path))
        .map((f) => f.path)
        .toList();
    if (videoPaths.isEmpty) return;
    VideoThumbnailHelper.setCurrentDirectory(dirPath);
    VideoThumbnailHelper.proactiveGenerateAll(videoPaths,
        directoryPath: dirPath);
  }

  void _emitPermissionError(
    Emitter<FileNavigationState> emit,
    Object e,
    String path,
  ) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('permission denied') || msg.contains('access denied')) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Access denied. Try running as administrator.',
        folders: [],
        files: [],
      ));
    } else {
      emit(state.copyWith(
        isLoading: false,
        error: e.toString(),
        folders: [],
        files: [],
      ));
    }
  }

  Future<T?> _safeCall<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }
}
