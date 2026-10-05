import 'dart:async';
import 'dart:io';

import 'package:node_protocol/src/messages.dart';

/// 播放内核适配器接口：node_core 不关心底层是 media_kit(libmpv)、假播放器还是未来的其他内核。
/// 平台实现位于 Flutter 侧（apps/omniplay），无头节点/测试用 [FakePlayerAdapter]。
abstract class PlayerAdapter {
  /// 每次状态变化都推送**全量快照**（简化消费端；频率已由实现节流）。
  Stream<PlayerSnapshot> get changes;

  /// kind: 'file'（本地路径）| 'url'（http(s) 流地址）。
  Future<void> load({required String kind, required String value, String? title});

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekMs(int ms);
  Future<void> setVolume(int volume); // 0-100
  Future<void> setSpeed(double rate);
  Future<void> selectTrack({required String kind, required int index}); // kind: audio|subtitle

  Future<void> dispose();
}

/// 播放快照（与会话广播的 player.evt.state 一一对应）。
class PlayerSnapshot {
  PlayerSnapshot({
    this.state = PlaybackStateName.idle,
    this.positionMs = 0,
    this.durationMs = 0,
    this.speed = 1.0,
    this.volume = 100,
    this.title,
    this.source,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.currentAudio,
    this.currentSubtitle,
  });

  PlaybackStateName state;
  int positionMs;
  int durationMs;
  double speed;
  int volume;
  String? title;
  String? source;
  List<TrackRef> audioTracks;
  List<TrackRef> subtitleTracks;
  int? currentAudio;
  int? currentSubtitle;

  PlayerSnapshot.idle() : this();

  PlayerStatePayload toPayload({required int epoch, String? controllerId, String? controllerName}) =>
      PlayerStatePayload(
        epoch: epoch,
        controllerId: controllerId,
        controllerName: controllerName,
        state: state,
        positionMs: positionMs,
        durationMs: durationMs,
        speed: speed,
        volume: volume,
        title: title,
        source: source,
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        currentAudio: currentAudio,
        currentSubtitle: currentSubtitle,
      );
}

/// 假播放器：用于测试与无头节点。模拟时长 10 分钟的媒体，播放时每秒推进。
class FakePlayerAdapter implements PlayerAdapter {
  final _controller = StreamController<PlayerSnapshot>.broadcast();
  final PlayerSnapshot _snapshot = PlayerSnapshot.idle();
  Timer? _ticker;

  static const int _fakeDurationMs = 10 * 60 * 1000;

  @override
  Stream<PlayerSnapshot> get changes => _controller.stream;

  void _emit() {
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

  void _startTickerIfPlaying() {
    _ticker?.cancel();
    if (_snapshot.state == PlaybackStateName.playing) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_snapshot.state != PlaybackStateName.playing) return;
        _snapshot.positionMs += (_snapshot.speed * 1000).round();
        if (_snapshot.positionMs >= _snapshot.durationMs) {
          _snapshot.positionMs = _snapshot.durationMs;
          _snapshot.state = PlaybackStateName.ended;
          _ticker?.cancel();
        }
        _emit();
      });
    }
  }

  @override
  Future<void> load({required String kind, required String value, String? title}) async {
    _ticker?.cancel();
    _snapshot
      ..source = value
      ..title = title ?? value.split(Platform.pathSeparator).last
      ..durationMs = _fakeDurationMs
      ..positionMs = 0
      ..state = PlaybackStateName.playing
      ..audioTracks = [TrackRef(index: 0, title: '默认音轨')]
      ..subtitleTracks = []
      ..currentAudio = 0
      ..currentSubtitle = null;
    _startTickerIfPlaying();
    _emit();
  }

  @override
  Future<void> play() async {
    if (_snapshot.state == PlaybackStateName.paused) {
      _snapshot.state = PlaybackStateName.playing;
      _startTickerIfPlaying();
      _emit();
    }
  }

  @override
  Future<void> pause() async {
    if (_snapshot.state == PlaybackStateName.playing) {
      _snapshot.state = PlaybackStateName.paused;
      _ticker?.cancel();
      _emit();
    }
  }

  @override
  Future<void> stop() async {
    _ticker?.cancel();
    _snapshot
      ..state = PlaybackStateName.idle
      ..positionMs = 0
      ..source = null
      ..title = null;
    _emit();
  }

  @override
  Future<void> seekMs(int ms) async {
    _snapshot.positionMs = ms.clamp(0, _snapshot.durationMs);
    _emit();
  }

  @override
  Future<void> setVolume(int volume) async {
    _snapshot.volume = volume.clamp(0, 100);
    _emit();
  }

  @override
  Future<void> setSpeed(double rate) async {
    _snapshot.speed = rate;
    _startTickerIfPlaying();
    _emit();
  }

  @override
  Future<void> selectTrack({required String kind, required int index}) async {
    if (kind == 'audio') {
      _snapshot.currentAudio = index;
    } else if (kind == 'subtitle') {
      _snapshot.currentSubtitle = index;
    }
    _emit();
  }

  @override
  Future<void> dispose() async {
    _ticker?.cancel();
    await _controller.close();
  }
}
