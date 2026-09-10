import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart' as vlc;

/// Converts file paths and authenticated SMB URLs without losing escaping or
/// leaking credentials into the MRL exposed by the native player.
vlc.VlcMediaSource vlcMediaSource(String source) {
  final windowsPath =
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(source) || source.startsWith(r'\\');
  var uri = windowsPath ? Uri.file(source, windows: true) : Uri.parse(source);
  if (!uri.hasScheme) uri = Uri.file(source, windows: Platform.isWindows);
  final options = <String>[];
  if (uri.scheme == 'smb' && uri.userInfo.isNotEmpty) {
    final colon = uri.userInfo.indexOf(':');
    var user = Uri.decodeComponent(
      colon < 0 ? uri.userInfo : uri.userInfo.substring(0, colon),
    );
    final password = colon < 0
        ? null
        : Uri.decodeComponent(uri.userInfo.substring(colon + 1));
    final domainSeparator = user.indexOf(RegExp(r'[;\\]'));
    if (domainSeparator > 0) {
      options.add(':smb-domain=${user.substring(0, domainSeparator)}');
      user = user.substring(domainSeparator + 1);
    }
    if (user.isNotEmpty) options.add(':smb-user=$user');
    if (password != null) options.add(':smb-pwd=$password');
    uri = uri.replace(userInfo: '');
  }
  return vlc.VlcMediaSource(uri: uri, mediaOptions: options);
}

