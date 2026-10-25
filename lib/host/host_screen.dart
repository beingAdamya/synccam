import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/protocol.dart';
import '../core/updates.dart';
import '../node/camera_node.dart';
import 'calibration_screen.dart';
import 'device_detail_screen.dart';
import 'device_tile.dart';
import 'gallery_screen.dart';
import 'host_server.dart';
import 'host_settings_screen.dart';
import 'rig_order_screen.dart';
import 'sync_panel.dart';
import 'take.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key, required this.sessionName, required this.hostIsCamera, required this.library});
  final String sessionName;
  final bool hostIsCamera;
  final TakeLibrary library;

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> with WidgetsBindingObserver {
  late final HostServer server = HostServer(sessionName: widget.sessionName, library: widget.library);
  StreamSubscription<CaptureReport>? _reportSub;
  bool _ending = false;
  CameraNode? _localNode;
  Timer? _ticker;
  bool _flash = false;
  bool _wasSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    server.addListener(_changed);
    server.slateFlash.addListener(_onSlate);
    server.start().then((_) async {
      if (widget.hostIsCamera && server.startError == null) {
        // The host phone joins its own session over loopback, so it behaves
        // exactly like every other camera.
        final id = await NodeIdentity.load();
        final node = CameraNode(hostAddress: '127.0.0.1', identity: id);
        node.addListener(_changed);
        await node.start();
        if (mounted) setState(() => _localNode = node);
      }
    });
    // Only the countdown needs a screen-wide tick; REC clocks tick in place.
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (server.nextTriggerUs != null) setState(() {});
    });
    _reportSub = server.reports.listen((r) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          backgroundColor: r.ok ? Colors.green.shade800 : Colors.orange.shade900,
          content: Row(children: [
            Icon(r.ok ? Icons.check_circle : Icons.warning_amber, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(r.text, style: const TextStyle(color: Colors.white))),
          ]),
        ));
    });
  }

  Future<void> _endSession() async {
    if (_ending) return;
    final recording = server.anyRecording || server.intervalRunning;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End session?'),
        content: Text([
          if (recording) 'Recording is still running. It will be stopped and saved.',
          'All ${server.onlineDevices.length} cameras will be disconnected and return to their start screen.',
          'Takes stay in the gallery on this phone.',
        ].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _ending = true;
    server.wrapUpCaptures();
    if (recording || server.pendingFiles > 0) {
      // Keep the host up until the cameras' files have arrived.
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _FinishingDialog(server: server, waitForStop: recording),
      );
    }
    server.endSession();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) Navigator.of(context).pop();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onSlate() async {
    setState(() => _flash = true);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (mounted) setState(() => _flash = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _wasSuspended = true;
        _localNode?.onLifecycle(false);
      case AppLifecycleState.resumed when _wasSuspended:
        _wasSuspended = false;
        if (Platform.isIOS) server.resumeNetwork();
        _localNode?.onLifecycle(true);
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _reportSub?.cancel();
    _localNode?.dispose();
    server.removeListener(_changed);
    server.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _showJoinInfo() {
    showModalBottomSheet<void>(context: context, builder: (_) => _JoinInfo(server: server));
  }

  @override
  Widget build(BuildContext context) {
    final devices = server.devices;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endSession();
      },
      child: Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.sessionName),
              SyncChip(server: server),
            ]),
            actions: [
              IconButton(tooltip: 'Add cameras', icon: const Icon(Icons.qr_code), onPressed: _showJoinInfo),
              IconButton(
                tooltip: 'Takes',
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => GalleryScreen(library: server.library, server: server))),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'end') {
                    _endSession();
                    return;
                  }
                  final page = switch (v) {
                    'rig' => RigOrderScreen(server: server),
                    'cal' => CalibrationScreen(server: server),
                    _ => HostSettingsScreen(server: server),
                  };
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rig', child: Text('Rig order & timing')),
                  PopupMenuItem(value: 'cal', child: Text('Sync calibration clock')),
                  PopupMenuItem(value: 'settings', child: Text('Capture settings')),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'end',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
                      title: Text('End session', style: TextStyle(color: Colors.redAccent)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (server.outdatedDevices case final out when out.isNotEmpty)
                MaterialBanner(
                  leading: Icon(Icons.system_update, color: out.any((d) => d.incompatible) ? Colors.redAccent : Colors.amber),
                  content: Text('${out.length} camera${out.length == 1 ? ' runs' : 's run'} a different SyncCam version '
                      'than this host (${AppVersion.current}): ${out.map((d) => d.name).join(', ')}. '
                      'Update every phone to the same version for reliable sync.'),
                  actions: const [SizedBox()],
                ),
              if (server.startError != null)
                MaterialBanner(content: Text(server.startError!), actions: const [SizedBox()]),
              Expanded(
                child: devices.isEmpty
                    ? _JoinInfo(server: server, big: true)
                    : LayoutBuilder(builder: (context, c) {
                        final cols = c.maxWidth > 900 ? 4 : c.maxWidth > 600 ? 3 : 2;
                        return GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            childAspectRatio: 3 / 4,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                          itemCount: devices.length,
                          itemBuilder: (_, i) => DeviceTile(
                            device: devices[i],
                            server: server,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                  builder: (_) => DeviceDetailScreen(server: server, device: devices[i])),
                            ),
                          ),
                        );
                      }),
              ),
              ControlPanel(server: server),
            ],
          ),
        ),
        if (_localNode?.controller case final CameraController c? when c.value.isInitialized)
          Positioned(
            right: 12,
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            width: 72,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(children: [
                CameraPreview(c),
                const Positioned(
                    left: 4,
                    top: 2,
                    child: Text('this phone', style: TextStyle(color: Colors.white, fontSize: 9))),
              ]),
            ),
          ),
        if (_countdown() case final t?)
          IgnorePointer(
            child: Center(
              child: Text(t,
                  style: const TextStyle(
                      fontSize: 140,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                      shadows: [Shadow(blurRadius: 30)])),
            ),
          ),
        if (_flash) const IgnorePointer(child: ColoredBox(color: Colors.white, child: SizedBox.expand())),
      ],
    ),
    );
  }

  String? _countdown() {
    final t = server.nextTriggerUs;
    if (t == null) return null;
    final remain = (t - server.nowUs()) / 1e6;
    if (remain < 0.9) return null;
    return remain.ceil().toString();
  }
}

