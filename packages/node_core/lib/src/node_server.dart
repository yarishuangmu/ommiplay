import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:node_protocol/src/envelope.dart';
import 'package:node_protocol/src/messages.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'identity.dart';
import 'library.dart';
import 'pairing.dart';
import 'session.dart';
import 'store.dart';
import 'stream_signer.dart';
import 'utils.dart';

/// 节点服务端：单端口承载 WS 控制、Web 配对、签名流分发与静态控制页（D5）。
class NodeServer {
  NodeServer({
    required this.nodeId,
    required this.nodeName,
    required this.store,
    required this.identity,
    required this.library,
    required this.session,
    required this.pairing,
    required this.signer,
    this.webRoot,
    this.announceHost,
  });

  final String nodeId;
  final String nodeName;
  final NodeStore store;
  final NodeIdentity identity;
  final Library library;
  final PlayerSession session;
  final PairingService pairing;
  final StreamSigner signer;
  final String? webRoot;
  final String? announceHost;

  HttpServer? _httpServer;
  final Set<_Peer> _peers = {};
  String? _lanHost;

  int get boundPort => _httpServer?.port ?? 0;

  String lanUrl() => 'http://${_lanHost ?? '127.0.0.1'}:$boundPort';

  Future<int> start({required int port}) async {
    _lanHost = announceHost ?? await detectLanAddress();
    final server = await shelf_io.serve(_router(), InternetAddress.anyIPv4, port);
    _httpServer = server;
    return server.port;
  }

