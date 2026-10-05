import 'package:node_protocol/src/envelope.dart';
import 'package:node_protocol/src/messages.dart';
import 'package:test/test.dart';

void main() {
  test('封套 JSON roundtrip', () {
    final msg = Msg(
      type: MsgTypes.playerSeek,
      id: 'abc',
      ts: '000000000000001.000000.n1',
      from: 'controller-1',
      payload: {'positionMs': 42000},
    );
    final decoded = Msg.fromJson(msg.toJson());
    expect(decoded.type, msg.type);
    expect(decoded.id, msg.id);
    expect(decoded.ts, msg.ts);
    expect(decoded.from, msg.from);
    expect(decoded.p<int>('positionMs'), 42000);
  });

  test('坏消息被拒（缺字段 / 版本过高）', () {
    expect(() => Msg.fromJson({'type': 'x'}), throwsFormatException);
    expect(() => Msg.fromJson({'v': 99, 'type': 'x', 'ts': 't', 'from': 'f'}),
        throwsFormatException);
  });

  test('PlayerStatePayload roundtrip 保留轨道与接管信息', () {
    final payload = PlayerStatePayload(
      epoch: 3,
      controllerId: 'dev-1',
      controllerName: '手机',
      state: PlaybackStateName.playing,
      positionMs: 1234,
      durationMs: 5678,
      speed: 1.5,
      volume: 40,
      title: '演示.mp4',
      source: '/media/演示.mp4',
      audioTracks: [TrackRef(index: 0, title: '普通话'), TrackRef(index: 1, title: '粤语')],
      subtitleTracks: [TrackRef(index: 0, title: '简体')],
      currentAudio: 1,
      currentSubtitle: 0,
    );
    final decoded = PlayerStatePayload.fromJson(payload.toJson());
    expect(decoded.epoch, 3);
    expect(decoded.controllerName, '手机');
    expect(decoded.state, PlaybackStateName.playing);
    expect(decoded.speed, 1.5);
    expect(decoded.audioTracks.length, 2);
    expect(decoded.audioTracks[1].title, '粤语');
    expect(decoded.currentAudio, 1);
    expect(decoded.currentSubtitle, 0);
  });
}
