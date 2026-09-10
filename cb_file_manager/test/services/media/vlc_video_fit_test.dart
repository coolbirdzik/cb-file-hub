import 'package:cb_file_manager/services/media/vlc_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart' as vlc;

void main() {
  testWidgets(
    'default video fit resizes to the viewport without crop or distortion',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var creations = 0;
      messenger.setMockMethodCallHandler(const MethodChannel('vlc_player'), (
        call,
      ) async {
        if (call.method == 'create') {
          creations++;
          return {'viewId': 1, 'textureId': 1};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('vlc_player/events/1'),
        (_) async => null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('vlc_player'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('vlc_player/events/1'),
          null,
        );
      });

      final player = PlaybackPlayer();
      final video = PlaybackVideoController(player);
      const viewportKey = ValueKey('viewport');
      Future<void> check(Size source, Size viewport, Size expected) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                key: viewportKey,
                width: viewport.width,
                height: viewport.height,
                child: PlaybackVideo(controller: video),
              ),
            ),
          ),
        );
        await tester.pump();
        player.controller.value = vlc.VlcPlayerValue(videoSize: source);
        await tester.pump();

        final bounds = tester.getRect(find.byKey(viewportKey));
        final rendered = tester.getRect(find.byType(Texture));
        expect(rendered.width, closeTo(expected.width, 0.01));
        expect(rendered.height, closeTo(expected.height, 0.01));
        expect(
          rendered.width / rendered.height,
          closeTo(source.aspectRatio, 0.001),
        );
        expect(rendered.center, bounds.center);
        expect(rendered.left, greaterThanOrEqualTo(bounds.left - 0.01));
        expect(rendered.top, greaterThanOrEqualTo(bounds.top - 0.01));
        expect(rendered.right, lessThanOrEqualTo(bounds.right + 0.01));
        expect(rendered.bottom, lessThanOrEqualTo(bounds.bottom + 0.01));
      }

      try {
        await check(
          const Size(320, 180),
          const Size(960, 540),
          const Size(960, 540),
        );
        await check(
          const Size(320, 180),
          const Size(900, 600),
          const Size(900, 506.25),
        );
        await check(
          const Size(360, 640),
          const Size(900, 600),
          const Size(337.5, 600),
        );
        await check(
          const Size(320, 180),
          const Size(160, 90),
          const Size(160, 90),
        );
        expect(
          creations,
          1,
          reason: 'Resizing must keep the native player alive',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
