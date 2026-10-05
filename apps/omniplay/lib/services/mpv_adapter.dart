import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:node_core/node_core.dart';

/// libmpv 播放内核（media_kit 封装）实现 node_core 的 [PlayerAdapter]。
/// 桌面与 Android 共用同一内核，格式能力（4K HDR/TrueHD/PGS）由 libmpv 保证（B5）。
class MpvPlayerAdapter implements PlayerAdapter {
  MpvPlayerAdapter(this._player) : videoController = VideoController(_player) {
    _player.stream.position.listen((d) => _update(positionMs: d.inMilliseconds));
    _player.stream.playing.listen((_) => _update());
    _player.stream.buffering.listen((_) => _update());
    _player.stream.duration.listen((d) {
      _ready = true;
      _update(durationMs: d.inMilliseconds);
      _applyPendingSeek();
    });
    _player.stream.completed.listen((completed) {
      if (completed) {
        _loaded = false;
        _update(state: PlaybackStateName.ended);
      }
    });
    _player.stream.tracks.listen((_) => _update());
    _player.stream.track.listen((_) => _update());
  }

  final Player _player;
  final VideoController videoController;

  final _controller = StreamController<PlayerSnapshot>.broadcast();
  final PlayerSnapshot _snapshot = PlayerSnapshot.idle();

  Timer? _throttle;
  bool _loaded = false;
  bool _ready = false;
  int _pendingSeekMs = -1;

  static const _native = MethodChannel('app.omniplay/native');

  @override
  Stream<PlayerSnapshot> get changes => _controller.stream;

  void _applyPendingSeek() {
    if (_ready && _pendingSeekMs >= 0) {
      final ms = _pendingSeekMs;
      _pendingSeekMs = -1;
      _player.seek(Duration(milliseconds: ms));
    }
  }

  void _update({
    PlaybackStateName? state,
    int? positionMs,
    int? durationMs,
    bool force = false,
  }) {
    if (positionMs != null) _snapshot.positionMs = positionMs;
    if (durationMs != null) _snapshot.durationMs = durationMs;
    if (state != null) _snapshot.state = state;

    _snapshot
      ..speed = _player.state.rate
      ..volume = _player.state.volume.round()
      ..title = _currentMediaTitle()
      ..audioTracks = _audioTrackRefs()
      ..subtitleTracks = _subtitleTrackRefs()
      ..currentAudio = _audioTrackIndex()
      ..currentSubtitle = _subtitleTrackIndex();

    // 未显式指定状态时按播放器实时状态推导。
    if (state == null) {
      if (!_loaded) {
        _snapshot.state = PlaybackStateName.idle;
      } else if (_player.state.buffering) {
        _snapshot.state = PlaybackStateName.buffering;
      } else if (_player.state.playing) {
        _snapshot.state = PlaybackStateName.playing;
      } else {
        _snapshot.state = PlaybackStateName.paused;
      }
    }

    _setKeepAwake(_snapshot.state == PlaybackStateName.playing);

    // 位置事件高频，节流到 300ms；其余立即推。
    if (!force && state == null && positionMs != null) {
      _throttle ??= Timer(const Duration(milliseconds: 300), () {
        _throttle = null;
        _emit();
      });
      return;
    }
    _emit();
  }

  String? _currentMediaTitle() {
    if (!_loaded || _player.state.playlist.medias.isEmpty) return null;
    final uri = _player.state.playlist.medias[_player.state.playlist.index].uri;
    return uri.split(Platform.pathSeparator).last;
  }

  List<TrackRef> _audioTrackRefs() => [
        for (var i = 0; i < _player.state.tracks.audio.length; i++)
          TrackRef(index: i, title: _label(_player.state.tracks.audio[i].title, _player.state.tracks.audio[i].language)),
      ];

  List<TrackRef> _subtitleTrackRefs() => [
        for (var i = 0; i < _player.state.tracks.subtitle.length; i++)
          TrackRef(index: i, title: _label(_player.state.tracks.subtitle[i].title, _player.state.tracks.subtitle[i].language)),
      ];

  int? _audioTrackIndex() {
    final currentId = _player.state.track.audio.id;
    final tracks = _player.state.tracks.audio;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].id == currentId) return i;
    }
    return null;
  }

  int? _subtitleTrackIndex() {
    final currentId = _player.state.track.subtitle.id;
    final tracks = _player.state.tracks.subtitle;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].id == currentId) return i;
    }
    return null;
  }

  String? _label(String? title, String? language) {
    if (title != null && title.isNotEmpty) return title;
    if (language != null && language.isNotEmpty) return language;
    return null;
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(PlayerSnapshot()
      ..state = _snapshot.state
      ..positionMs = _snapshot.positionMs
      ..durationMs = _snapshot.durationMs
      ..speed = _snapshot.speed
      ..volume = _snapshot.volume
      ..title = _snapshot.title
      ..source = _snapshot.source
      ..audioTracks = _snapshot.audioTracks
      ..subtitleTracks = _snapshot.subtitleTracks
      ..currentAudio = _snapshot.currentAudio
      ..currentSubtitle = _snapshot.currentSubtitle);
  }

  Future<void> _setKeepAwake(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _native.invokeMethod('setKeepAwake', active);
    } on PlatformException {
      // 忽略。
    }
  }

  @override
  Future<void> load({required String kind, required String value, String? title}) async {
    _loaded = false;
    _ready = false;
    _pendingSeekMs = -1;
    _update(state: PlaybackStateName.buffering, positionMs: 0, durationMs: 0, force: true);
    await _player.open(Media(value), play: true);
    _loaded = true;
    _snapshot.source = value;
    _update(force: true);
  }

  @override
  Future<void> play() => _player.play().then((_) => _update(force: true));

  @override
  Future<void> pause() => _player.pause().then((_) => _update(force: true));

  @override
  Future<void> stop() async {
    await _player.stop();
    _loaded = false;
    _update(state: PlaybackStateName.idle, positionMs: 0, force: true);
  }

  @override
  Future<void> seekMs(int ms) async {
    if (_ready) {
      await _player.seek(Duration(milliseconds: ms));
    } else {
      _pendingSeekMs = ms; // 媒体未就绪（自动续播场景），等 duration 事件后执行。
    }
    _update(positionMs: ms, force: true);
  }

  @override
  Future<void> setVolume(int volume) =>
      _player.setVolume(volume.toDouble()).then((_) => _update(force: true));

  @override
  Future<void> setSpeed(double rate) =>
      _player.setRate(rate).then((_) => _update(force: true));

  @override
  Future<void> selectTrack({required String kind, required int index}) async {
    if (kind == 'audio') {
      final tracks = _player.state.tracks.audio;
      if (index >= 0 && index < tracks.length) await _player.setAudioTrack(tracks[index]);
    } else {
      final tracks = _player.state.tracks.subtitle;
      if (index >= 0 && index < tracks.length) await _player.setSubtitleTrack(tracks[index]);
    }
    _update(force: true);
  }

  @override
  Future<void> dispose() async {
    _throttle?.cancel();
    await _controller.close();
    await _player.dispose();
  }
}