/// Bottom panel: mode, the shutter, and the settings every camera shares.
class ControlPanel extends StatelessWidget {
  const ControlPanel({super.key, required this.server});
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    final g = server.global;
    final cfg = server.config;
    final scheme = Theme.of(context).colorScheme;
    final busy = server.anyRecording || server.intervalRunning;
    final maxZoom = server.onlineDevices.isEmpty
        ? 10.0
        : server.onlineDevices.map((d) => d.maxZoom).reduce((a, b) => a > b ? a : b).clamp(1.0, 20.0);

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<CaptureMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: CaptureMode.photo, label: Text('Photo'), icon: Icon(Icons.photo_camera)),
                  ButtonSegment(value: CaptureMode.burst, label: Text('Burst'), icon: Icon(Icons.burst_mode)),
                  ButtonSegment(value: CaptureMode.video, label: Text('Video'), icon: Icon(Icons.videocam)),
                  ButtonSegment(value: CaptureMode.interval, label: Text('Lapse'), icon: Icon(Icons.timelapse)),
                ],
                selected: {cfg.mode},
                onSelectionChanged: busy
                    ? null
                    : (s) {
                        cfg.mode = s.first;
                        server.updatePolicy();
                      },
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _toggle(context, g.lens == LensChoice.front ? Icons.camera_front : Icons.camera_rear,
                      g.lens == LensChoice.front ? 'Front' : 'Back', true, () {
                    server.updateGlobal(
                        (s) => s.lens = s.lens == LensChoice.back ? LensChoice.front : LensChoice.back);
                  }),
                  _toggle(context, _flashIcon(g.flash), g.flash.name, g.flash != FlashChoice.off, () {
                    server.updateGlobal((s) => s.flash = FlashChoice.values[(s.flash.index + 1) % 4]);
                  }),
                  _toggle(context, Icons.lock_outline, 'AE', g.exposureLocked,
                      () => server.updateGlobal((s) => s.exposureLocked = !s.exposureLocked)),
                  _toggle(context, Icons.center_focus_strong, 'AF', g.focusLocked,
                      () => server.updateGlobal((s) => s.focusLocked = !s.focusLocked)),
                  _toggle(context, Icons.grid_on, 'Grid', g.showGrid,
                      () => server.updateGlobal((s) => s.showGrid = !s.showGrid)),
                  _toggle(context, g.enableAudio ? Icons.mic : Icons.mic_off, 'Audio', g.enableAudio,
                      () => server.updateGlobal((s) => s.enableAudio = !s.enableAudio)),
                  PopupMenuButton<ResChoice>(
                    initialValue: g.resolution,
                    onSelected: (r) => server.updateGlobal((s) => s.resolution = r),
                    itemBuilder: (_) => [
                      for (final r in ResChoice.values) PopupMenuItem(value: r, child: Text(_resLabel(r))),
                    ],
                    child: Chip(avatar: const Icon(Icons.high_quality, size: 18), label: Text(_resLabel(g.resolution))),
                  ),
                ]),
              ),
              Row(children: [
                const SizedBox(width: 44, child: Text('Zoom')),
                Expanded(
                  child: Slider(
                    min: 1,
                    max: maxZoom,
                    value: g.zoom.clamp(1, maxZoom),
                    label: '${g.zoom.toStringAsFixed(1)}×',
                    divisions: ((maxZoom - 1) * 10).round().clamp(1, 200),
                    onChanged: (v) => server.updateGlobal((s) => s.zoom = v),
                  ),
                ),
                SizedBox(width: 40, child: Text('${g.zoom.toStringAsFixed(1)}×')),
              ]),
              Row(children: [
                const SizedBox(width: 44, child: Text('EV')),
                Expanded(
                  child: Slider(
                    min: -3,
                    max: 3,
                    divisions: 18,
                    value: g.exposureOffset.clamp(-3, 3),
                    label: g.exposureOffset.toStringAsFixed(1),
                    onChanged: (v) => server.updateGlobal((s) => s.exposureOffset = v),
                  ),
                ),
                SizedBox(width: 40, child: Text(g.exposureOffset.toStringAsFixed(1))),
              ]),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DropdownButton<int>(
                        value: cfg.countdownSec,
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('No timer')),
                          DropdownMenuItem(value: 3, child: Text('3 s')),
                          DropdownMenuItem(value: 5, child: Text('5 s')),
                          DropdownMenuItem(value: 10, child: Text('10 s')),
                        ],
                        onChanged: (v) {
                          cfg.countdownSec = v ?? 0;
                          server.updatePolicy();
                        },
                      ),
                    ),
                  ),
                  _Shutter(server: server),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: server.slate,
                        icon: const Icon(Icons.campaign),
                        label: const Text('Slate'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _resLabel(ResChoice r) => switch (r) {
        ResChoice.low => '240p',
        ResChoice.medium => '480p',
        ResChoice.high => '720p',
        ResChoice.veryHigh => '1080p',
        ResChoice.ultraHigh => '4K',
        ResChoice.max => 'Max',
      };

  static IconData _flashIcon(FlashChoice f) => switch (f) {
        FlashChoice.off => Icons.flash_off,
        FlashChoice.auto => Icons.flash_auto,
        FlashChoice.always => Icons.flash_on,
        FlashChoice.torch => Icons.flashlight_on,
      };

  Widget _toggle(BuildContext context, IconData icon, String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          avatar: Icon(icon, size: 18),
          label: Text(label),
          selected: on,
          showCheckmark: false,
          onSelected: (_) => onTap(),
        ),
      );
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.server});
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    final mode = server.config.mode;
    final active = (mode == CaptureMode.video && server.anyRecording) ||
        (mode == CaptureMode.interval && server.intervalRunning);
    final isVideoish = mode == CaptureMode.video || mode == CaptureMode.interval;
    final enabled = server.onlineDevices.isNotEmpty;
    return GestureDetector(
      onTap: enabled
          ? () {
              // Warn, but never block: the moment may not come again.
              final warnings = active ? const <String>[] : server.preflightWarnings();
              if (warnings.isNotEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(warnings.join('\n'))));
              }
              server.shutter();
            }
          : null,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: enabled ? Colors.white : Colors.white24, width: 4),
        ),
        padding: const EdgeInsets.all(5),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.white24
                : isVideoish
                    ? Colors.red
                    : Colors.white,
            borderRadius: BorderRadius.circular(active ? 8 : 40),
          ),
          margin: EdgeInsets.all(active ? 14 : 0),
        ),
      ),
    );
  }
}

