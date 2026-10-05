import 'dart:async';

import 'package:node_protocol/src/messages.dart';

import 'hlc.dart';
import 'player_adapter.dart';
import 'store.dart';

/// 播放器会话：**状态权威**（A4）。
/// 控制器连接后先收一份 snapshot，之后每次变化广播 player.evt.state；
/// 写操作按到达序生效（最后写入者生效），显式接管经 [takeover] 提升抢占语义。
class PlayerSession {
  PlayerSession({
    required this.nodeId,
    required this.clock,
    required this.store,
  });

  final String nodeId;
  final HlcClock clock;
  final NodeStore store;

  PlayerSnapshot _snapshot = PlayerSnapshot.idle();
  PlayerAdapter? _adapter;
  StreamSubscription<PlayerSnapshot>? _sub;

  /// 接管代次：每次显式接管 +1，控制器 UI 借此显示"当前受控于谁"。
  int epoch = 0;
  String? controllerId;
  String? controllerName;

  /// 快照变化回调（由 Node 注入，向所有已认证连接广播）。
  void Function(PlayerStatePayload payload)? onSnapshotChanged;

  int _lastPersistedPositionMs = 0;

  PlayerSnapshot get snapshot => _snapshot;

  bool get hasAdapter => _adapter != null;

  void attach(PlayerAdapter adapter) {
    _sub?.cancel();
    _adapter = adapter;
    _sub = adapter.changes.listen((snapshot) {
      _snapshot = snapshot;
      _maybePersist();
      onSnapshotChanged?.call(toPayload());
    });
  }

  PlayerStatePayload toPayload() => _snapshot.toPayload(
        epoch: epoch,
        controllerId: controllerId,
        controllerName: controllerName,
      );

  /// 显式接管（player.takeover）。
  void takeover({required String id, required String? name}) {
    if (controllerId == id) return;
    epoch += 1;
    controllerId = id;
    controllerName = name;
    onSnapshotChanged?.call(toPayload());
  }

  /// 处理播放指令。返回是否认识该指令（未知指令由上层回 node.error）。
  Future<bool> handleCommand({
    required String type,
    required Map<String, Object?> payload,
    required String fromId,
  }) async {
    final adapter = _adapter;
    if (adapter == null) return true; // 无内核：静默吞掉（无头节点角色裁剪）

    switch (type) {
      case MsgTypes.playerLoad:
        final kind = payload['kind'] as String? ?? 'file';
        final value = payload['value'] as String?;
        if (value == null) throw ArgumentError('load 缺少 value');
        final title = payload['title'] as String?;
        await adapter.load(kind: kind, value: value, title: title);
        _maybeAutoResume(value);
        return true;
      case MsgTypes.playerPlay:
        await adapter.play();
        return true;
      case MsgTypes.playerPause:
        await adapter.pause();
        return true;
      case MsgTypes.playerStop:
        _persistNow();
        await adapter.stop();
        return true;
      case MsgTypes.playerSeek:
        await adapter.seekMs((payload['positionMs'] as num?)?.toInt() ?? 0);
        return true;
      case MsgTypes.playerSetVolume:
        await adapter.setVolume((payload['volume'] as num?)?.toInt() ?? 100);
        return true;
      case MsgTypes.playerSetSpeed:
        await adapter.setSpeed((payload['rate'] as num?)?.toDouble() ?? 1.0);
        return true;
      case MsgTypes.playerSelectTrack:
        await adapter.selectTrack(
          kind: payload['kind'] as String? ?? 'audio',
          index: (payload['index'] as num?)?.toInt() ?? 0,
        );
        return true;
      default:
        return false;
    }
  }

  /// 断电/闪退续播：加载后若本地有 >30s 且 <95% 的进度则自动跳转（非功能需求）。
  void _maybeAutoResume(String sourceValue) {
    final progress = store.progressOf(sourceValue);
    if (progress == null) return;
    if (progress.positionMs <= 30 * 1000) return;
    if (progress.durationMs > 0 && progress.positionMs >= progress.durationMs * 0.95) return;
    _adapter?.seekMs(progress.positionMs);
  }

  /// 播放推进每 5 秒落一次盘（断电续播，非功能需求）。
  void _maybePersist() {
    if (_snapshot.state == PlaybackStateName.idle) return;
    if ((_snapshot.positionMs - _lastPersistedPositionMs).abs() < 5 * 1000) return;
    _persistNow();
  }

  void _persistNow() {
    final source = _snapshot.source;
    if (source == null) return;
    if (_snapshot.positionMs <= 0) return;
    _lastPersistedPositionMs = _snapshot.positionMs;
    store.saveProgress(
      itemKey: source,
      title: _snapshot.title,
      positionMs: _snapshot.positionMs,
      durationMs: _snapshot.durationMs,
      updatedHlc: clock.tick(),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}
