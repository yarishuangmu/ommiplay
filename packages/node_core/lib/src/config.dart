/// 节点配置。端口默认值见 docs/development.md（冲突可改）。
class NodeConfig {
  NodeConfig({
    required this.name,
    required this.dataDir,
    this.httpPort = defaultHttpPort,
    this.udpPort = defaultUdpPort,
    this.mediaDirs = const [],
    this.webRoot,
    this.announceHost,
  });

  /// 节点显示名（发现列表与 hello 中呈现）。
  final String name;

  /// 本地数据目录（sqlite、密钥等）。
  final String dataDir;

  /// HTTP + WS 服务端口；传 0 表示系统分配（测试用），启动后经 [Node.boundPort] 读取。
  final int httpPort;

  /// UDP 信标端口；传 null 关闭信标通道（测试用）。
  final int? udpPort;

  /// 本机对外共享的媒体目录（Library 角色，M0 全部为本地文件夹）。
  final List<String> mediaDirs;

  /// Web 控制页静态资源目录；null 则托管内置占位页。
  final String? webRoot;

  /// 对外宣告的主机名/IP；null 则自动探测本机局域网 IPv4。
  final String? announceHost;

  static const int defaultHttpPort = 47771;
  static const int defaultUdpPort = 47770;
}