class _JoinInfo extends StatelessWidget {
  const _JoinInfo({required this.server, this.big = false});
  final HostServer server;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final ip = server.addresses.isEmpty ? null : server.addresses.first;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(big ? 'Waiting for cameras' : 'Add cameras', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'On each phone open SyncCam → "Join as camera". This host appears automatically, '
            'or scan the code below. All phones must be on the same Wi-Fi or this phone\'s hotspot.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (ip != null)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: 'synccam://$ip:${Net.httpPort}', size: big ? 220 : 180),
            ),
          const SizedBox(height: 12),
          if (server.addresses.isEmpty)
            const Text('No network found. Connect to Wi-Fi or turn on a hotspot.',
                style: TextStyle(color: Colors.orange))
          else
            SelectableText(server.addresses.map((a) => '$a:${Net.httpPort}').join('\n'),
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// Waits for recordings to stop and files to reach the host before a session
/// ends, so "End session" never loses footage. "End now" skips the wait;
/// cameras keep their own copies in Photos either way.
class _FinishingDialog extends StatefulWidget {
  const _FinishingDialog({required this.server, required this.waitForStop});
  final HostServer server;
  final bool waitForStop;

  @override
  State<_FinishingDialog> createState() => _FinishingDialogState();
}

class _FinishingDialogState extends State<_FinishingDialog> {
  late final Timer _poll;
  final _since = DateTime.now();

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final s = widget.server;
      // Camera status arrives every 2 s, so give a stop at least 3 s to show up.
      final settled = !widget.waitForStop || DateTime.now().difference(_since) > const Duration(seconds: 3);
      final busy = s.onlineDevices.any((d) => d.recording) || s.pendingFiles > 0;
      final timedOut = DateTime.now().difference(_since) > const Duration(minutes: 3);
      if ((settled && !busy) || timedOut) {
        _poll.cancel();
        if (mounted) Navigator.of(context).pop();
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _poll.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.server;
    final rec = s.onlineDevices.where((d) => d.recording).length;
    return AlertDialog(
      title: const Text('Finishing up'),
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 20),
        Expanded(
          child: Text(rec > 0
              ? 'Stopping recording on $rec camera${rec == 1 ? '' : 's'}…'
              : s.pendingFiles > 0
                  ? 'Receiving ${s.pendingFiles} file${s.pendingFiles == 1 ? '' : 's'} from the cameras…'
                  : 'Saving…'),
        ),
      ]),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('End now'))],
    );
  }
}
