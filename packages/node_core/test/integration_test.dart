import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:node_core/node_core.dart';
import 'package:test/test.dart';

/// 全链路回环集成测试：真实 Node（shelf HTTP/WS + sqlite + FakePlayerAdapter）
/// 与真实 PlayerRemote 客户端在同一进程内走完 M0 的核心用户路径。
void main() {
  late Directory tempDir;
  late Node node;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('omniplay-int-');
    Directory('${tempDir.path}/media').createSync();
    File('${tempDir.path}/media/a.mkv').writeAsBytesSync(List.filled(256, 7));

    node = Node(
      config: NodeConfig(
        name: '测试节点',
        dataDir: '${tempDir.path}/data',
        httpPort: 0, // 系统分配，避免端口冲突
        udpPort: null, // 关闭信标，回环测试用直连
        mediaDirs: ['${tempDir.path}/media'],
      ),
      playerAdapterFactory: () => FakePlayerAdapter(),
    );
    await node.start();
  });

  tearDown(() async {
    await node.stop();
    tempDir.deleteSync(recursive: true);
  });

  test('原生设备：PIN 配对 → 浏览 → 播放/seek/暂停 → 免 PIN 重连', () async {
    final identityStoreDir = '${tempDir.path}/client1';
    final identity = await NodeIdentity.loadOrCreate(NodeStore.open(identityStoreDir));

    final pin = node.newPin();
    DeviceRecord? pairedHost;
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '测试手机',
      identity: identity,
      pin: pin,
      onPaired: (record) => pairedHost = record,
    );
    addTearDown(remote.close);

    // A2 互换语义：配对响应必须带回主机端记录（含主机公钥）。
    expect(pairedHost, isNotNull);
    expect(pairedHost!.deviceId, node.nodeId);
    expect(pairedHost!.pubKey, node.identity.publicKeyBase64);

    final states = <PlayerStatePayload>[];
    remote.attachStateSink(states.add);

    // 欢迎包里的自我宣告。
    await _waitFor(() => remote.hello != null);
    expect(remote.hello!.name, '测试节点');
    expect(remote.hello!.protoVer, protocolVersion);

    // 浏览内容源。
    final sources = await remote.refreshSources();
    expect(sources, hasLength(1));
    final entries = await remote.browse(sourceId: sources.first.sourceId);
    expect(entries.map((e) => e.name), contains('a.mkv'));

    // 播放 → seek → 暂停，状态事件按序到达。
    await remote.loadMedia(kind: 'file', value: '${sources.first.root}/a.mkv', title: '演示');
    await _waitFor(() => states.any((s) => s.state == PlaybackStateName.playing));
    expect(states.last.title, '演示');

    await remote.seekMs(600 * 1000);
    await _waitFor(() => states.last.positionMs >= 600 * 1000);

    await remote.pause();
    await _waitFor(() => states.last.state == PlaybackStateName.paused);
    expect(states.last.positionMs, greaterThanOrEqualTo(600 * 1000));

    // 断开重连：已配对设备应能免 PIN 认证，并收到快照。
    await remote.close();
    final remote2 = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '测试手机',
      identity: identity,
    );
    await _waitFor(() => remote2.hello != null);
    expect(remote2.hello!.nodeId, node.nodeId);
    await remote2.close();

    // 未配对的设备被拒（要求 PIN）。
    final stranger = await NodeIdentity.loadOrCreate(
      NodeStore.open('${tempDir.path}/client2'),
    );
    await expectLater(
      PlayerRemote.connect(
        host: '127.0.0.1',
        port: node.boundPort,
        deviceName: '陌生设备',
        identity: stranger,
      ),
      throwsA(isA<NeedPinException>()),
    );
  });

  test('Web 配对：PIN 换令牌 → 令牌认证 → 签名流 URL 走 HTTP Range', () async {
    final pin = node.newPin();
    final http = HttpClient();
    addTearDown(http.close);

    // 1. 错误 PIN 被拒。
    final badRes = await _postJson(http, 'http://127.0.0.1:${node.boundPort}/api/pair',
        {'pin': '000000', 'name': 'x'});
    expect(badRes['ok'], false);

    // 2. 正确 PIN 换令牌。
    final pairRes = await _postJson(http, 'http://127.0.0.1:${node.boundPort}/api/pair',
        {'pin': pin, 'name': '测试浏览器'});
    expect(pairRes['ok'], true);
    final token = pairRes['token'] as String;

    // 3. 令牌认证连接。
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '测试浏览器',
      webToken: token,
    );
    addTearDown(remote.close);

    final sources = await remote.refreshSources();
    final stream = await remote.requestStream(sourceId: sources.first.sourceId, path: 'a.mkv');
    expect(stream.url, isNotNull);
    expect(stream.localPath, endsWith('a.mkv'));

    // 4. 拿 URL 用 Range 直读（数据面与控制面分离的验证）。
    final fileReq = await http.getUrl(Uri.parse(stream.url!));
    fileReq.headers.set('Range', 'bytes=0-9');
    final fileRes = await fileReq.close();
    expect(fileRes.statusCode, 206);
    expect(fileRes.headers.value('content-range'), startsWith('bytes 0-9/'));
    final bytes = <int>[];
    await for (final chunk in fileRes) {
      bytes.addAll(chunk);
    }
    expect(bytes, hasLength(10));
    expect(bytes.every((b) => b == 7), isTrue);
  });

  test('断电续播：进度落盘后重新加载自动跳转', () async {
    // 先制造进度：播放 → seek → 落盘。
    final identity = await NodeIdentity.loadOrCreate(NodeStore.open('${tempDir.path}/c3'));
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '续播测试',
      identity: identity,
      pin: node.newPin(),
    );
    addTearDown(remote.close);

    final sources = await remote.refreshSources();
    final mediaPath = '${sources.first.root}/a.mkv';
    await remote.loadMedia(kind: 'file', value: mediaPath);
    await remote.seekMs(120 * 1000);
    // _maybePersist 由快照事件触发，轮询等待落盘。
    await _waitFor(() => node.store.progressOf(mediaPath) != null);
    await remote.close();

    // 新会话（模拟重启后重新加载同一文件）应自动跳到上次进度。
    final remote2 = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '续播测试',
      identity: identity,
    );
    addTearDown(remote2.close);
    final states = <PlayerStatePayload>[];
    remote2.attachStateSink(states.add);

    await remote2.loadMedia(kind: 'file', value: mediaPath);
    await _waitFor(
      () => states.any((s) => s.state == PlaybackStateName.playing && s.positionMs >= 120 * 1000),
    );
  });

  test('双向互信：A 配对 B 后，A 的身份应能免 PIN 认证到 B 的节点', () async {
    // nodeA = 已启动的主节点（host）。nodeB = 独立节点（模拟手机端）。
    final nodeB = Node(
      config: NodeConfig(
        name: '节点B',
        dataDir: '${tempDir.path}/node-b',
        httpPort: 0,
        udpPort: null,
      ),
    );
    await nodeB.start();
    addTearDown(nodeB.stop);

    // B 作为控制器 PIN 配对到 A；onPaired 把 A 的记录落进 B 的库。
    DeviceRecord? hostRecord;
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '节点B',
      identity: nodeB.identity,
      pin: node.newPin(),
      onPaired: (record) {
        hostRecord = record;
        nodeB.store.upsertDevice(record);
      },
    );
    addTearDown(remote.close);
    expect(hostRecord, isNotNull);

    // 反向：A 的身份直连 B 的节点，应免 PIN 认证通过（配对互换语义的回归用例）。
    final remoteReverse = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: nodeB.boundPort,
      deviceName: '主节点',
      identity: node.identity,
    );
    await _waitFor(() => remoteReverse.hello != null);
    expect(remoteReverse.hello, isNotNull);
    expect(remoteReverse.hello!.nodeId, nodeB.nodeId);
    await remoteReverse.close();
  });
}

Future<Map<String, Object?>> _postJson(HttpClient http, String url, Map<String, Object?> body) async {
  final request = await http.postUrl(Uri.parse(url));
  request.headers.contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return jsonDecode(text) as Map<String, Object?>;
}

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
