import 'dart:io';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cb_file_manager/helpers/files/trash_manager.dart';
import 'package:cb_file_manager/helpers/core/filesystem_utils.dart'
    show FileOperations;
import 'package:cb_file_manager/ui/controllers/operation_progress_controller.dart';
import 'package:cb_file_manager/ui/screens/folder_list/bloc/file_navigation_bloc.dart';
import 'package:cb_file_manager/ui/screens/folder_list/bloc/file_navigation_event.dart';
import 'package:cb_file_manager/utils/app_logger.dart';

import 'file_operations_event.dart';

/// Holds current clipboard state for the file operations layer.
class FileOperationsState extends Equatable {
  final int clipboardRevision;
  final String? error;
  final bool isProcessing;

  const FileOperationsState({
    this.clipboardRevision = 0,
    this.error,
    this.isProcessing = false,
  });

  FileOperationsState copyWith({
    int? clipboardRevision,
    Object? error,
    bool? isProcessing,
  }) {
    return FileOperationsState(
      clipboardRevision: clipboardRevision ?? this.clipboardRevision,
      error: error is String ? error : (error == _unset ? null : this.error),
      isProcessing: isProcessing ?? this.isProcessing,
    );
  }

  static const _unset = Object();

  @override
  List<Object?> get props => [clipboardRevision, error, isProcessing];
}

