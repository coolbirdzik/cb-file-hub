import 'package:cb_file_manager/ui/components/common/grid_list_collection.dart';
import 'package:cb_file_manager/ui/widgets/adaptive_file_list.dart';
import 'package:cb_file_manager/design_system/cb_design_system.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:cb_file_manager/services/ssh/ssh_profile_store.dart';
import 'package:cb_file_manager/ui/screens/ssh/ssh_workspace_screen.dart';
import 'package:cb_file_manager/ui/screens/ssh/ssh_host_list_item.dart';
import 'package:cb_file_manager/ui/screens/ssh/ssh_host_dialog.dart';
import 'package:cb_file_manager/ui/tab_manager/core/tab_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'network_recovery_test.dart' show host;
import 'ssh_connection_dialog_test.dart' show FixtureSshDiscovery;
import 'package:cb_file_manager/services/ssh/local_ssh_discovery.dart';

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CB_SSH_CAPTURE')) return;
    for (final entry in {
      'Inter': 'assets/fonts/Inter-Regular.ttf',
      'Segoe UI': 'assets/fonts/Inter-Regular.ttf',
      'packages/phosphor_flutter/PhosphorLight':
          'third_party/phosphor_flutter/lib/fonts/Phosphor-Light.ttf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(
          entry.value,
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  for (final language in ['en', 'vi']) {
    for (final width in [320.0, 1200.0]) {
      for (final sftp in [false, true]) {
        testWidgets(
          'SSH workspace $language $width sftp=$sftp keeps controls accessible',
          (tester) async {
            tester.view.physicalSize = Size(width, 650);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final store = SshProfileStore();
            final key = SshStoredKey.generate('Work key');
            await store.saveKey(key);
            await store.saveProfile(
              SshProfile(
                id: 'fixture',
                name: 'Development server',
                host: 'dev.example.test',
                username: 'developer',
                port: 2222,
                group: 'Development',
                keyId: key.id,
              ),
            );
            final tabs = TabManagerBloc();
            addTearDown(tabs.close);
            final change = tabs.stream.first;
            tabs.add(AddTab(path: sftp ? '#sftp' : '#ssh'));
            await change;
            final capture = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: BlocProvider.value(
                  value: tabs,
                  child: host(
                    SshWorkspaceScreen(
                      tabId: tabs.state.activeTabId!,
                      sftpOnly: sftp,
                      store: store,
                      viewController: GridListViewController(),
                      discovery: FixtureSshDiscovery(
                        Future.value(const LocalSshSnapshot()),
                      ),
                    ),
                    vietnamese: language == 'vi',
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('Development server'), findsOneWidget);
            if (const bool.fromEnvironment('CB_SSH_CAPTURE') &&
                language == 'en' &&
                width == 1200 &&
                !sftp) {
              await tester.runAsync(() async {
                final boundary =
                    capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/network-layout-review/ssh-workspace.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
            }
            final beforeSelection = tester.getTopLeft(
              find.text('Development server'),
            );
            await tester.tap(find.text('Development server'));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<SshHostListItem>(
                    find.byKey(const ValueKey('fixture')),
                  )
                  .isSelected,
              isTrue,
            );
            expect(
              tester.getTopLeft(find.text('Development server')),
              beforeSelection,
              reason:
                  'Selecting must not shift the target between double clicks',
            );
            await tester.tapAt(Offset(width - 16, 620));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<SshHostListItem>(
                    find.byKey(const ValueKey('fixture')),
                  )
                  .isSelected,
              isFalse,
            );
            expect(find.byType(PopupMenuButton<void>), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey('collection-view-list')),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('grid-list-collection-list')),
              findsOneWidget,
            );
            expect(find.byType(AdaptiveFileList), findsOneWidget);
            expect(find.text('Development server'), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey('collection-view-grid')),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('grid-list-collection-grid')),
              findsOneWidget,
            );
            expect(find.byType(AdaptiveFileList), findsNothing);
            expect(find.byType(GridView), findsOneWidget);
            expect(find.byType(CbSurface), findsOneWidget);
            expect(find.text('Development server'), findsOneWidget);
            expect(tester.takeException(), isNull);
            if (!sftp) {
              await tester.tap(
                find.widgetWithText(
                  ChoiceChip,
                  language == 'vi' ? 'SSH key' : 'SSH keys',
                ),
              );
              await tester.pumpAndSettle();
              expect(find.text('Work key'), findsOneWidget);
              expect(tester.takeException(), isNull);
              await tester.tap(
                find.widgetWithText(
                  ChoiceChip,
                  language == 'vi' ? 'Máy chủ đã tin cậy' : 'Trusted hosts',
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
          },
        );
      }
    }
  }
  testWidgets(
    'unsaved config hosts stay out of Hosts while local keys remain available',
    (tester) async {
      final store = SshProfileStore();
      final tabs = TabManagerBloc();
      addTearDown(tabs.close);
      final change = tabs.stream.first;
      tabs.add(AddTab(path: '#ssh'));
      await change;
      final discovery = FixtureSshDiscovery(
        Future.value(
          const LocalSshSnapshot(
            hosts: [
              LocalSshHost(
                alias: 'Local dev',
                host: 'dev.example.test',
                username: 'developer',
              ),
            ],
            keys: [LocalSshKey('/fixture/dev_key')],
          ),
        ),
      );
      await tester.pumpWidget(
        BlocProvider.value(
          value: tabs,
          child: host(
            SshWorkspaceScreen(
              tabId: tabs.state.activeTabId!,
              store: store,
              discovery: discovery,
              viewController: GridListViewController(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Local dev'), findsNothing);
      expect(
        find.widgetWithText(CbButton, 'Import private key'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'SSH keys'));
      await tester.pumpAndSettle();
      expect(find.text('dev_key'), findsOneWidget);
      expect(store.keys, isEmpty);
      expect(store.profiles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown or changed SSH fingerprint requires an explicit decision',
    (tester) async {
      bool? result;
      await tester.pumpWidget(
        host(
          Material(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await promptSshHostTrust(
                    context,
                    'localhost',
                    2222,
                    'ssh-ed25519',
                    'SHA256:new',
                    'SHA256:previous',
                  );
                },
                child: const Text('Verify'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();
      expect(find.text('SSH host key changed'), findsOneWidget);
      expect(find.text('SHA256:new'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    },
  );
}