  Future<void> stop() async {
    for (final peer in List.of(_peers)) {
      await peer.channel.sink.close();
    }
    _peers.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Router _router() {
    final router = Router();
    router.get('/ws', _wsRoute);
    router.post('/api/pair', _apiPair);
    router.get('/stream/<token>', _streamRoute);
    router.get('/<path|.*>', _staticRoute);
    return router;
  }

  // ---------------------------------------------------------------- WS ----

  late final _wsRoute = webSocketHandler((WebSocketChannel channel, String? _) {
    final peer = _Peer(channel);
    _peers.add(peer);
    final nonce = newMsgId();
    peer.nonce = nonce;
    _send(peer, MsgTypes.challenge, {'nonce': nonce});

    channel.stream.listen(
      (data) => _onData(peer, data),
      onDone: () => _peers.remove(peer),
      onError: (Object _) => _peers.remove(peer),
      cancelOnError: true,
    );
  });

  void _onData(_Peer peer, Object data) async {
    final Msg msg;
    try {
      msg = Msg.fromJson(jsonDecode(data as String));
    } on FormatException catch (e) {
      _send(peer, MsgTypes.error, {'code': 'bad-message', 'message': e.message});
      return;
    }

    try {
      switch (msg.type) {
        case MsgTypes.pinRequest:
          await _onPinRequest(peer, msg);
          return;
        case MsgTypes.authRequest:
          await _onAuthRequest(peer, msg);
          return;
      }

      if (!peer.authed) {
        _send(peer, MsgTypes.error, {'code': 'unauthorized', 'message': '请先完成配对或认证'});
        return;
      }

      switch (msg.type) {
        case MsgTypes.hello:
          peer.name = msg.pOrNull<String>('name') ?? peer.name;
          return;
        case MsgTypes.sources:
          _reply(peer, msg.type, _sourcesPayload(), reqId: msg.pOrNull<String>('reqId'));
          return;
        case MsgTypes.browseRequest:
          await _onBrowse(peer, msg);
          return;
        case MsgTypes.streamRequest:
          await _onStreamRequest(peer, msg);
          return;
        case MsgTypes.playerTakeover:
          session.takeover(id: peer.deviceId ?? peer.hashCode.toString(), name: peer.name);
          return;
        default:
          if (msg.type.startsWith('player.cmd.')) {
            final handled = await session.handleCommand(
              type: msg.type,
              payload: msg.payload,
              fromId: peer.deviceId ?? '',
            );
            if (!handled) {
              _send(peer, MsgTypes.error, {'code': 'unknown-command', 'message': msg.type});
            }
            return;
          }
          _send(peer, MsgTypes.error, {'code': 'unknown-type', 'message': msg.type});
      }
    } on ArgumentError catch (e) {
      _send(peer, MsgTypes.error, {'code': 'bad-request', 'message': e.message ?? '参数错误'});
    } on StateError catch (e) {
      _send(peer, MsgTypes.error, {'code': 'not-found', 'message': e.message});
    }
  }

  Future<void> _onPinRequest(_Peer peer, Msg msg) async {
    final pin = msg.p<String>('pin');
    final deviceId = msg.p<String>('deviceId');
    final name = msg.pOrNull<String>('name') ?? '未命名设备';
    final pubKey = msg.p<String>('pubKey');

    if (!pairing.validatePin(pin)) {
      _send(peer, MsgTypes.pinResponse, {'ok': false, 'error': 'PIN 无效或已过期'});
      return;
    }
    store.upsertDevice(DeviceRecord(
      deviceId: deviceId,
      name: name,
      kind: 'device',
      pubKey: pubKey,
      addedAt: DateTime.now(),
    ));
    peer
      ..authed = true
      ..deviceId = deviceId
      ..name = name;
    _send(peer, MsgTypes.pinResponse, {
      'ok': true,
      'nodeId': nodeId,
      'nodeName': nodeName,
      'familyId': store.getMeta('family_id') ?? nodeId,
    });
    _sendAuthenticatedBundle(peer);
  }

  Future<void> _onAuthRequest(_Peer peer, Msg msg) async {
    final token = msg.pOrNull<String>('token');
    if (token != null) {
      final hash = crypto.sha256.convert(utf8.encode(token)).toString();
      final device = store.deviceByTokenHash(hash);
      if (device == null) {
        _send(peer, MsgTypes.authResult, {'ok': false, 'error': '令牌无效'});
        return;
      }
      peer
        ..authed = true
        ..deviceId = device.deviceId
        ..name = device.name;
      _send(peer, MsgTypes.authResult, {'ok': true, 'nodeName': nodeName});
      _sendAuthenticatedBundle(peer);
      return;
    }

    final deviceId = msg.p<String>('deviceId');
    final sig = msg.p<String>('sig');
    final nonce = peer.nonce;
    if (nonce == null) {
      _send(peer, MsgTypes.authResult, {'ok': false, 'error': '未收到挑战'});
      return;
    }
    final device = store.deviceById(deviceId);
    final ok = device != null &&
        device.kind == 'device' &&
        device.pubKey != null &&
        await NodeIdentity.verify(
          publicKeyBase64: device.pubKey!,
          data: nonce,
          signatureBase64: sig,
        );
    if (!ok) {
      _send(peer, MsgTypes.authResult, {'ok': false, 'error': '设备未配对或签名无效'});
      return;
    }
    peer
      ..authed = true
      ..deviceId = deviceId
      ..name = device.name;
    _send(peer, MsgTypes.authResult, {'ok': true, 'nodeName': nodeName});
    _sendAuthenticatedBundle(peer);
  }

  Future<void> _onBrowse(_Peer peer, Msg msg) async {
    final reqId = msg.pOrNull<String>('reqId');
    try {
      final entries = library.browse(
        sourceId: msg.p<String>('sourceId'),
        dirPath: msg.pOrNull<String>('dirPath') ?? '',
      );
      _reply(peer, MsgTypes.browseResponse, {
        'ok': true,
        'entries': entries.map((e) => e.toJson()).toList(),
      }, reqId: reqId);
    } on Object catch (e) {
      _reply(peer, MsgTypes.browseResponse, {
        'ok': false,
        'error': e.toString(),
      }, reqId: reqId);
    }
  }

  Future<void> _onStreamRequest(_Peer peer, Msg msg) async {
    final reqId = msg.pOrNull<String>('reqId');
    try {
      final absolute = library.resolveFile(
        sourceId: msg.p<String>('sourceId'),
        path: msg.p<String>('path'),
      );
      final sourceId = msg.p<String>('sourceId');
      final relative = msg.p<String>('path');
      final token = signer.sign(sourceId: sourceId, path: relative);
      _reply(peer, MsgTypes.streamResponse, {
        'ok': true,
        'url': '${lanUrl()}/stream/$token',
        'localPath': absolute,
        'expiresAt': DateTime.now().add(const Duration(hours: 2)).toIso8601String(),
      }, reqId: reqId);
    } on Object catch (e) {
      _reply(peer, MsgTypes.streamResponse, {'ok': false, 'error': e.toString()}, reqId: reqId);
    }
  }

  Map<String, Object?> _sourcesPayload() => {
        'sources': library.sources.map((s) => s.toJson()).toList(),
      };

  /// 认证后的欢迎包：自我宣告 + 内容源 + 播放快照。
  void _sendAuthenticatedBundle(_Peer peer) {
    _send(peer, MsgTypes.hello, NodeInfo(
      nodeId: nodeId,
      name: nodeName,
      roles: const ['C', 'P', 'L'],
      protoVer: protocolVersion,
      httpPort: boundPort,
    ).toJson());
    _send(peer, MsgTypes.sources, _sourcesPayload());
    _send(peer, MsgTypes.playerState, session.toPayload().toJson());
  }

  void _send(_Peer peer, String type, Map<String, Object?> payload) {
    peer.channel.sink.add(jsonEncode(Msg(
      type: type,
      id: newMsgId(),
      ts: session.clock.tick(),
      from: nodeId,
      payload: payload,
    ).toJson()));
  }

  void _reply(_Peer peer, String type, Map<String, Object?> payload, {String? reqId}) {
    _send(peer, type, reqId == null ? payload : {'reqId': reqId, ...payload});
  }

  /// 向所有已认证连接广播（播放状态变化等）。
  void broadcast(Msg msg) {
    final text = jsonEncode(msg.toJson());
    for (final peer in _peers) {
      if (peer.authed) peer.channel.sink.add(text);
    }
  }

  // ---------------------------------------------------------------- HTTP --

  Future<shelf.Response> _apiPair(shelf.Request request) async {
    Map<String, Object?> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, Object?>;
    } on FormatException {
      return shelf.Response.badRequest(body: jsonEncode({'ok': false, 'error': '请求体不是 JSON'}));
    }
    final pin = body['pin'] as String?;
    final name = (body['name'] as String?) ?? 'Web 控制器';
    if (pin == null || !pairing.validatePin(pin)) {
      return shelf.Response.ok(jsonEncode({'ok': false, 'error': 'PIN 无效或已过期'}),
          headers: _jsonHeaders);
    }
    final token = randomHex(32);
    final deviceId = 'web-${randomHex(8)}';
    store.upsertDevice(DeviceRecord(
      deviceId: deviceId,
      name: name,
      kind: 'web',
      tokenHash: crypto.sha256.convert(utf8.encode(token)).toString(),
      addedAt: DateTime.now(),
    ));
    return shelf.Response.ok(jsonEncode({
      'ok': true,
      'token': token,
      'nodeId': nodeId,
      'nodeName': nodeName,
      'familyId': store.getMeta('family_id') ?? nodeId,
    }), headers: _jsonHeaders);
  }

