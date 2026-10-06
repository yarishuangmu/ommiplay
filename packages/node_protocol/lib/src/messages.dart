/// 消息类型常量（命名空间见 docs/protocol.md）。
abstract final class MsgTypes {
  // —— node.*：节点宣告与错误 ——
  static const hello = 'node.hello';
  static const error = 'node.error';

  // —— pair.*：配对与认证 ——
  static const challenge = 'pair.challenge';
  static const authRequest = 'pair.auth.request';
  static const authResult = 'pair.auth.result';
  static const pinRequest = 'pair.pin.request';
  static const pinResponse = 'pair.pin.response';

  // —— lib.*：内容源 ——
  static const sources = 'lib.sources';
  static const browseRequest = 'lib.browse.request';
  static const browseResponse = 'lib.browse.response';
  static const streamRequest = 'lib.stream.request';
  static const streamResponse = 'lib.stream.response';
  static const sourceAdd = 'lib.source.add';
  static const sourceRemove = 'lib.source.remove';

  // —— player.*：播放指令与状态事件 ——
  static const playerLoad = 'player.cmd.load';
  static const playerPlay = 'player.cmd.play';
  static const playerPause = 'player.cmd.pause';
  static const playerStop = 'player.cmd.stop';
  static const playerSeek = 'player.cmd.seek';
  static const playerSetVolume = 'player.cmd.setVolume';
  static const playerSetSpeed = 'player.cmd.setSpeed';
  static const playerSelectTrack = 'player.cmd.selectTrack';
  static const playerState = 'player.evt.state';
  static const playerTakeover = 'player.takeover';

  // —— 语义按键（播放器会话自行映射：音量/快进/暂停/全屏/重播…）——
  static const playerKey = 'player.cmd.key';

  // —— 节点系统控制（重启应用/重启系统/睡眠，按平台能力裁剪）——
  static const restartApp = 'node.cmd.restartApp';
  static const rebootSystem = 'node.cmd.rebootSystem';
  static const sleepSystem = 'node.cmd.sleepSystem';

  // —— PC 控制（仿真触控板/键鼠，仅桌面节点支持，参考 TinyPlay）——
  static const inputMouseMove = 'input.mouseMove';
  static const inputMouseClick = 'input.mouseClick';
  static const inputMouseScroll = 'input.mouseScroll';
  static const inputKeyPress = 'input.keyPress';
  static const inputText = 'input.text';
  static const inputGamepad = 'input.gamepad';

  // —— 在线网页（优酷/爱奇艺/腾讯等，桌面节点内置 WebView 承载）——
  static const webOpen = 'web.open';
  static const webClose = 'web.close';
}

/// node.hello 载荷：节点自我宣告。
class NodeInfo {
  NodeInfo({
    required this.nodeId,
    required this.name,
    required this.roles,
    required this.protoVer,
    required this.httpPort,
  });

  final String nodeId;
  final String name;
  final List<String> roles; // C / P / L
  final int protoVer;
  final int httpPort;

  Map<String, Object?> toJson() => {
        'nodeId': nodeId,
        'name': name,
        'roles': roles,
        'protoVer': protoVer,
        'httpPort': httpPort,
      };

  static NodeInfo fromJson(Map<String, Object?> json) => NodeInfo(
        nodeId: json['nodeId'] as String,
        name: json['name'] as String,
        roles: (json['roles'] as List?)?.cast<String>() ?? const [],
        protoVer: json['protoVer'] as int? ?? 1,
        httpPort: json['httpPort'] as int? ?? 0,
      );
}

/// 内容源（M0 仅本机文件夹）。
class SourceInfo {
  SourceInfo({
    required this.sourceId,
    required this.name,
    required this.root,
    this.kind = 'folder',
  });

  final String sourceId;
  final String name;
  final String root;

  /// 源类型：folder（本机目录）｜ webdav（网络源）…新类型按路线图扩展。
  final String kind;

