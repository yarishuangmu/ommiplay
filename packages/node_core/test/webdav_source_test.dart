import 'dart:async';
import 'dart:io';

import 'package:node_core/node_core.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// 内置 fake WebDAV 服务器：PROPFIND（多状态 XML）+ GET（含 Range 切片）。
/// 需 Basic Auth（user:pass），验证凭据经源节点代理、不进入播放器侧。
Future<HttpServer> _startFakeDav() async {
  final fileBytes = List<int>.generate(256, (i) => i % 251);
  const propfindXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/dav/%E7%94%B5%E5%BD%B1/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/dav/a.mkv</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>256</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''';

  final router = Router()
    ..add('PROPFIND', '/dav/<path|.*>', (shelf.Request request) async {
      final auth = request.headers['authorization'] ?? '';
      if (auth != 'Basic dXNlcjpwYXNz') return shelf.Response(401);
      return shelf.Response(207, body: propfindXml,
          headers: {'content-type': 'application/xml; charset=utf-8'});
    })
    ..get('/dav/a.mkv', (shelf.Request request) {
      final range = request.headers['range'];
      if (range == null) {
        return shelf.Response(200, body: Stream<List<int>>.fromIterable([fileBytes]),
            headers: {'content-type': 'video/x-matroska', 'content-length': '256', 'accept-ranges': 'bytes'});
      }
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      final start = int.parse(m.group(1)!);
      final end = m.group(2)!.isEmpty ? 255 : int.parse(m.group(2)!);
      return shelf.Response(206, body: Stream<List<int>>.fromIterable([fileBytes.sublist(start, end + 1)]),
          headers: {
            'content-type': 'video/x-matroska',
            'content-range': 'bytes $start-$end/256',
            'accept-ranges': 'bytes',
          });
    });

  return shelf_io.serve(router, InternetAddress.loopbackIPv4, 0);
}

void main() {
  late HttpServer dav;

  setUp(() async {
    dav = await _startFakeDav();
  });

  tearDown(() async {
    await dav.close(force: true);
  });

  test('WebdavSource：ping 可达 + PROPFIND 解析（目录优先/中文路径/大小）', () async {
    final source = WebdavSource(
      url: 'http://127.0.0.1:${dav.port}/dav/',
      username: 'user',
      password: 'pass',
      name: '家庭NAS',
    );
    expect(await source.ping(), 207);

    final entries = await source.browse('');
    expect(entries.map((e) => e.name), ['电影', 'a.mkv']);
    expect(entries.first.isDir, isTrue);
    expect(entries.last.sizeBytes, 256);
    expect(entries.last.path, 'a.mkv');

    // 错误凭据被上游拒绝 → 异常向上抛
    final bad = WebdavSource(url: 'http://127.0.0.1:${dav.port}/dav/', username: 'x', password: 'y');
    await expectLater(bad.browse(''), throwsA(isA<HttpException>()));
  });

  test('远端管理：lib.source.add → 浏览 → 签名 URL 经源节点代理拉流', () async {
    final tempDir = Directory.systemTemp.createTempSync('omniplay-dav-');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final node = Node(
      config: NodeConfig(name: '测试节点', dataDir: '${tempDir.path}/data', httpPort: 0, udpPort: null),
    );
    await node.start();
    addTearDown(node.stop);

    final clientStore = NodeStore.open('${tempDir.path}/client');
    final identity = await NodeIdentity.loadOrCreate(clientStore);
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '客户端',
      identity: identity,
      pin: node.newPin(),
    );
    addTearDown(remote.close);

    // 1. 远程添加网络源（走 lib.source.add）
    final added = await remote.addSource(
      kind: 'webdav',
      name: '家庭NAS',
      url: 'http://127.0.0.1:${dav.port}/dav/',
      username: 'user',
      password: 'pass',
    );
    expect(added['ok'], true);
    final source = (added['source'] as Map).cast<String, Object?>();
    expect(source['kind'], 'webdav');
    expect(source['name'], '家庭NAS');

    // 2. 浏览网络源（协议与本地源完全一致）
    final entries = await remote.browse(sourceId: source['sourceId'] as String);
    expect(entries.map((e) => e.name), contains('a.mkv'));

    // 3. 请求流地址 → 网络源不暴露 localPath，播放器拿代理 URL
    final stream = await remote.requestStream(
      sourceId: source['sourceId'] as String,
      path: 'a.mkv',
    );
    expect(stream.url, isNotNull);
    expect(stream.localPath, isNull);

    // 4. 携 Range 走代理：凭据在源节点附加，客户端无需知道
    final http = HttpClient();
    addTearDown(http.close);
    final request = await http.getUrl(Uri.parse(stream.url!));
    request.headers.set('Range', 'bytes=100-103');
    final response = await request.close();
    expect(response.statusCode, 206);
    expect(response.headers.value('content-range'), 'bytes 100-103/256');
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    expect(bytes, [100, 101, 102, 103]);

    // 5. 移除源后浏览报错
    final removed = await remote.removeSource(sourceId: source['sourceId'] as String);
    expect(removed['ok'], true);
    await expectLater(
      remote.browse(sourceId: source['sourceId'] as String),
      throwsA(isA<PlayerRemoteException>()),
    );
  });

  test('网络源配置持久化：节点重启后仍在', () async {
    final dataDir = '${Directory.systemTemp.createTempSync('omniplay-persist-').path}/data';
    final node = Node(
      config: NodeConfig(name: '持久化', dataDir: dataDir, httpPort: 0, udpPort: null),
    );
    await node.start();
    final info = await node.addWebdavSource(
      url: 'http://127.0.0.1:${dav.port}/dav/',
      username: 'user',
      password: 'pass',
    );
    await node.stop();

    final restarted = Node(
      config: NodeConfig(name: '持久化', dataDir: dataDir, httpPort: 0, udpPort: null),
    );
    await restarted.start();
    addTearDown(restarted.stop);
    expect(restarted.library.contains(info.sourceId), isTrue);
    expect(restarted.library.sources.firstWhere((s) => s.sourceId == info.sourceId).kind, 'webdav');
  });
}
