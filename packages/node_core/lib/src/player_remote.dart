import 'dart:async';
import 'dart:convert';

import 'package:node_protocol/src/envelope.dart';
import 'package:node_protocol/src/messages.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'hlc.dart';
import 'identity.dart';
import 'store.dart';

/// 需要配对（PIN）才能连接：对端不认识本设备身份时抛出。
class NeedPinException implements Exception {
  NeedPinException(this.message);
  final String message;

  @override
  String toString() => 'NeedPinException: $message';
}

/// 控制器端到播放器节点的 WS 客户端（A4）。
/// 连接握手：challenge → 签名认证 / PIN 配对 / Web 令牌，随后收 bundle（hello/sources/state）。
class PlayerRemote {
  PlayerRemote._(this._channel, this._clock, this.deviceId, this._name);

  final WebSocketChannel _channel;
  final HlcClock _clock;
  final String deviceId;
  final String _name;

  NodeInfo? hello;
  final _messages = StreamController<Msg>.broadcast();
  final List<StreamSubscription> _subs = [];
  bool _closed = false;

  /// 对端节点广播/推送的消息（hello、lib.*、player.evt.state 等）。
  Stream<Msg> get messages => _messages.stream;

  /// 与本机自持有的 PlayerStatePayload 对应的对端最新状态（由 [attachStateSink] 维护）。
  PlayerStatePayload? latestState;

  /// 便捷：把对端 player.evt.state 汇入一个 ChangeNotifier 式回调。
  void attachStateSink(void Function(PlayerStatePayload state)? onState) {
    _subs.add(messages.listen((msg) {
      if (msg.type == MsgTypes.playerState) {
        latestState = PlayerStatePayload.fromJson(msg.payload);
        onState?.call(latestState!);
      }
    }));
  }

  static Future<PlayerRemote> connect({
    required String host,
    required int port,
    required String deviceName,
    NodeIdentity? identity,
    String? pin,
    String? joinToken,
    String? webToken,
    Duration timeout = const Duration(seconds: 10),

    /// PIN 配对成功时回调：携带主机端设备记录（含主机公钥），调用方应落库，
    /// 否则本机将来无法认证主机（A2 互换语义）。
    void Function(DeviceRecord hostDevice)? onPaired,
  }) async {
    if (webToken == null && identity == null) {
      throw ArgumentError('必须提供 identity（原生设备）或 webToken（浏览器）之一');
    }
    final channel = WebSocketChannel.connect(
      Uri(scheme: 'ws', host: host, port: port, path: '/ws'),
    );
    await channel.ready.timeout(timeout);

    final deviceId = identity?.deviceId ?? 'web-${newMsgId().substring(0, 8)}';
    final remote = PlayerRemote._(channel, HlcClock(deviceId), deviceId, deviceName);

    final handshake = Completer<void>();
    Object? handshakeError;

    late final StreamSubscription sub;
    sub = channel.stream.listen(
      (data) {
        final Msg msg;
        try {
          msg = Msg.fromJson(jsonDecode(data as String));
        } on FormatException {
          return;
        }

        if (!handshake.isCompleted) {
          switch (msg.type) {
            case MsgTypes.challenge:
              remote._answerChallenge(msg, identity: identity, pin: pin, joinToken: joinToken, webToken: webToken);
              return;
            case MsgTypes.authResult:
              if (msg.p<bool>('ok')) {
                handshake.complete();
              } else {
                handshakeError = NeedPinException(msg.pOrNull<String>('error') ?? '认证失败');
                handshake.completeError(handshakeError!);
              }
              return;
            case MsgTypes.pinResponse:
              if (msg.p<bool>('ok')) {
                final hostDevice = msg.pOrNull<Map<dynamic, dynamic>>('hostDevice');
                if (onPaired != null && hostDevice != null) {
                  onPaired(DeviceRecord(
                    deviceId: hostDevice['deviceId'] as String,
                    name: hostDevice['name'] as String? ?? 'OmniPlay 节点',
                    kind: 'device',
                    pubKey: hostDevice['pubKey'] as String,
                    addedAt: DateTime.now(),
                  ));
                }
                handshake.complete();
              } else {
                handshakeError = NeedPinException(msg.pOrNull<String>('error') ?? '配对失败');
                handshake.completeError(handshakeError!);
              }
              return;
            case MsgTypes.error:
              handshakeError = PlayerRemoteException(
                msg.pOrNull<String>('message') ?? '节点拒绝连接',
              );
              handshake.completeError(handshakeError!);
              return;
          }
        }

        if (msg.type == MsgTypes.hello) {
          remote.hello = NodeInfo.fromJson(msg.payload);
          return;
        }
        remote._messages.add(msg);
      },
      onError: (Object error) {
        if (!handshake.isCompleted) handshake.completeError(error);
        remote._messages.addError(error);
      },
      onDone: () {
        if (!handshake.isCompleted) {
          handshake.completeError(PlayerRemoteException('连接已关闭'));
        }
        remote._messages.close();
      },
    );
    remote._subs.add(sub);

    try {
      await handshake.future.timeout(timeout);
    } on NeedPinException {
      await remote.close();
      rethrow;
    } on Object {
      await remote.close();
      rethrow;
    }
    return remote;
  }