  Map<String, Object?> toJson() =>
      {'sourceId': sourceId, 'name': name, 'root': root, 'kind': kind};

  static SourceInfo fromJson(Map<String, Object?> json) => SourceInfo(
        sourceId: json['sourceId'] as String,
        name: json['name'] as String,
        root: json['root'] as String,
        kind: json['kind'] as String? ?? 'folder',
      );
}

/// 目录条目。
class LibEntry {
  LibEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.sizeBytes,
  });

  /// 显示名（文件名）。
  final String name;

  /// 相对内容源根目录的路径（浏览请求用）。
  final String path;
  final bool isDir;
  final int? sizeBytes;

  Map<String, Object?> toJson() => {
        'name': name,
        'path': path,
        'isDir': isDir,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
      };

  static LibEntry fromJson(Map<String, Object?> json) => LibEntry(
        name: json['name'] as String,
        path: json['path'] as String,
        isDir: json['isDir'] as bool,
        sizeBytes: json['sizeBytes'] as int?,
      );
}

/// 轨道引用（音轨/字幕轨）。
class TrackRef {
  TrackRef({required this.index, this.title});

  final int index;
  final String? title;

  Map<String, Object?> toJson() =>
      {'index': index, if (title != null) 'title': title};

  static TrackRef fromJson(Map<String, Object?> json) => TrackRef(
        index: json['index'] as int,
        title: json['title'] as String?,
      );
}

enum PlaybackStateName { idle, buffering, playing, paused, ended }

/// player.evt.state 载荷：播放会话全量快照（权威端每次变化都广播整份）。
class PlayerStatePayload {
  PlayerStatePayload({
    required this.epoch,
    this.controllerId,
    this.controllerName,
    required this.state,
    required this.positionMs,
    required this.durationMs,
    required this.speed,
    required this.volume,
    this.title,
    this.source,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.currentAudio,
    this.currentSubtitle,
  });

  final int epoch;
  final String? controllerId;
  final String? controllerName;
  final PlaybackStateName state;
  final int positionMs;
  final int durationMs;
  final double speed;
  final int volume;
  final String? title;
  final String? source;
  final List<TrackRef> audioTracks;
  final List<TrackRef> subtitleTracks;
  final int? currentAudio;
  final int? currentSubtitle;

  Map<String, Object?> toJson() => {
        'epoch': epoch,
        if (controllerId != null) 'controllerId': controllerId,
        if (controllerName != null) 'controllerName': controllerName,
        'state': state.name,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'speed': speed,
        'volume': volume,
        if (title != null) 'title': title,
        if (source != null) 'source': source,
        'audioTracks': audioTracks.map((t) => t.toJson()).toList(),
        'subtitleTracks': subtitleTracks.map((t) => t.toJson()).toList(),
        if (currentAudio != null) 'currentAudio': currentAudio,
        if (currentSubtitle != null) 'currentSubtitle': currentSubtitle,
      };

  static PlayerStatePayload fromJson(Map<String, Object?> json) =>
      PlayerStatePayload(
        epoch: json['epoch'] as int? ?? 0,
        controllerId: json['controllerId'] as String?,
        controllerName: json['controllerName'] as String?,
        state: PlaybackStateName.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => PlaybackStateName.idle,
        ),
        positionMs: json['positionMs'] as int? ?? 0,
        durationMs: json['durationMs'] as int? ?? 0,
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        volume: json['volume'] as int? ?? 100,
        title: json['title'] as String?,
        source: json['source'] as String?,
        audioTracks: ((json['audioTracks'] as List?) ?? const [])
            .map((t) => TrackRef.fromJson(Map<String, Object?>.from(t as Map)))
            .toList(),
        subtitleTracks: ((json['subtitleTracks'] as List?) ?? const [])
            .map((t) => TrackRef.fromJson(Map<String, Object?>.from(t as Map)))
            .toList(),
        currentAudio: json['currentAudio'] as int?,
        currentSubtitle: json['currentSubtitle'] as int?,
      );
}
