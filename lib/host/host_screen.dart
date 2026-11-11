import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/prefs.dart';
import '../node/camera_node.dart';
import '../ui/cam_status.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'add_cameras.dart';
import 'calibration_screen.dart';
import 'external_camera_screen.dart';
import 'gallery_screen.dart';
import 'host_server.dart';
import 'live_wall.dart';
import 'recent_rigs.dart';
import 'settings_tab.dart';
import 'take.dart';

/// The controller: a floating glass dock with Rig (live wall and shooting),
/// Gallery and Settings.
class HostScreen extends StatefulWidget {
  const HostScreen({
    super.key,
    required this.sessionName,
    required this.hostIsCamera,
    required this.library,
  });
  final String sessionName;
  final bool hostIsCamera;
  final TakeLibrary library;

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> with WidgetsBindingObserver {
  late final HostServer server = HostServer(
    sessionName: widget.sessionName,
    library: widget.library,
  );
  StreamSubscription<CaptureReport>? _reportSub;
  bool _ending = false;
  CameraNode? _localNode;
  bool _wasSuspended = false;
  int _tab = 0;

  // For haptics on rig-wide changes.
  bool _wasAllReady = false;
  int _lostBefore = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    server.addListener(_changed);
    server.start().then((_) async {
      if (widget.hostIsCamera && server.startError == null) {
        // The controller joins its own rig over loopback, so it behaves
        // exactly like every other camera.
        final id = await NodeIdentity.load();
        final node = CameraNode(hostAddress: '127.0.0.1', identity: id);
        await node.start();
        if (mounted) setState(() => _localNode = node);
      }
    });
    _reportSub = server.reports.listen((r) {
      if (!mounted || r.ok) return;
      // Successful shots are shown by the flash and the ticks; only
      // problems need words.
      showSnack(context, r.text, duration: const Duration(seconds: 5));
    });
  }

  Future<void> _endSession() async {
    if (_ending) return;
    final recording = server.anyRecording || server.intervalRunning;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this shoot?'),
        content: Text(
          [
            if (recording)
              'Recording is still on. It will be stopped and saved first.',
            'The ${server.onlineDevices.length} connected cameras will be let go.',
            'Your photos and videos stay in the Gallery.',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Status.recording,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End shoot'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _ending = true;
    await RecentRigs.remember(server, hostIsCamera: widget.hostIsCamera);
    server.wrapUpCaptures();
    if (recording || server.pendingFiles > 0) {
      if (!mounted) return;
      // Keep the controller up until the cameras' files have arrived.
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _FinishingDialog(server: server, waitForStop: recording),
      );
    }
    server.endSession();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) Navigator.of(context).pop();
  }