  void _answerChallenge(
    Msg challenge, {
    required NodeIdentity? identity,
    required String? pin,
    required String? joinToken,
    required String? webToken,
  }) async {
    final nonce = challenge.p<String>('nonce');
    if (webToken != null) {
      _send(MsgTypes.authRequest, {'token': webToken});
      return;
    }
    if (pin != null && identity != null) {
      _send(MsgTypes.pinRequest, {
        'pin': pin,
        'deviceId': identity.deviceId,
        'name': _name,
        'pubKey': identity.publicKeyBase64,
      });
      return;
    }
    if (joinToken != null && identity != null) {
      _send(MsgTypes.pinRequest, {
        'joinToken': joinToken,
        'deviceId': identity.deviceId,
        'name': _name,
        'pubKey': identity.publicKeyBase64,
      });
      return;
    }
    if (identity != null) {
      final sig = await identity.sign(nonce);
      _send(MsgTypes.authRequest, {'deviceId': identity.deviceId, 'sig': sig});
      return;
    }
    _send(MsgTypes.error, {'code': 'no-credentials', 'message': '无认证材料'});
  }

  // ------------------------------------------------------------- 通用 ----

  void _send(String type, Map<String, Object?> payload) {
    if (_closed) return;
    _channel.sink.add(jsonEncode(Msg(
      type: type,
      id: newMsgId(),
      ts: _clock.tick(),
      from: deviceId,
      payload: payload,
    ).toJson()));
  }