/// Shared VLC backend for the main player, PiP and frame picker. Commands issued
/// before Flutter mounts the native view are remembered, then applied once VLC
/// is attached/seekable. The UI can retain its existing stream-based controls.
class PlaybackPlayer {
  PlaybackPlayer({this.configuration = const PlaybackConfiguration()}) {
    stream = PlaybackStreams(_events.stream);
    _maintenance = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_flushPending());
    });
  }

  final PlaybackConfiguration configuration;
  final revision = ValueNotifier<int>(0);
  final _events = StreamController<vlc.VlcPlayerValue>.broadcast();
  late final PlaybackStreams stream;
  late final Timer _maintenance;
  vlc.VlcPlayerController? _controller;
  bool _hardwareAcceleration = false;
  bool _disposed = false;
  bool _flushing = false;
  double? _pendingVolume;
  double? _pendingRate;
  Duration? _pendingSeek;
  bool? _pendingPlaying;
  vlc.VlcMediaSource? _source;
  vlc.VlcPlayerValue _value = const vlc.VlcPlayerValue();

  PlaybackState get state => PlaybackState(_value);

  vlc.VlcPlayerController get controller {
    if (_disposed) throw StateError('VLC player has been disposed');
    return _controller ??= _createController();
  }

  vlc.VlcPlayerController _createController() {
    final native = vlc.VlcPlayerController(
      options: [
        '--no-video-title-show',
        '--no-snapshot-preview',
        if (!_hardwareAcceleration) '--avcodec-hw=none',
        '--network-caching=${configuration.networkCaching.inMilliseconds}',
      ],
    );
    native.addListener(() {
      if (_disposed || native != _controller) return;
      _value = native.value;
      _events.add(_value);
      unawaited(_flushPending());
    });
    return native;
  }

  void configureVideo(PlaybackVideoConfiguration config) {
    final enabled = config.enableHardwareAcceleration;
    if (enabled == _hardwareAcceleration) return;
    _hardwareAcceleration = enabled;
    final previous = _controller;
    if (previous == null) return;
    _pendingSeek = state.position;
    _pendingVolume = state.volume;
    _pendingRate = previous.value.playbackSpeed;
    _pendingPlaying = state.playing;
    _controller = null;
    previous.dispose();
    if (_source != null) {
      unawaited(_setSource(_source!, play: _pendingPlaying ?? false));
    }
    revision.value++;
  }

  Future<void> open(PlaybackMedia media, {bool play = true}) async {
    _pendingSeek = null;
    _value = const vlc.VlcPlayerValue();
    _events.add(_value);
    final source = vlcMediaSource(media.uri);
    _source = source;
    await _setSource(source, play: play);
  }

  Future<void> _setSource(vlc.VlcMediaSource source, {required bool play}) {
    _pendingPlaying = play;
    // VLC must decode the first frame even for the paused frame picker.
    final playable = vlc.VlcMediaSource(
      uri: source.uri,
      mediaOptions: [...source.mediaOptions, if (!play) ':start-paused'],
      startPosition: _pendingSeek ?? Duration.zero,
    );
    return controller.setPlaylist(
      [playable],
      autoPlay: true,
      loopMode: configuration.looping
          ? vlc.VlcPlaylistLoopMode.loopOne
          : vlc.VlcPlaylistLoopMode.none,
    );
  }

  Future<void> play() async {
    _pendingPlaying = true;
    await _flushPending();
  }

  Future<void> pause() async {
    _pendingPlaying = false;
    await _flushPending();
  }

  Future<void> playOrPause() => state.playing ? pause() : play();

  Future<void> seek(Duration position) async {
    _pendingSeek = position;
    await _flushPending();
  }

  Future<void> setVolume(double volume) async {
    _pendingVolume = volume.clamp(0, 100).toDouble();
    await _flushPending();
  }

  Future<void> setRate(double rate) async {
    _pendingRate = rate;
    await _flushPending();
  }

  Future<void> _flushPending() async {
    final native = _controller;
    if (_disposed || _flushing || native == null || !native.isAttached) return;
    _flushing = true;
    try {
      if (_pendingVolume case final volume?) {
        _pendingVolume = null;
        await native.setVolume(volume.round());
      }
      if (_disposed || native != _controller) return;
      if (_pendingRate case final rate?) {
        _pendingRate = null;
        await native.setPlaybackSpeed(rate);
      }
      if (_disposed || native != _controller) return;
      // libVLC can report seekable while still opening, before its initial
      // position reset. Seeking then is lost when playback becomes ready.
      if (native.value.isReady &&
          native.value.isSeekable &&
          _pendingSeek != null) {
        final seek = _pendingSeek!;
        _pendingSeek = null;
        await native.seekTo(seek);
      }
      if (_disposed || native != _controller) return;
      if (native.value.isReady && _pendingPlaying != null) {
        final playing = _pendingPlaying!;
        _pendingPlaying = null;
        if (playing && !native.value.isPlaying) await native.play();
        if (!playing && native.value.isPlaying) await native.pause();
      }
    } catch (error) {
      if (!_disposed && native == _controller) {
        _events.add(
          _value.copyWith(
            state: vlc.VlcPlaybackState.error,
            errorDescription: 'VLC playback command failed: $error',
          ),
        );
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> next() => controller.next();
  Future<void> previous() => controller.previous();
  Future<Uint8List?> screenshot() => controller.takeSnapshot();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _maintenance.cancel();
    _controller?.dispose();
    await _events.close();
    revision.dispose();
  }
}

class PlaybackConfiguration {
  const PlaybackConfiguration({
    this.networkCaching = const Duration(seconds: 1),
    this.looping = false,
  });

  final Duration networkCaching;
  final bool looping;
}

class PlaybackMedia {
  const PlaybackMedia(this.uri);
  final String uri;
}

class PlaybackState {
  const PlaybackState(this.value);
  final vlc.VlcPlayerValue value;
  bool get playing => value.isPlaying;
  double get volume => value.volume.toDouble();
  Duration get position => value.position;
  Duration get duration => value.duration;
  int? get width => value.videoSize?.width.round();
  int? get height => value.videoSize?.height.round();
}

class PlaybackStreams {
  const PlaybackStreams(this.values);
  final Stream<vlc.VlcPlayerValue> values;
  Stream<bool> get playing => values.map((v) => v.isPlaying).distinct();
  Stream<bool> get buffering => values.map((v) => v.isBuffering).distinct();
  Stream<double> get volume =>
      values.map((v) => v.volume.toDouble()).distinct();
  Stream<Duration> get position => values.map((v) => v.position).distinct();
  Stream<Duration> get duration => values.map((v) => v.duration).distinct();
  Stream<int?> get width =>
      values.map((v) => v.videoSize?.width.round()).distinct();
  Stream<int?> get height =>
      values.map((v) => v.videoSize?.height.round()).distinct();
  Stream<String> get error => values
      .where((v) => v.hasError)
      .map((v) => v.errorDescription ?? 'VLC could not play this media')
      .distinct();
}

class PlaybackVideoConfiguration {
  const PlaybackVideoConfiguration({this.enableHardwareAcceleration = false});
  final bool enableHardwareAcceleration;
}

class PlaybackVideoController {
  PlaybackVideoController(
    this.player, {
    PlaybackVideoConfiguration configuration =
        const PlaybackVideoConfiguration(),
  }) {
    player.configureVideo(configuration);
  }
  final PlaybackPlayer player;
}

class PlaybackVideo extends StatelessWidget {
  const PlaybackVideo({
    super.key,
    required this.controller,
    this.fill = Colors.black,
    this.fit = BoxFit.contain,
  });

  final PlaybackVideoController controller;
  final Color fill;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: controller.player.revision,
    builder: (context, revision, child) => vlc.VlcPlayer(
      controller: controller.player.controller,
      backgroundColor: fill,
      fit: switch (fit) {
        BoxFit.cover => vlc.VlcVideoFit.cover,
        BoxFit.fill => vlc.VlcVideoFit.fill,
        BoxFit.none => vlc.VlcVideoFit.none,
        _ => vlc.VlcVideoFit.contain,
      },
    ),
  );
}
