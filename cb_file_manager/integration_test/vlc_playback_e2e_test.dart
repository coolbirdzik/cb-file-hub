import 'dart:io';
import 'dart:ui' as ui;

import 'package:cb_file_manager/services/media/vlc_playback.dart';
import 'package:cb_file_manager/ui/components/video/video_player/video_player.dart'
    as app;
import 'package:cb_file_manager/config/languages/app_localizations_delegate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart' as vlc;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(condition(), isTrue, reason: 'VLC did not reach the expected state');
  }

  final sample = File(
    '${Directory.current.path}/integration_test/samples/file_example_MP4_1920_18MG.mp4',
  ).absolute;

  Future<void> exercise(WidgetTester tester, String source) async {
    debugPrint('VLC test platform: $defaultTargetPlatform');
    final player = PlaybackPlayer();
    final errors = <String>[];
    final subscription = player.stream.error.listen(errors.add);
    var eventCount = 0;
    final diagnostics = player.stream.values.listen((value) {
      if (eventCount++ < 20 || value.hasError) {
        debugPrint(
          'VLC event: ${value.state}, position=${value.position}, duration=${value.duration}, volume=${value.volume}, seekable=${value.isSeekable}, size=${value.videoSize}, error=${value.errorDescription}',
        );
      }
    });
    final video = PlaybackVideoController(player);
    // These commands deliberately precede native view attachment, as they do
    // when opening the main player and restoring a PiP window.
    await player.open(PlaybackMedia(source), play: false);
    await player.setVolume(23);
    await player.seek(const Duration(seconds: 2));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlaybackVideo(controller: video)),
      ),
    );
    try {
      await waitFor(
        tester,
        () =>
            player.state.duration > Duration.zero &&
            player.state.position.inMilliseconds >= 1800,
      );
      await waitFor(
        tester,
        () => !player.state.playing && player.state.volume == 23,
      );
      expect(errors, isEmpty);
      await player.play();
      await waitFor(
        tester,
        () =>
            player.state.playing && player.state.position.inMilliseconds > 2500,
      );
      await player.pause();
      await waitFor(tester, () => !player.state.playing);
      await player.seek(const Duration(seconds: 5));
      await waitFor(
        tester,
        () => (player.state.position.inMilliseconds - 5000).abs() < 500,
      );
      final png = await player.screenshot();
      expect(png, isNotNull);
      final codec = await ui.instantiateImageCodec(png!);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(100));
      expect(frame.image.height, greaterThan(100));
      final pixels = await frame.image.toByteData();
      expect(pixels, isNotNull);
      // Reject a black/constant frame: snapshots must contain decoded video.
      expect(pixels!.buffer.asUint8List().toSet().length, greaterThan(16));
      frame.image.dispose();
      codec.dispose();
      // Reuse this player for another source without creating a second window.
      await player.open(PlaybackMedia(sample.path), play: true);
      await waitFor(
        tester,
        () =>
            player.state.playing && player.state.position.inMilliseconds > 500,
      );
      expect(errors, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
      await subscription.cancel();
      await diagnostics.cancel();
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets(
    'VLC local playback, paused preview, seek, volume, snapshot and reuse',
    (tester) async {
      expect(sample.existsSync(), isTrue);
      await exercise(tester, sample.path);
    },
  );

  testWidgets(
    'VLC streams and seeks through a real Windows SMB share',
    (tester) async {
      await exercise(tester, const String.fromEnvironment('CB_E2E_SMB_URL'));
    },
    skip:
        !Platform.isWindows ||
        const String.fromEnvironment('CB_E2E_SMB_URL').isEmpty,
  );

  testWidgets('main player retains VLC through buffering and source changes', (
    tester,
  ) async {
    final errors = <String>[];
    Widget host(Widget player) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('vi')],
      home: Scaffold(body: player),
    );
    await tester.pumpWidget(
      host(app.VideoPlayer.file(file: sample, onError: errors.add)),
    );
    await waitFor(
      tester,
      () => find.byType(vlc.VlcPlayer).evaluate().isNotEmpty,
    );
    final first = tester
        .widget<vlc.VlcPlayer>(find.byType(vlc.VlcPlayer))
        .controller;
    await waitFor(tester, () => first.value.position.inMilliseconds > 500);
    expect(
      tester.widget<vlc.VlcPlayer>(find.byType(vlc.VlcPlayer)).controller,
      same(first),
    );
    await tester.pumpWidget(
      host(
        app.VideoPlayer.url(
          streamingUrl: sample.uri.toString(),
          fileName: sample.uri.pathSegments.last,
          onError: errors.add,
        ),
      ),
    );
    await waitFor(
      tester,
      () => find.byType(vlc.VlcPlayer).evaluate().isNotEmpty,
    );
    final second = tester
        .widget<vlc.VlcPlayer>(find.byType(vlc.VlcPlayer))
        .controller;
    expect(second, isNot(same(first)));
    await waitFor(tester, () => second.value.position.inMilliseconds > 500);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'streamed video stays visible while seeking and controls auto-hide',
    (tester) async {
      final surfaceKey = GlobalKey();
      final errors = <String>[];
      const smbSource = String.fromEnvironment('CB_E2E_SMB_URL');
      final video = smbSource.isEmpty
          ? app.VideoPlayer.url(
              streamingUrl: sample.uri.toString(),
              fileName: 'seek-fixture.mp4',
              onError: errors.add,
            )
          : app.VideoPlayer.smb(
              smbMrl: smbSource,
              fileName: 'seek-fixture.mp4',
              onError: errors.add,
            );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('vi')],
          home: Scaffold(
            body: RepaintBoundary(key: surfaceKey, child: video),
          ),
        ),
      );
      try {
        await waitFor(
          tester,
          () => find.byType(vlc.VlcPlayer).evaluate().isNotEmpty,
        );
        final controller = tester
            .widget<vlc.VlcPlayer>(find.byType(vlc.VlcPlayer))
            .controller;
        await waitFor(
          tester,
          () => controller.value.position.inMilliseconds > 500,
        );
        Future<void> checkVisibleFrame(String label) async {
          debugPrint(
            'Checking $label: ${controller.value.state}, '
            '${controller.value.position}, size=${controller.value.videoSize}',
          );
          final boundary =
              surfaceKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          expect(
            boundary.size.width,
            greaterThan(100),
            reason: 'Video surface collapsed at $label',
          );
          expect(
            boundary.size.height,
            greaterThan(100),
            reason: 'Video surface collapsed at $label',
          );
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final pixels = (await image.toByteData())!.buffer.asUint8List();
            var visible = 0;
            var count = 0;
            // Sample only the middle half; controls and loading spinners must not
            // make a black video surface look like a successful decoded picture.
            for (var y = image.height ~/ 4; y < image.height * 3 ~/ 4; y += 7) {
              for (var x = image.width ~/ 4; x < image.width * 3 ~/ 4; x += 7) {
                final offset = (y * image.width + x) * 4;
                if (pixels[offset] + pixels[offset + 1] + pixels[offset + 2] >
                    45) {
                  visible++;
                }
                count++;
              }
            }
            expect(
              visible / count,
              greaterThan(0.1),
              reason: 'Black Flutter video surface at $label',
            );
            debugPrint('Visible video pixels at $label: ${visible / count}');
          } finally {
            image.dispose();
          }
        }

        await tester.pump(const Duration(milliseconds: 400));
        await checkVisibleFrame('before-seek');
        await tester.pump(const Duration(seconds: 4));
        await checkVisibleFrame('controls-hidden-before-seek');
        await tester.tap(find.byKey(surfaceKey));
        await tester.pump(const Duration(milliseconds: 350));
        final sliderFinder = find.byWidgetPredicate(
          (widget) => widget is Slider && widget.max > 1000,
        );
        expect(sliderFinder, findsOneWidget);
        for (final fraction in [0.75, 0.2, 0.6]) {
          final paused = fraction == 0.2;
          if (paused) {
            await controller.pause();
            await waitFor(tester, () => !controller.value.isPlaying);
          }
          final slider = tester.widget<Slider>(sliderFinder);
          final bounds = tester.getRect(sliderFinder);
          final start =
              bounds.left +
              24 +
              (bounds.width - 48) * slider.value / slider.max;
          final end = bounds.left + 24 + (bounds.width - 48) * fraction;
          final gesture = await tester.startGesture(
            Offset(start, bounds.center.dy),
          );
          for (var step = 1; step <= 18; step++) {
            await gesture.moveTo(
              Offset(start + (end - start) * step / 18, bounds.center.dy),
            );
            await tester.pump(const Duration(milliseconds: 25));
            if (step == 9 || step == 18) {
              // Keep the pointer down: a release-only seek must fail here.
              final requested = tester.widget<Slider>(sliderFinder).value;
              await waitFor(
                tester,
                () =>
                    (controller.value.position.inMilliseconds - requested)
                        .abs() <
                    1500,
              );
              await waitFor(tester, () => !controller.value.isPlaying);
              // Allow the last throttled preview to land, then hold still.
              // The picture must stay at this position until another move
              // or release, even if playback was active before the drag.
              await tester.pump(const Duration(milliseconds: 300));
              final heldPosition = controller.value.position;
              await tester.pump(const Duration(seconds: 1));
              expect(controller.value.isPlaying, isFalse);
              expect(
                (controller.value.position - heldPosition).inMilliseconds.abs(),
                lessThan(100),
                reason: 'Video advanced while holding the seek thumb still',
              );
              await checkVisibleFrame('drag-$fraction-step-$step');
            }
          }
          await gesture.up();
          final target = controller.value.duration.inMilliseconds * fraction;
          debugPrint(
            'Seek requested: $target; current: ${controller.value.position}',
          );
          await waitFor(
            tester,
            () =>
                controller.value.isPlaying == !paused &&
                (controller.value.position.inMilliseconds - target).abs() <
                    2000 + controller.value.duration.inMilliseconds * 0.02,
          );
          await tester.pump(const Duration(milliseconds: 700));
          await checkVisibleFrame('seek-${(fraction * 100).round()}');
          expect(
            tester.widget<vlc.VlcPlayer>(find.byType(vlc.VlcPlayer)).controller,
            same(controller),
          );
          if (paused) {
            await controller.play();
            await waitFor(tester, () => controller.value.isPlaying);
          }
          await tester.pump(const Duration(seconds: 4));
          await checkVisibleFrame('controls-hidden-after-seek');
          await tester.tap(find.byKey(surfaceKey));
          await tester.pump(const Duration(milliseconds: 350));
        }
        expect(errors, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
      }
    },
    skip: !Platform.isWindows,
  );
}