  /// 请求-响应：以 reqId 关联（对端在响应 payload 中回传 reqId）。
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    required String responseType,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final reqId = newMsgId();
    final completer = Completer<Map<String, Object?>>();
    final sub = messages.listen((msg) {
      if (msg.type != responseType) return;
      if (msg.pOrNull<String>('reqId') != reqId) return;
      if (!completer.isCompleted) completer.complete(msg.payload);
    });
    _subs.add(sub);
    _send(type, {'reqId': reqId, ...payload});
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw PlayerRemoteException('请求 $type 超时');
    } finally {
      sub.cancel();
      _subs.remove(sub);
    }
  }

  // ------------------------------------------------------------- 命令 ----

  Future<void> loadMedia({
    required String kind,
    required String value,
    String? title,
  }) =>
      _cmd(MsgTypes.playerLoad, {'kind': kind, 'value': value, if (title != null) 'title': title});

  Future<void> play() => _cmd(MsgTypes.playerPlay, {});
  Future<void> pause() => _cmd(MsgTypes.playerPause, {});
  Future<void> stop() => _cmd(MsgTypes.playerStop, {});
  Future<void> seekMs(int ms) => _cmd(MsgTypes.playerSeek, {'positionMs': ms});
  Future<void> setVolume(int volume) => _cmd(MsgTypes.playerSetVolume, {'volume': volume});
  Future<void> setSpeed(double rate) => _cmd(MsgTypes.playerSetSpeed, {'rate': rate});
  Future<void> selectTrack({required String kind, required int index}) =>
      _cmd(MsgTypes.playerSelectTrack, {'kind': kind, 'index': index});

  /// 显式接管（last-writer-wins 之上的抢占提示，A4）。
  Future<void> takeover() async {
    _send(MsgTypes.playerTakeover, {});
  }

  // —— 语义按键（遥控器）：播放器会话自行映射 ——
  Future<void> sendKey(String key) => _cmd(MsgTypes.playerKey, {'key': key});

  // —— PC 控制（仿真触控板/键鼠，桌面节点）——
  Future<void> mouseMove({required double dx, required double dy}) =>
      _cmd(MsgTypes.inputMouseMove, {'dx': dx, 'dy': dy});

  Future<void> mouseClick({String button = 'left', bool doubleClick = false}) =>
      _cmd(MsgTypes.inputMouseClick, {'button': button, 'doubleClick': doubleClick});

  Future<void> mouseScroll({required double dx, required double dy}) =>
      _cmd(MsgTypes.inputMouseScroll, {'dx': dx, 'dy': dy});

  Future<void> keyPress(String key) => _cmd(MsgTypes.inputKeyPress, {'key': key});

  Future<void> inputText(String text) => _cmd(MsgTypes.inputText, {'text': text});

  // —— 在线网页（优酷/爱奇艺/腾讯等，桌面节点承载）——
  Future<Map<String, Object?>> webOpen(String url, {String? title}) => request(
        MsgTypes.webOpen,
        {'url': url, if (title != null) 'title': title},
        responseType: MsgTypes.webOpen,
      );

  Future<void> webClose() => _cmd(MsgTypes.webClose, {});

  // —— 系统（重启/睡眠）——
  Future<void> restartApp() => _cmd(MsgTypes.restartApp, {});
  Future<void> rebootSystem() => _cmd(MsgTypes.rebootSystem, {});
  Future<void> sleepSystem() => _cmd(MsgTypes.sleepSystem, {});

  Future<void> _cmd(String type, Map<String, Object?> payload) async {
    _send(type, payload);
  }

  // ------------------------------------------------------------- 业务 ----

  Future<List<SourceInfo>> refreshSources() async {
    final payload = await request(MsgTypes.sources, {}, responseType: MsgTypes.sources);
    return ((payload['sources'] as List?) ?? const [])
        .map((s) => SourceInfo.fromJson(Map<String, Object?>.from(s as Map)))
        .toList();
  }

  Future<List<LibEntry>> browse({required String sourceId, String dirPath = ''}) async {
    final payload = await request(
      MsgTypes.browseRequest,
      {'sourceId': sourceId, 'dirPath': dirPath},
      responseType: MsgTypes.browseResponse,
    );
    if (payload['ok'] != true) {
      throw PlayerRemoteException(payload['error'] as String? ?? '浏览失败');
    }
    return ((payload['entries'] as List?) ?? const [])
        .map((e) => LibEntry.fromJson(Map<String, Object?>.from(e as Map)))
        .toList();
  }

  /// 请求一个可直接投给目标播放器的流地址（本机是播放器时用 localPath；跨节点用 url）。
  /// 远端添加内容源（kind: folder|webdav）。返回 {ok, source?}。
  Future<Map<String, Object?>> addSource({
    required String kind,
    String? name,
    String? url,
    String? username,
    String? password,
    String? path,
  }) =>
      request(
        MsgTypes.sourceAdd,
        {
          'kind': kind,
          if (name != null) 'name': name,
          if (url != null) 'url': url,
          if (username != null) 'username': username,
          if (password != null) 'password': password,
          if (path != null) 'path': path,
        },
        responseType: MsgTypes.sourceAdd,
      );

  /// 远端移除内容源。
  Future<Map<String, Object?>> removeSource({required String sourceId}) => request(
        MsgTypes.sourceRemove,
        {'sourceId': sourceId},
        responseType: MsgTypes.sourceRemove,
      );

  Future<({String? url, String? localPath})> requestStream({
    required String sourceId,
    required String path,
  }) async {
    final payload = await request(
      MsgTypes.streamRequest,
      {'sourceId': sourceId, 'path': path},
      responseType: MsgTypes.streamResponse,
    );
    if (payload['ok'] != true) {
      throw PlayerRemoteException(payload['error'] as String? ?? '获取流地址失败');
    }
    return (url: payload['url'] as String?, localPath: payload['localPath'] as String?);
  }

  Future<void> close() async {
    _closed = true;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _channel.sink.close();
    await _messages.close();
  }
}

class PlayerRemoteException implements Exception {
  PlayerRemoteException(this.message);
  final String message;

  @override
  String toString() => 'PlayerRemoteException: $message';
}
