import 'dart:async';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cb_file_manager/helpers/core/filesystem_sorter.dart';
import 'package:cb_file_manager/helpers/media/video_thumbnail_helper.dart';
import 'package:cb_file_manager/services/video_library_service.dart';
import 'package:cb_file_manager/services/video_library_cache_service.dart';
import 'package:cb_file_manager/utils/app_logger.dart';
import 'package:cb_file_manager/ui/utils/file_type_utils.dart';

import 'package:cb_file_manager/ui/screens/folder_list/bloc/file_navigation_event.dart';
import 'package:cb_file_manager/ui/screens/folder_list/bloc/file_navigation_state.dart';

/// A specialized FileNavigationBloc for video libraries.
/// Uses VideoLibraryService instead of Directory.list() to load files,
/// while keeping the same state shape and API as the parent bloc.
///
/// Usage:
/// ```dart
/// final bloc = VideoLibraryNavigationBloc(libraryId: 42);
/// bloc.loadLibrary(); // triggers loading
/// ```
class VideoLibraryNavigationBloc
    extends Bloc<FileNavigationEvent, FileNavigationState> {
  final VideoLibraryService _libraryService = VideoLibraryService();
  final VideoLibraryCacheService _cacheService =
      VideoLibraryCacheService.instance;
  final int libraryId;

  /// In-memory cache: libraryId → cached files list (mirrors disk cache).
  /// Used for fast in-session reuse. Disk cache is the source of truth.
  static final Map<int, List<File>> _memoryCache = {};

  VideoLibraryNavigationBloc({
    required this.libraryId,
    FileNavigationState? initialState,
  }) : super(initialState ??
            FileNavigationState.initial('#video-library/$libraryId')) {
    on<FileNavigationLoad>(_onLoad);
    on<FileNavigationRefresh>(_onRefresh);
    on<FileNavigationSetViewMode>(_onSetViewMode);
    on<FileNavigationSetGridZoom>(_onSetGridZoom);
    on<FileNavigationSetSortOption>(_onSetSortOption);
    on<FileNavigationFilter>(_onFilter);
    on<FileNavigationSearchByFileName>(_onSearchByFileName);
    on<FileNavigationClearSearchAndFilters>(_onClearSearchAndFilters);
  }

  /// Trigger loading of the library's files.
  void loadLibrary() {
    add(FileNavigationLoad(
      '#video-library/$libraryId',
      isVirtualPath: true,
    ));
  }

  /// Refresh the library's files — forces disk re-scan and clears disk cache.
  void refreshLibrary() {
    // Invalidate disk cache so we get fresh data
    _cacheService.invalidateLibrary(libraryId);
    add(FileNavigationRefresh(
      '#video-library/$libraryId',
      isVirtualPath: true,
    ));
  }

  /// Invalidate both memory and disk cache for a specific library.
  static Future<void> invalidateCache(int libraryId) async {
    _memoryCache.remove(libraryId);
    await VideoLibraryCacheService.instance.invalidateLibrary(libraryId);
  }

  /// Clear all cached library files from memory and disk.
  static Future<void> clearAllCache() async {
    _memoryCache.clear();
    await VideoLibraryCacheService.instance.clearAll();
  }

  // ── Event handlers ──────────────────────────────────────────────

  Future<void> _onLoad(
    FileNavigationLoad event,
    Emitter<FileNavigationState> emit,
  ) async {
    final totalSw = Stopwatch()..start();
    AppLogger.perf('Starting video library load libraryId=$libraryId');

    // 1. Check in-memory cache first (fastest)
    final memCached = _memoryCache[libraryId];
    if (memCached != null && memCached.isNotEmpty) {
      AppLogger.perf('Video library memory cache hit for libraryId=$libraryId');
      final sorted = await FileSystemSorter.sortFiles(
        memCached,
        state.sortOption,
      );
      emit(state.copyWith(
        isLoading: false,
        files: sorted,
        folders: const [],
        currentPath: Directory(event.path),
        error: null,
      ));
      _prefetchThumbnails(sorted, event.path);
      return;
    }

    // 2. Check disk cache
    final diskCached = await _cacheService.loadCachedFiles(libraryId);
    if (diskCached != null && diskCached.isNotEmpty) {
      AppLogger.perf('Video library disk cache hit for libraryId=$libraryId');
      final files = diskCached.map((p) => File(p)).toList();
      _memoryCache[libraryId] = files; // promote to memory
      final sorted = await FileSystemSorter.sortFiles(
        files,
        state.sortOption,
      );
      emit(state.copyWith(
        isLoading: false,
        files: sorted,
        folders: const [],
        currentPath: Directory(event.path),
        error: null,
      ));
      _prefetchThumbnails(sorted, event.path);
      return;
    }

    // 3. Cache miss — scan from disk
    emit(state.copyWith(
      isLoading: true,
      currentPath: Directory(event.path),
    ));

    try {
      // Stream files so UI updates progressively as each directory is scanned.
      // This mirrors FileNavigationBloc's await-for directory listing pattern.
      //
      // Adaptive batch sizing: emit early for responsiveness, then back off
      // to reduce sort overhead as the list grows.
      final List<File> files = [];
      int nextEmitAt = 50; // first batch at 50 for quick initial display

      await for (final path in _libraryService.streamLibraryFiles(libraryId)) {
        if (isClosed) return;

        files.add(File(path));

        // Emit progressive state at adaptive intervals
        if (files.length >= nextEmitAt) {
          final sorted = await FileSystemSorter.sortFiles(
            List<File>.from(files),
            state.sortOption,
          );

          emit(state.copyWith(
            isLoading: true,
            files: sorted,
            folders: const [],
          ));

          // Increase batch size as list grows: 50 → 200 → 500 → 1000
          if (files.length < 200) {
            nextEmitAt = files.length + 150;
          } else if (files.length < 1000) {
            nextEmitAt = files.length + 500;
          } else {
            nextEmitAt = files.length + 1000;
          }
        }
      }

      // Final sort
      final sortedFiles = await FileSystemSorter.sortFiles(
        files,
        state.sortOption,
      );

      if (isClosed) return;
      emit(state.copyWith(
        isLoading: false,
        files: sortedFiles,
        folders: const [],
        error: null,
      ));

      // Save to memory + disk cache for future re-opens
      _memoryCache[libraryId] = files;
      await _cacheService.saveFiles(
          libraryId, files.map((f) => f.path).toList());

      // Persist file count to config table so VideoHubScreen can show
      // cached counts instantly without a second filesystem scan.
      _libraryService.updateCachedLibraryVideoCount(libraryId, files.length);

      AppLogger.perf('UI ready total=${totalSw.elapsedMilliseconds}ms');

      // Thumbnail prefetch — same pattern as regular folders
      _prefetchThumbnails(sortedFiles, event.path);

      AppLogger.perf('Complete total=${totalSw.elapsedMilliseconds}ms');
    } catch (e) {
      AppLogger.error('VideoLibraryNavigationBloc._onLoad failed', error: e);
      emit(state.copyWith(
        isLoading: false,
        error: e.toString(),
      ));
    }
  }

  Future<void> _onRefresh(
    FileNavigationRefresh event,
    Emitter<FileNavigationState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));

    try {
      final List<File> files = [];
      int nextEmitAt = 50;

      await for (final path in _libraryService.streamLibraryFiles(libraryId)) {
        if (isClosed) return;

        files.add(File(path));

        // Emit progressive state at adaptive intervals
        if (files.length >= nextEmitAt) {
          final sorted = await FileSystemSorter.sortFiles(
            List<File>.from(files),
            state.sortOption,
          );

          emit(state.copyWith(
            isLoading: true,
            files: sorted,
            folders: const [],
          ));

          // Increase batch size as list grows
          if (files.length < 200) {
            nextEmitAt = files.length + 150;
          } else if (files.length < 1000) {
            nextEmitAt = files.length + 500;
          } else {
            nextEmitAt = files.length + 1000;
          }
        }
      }

      final sortedFiles = await FileSystemSorter.sortFiles(
        files,
        state.sortOption,
      );

      if (isClosed) return;
      emit(state.copyWith(
        isLoading: false,
        files: sortedFiles,
        folders: const [],
        error: null,
      ));

      // Save refreshed results and count for future fast loads.
      _memoryCache[libraryId] = files;
      await _cacheService.saveFiles(
          libraryId, files.map((f) => f.path).toList());
      _libraryService.updateCachedLibraryVideoCount(libraryId, files.length);

      // Thumbnail prefetch
      if (event.forceRegenerateThumbnails) {
        VideoThumbnailHelper.regenerateThumbnailsForDirectory(event.path);
      } else {
        _prefetchThumbnails(sortedFiles, event.path);
      }
    } catch (e) {
      AppLogger.error('VideoLibraryNavigationBloc._onRefresh failed', error: e);
      emit(state.copyWith(
        isLoading: false,
        error: e.toString(),
      ));
    }
  }

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

  void _onSetSortOption(
    FileNavigationSetSortOption event,
    Emitter<FileNavigationState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));

    final sortedFiles = await FileSystemSorter.sortFiles(
      state.files.cast<File>(),
      event.sortOption,
    );

    emit(state.copyWith(
      isLoading: false,
      files: sortedFiles,
      sortOption: event.sortOption,
    ));
  }

  void _onFilter(
    FileNavigationFilter event,
    Emitter<FileNavigationState> emit,
  ) {
    // For video libraries, we don't support filtering by type since
    // all files are already videos. Just emit current state.
    emit(state.copyWith(currentFilter: event.fileType));
  }

  void _onSearchByFileName(
    FileNavigationSearchByFileName event,
    Emitter<FileNavigationState> emit,
  ) {
    final query = event.query.toLowerCase();
    final results =
        state.files.where((f) => f.path.toLowerCase().contains(query)).toList();
    emit(state.copyWith(
      searchResults: results,
      currentSearchQuery: event.query,
      isSearchByName: true,
      searchRecursive: event.recursive,
    ));
  }

  void _onClearSearchAndFilters(
    FileNavigationClearSearchAndFilters event,
    Emitter<FileNavigationState> emit,
  ) {
    emit(state.copyWith(
      searchResults: const [],
      currentSearchQuery: null,
      currentFilter: null,
      isSearchByName: false,
    ));
  }

  void _prefetchThumbnails(List<FileSystemEntity> files, String dirPath) {
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
}
