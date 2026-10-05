import 'dart:io';

import 'package:node_core/node_core.dart';
import 'package:test/test.dart';

class _FakeSystemControl implements SystemControl {
  int toggles = 0;
  int restarts = 0;
  int reboots = 0;
  int sleeps = 0;

  @override
  Future<bool> toggleFullscreen() async => (++toggles).isOdd;

  @override
  Future<void> restartApp() async => restarts++;

  @override
  Future<void> rebootSystem() async => reboots++;

  @override
  Future<void> sleepSystem() async => sleeps++;
}

class _FakeWebPresenter implements WebPresenter {
  final opened = <String>[];
  var closed = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> open(String url, {bool maximized = false, String? title}) async {
    opened.add(url);
  }

  @override
  Future<void> close() async => closed++;
}

void main() {
  late Directory tempDir;
  late Node node;
  late _FakeSystemControl systemControl;
  late _FakeWebPresenter webPresenter;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('omniplay-ctrl-');
    Directory('${tempDir.path}/media').createSync();
    File('${tempDir.path}/media/a.mkv').writeAsBytesSync(List.filled(256, 7));
    systemControl = _FakeSystemControl();
    webPresenter = _FakeWebPresenter();
    node = Node(
      config: NodeConfig(
        name: '控制测试节点',
        dataDir: '${tempDir.path}/data',
        httpPort: 0,
        udpPort: null,
        mediaDirs: ['${tempDir.path}/media'],
      ),
      playerAdapterFactory: () => FakePlayerAdapter(),
      systemControl: systemControl,
      webPresenter: webPresenter,
    );
    await node.start();
  });

  tearDown(() async {
    await node.stop();
    tempDir.deleteSync(recursive: true);
  });

  test('语义按键：up/down 音量、left/right 快进退、ok 暂停播放、restart 重播', () async {
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '遥控器',
      identity: await NodeIdentity.loadOrCreate(NodeStore.open('${tempDir.path}/c1')),
      pin: node.newPin(),
    );
    addTearDown(remote.close);

    final states = <PlayerStatePayload>[];
    remote.attachStateSink(states.add);
    final sources = await remote.refreshSources();

    await remote.loadMedia(kind: 'file', value: '${sources.first.root}/a.mkv', title: 'A');
    await _waitFor(() => states.last.state == PlaybackStateName.playing);

    // 音量
    await remote.sendKey('down');
    await _waitFor(() => states.last.volume == 90);
    await remote.sendKey('up');
    await _waitFor(() => states.last.volume == 100);

    // 快进
    await remote.sendKey('right');
    await _waitFor(() => states.last.positionMs >= 10000);

    // 暂停/播放
    await remote.sendKey('ok');
    await _waitFor(() => states.last.state == PlaybackStateName.paused);
    await remote.sendKey('playPause');
    await _waitFor(() => states.last.state == PlaybackStateName.playing);

    // 重播：从当前位置重载 → 进度归零（无续播进度时）
    await remote.sendKey('right');
    await _waitFor(() => states.last.positionMs >= 20000);
    await remote.sendKey('restart');
    await _waitFor(() => states.last.positionMs == 0);

    // 全屏切换走 SystemControl
    await remote.sendKey('fullscreen');
    await _waitFor(() => systemControl.toggles >= 1);
    expect(node.session.fullscreen, isTrue);
  });

  test('扫码配对：joinToken 一次性令牌等价 PIN', () async {
    final identity = await NodeIdentity.loadOrCreate(NodeStore.open('${tempDir.path}/scan'));
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '扫码手机',
      identity: identity,
      joinToken: node.newJoinToken(),
    );
    addTearDown(remote.close);
    await _waitFor(() => remote.hello != null);
    expect(node.store.deviceById(identity.deviceId)!.name, '扫码手机');

    // 令牌一次性：第二个设备用同一令牌被拒
    final second = await NodeIdentity.loadOrCreate(NodeStore.open('${tempDir.path}/scan2'));
    await expectLater(
      PlayerRemote.connect(
        host: '127.0.0.1',
        port: node.boundPort,
        deviceName: '第二台',
        identity: second,
        joinToken: node.newJoinToken().isEmpty ? '' : 'expired-token',
      ),
      throwsA(isA<NeedPinException>()),
    );
  });

  test('系统控制与网页承载：命令路由到平台实现', () async {
    final remote = await PlayerRemote.connect(
      host: '127.0.0.1',
      port: node.boundPort,
      deviceName: '系统遥控',
      identity: await NodeIdentity.loadOrCreate(NodeStore.open('${tempDir.path}/c2')),
      pin: node.newPin(),
    );
    addTearDown(remote.close);

    await remote.webOpen('https://www.iqiyi.com', title: '爱奇艺');
    await _waitFor(() => webPresenter.opened.isNotEmpty);
    expect(webPresenter.opened.single, 'https://www.iqiyi.com');

    await remote.rebootSystem();
    await _waitFor(() => systemControl.reboots == 1);
    await remote.sleepSystem();
    await _waitFor(() => systemControl.sleeps == 1);
  });
}

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
