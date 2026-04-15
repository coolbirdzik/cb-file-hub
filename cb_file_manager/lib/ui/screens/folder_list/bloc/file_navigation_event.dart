import 'package:equatable/equatable.dart';
import 'package:cb_file_manager/ui/screens/folder_list/folder_list_state.dart';

/// Events for file navigation — browse, sort, filter, search, view mode
abstract class FileNavigationEvent extends Equatable {
  const FileNavigationEvent();

  @override
  List<Object?> get props => [];
}

// ─── Initialization ────────────────────────────────────────────────

class FileNavigationInit extends FileNavigationEvent {
  const FileNavigationInit();
}

class FileNavigationLoad extends FileNavigationEvent {
  final String path;

  const FileNavigationLoad(this.path);

  @override
  List<Object> get props => [path];
}

class FileNavigationRefresh extends FileNavigationEvent {
  final String path;
  final bool forceRegenerateThumbnails;

  const FileNavigationRefresh(this.path,
      {this.forceRegenerateThumbnails = false});

  @override
  List<Object> get props => [path, forceRegenerateThumbnails];
}

class FileNavigationReloadCurrentFolder extends FileNavigationEvent {
  const FileNavigationReloadCurrentFolder();
}

class FileNavigationLoadDrives extends FileNavigationEvent {
  const FileNavigationLoadDrives();
}

// ─── Filtering ─────────────────────────────────────────────────────

class FileNavigationFilter extends FileNavigationEvent {
  final String? fileType; // 'image', 'video', 'audio', 'document', null = clear

  const FileNavigationFilter(this.fileType);

  @override
  List<Object?> get props => [fileType];
}

// ─── Sorting ────────────────────────────────────────────────────────

class FileNavigationSetSortOption extends FileNavigationEvent {
  final SortOption sortOption;

  const FileNavigationSetSortOption(this.sortOption);

  @override
  List<Object> get props => [sortOption];
}

// ─── View Mode ─────────────────────────────────────────────────────

class FileNavigationSetViewMode extends FileNavigationEvent {
  final ViewMode viewMode;

  const FileNavigationSetViewMode(this.viewMode);

  @override
  List<Object> get props => [viewMode];
}

class FileNavigationSetGridZoom extends FileNavigationEvent {
  final int zoomLevel;

  const FileNavigationSetGridZoom(this.zoomLevel);

  @override
  List<Object> get props => [zoomLevel];
}

// ─── Search ────────────────────────────────────────────────────────

class FileNavigationSearchByFileName extends FileNavigationEvent {
  final String query;
  final bool recursive;
  final bool useRegex;

  const FileNavigationSearchByFileName(
    this.query, {
    this.recursive = false,
    this.useRegex = false,
  });

  @override
  List<Object> get props => [query, recursive, useRegex];
}

class FileNavigationClearSearchAndFilters extends FileNavigationEvent {
  const FileNavigationClearSearchAndFilters();
}

class FileNavigationLoadMoreSearchResults extends FileNavigationEvent {
  const FileNavigationLoadMoreSearchResults();
}