class FileOperationsBloc
    extends Bloc<FileOperationsEvent, FileOperationsState> {
  final FileNavigationBloc navigationBloc;
  final OperationProgressController _progressController;

  FileOperationsBloc({
    required this.navigationBloc,
    required OperationProgressController progressController,
  })  : _progressController = progressController,
        super(const FileOperationsState()) {
    on<FileOperationsCopy>(_onCopy);
    on<FileOperationsCut>(_onCut);
    on<FileOperationsPaste>(_onPaste);
    on<FileOperationsDeleteFiles>(_onDeleteFiles);
    on<FileOperationsDeleteItems>(_onDeleteItems);
    on<FileOperationsRename>(_onRename);
    on<FileOperationsClearClipboard>(_onClearClipboard);
  }

  void _onCopy(
    FileOperationsCopy event,
    Emitter<FileOperationsState> emit,
  ) {
    try {
      FileOperations().copyFilesToClipboard(event.entities);
      emit(state.copyWith(
        error: null,
        clipboardRevision: state.clipboardRevision + 1,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Error copying: ${e.toString()}'));
    }
  }

  void _onCut(
    FileOperationsCut event,
    Emitter<FileOperationsState> emit,
  ) {
    try {
      FileOperations().cutFilesToClipboard(event.entities);
      emit(state.copyWith(
        error: null,
        clipboardRevision: state.clipboardRevision + 1,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Error cutting: ${e.toString()}'));
    }
  }

  Future<void> _onPaste(
    FileOperationsPaste event,
    Emitter<FileOperationsState> emit,
  ) async {
    if (!FileOperations().hasClipboardItem) {
      emit(state.copyWith(error: 'Nothing to paste — clipboard is empty'));
      return;
    }

    emit(state.copyWith(isProcessing: true));

    final isCut = FileOperations().isCutOperation;
    final itemCount = FileOperations().clipboardItemCount;
    final opType = isCut ? 'Moving' : 'Copying';

    final progressId = _progressController.begin(
      title: '$opType $itemCount item${itemCount > 1 ? 's' : ''}...',
      total: itemCount,
    );

    try {
      await FileOperations().pasteFromClipboard(
        event.destinationPath,
        onProgress: (completed, total) {
          _progressController.update(
            progressId,
            completed: completed,
            detail: '$opType file $completed of $total',
          );
        },
      );

      _progressController.succeed(
        progressId,
        detail:
            '${isCut ? 'Moved' : 'Copied'} $itemCount item${itemCount > 1 ? 's' : ''}',
      );

      emit(state.copyWith(
        isProcessing: false,
        clipboardRevision: state.clipboardRevision + 1,
      ));

      // Refresh the navigation bloc
      final navState = navigationBloc.state;
      navigationBloc.add(
        FileNavigationRefresh(navState.currentPath.path),
      );
    } catch (e) {
      _progressController.fail(progressId, detail: 'Error: ${e.toString()}');
      emit(state.copyWith(
        isProcessing: false,
        error: 'Error pasting: ${e.toString()}',
      ));
    }
  }

  Future<void> _onDeleteFiles(
    FileOperationsDeleteFiles event,
    Emitter<FileOperationsState> emit,
  ) async {
    final targetPaths = event.filePaths.toSet();
    if (targetPaths.isEmpty) return;

    final progressId = _progressController.begin(
      title:
          'Deleting ${event.filePaths.length} file${event.filePaths.length > 1 ? 's' : ''}',
      total: event.filePaths.length,
      showModal: true,
    );

    final trashManager = TrashManager();
    int completed = 0;
    final List<String> failed = [];

    for (final filePath in event.filePaths) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          if (event.permanent) {
            await file.delete();
          } else {
            await trashManager.moveToTrash(filePath);
          }
        }
        completed++;
        _progressController.update(progressId, completed: completed);
      } catch (e) {
        failed.add(filePath);
        AppLogger.warning('Delete failed for $filePath: $e');
      }
    }

    if (failed.isNotEmpty) {
      _progressController.fail(
        progressId,
        detail:
            'Failed to delete ${failed.length} item${failed.length > 1 ? 's' : ''}',
      );
      emit(state.copyWith(
        error:
            'Failed to delete ${failed.length} item${failed.length > 1 ? 's' : ''}',
      ));
    } else {
      _progressController.succeed(progressId, detail: 'Done');
      emit(state.copyWith(error: null));
    }

    // Refresh
    final navState = navigationBloc.state;
    navigationBloc.add(FileNavigationRefresh(navState.currentPath.path));
  }

  Future<void> _onDeleteItems(
    FileOperationsDeleteItems event,
    Emitter<FileOperationsState> emit,
  ) async {
    final Set<String> targets = {...event.filePaths, ...event.folderPaths};
    if (targets.isEmpty) return;

    final total = event.filePaths.length + event.folderPaths.length;
    final title = event.permanent
        ? 'Deleting $total items'
        : 'Moving $total items to trash';

    final progressId = _progressController.begin(
      title: title,
      total: total,
      showModal: true,
    );

    final trashManager = TrashManager();
    int completed = 0;
    final List<String> failed = [];

    for (final path in event.filePaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          if (event.permanent) {
            await file.delete();
          } else {
            await trashManager.moveToTrash(path);
          }
        }
        completed++;
        _progressController.update(progressId, completed: completed);
      } catch (e) {
        failed.add(path);
        AppLogger.warning('Delete failed for $path: $e');
      }
    }

    for (final path in event.folderPaths) {
      try {
        final dir = Directory(path);
        if (await dir.exists()) {
          if (event.permanent) {
            await dir.delete(recursive: true);
          } else {
            await trashManager.moveToTrash(path);
          }
        }
        completed++;
        _progressController.update(progressId, completed: completed);
      } catch (e) {
        failed.add(path);
        AppLogger.warning('Delete failed for $path: $e');
      }
    }

    if (failed.isNotEmpty) {
      _progressController.fail(
        progressId,
        detail:
            'Failed to delete ${failed.length} item${failed.length > 1 ? 's' : ''}',
      );
      emit(state.copyWith(
        error:
            'Failed to delete ${failed.length} item${failed.length > 1 ? 's' : ''}',
      ));
    } else {
      _progressController.succeed(progressId, detail: 'Done');
      emit(state.copyWith(error: null));
    }

    final navState = navigationBloc.state;
    navigationBloc.add(FileNavigationRefresh(navState.currentPath.path));
  }

  Future<void> _onRename(
    FileOperationsRename event,
    Emitter<FileOperationsState> emit,
  ) async {
    try {
      await FileOperations().rename(event.entity, event.newName);
      emit(state.copyWith(error: null));

      // Refresh navigation bloc
      final navState = navigationBloc.state;
      navigationBloc.add(FileNavigationRefresh(navState.currentPath.path));
    } catch (e) {
      emit(state.copyWith(error: 'Error renaming: ${e.toString()}'));
    }
  }

  void _onClearClipboard(
    FileOperationsClearClipboard event,
    Emitter<FileOperationsState> emit,
  ) {
    FileOperations().clearClipboard();
    emit(state.copyWith(clipboardRevision: state.clipboardRevision + 1));
  }
}
