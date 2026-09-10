import 'dart:async';
import 'package:cb_file_manager/ui/components/common/grid_list_collection.dart';
import 'package:cb_file_manager/ui/screens/folder_list/folder_list_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'restores saved choice when reopening and excludes other modes',
    () async {
      var saved = ViewMode.details;
      GridListViewController create() => GridListViewController(
        load: () async => saved,
        save: (mode) async {
          saved = mode;
        },
      );
      final first = create();
      await first.initialize();
      expect(first.mode, ViewMode.grid);
      await first.select(ViewMode.list);
      first.dispose();
      final reopened = create();
      await reopened.initialize();
      expect(reopened.mode, ViewMode.list);
      reopened.dispose();
    },
  );

  test('late restore cannot overwrite a user switch', () async {
    final restoring = Completer<ViewMode>();
    final controller = GridListViewController(load: () => restoring.future);
    final loaded = controller.initialize();
    await controller.select(ViewMode.list);
    restoring.complete(ViewMode.grid);
    await loaded;
    expect(controller.mode, ViewMode.list);
    controller.dispose();
  });

  test('rapid switches save in order', () async {
    final firstWrite = Completer<void>();
    final saved = <ViewMode>[];
    final controller = GridListViewController(
      save: (mode) async {
        if (saved.isEmpty) await firstWrite.future;
        saved.add(mode);
      },
    );
    final first = controller.select(ViewMode.list);
    final second = controller.select(ViewMode.grid);
    expect(controller.mode, ViewMode.grid);
    firstWrite.complete();
    await Future.wait([first, second]);
    expect(saved, [ViewMode.list, ViewMode.grid]);
    controller.dispose();
  });
}
