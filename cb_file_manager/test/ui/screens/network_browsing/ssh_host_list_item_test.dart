import 'package:cb_file_manager/ui/screens/ssh/ssh_host_list_item.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host click selects, double click and Enter open, menu edits', (
    tester,
  ) async {
    var selected = 0;
    var opened = 0;
    var openedInNewTab = 0;
    var edited = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 270,
            height: 40,
            child: SshHostListItem(
              name: 'Development server',
              description: 'developer@dev.example.test:2222',
              isDesktop: true,
              isSelected: false,
              onSelect: () => selected++,
              onOpen: () => opened++,
              onOpenInNewTab: () => openedInNewTab++,
              onBrowse: () {},
              menuTooltip: 'More options',
              terminalTooltip: 'Open terminal',
              browseTooltip: 'Browse SFTP',
              menuBuilder: (_) => [
                PopupMenuItem<void>(
                  onTap: () => edited++,
                  child: const Text('Edit'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Development server'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, 1);
    expect(opened, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, 1);
    await tester.tap(find.text('Development server'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('Development server'));
    expect(opened, 2);
    await tester.tap(
      find.text('Development server'),
      buttons: kMiddleMouseButton,
    );
    expect(openedInNewTab, 1);
    expect(
      tester
          .widget<PopupMenuButton<void>>(find.byType(PopupMenuButton<void>))
          .popUpAnimationStyle,
      AnimationStyle.noAnimation,
    );
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(edited, 1);
    expect(tester.takeException(), isNull);
  });
}