  Future<shelf.Response> _streamRoute(shelf.Request request, String token) async {
    final verified = signer.verify(token);
    if (verified == null) {
      return shelf.Response(403, body: 'invalid stream token');
    }
    String absolute;
    try {
      absolute = library.resolveFile(sourceId: verified.sourceId, path: verified.path);
    } on Object {
      return shelf.Response(404, body: 'file not found');
    }
    return _serveFile(request, absolute);
  }

  Future<shelf.Response> _staticRoute(shelf.Request request, String path) async {
    if (request.method != 'GET') {
      return shelf.Response(405, body: 'method not allowed');
    }
    final root = webRoot;
    if (root == null || !Directory(root).existsSync()) {
      return shelf.Response.ok(
        '<!doctype html><meta charset="utf-8"><body style="font-family:sans-serif;'
        'background:#111;color:#eee;display:grid;place-items:center;height:100vh">'
        '<div>OmniPlay 节点在线（$nodeName）<br>Web 控制页未部署</div></body>',
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    final relative = path.isEmpty ? 'index.html' : path;
    try {
      final absolute = resolveWithinRoot(root, relative);
      final file = File(absolute);
      if (!file.existsSync()) {
        // SPA 路由兜底：非资源路径回退 index.html。
        if (!relative.contains('.')) {
          return await _serveFile(request, resolveWithinRoot(root, 'index.html'));
        }
        return shelf.Response.notFound('not found');
      }
      return await _serveFile(request, absolute);
    } on ArgumentError {
      return shelf.Response(400, body: 'bad path');
    }
  }

  Future<shelf.Response> _serveFile(shelf.Request request, String absolute) async {
    final file = File(absolute);
    final length = file.lengthSync();
    final headers = <String, String>{
      'accept-ranges': 'bytes',
      'content-type': _contentTypeOf(absolute),
    };

    final rangeHeader = request.headers['range'];
    if (rangeHeader == null) {
      headers['content-length'] = '$length';
      return shelf.Response(200, body: file.openRead(), headers: headers);
    }

    final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
    if (match == null || (match.group(1)!.isEmpty && match.group(2)!.isEmpty)) {
      return shelf.Response(416, body: 'invalid range');
    }
    int start;
    int end;
    if (match.group(1)!.isNotEmpty) {
      start = int.parse(match.group(1)!);
      end = match.group(2)!.isNotEmpty ? int.parse(match.group(2)!) : length - 1;
    } else {
      // suffix range: bytes=-N
      final suffix = int.parse(match.group(2)!);
      start = length - suffix;
      end = length - 1;
    }
    if (start < 0 || end >= length || start > end) {
      return shelf.Response(416, body: 'range out of bounds',
          headers: {'content-range': 'bytes */$length'});
    }
    headers
      ..['content-range'] = 'bytes $start-$end/$length'
      ..['content-length'] = '${end - start + 1}';
    return shelf.Response(206, body: file.openRead(start, end + 1), headers: headers);
  }

  static const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  static String _contentTypeOf(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'html' || 'htm' => 'text/html; charset=utf-8',
      'js' || 'mjs' => 'text/javascript; charset=utf-8',
      'css' => 'text/css; charset=utf-8',
      'json' => 'application/json; charset=utf-8',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'ico' => 'image/x-icon',
      'woff2' => 'font/woff2',
      'mp4' || 'm4v' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'ts' => 'video/mp2t',
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'm4a' => 'audio/mp4',
      'epub' => 'application/epub+zip',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
  }
}

/// 一条已建立的 WS 连接（含认证态）。
class _Peer {
  _Peer(this.channel);

  final WebSocketChannel channel;
  bool authed = false;
  String? deviceId;
  String? name;
  String? nonce;
}