  void _changed() {
    final all = server.devices;
    final allReady = all.isNotEmpty && all.every((d) => statusOf(d).isReady);
    if (allReady && !_wasAllReady) Haptic.allReady();
    _wasAllReady = allReady;
    final lost = all.where((d) => !d.online).length;
    if (lost > _lostBefore) Haptic.warning();
    _lostBefore = lost;
    if (mounted) setState(() {});
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
    _reportSub?.cancel();
    _localNode?.dispose();
    server.removeListener(_changed);
    server.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _addCameras() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => AddCamerasScreen(server: server)),
  );

  Widget _menu() => PopupMenuButton<String>(
    tooltip: 'More',
    icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
    onSelected: (v) {
      switch (v) {
        case 'add':
          _addCameras();
        case 'cam':
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ExternalCameraScreen(server: server),
            ),
          );
        case 'cal':
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => CalibrationScreen(server: server),
            ),
          );
        case 'end':
          _endSession();
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: 'add',
        child: ListTile(
          leading: Icon(Icons.add_rounded),
          title: Text('Add camera'),
        ),
      ),
      PopupMenuItem(
        value: 'cam',
        child: ListTile(
          leading: Icon(Icons.videocam_rounded),
          title: Text('Wi-Fi camera'),
        ),
      ),
      PopupMenuItem(
        value: 'cal',
        child: ListTile(
          leading: Icon(Icons.timer_outlined),
          title: Text('Fine-tune timing'),
        ),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        value: 'end',
        child: ListTile(
          leading: Icon(Icons.stop_circle_outlined, color: Status.recording),
          title: Text('End shoot', style: TextStyle(color: Status.recording)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final landscape = mq.size.width > mq.size.height;
    final choice = AppPrefs.theme.value;
    // Video is always judged on a dark, neutral surround.
    final rigTheme = buildTheme(
      choice == ThemeChoice.daylight ? ThemeChoice.studio : choice,
    );
    const dockSize = 64.0;

    final pages = [
      Theme(
        data: rigTheme,
        child: LiveWall(
          server: server,
          onAddCameras: _addCameras,
          menu: _menu(),
          dockInset: landscape
              ? EdgeInsets.only(left: dockSize + 12 + mq.padding.left)
              : EdgeInsets.only(bottom: dockSize + 8 + mq.padding.bottom),
        ),
      ),
      AppBackground(
        child: Padding(
          padding: landscape
              ? EdgeInsets.only(left: dockSize + 20 + mq.padding.left)
              : EdgeInsets.only(bottom: dockSize + 16 + mq.padding.bottom),
          child: GalleryView(library: server.library, server: server),
        ),
      ),
      AppBackground(
        child: Padding(
          padding: landscape
              ? EdgeInsets.only(left: dockSize + 20 + mq.padding.left)
              : EdgeInsets.only(bottom: dockSize + 16 + mq.padding.bottom),
          child: SettingsTab(server: server, onEnd: _endSession),
        ),
      ),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab != 0) {
          setState(() => _tab = 0);
        } else {
          _endSession();
        }
      },
      child: Scaffold(
        backgroundColor: _tab == 0 ? Colors.black : context.sync.background,
        body: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(index: _tab, children: pages),
            ),
            if (landscape)
              Positioned(
                left: 8 + mq.padding.left,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Theme(
                    data: rigTheme,
                    child: _Dock(
                      tab: _tab,
                      vertical: true,
                      onTab: _setTab,
                      server: server,
                    ),
                  ),
                ),
              )
            else
              Positioned(
                left: 0,
                right: 0,
                bottom: 8 + mq.padding.bottom,
                child: Center(
                  child: Theme(
                    data: rigTheme,
                    child: _Dock(
                      tab: _tab,
                      vertical: false,
                      onTab: _setTab,
                      server: server,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _setTab(int i) {
    if (i == _tab) return;
    Haptic.tick();
    setState(() => _tab = i);
  }
}

class _Dock extends StatelessWidget {
  const _Dock({
    required this.tab,
    required this.vertical,
    required this.onTab,
    required this.server,
  });
  final int tab;
  final bool vertical;
  final ValueChanged<int> onTab;
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    final accent = context.sync.accent;
    Widget item(int i, IconData icon, String label) {
      final sel = tab == i;
      final rec = i == 0 && server.anyRecording;
      return Semantics(
        selected: sel,
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => onTab(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            constraints: const BoxConstraints(minWidth: 56, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: sel
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: rec
                      ? Status.recording
                      : (sel ? accent : Colors.white70),
                  size: 22,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : Colors.white60,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final items = [
      item(0, Icons.grid_view_rounded, 'Rig'),
      item(1, Icons.photo_library_rounded, 'Gallery'),
      item(2, Icons.settings_rounded, 'Settings'),
    ];
    return VideoGlass(
      radius: 30,
      padding: const EdgeInsets.all(6),
      child: vertical
          ? Column(mainAxisSize: MainAxisSize.min, children: items)
          : Row(mainAxisSize: MainAxisSize.min, children: items),
    );
  }
}

/// Waits for recordings to stop and files to reach the controller before a
/// shoot ends, so "End shoot" never loses footage.
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
      final settled =
          !widget.waitForStop ||
          DateTime.now().difference(_since) > const Duration(seconds: 3);
      final busy =
          s.onlineDevices.any((d) => d.recording) || s.pendingFiles > 0;
      final timedOut =
          DateTime.now().difference(_since) > const Duration(minutes: 3);
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
      title: const Text('Saving everything…'),
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              rec > 0
                  ? 'Stopping recording on $rec camera${rec == 1 ? '' : 's'}…'
                  : s.pendingFiles > 0
                  ? 'Receiving ${s.pendingFiles} file${s.pendingFiles == 1 ? '' : 's'} from the cameras…'
                  : 'Saving…',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('End now'),
        ),
      ],
    );
  }
}
