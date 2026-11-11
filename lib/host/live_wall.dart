import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/protocol.dart';
import '../core/widgets.dart';
import '../ui/cam_status.dart';
import '../ui/rig_widgets.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'device_detail_screen.dart';
import 'device_tile.dart';
import 'host_server.dart';
import 'rig_settings.dart';
import 'sync_panel.dart';

/// The main shooting screen: every camera's live view as one monitor, the
/// rig's status along the top, and the shutter where the thumb rests.
class LiveWall extends StatefulWidget {
  const LiveWall({
    super.key,
    required this.server,
    required this.onAddCameras,
    required this.menu,
    this.dockInset = EdgeInsets.zero,
  });
  final HostServer server;
  final VoidCallback onAddCameras;

  /// The ⋯ menu in the top bar.
  final Widget menu;

  /// Space kept clear for the floating tab dock.
  final EdgeInsets dockInset;

  @override
  State<LiveWall> createState() => _LiveWallState();
}

class _LiveWallState extends State<LiveWall> {
  HostServer get server => widget.server;

  /// Columns chosen by pinching; null = automatic.
  int? _cols;
  double _pinchStart = 1;
  bool _overlays = true;

  /// Controls folded away, leaving only the floating shutter.
  bool _collapsed = false;
  bool _slateFlash = false;
  bool _preflightDone = false;
  final _flash = ValueNotifier<int>(0);
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    server.slateFlash.addListener(_onSlate);
  }

  Future<void> _onSlate() async {
    setState(() => _slateFlash = true);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (mounted) setState(() => _slateFlash = false);
  }

  /// Sync beep: a beep and a white flash of this screen, so cameras that
  /// hear or see it (and any camera recording on its own) can be lined up.
  Widget _syncBeepButton() => Semantics(
    button: true,
    label: 'Sync beep',
    child: Tooltip(
      message: 'Sync beep: beeps and flashes this screen',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          Haptic.light();
          server.slate();
        },
        child: const SizedBox(
          width: 56,
          height: 56,
          child: VideoGlass(
            radius: 28,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.flash_on_rounded, color: Colors.white, size: 22),
                  Text(
                    'Sync',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _collapseButton({required bool landscape}) {
    final icon = landscape
        ? (_collapsed
              ? Icons.chevron_left_rounded
              : Icons.chevron_right_rounded)
        : (_collapsed ? Icons.expand_less_rounded : Icons.expand_more_rounded);
    final button = IconButton(
      tooltip: _collapsed ? 'Show controls' : 'Hide controls',
      icon: Icon(icon, color: Colors.white),
      onPressed: () {
        Haptic.tick();
        setState(() => _collapsed = !_collapsed);
      },
    );
    return _collapsed && !landscape
        ? SizedBox(
            width: 56,
            height: 56,
            child: VideoGlass(radius: 28, child: Center(child: button)),
          )
        : SizedBox(width: 56, child: Center(child: button));
  }

  @override
  void dispose() {
    server.slateFlash.removeListener(_onSlate);
    _flash.dispose();
    _flashTimer?.cancel();
    super.dispose();
  }

  bool get _videoMode =>
      server.config.mode == CaptureMode.video ||
      server.config.mode == CaptureMode.interval;
  bool get _active =>
      (server.config.mode == CaptureMode.video && server.anyRecording) ||
      (server.config.mode == CaptureMode.interval && server.intervalRunning);

  int? get _recStartUs {
    final starts = server.onlineDevices
        .where((d) => d.recording)
        .map((d) => d.recStartHostUs)
        .nonNulls;
    return starts.isEmpty ? null : starts.reduce(math.min);
  }

  // ------------------------------------------------------------ shutter

  Future<void> _press() async {
    if (!_active && !_preflightDone) {
      _preflightDone = true;
      final issues = [
        for (final d in server.devices)
          if (statusOf(d) case final s
              when s.state == CamState.warning || s.state == CamState.lost)
            s.fix ?? '${d.name}: ${s.word}',
      ];
      if (issues.isNotEmpty) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Before you shoot'),
            content: Text('${issues.join('\n\n')}\n\nShoot anyway?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Fix'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Shoot'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (go != true) {
          showNotReadySheet(context, server);
          return;
        }
      }
    }
    final wasActive = _active;
    server.shutter();
    if (_videoMode) {
      Haptic.light();
    }
    if (!_videoMode ||
        (server.config.mode == CaptureMode.interval && !wasActive)) {
      // Flash every tile at the moment the cameras fire: visual proof they
      // fired together.
      final at = server.nextTriggerUs;
      if (at != null) {
        _flashTimer?.cancel();
        _flashTimer = Timer(
          Duration(microseconds: math.max(0, at - server.nowUs())),
          () => _flash.value++,
        );
      }
    }
  }

  // ------------------------------------------------------------- layout

  /// Columns that make the best use of the space for [n] tiles.
  int _autoCols(int n, Size size, {required bool landscape}) {
    if (n <= 1) return 1;
    var best = 1;
    var bestScore = double.infinity;
    for (var c = 1; c <= math.min(n, 5); c++) {
      final r = (n / c).ceil();
      final cell = Size(size.width / c, size.height / r);
      final aspect = cell.width / cell.height;
      // Prefer cells shaped like the frames (3:4 upright, 3:2 sideways)
      // and few empty slots.
      final score =
          (math.log(aspect / (landscape ? 1.5 : 0.75))).abs() +
          (c * r - n) * 0.15;
      if (score < bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  Widget _grid(List<RemoteDevice> devices, bool landscape) {
    return LayoutBuilder(
      builder: (context, box) {
        final n = devices.length;
        final cols = (_cols ?? _autoCols(n, box.biggest, landscape: landscape))
            .clamp(1, math.max(1, n))
            .toInt();
        final rows = (n / cols).ceil();
        const gap = 4.0;
        final cellW = (box.maxWidth - gap * (cols - 1)) / cols;
        var cellH = (box.maxHeight - gap * (rows - 1)) / rows;
        // Too many rows to fit: keep tiles a usable shape and scroll.
        final scroll = cellH < cellW * 0.4;
        if (scroll) cellH = cellW * 0.75;
        return GestureDetector(
          onScaleStart: (_) => _pinchStart = 1,
          onScaleUpdate: (d) {
            if (d.pointerCount < 2) return;
            if (d.scale / _pinchStart > 1.3 && cols > 1) {
              _pinchStart = d.scale;
              setState(() => _cols = cols.toInt() - 1);
              Haptic.tick();
            } else if (d.scale / _pinchStart < 0.75 && cols < math.min(n, 5)) {
              _pinchStart = d.scale;
              setState(() => _cols = cols.toInt() + 1);
              Haptic.tick();
            }
          },
          child: SingleChildScrollView(
            physics: scroll ? null : const NeverScrollableScrollPhysics(),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final (i, d) in devices.indexed)
                  SizedBox(
                    width: cellW,
                    height: cellH,
                    child: CameraTile(
                      key: ValueKey(d.id),
                      device: d,
                      server: server,
                      flash: _flash,
                      overlays: _overlays,
                      onTap: () => _openDetail(d),
                      onDoubleTap: () => _openFull(devices, i),
                      onLongPress: () {
                        Haptic.light();
                        server.identify(d);
                        showSnack(context, '${d.name} is flashing its number.');
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openDetail(RemoteDevice d) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DeviceDetailScreen(server: server, device: d),
      ),
    );
  }

  void _openFull(List<RemoteDevice> devices, int i) {
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) =>
            _FullScreenCameras(server: server, devices: devices, initial: i),
        transitionsBuilder: (_, a, _, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
  }

  // --------------------------------------------------------------- bars

  /// Rig name and timecode, cameras ready, sync quality. Two rows on a
  /// narrow screen so the name is never cut off.
  Widget _topBar({bool twoRows = false}) {
    final rec = _recStartUs;
    final title = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            server.sessionName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: Colors.white,
            ),
          ),
          Every(
            const Duration(milliseconds: 250),
            builder: (_) {
              if (rec != null) {
                final e = Duration(microseconds: server.nowUs() - rec);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.fiber_manual_record_rounded,
                      size: 10,
                      color: Status.recording,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _timecode(e),
                      style: mono(
                        size: 13,
                        color: Status.recording,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ],
                );
              }
              final c = server.nextTriggerUs;
              if (c != null && server.config.countdownSec > 0) {
                final remain = ((c - server.nowUs()) / 1e6).ceil();
                if (remain > 0) {
                  return Text(
                    'Shooting in $remain',
                    style: mono(size: 13, color: Status.syncing),
                  );
                }
              }
              final now = DateTime.now();
              return Text(
                '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
                style: mono(size: 13, color: Colors.white60),
              );
            },
          ),
        ],
      ),
    );
    final status = <Widget>[
      ReadyCounter(server: server),
      const SizedBox(width: 6),
      SyncMeter(
        server: server,
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => SyncSheet(server: server),
        ),
      ),
    ];
    final actions = <Widget>[
      IconButton(
        tooltip: _overlays ? 'Hide badges' : 'Show badges',
        icon: Icon(
          _overlays ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          color: Colors.white70,
        ),
        onPressed: () => setState(() => _overlays = !_overlays),
      ),
      widget.menu,
    ];
    return VideoGlass(
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      child: twoRows
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [title, ...actions]),
                Padding(
                  padding: const EdgeInsets.only(right: 10, bottom: 4),
                  child: Row(
                    children: [
                      ...status.take(1),
                      const Spacer(),
                      ...status.skip(2),
                    ],
                  ),
                ),
              ],
            )
          : Row(children: [title, ...status, ...actions]),
    );
  }

  static String two(int v) => v.toString().padLeft(2, '0');
  static String _timecode(Duration d) =>
      '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';

  Widget _modeSwitch({Axis axis = Axis.horizontal}) {
    final mode = server.config.mode;
    final busy = server.anyRecording || server.intervalRunning;
    Widget item(CaptureMode m, String label) {
      final sel =
          mode == m || (m == CaptureMode.video && mode == CaptureMode.interval);
      return Semantics(
        selected: sel,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
          onTap: busy || sel
              ? null
              : () {
                  Haptic.tick();
                  server.config.mode = m;
                  server.updatePolicy();
                },
          child: Container(
            constraints: BoxConstraints(minHeight: axis == Axis.vertical ? 34 : 40, minWidth: 64),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: sel
                  ? Colors.white.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
            ),
            child: Text(
              m == CaptureMode.video && mode == CaptureMode.interval
                  ? 'Time-lapse'
                  : label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                letterSpacing: 0.4,
                color: sel
                    ? (m == CaptureMode.video ? Status.recording : Colors.white)
                    : Colors.white60,
              ),
            ),
          ),
        ),
      );
    }

    final items = [
      item(CaptureMode.photo, 'PHOTO'),
      item(CaptureMode.video, 'VIDEO'),
      item(CaptureMode.burst, 'BURST'),
    ];
    return axis == Axis.horizontal
        ? Row(mainAxisSize: MainAxisSize.min, children: items)
        : Column(mainAxisSize: MainAxisSize.min, children: items);
  }

  Widget _quickStrip() {
    final g = server.global;
    final t = context.sync;
    Widget chip(
      String text, {
      bool on = false,
      IconData? icon,
      required VoidCallback onTap,
      bool isMono = true,
    }) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on
                ? t.accent.withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
            border: Border.all(
              color: on ? t.accent.withValues(alpha: 0.6) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: on ? t.accent : Colors.white70),
                const SizedBox(width: 5),
              ],
              Text(
                text,
                style: isMono
                    ? mono(
                        size: 12,
                        color: on ? t.accent : Colors.white,
                        weight: FontWeight.w600,
                      )
                    : TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: on ? t.accent : Colors.white,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    final ev = g.exposureOffset;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip(
            '${resLabel(g.resolution)} · ${g.fps == null ? 'Auto' : '${g.fps} fps'}',
            onTap: () => showRigSettings(context, server),
          ),
          chip(
            '${g.zoom.toStringAsFixed(1)}×',
            icon: Icons.zoom_in_rounded,
            onTap: () => showRigSettings(context, server),
          ),
          chip(
            ev.abs() < 0.05
                ? 'EV ±0'
                : 'EV ${ev > 0 ? '+' : '−'}${ev.abs().toStringAsFixed(1)}',
            icon: Icons.exposure_rounded,
            onTap: () => showRigSettings(context, server),
          ),
          chip(
            'Light',
            icon: Icons.lock_rounded,
            on: g.exposureLocked,
            isMono: false,
            onTap: () {
              Haptic.tick();
              server.updateGlobal((s) => s.exposureLocked = !s.exposureLocked);
            },
          ),
          chip(
            'Focus',
            icon: Icons.center_focus_strong_rounded,
            on: g.focusLocked,
            isMono: false,
            onTap: () {
              Haptic.tick();
              server.updateGlobal((s) => s.focusLocked = !s.focusLocked);
            },
          ),
          chip(
            g.lens == LensChoice.front ? 'Front' : 'Back',
            icon: Icons.cameraswitch_rounded,
            isMono: false,
            onTap: () {
              Haptic.tick();
              server.updateGlobal(
                (s) => s.lens = s.lens == LensChoice.front
                    ? LensChoice.back
                    : LensChoice.front,
              );
            },
          ),
          chip(
            'More',
            icon: Icons.tune_rounded,
            isMono: false,
            onTap: () => showRigSettings(context, server),
          ),
        ],
      ),
    );
  }

  Widget _shutter() {
    final readyCount = server.devices.where((d) => statusOf(d).isReady).length;
    final rec = _recStartUs;
    final long = rec != null && server.nowUs() - rec > 10 * 1000000;
    double? countdown;
    final at = server.nextTriggerUs;
    if (at != null && server.config.countdownSec > 0) {
      final total =
          (server.config.leadMs + server.config.countdownSec * 1000) * 1000;
      countdown = (1 - (at - server.nowUs()) / total).clamp(0.0, 1.0);
    }
    return Shutter(
      mode: server.config.mode,
      active: _active,
      enabled: readyCount > 0 || _active,
      disabledReason: server.devices.isEmpty ? 'Add a camera first.' : 'No camera is ready yet. Wait for them to sync, or tap the ready counter to see why.',
      holdToStop: _active && long,
      countdown: countdown,
      onPressed: _press,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final devices = server.devices;
        final mq = MediaQuery.of(context);
        final landscape = mq.size.width > mq.size.height;
        final pad = mq.padding;
        final recording = server.anyRecording;
        final ticking = server.nextTriggerUs != null || recording;

        final shutter = ticking
            ? Every(
                const Duration(milliseconds: 100),
                builder: (_) => _shutter(),
              )
            : _shutter();

        final wall = devices.isEmpty
            ? _EmptyWall(onAdd: widget.onAddCameras)
            : _grid(devices, landscape);

        final body = landscape
            ? Row(
                children: [
                  SizedBox(width: widget.dockInset.left),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: EdgeInsets.only(top: pad.top + 64),
                            child: wall,
                          ),
                        ),
                        Positioned(
                          left: 8,
                          right: 8,
                          top: pad.top + 6,
                          child: _topBar(),
                        ),
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8 + pad.bottom,
                          child: ApplyRow(server: server),
                        ),
                      ],
                    ),
                  ),
                  // The shutter lives on the right edge, under the thumb.
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      6,
                      pad.top + 6,
                      8 + pad.right,
                      8 + pad.bottom,
                    ),
                    child: VideoGlass(
                      radius: 28,
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 6,
                      ),
                      child: Column(
                        children: [
                          _collapseButton(landscape: true),
                          if (!_collapsed) _modeSwitch(axis: Axis.vertical),
                          const Spacer(),
                          shutter,
                          const Spacer(),
                          _syncBeepButton(),
                          if (!_collapsed)
                            IconButton(
                              tooltip: 'Rig settings',
                              icon: const Icon(
                                Icons.tune_rounded,
                                color: Colors.white,
                              ),
                              onPressed: () => showRigSettings(context, server),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  SizedBox(height: pad.top + 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: _topBar(twoRows: true),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: wall,
                          ),
                        ),
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: ApplyRow(server: server),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      8,
                      6,
                      8,
                      widget.dockInset.bottom + 6,
                    ),
                    // Collapsed: only the floating shutter stays, in the
                    // same place, so more of the picture shows.
                    child: _collapsed
                        ? Row(
                            children: [
                              _syncBeepButton(),
                              const Spacer(),
                              shutter,
                              const Spacer(),
                              _collapseButton(landscape: false),
                            ],
                          )
                        : VideoGlass(
                            radius: 24,
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _quickStrip(),
                                const SizedBox(height: 8),
                                _modeSwitch(),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    _syncBeepButton(),
                                    const Spacer(),
                                    shutter,
                                    const Spacer(),
                                    _collapseButton(landscape: false),
                                  ],
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              );

        return ColoredBox(
          color: const Color(0xFF050507),
          child: Stack(
            children: [
              Positioned.fill(child: body),
              // Sync beep: the whole screen flashes white so every camera
              // pointed at it sees the same instant.
              if (_slateFlash)
                const IgnorePointer(
                  child: ColoredBox(
                    color: Colors.white,
                    child: SizedBox.expand(),
                  ),
                ),
              // Recording: a thin red edge around the whole screen.
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: recording ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Status.recording, width: 3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyWall extends StatelessWidget {
  const _EmptyWall({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.grid_view_rounded,
              size: 48,
              color: Colors.white38,
            ),
            const SizedBox(height: 16),
            const Text(
              'No cameras yet',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Add phones, iPhones or Wi-Fi cameras. Each one appears here as it joins.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              label: 'Add camera',
              icon: Icons.add_rounded,
              expand: false,
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

/// One camera full screen; swipe to step through the rig.
class _FullScreenCameras extends StatefulWidget {
  const _FullScreenCameras({
    required this.server,
    required this.devices,
    required this.initial,
  });
  final HostServer server;
  final List<RemoteDevice> devices;
  final int initial;

  @override
  State<_FullScreenCameras> createState() => _FullScreenCamerasState();
}

class _FullScreenCamerasState extends State<_FullScreenCameras> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late int _i = widget.initial;
  bool _fit = true;

  @override
  void initState() {
    super.initState();
    widget.server.setFocused(widget.devices[_i].id);
  }

  @override
  void dispose() {
    widget.server.setFocused(null);
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.devices.length,
            onPageChanged: (i) {
              setState(() => _i = i);
              widget.server.setFocused(widget.devices[i].id);
              Haptic.tick();
            },
            itemBuilder: (_, i) => CameraTile(
              device: widget.devices[i],
              server: widget.server,
              fit: _fit ? BoxFit.contain : BoxFit.cover,
              onTap: () => setState(() => _fit = !_fit),
              onDoubleTap: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            top: pad.top + 8,
            right: 8,
            child: VideoGlass(
              radius: 24,
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          Positioned(
            bottom: pad.bottom + 16,
            left: 0,
            right: 0,
            child: Center(
              child: VideoGlass(
                radius: 20,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Text(
                  '${widget.devices[_i].name} · ${_i + 1} of ${widget.devices.length} · tap to ${_fit ? 'fill' : 'fit'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
