/// 极简 YAML 解析器（plugin.yaml：扁平 key: value + 单层 dependencies: map）。
/// 避免引入 `yaml` 包。规则：
/// - 行内 `#` 后为注释；
/// - `key:`（键后立即冒号、无值）= 分组标记，建立嵌套 map；
/// - `key: value` = 平坦项，按当前分组落入或落入根。
Map<String, Object?> parseSimpleYaml(String source) {
  final lines = source.split('\n');
  final root = <String, Object?>{};
  Map<String, Object?>? currentMap;

  for (final raw in lines) {
    final line = raw.replaceFirst(RegExp(r'#.*$'), '').trimRight();
    if (line.trim().isEmpty) continue;
    final indent = _leadingSpaces(raw);
    final content = line.trimLeft();
    final colon = content.indexOf(':');
    if (colon <= 0) continue;
    final key = content.substring(0, colon).trim();
    final rest = content.substring(colon + 1).trim();

    if (rest.isEmpty) {
      // 分组标记：建嵌套 map，切换当前写入对象。
      if (indent == 0) {
        currentMap = <String, Object?>{};
        root[key] = currentMap;
      } else if (currentMap != null) {
        final map = <String, Object?>{};
        currentMap[key] = map;
        currentMap = map;
      }
      continue;
    }

    var value = rest;
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }
    (currentMap ?? root)[key] = value;
  }
  return root;
}

int _leadingSpaces(String s) {
  var i = 0;
  while (i < s.length && s.codeUnitAt(i) == 0x20) {
    i++;
  }
  return i;
}