import 'package:flutter/material.dart';
import 'package:node_core/node_core.dart';

/// 通用遥控盘（C3）：Android 虚拟遥控器与 macOS「控制其他节点」共用。
class RemotePad extends StatefulWidget {
  const RemotePad({
    super.key,
    required this.remote,
    required this.state,
    required this.onBrowse,
  });

  final PlayerRemote remote;
  final PlayerStatePayload? state;
  final VoidCallback onBrowse;

  @override
  State<RemotePad> createState() => _RemotePadState();
}

class _RemotePadState extends State<RemotePad> {
  double? _dragPositionMs;

  PlayerStatePayload get _state => widget.state ?? _idle;

  static final PlayerStatePayload _idle = PlayerStatePayload(epoch: 0, state: PlaybackStateName.idle, positionMs: 0, durationMs: 0, speed: 1, volume: 100);

  String _fmt(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final playing = state.state == PlaybackStateName.playing;
    final duration = state.durationMs <= 0 ? 1.0 : state.durationMs.toDouble();
    final position = (_dragPositionMs ?? state.positionMs).clamp(0, state.durationMs).toDouble();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(state.title!, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          ),
        if (state.controllerName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('受控于 ${state.controllerName}', style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          ),
        Text(
          '${_fmt(position.round())} / ${_fmt(state.durationMs)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: position,
          max: duration,
          onChangeStart: (v) => setState(() => _dragPositionMs = v),
          onChanged: (v) => setState(() => _dragPositionMs = v),
          onChangeEnd: (v) {
            widget.remote.seekMs(v.round());
            setState(() => _dragPositionMs = null);
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: '停止',
              onPressed: widget.remote.stop,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: playing ? widget.remote.pause : widget.remote.play,
              icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 40),
              label: Text(playing ? '暂停' : '播放'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '浏览内容源并投片',
              onPressed: widget.onBrowse,
              icon: const Icon(Icons.video_library_outlined),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.volume_down, size: 20),
            Expanded(
              child: Slider(
                value: state.volume.clamp(0, 100).toDouble(),
                max: 100,
                onChanged: (v) => widget.remote.setVolume(v.round()),
              ),
            ),
            const Icon(Icons.volume_up, size: 20),
          ],
        ),
        Wrap(
          spacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final rate in const [0.5, 1.0, 1.25, 1.5, 2.0])
              ChoiceChip(
                label: Text('${rate}x'),
                selected: state.speed == rate,
                onSelected: (_) => widget.remote.setSpeed(rate),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (state.audioTracks.isNotEmpty)
              DropdownButton<int>(
                value: state.currentAudio,
                hint: const Text('音轨'),
                items: [
                  for (final track in state.audioTracks)
                    DropdownMenuItem(value: track.index, child: Text(track.title ?? '音轨 ${track.index}')),
                ],
                onChanged: (index) {
                  if (index != null) widget.remote.selectTrack(kind: 'audio', index: index);
                },
              ),
            const SizedBox(width: 16),
            if (state.subtitleTracks.isNotEmpty)
              DropdownButton<int>(
                value: state.currentSubtitle,
                hint: const Text('字幕'),
                items: [
                  for (final track in state.subtitleTracks)
                    DropdownMenuItem(value: track.index, child: Text(track.title ?? '字幕 ${track.index}')),
                ],
                onChanged: (index) {
                  if (index != null) widget.remote.selectTrack(kind: 'subtitle', index: index);
                },
              ),
          ],
        ),
      ],
    );
  }
}
