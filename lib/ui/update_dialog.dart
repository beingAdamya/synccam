import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_service.dart';
import '../core/updates.dart';
import 'theme.dart';
import 'widgets.dart';

/// "A new version is ready" popup. On Android the whole update happens here:
/// download with progress, verify, then Android's install screen.
Future<void> showUpdateDialog(BuildContext context, ReleaseInfo release) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(release: release),
  );
}

/// The "what's new" part of release notes (above the `---` line), as
/// plain bullet lines.
List<String> whatsNew(String notes) {
  final top = notes.split(RegExp(r'^\s*---\s*$', multiLine: true)).first;
  return top
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[*`#]'), '').replaceFirst(RegExp(r'^\s*[-•]\s*'), '').trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

enum _Stage { info, downloading, ready, needsPermission, error }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.release});
  final ReleaseInfo release;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Stage _stage = _Stage.info;
  double _progress = 0;
  String? _error;
  File? _apk;
  bool _cancel = false;

  ReleaseInfo get r => widget.release;

  Future<void> _update() async {
    if (!Platform.isAndroid) {
      // iPhone apps can't install themselves: open the release page.
      await launchUrl(Uri.parse(r.pageUrl), mode: LaunchMode.externalApplication);
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _stage = _Stage.downloading;
      _progress = 0;
      _cancel = false;
    });
    try {
      _apk = await UpdateInstaller.download(r,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          cancelled: () => _cancel);
      if (!mounted) return;
      setState(() => _stage = _Stage.ready);
      await _install();
    } catch (e) {
      if (UpdateInstaller.isCancel(e)) {
        if (mounted) setState(() => _stage = _Stage.info);
        return;
      }
      if (mounted) {
        setState(() {
          _stage = _Stage.error;
          _error = e is StateError ? e.message : 'Couldn\'t download the update. Check your internet and try again.';
        });
      }
    }
  }

  Future<void> _install() async {
    final apk = _apk;
    if (apk == null) return;
    final started = await UpdateInstaller.install(apk);
    if (!mounted) return;
    setState(() => _stage = started ? _Stage.ready : _Stage.needsPermission);
  }

  Future<void> _later({bool skip = false}) async {
    if (skip) await UpdateChecker.skip(r);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final notes = whatsNew(r.notes);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Center(child: AppLogo(size: 84)),
            const SizedBox(height: 16),
            Text('A new version is ready', textAlign: TextAlign.center, style: t.titleLarge),
            const SizedBox(height: 8),
            Center(
              child: StatusPill('SyncCam ${r.version}  ·  you have ${AppVersion.current}',
                  color: Brand.coral, icon: Icons.auto_awesome_rounded),
            ),
            const SizedBox(height: 18),
            if (notes.isNotEmpty) ...[
              Text('What\'s new', style: t.titleSmall?.copyWith(color: Brand.textDim)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final n in notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 5),
                            child: Icon(Icons.circle, size: 7, color: Brand.coral),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(n, style: t.bodyMedium)),
                        ]),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
            ],
            ..._actions(t),
          ]),
        ),
      ),
    );
  }

  List<Widget> _actions(TextTheme t) {
    switch (_stage) {
      case _Stage.info:
        return [
          PrimaryButton(
            label: Platform.isAndroid ? 'Update now' : 'Get the update',
            icon: Icons.system_update_alt_rounded,
            onPressed: _update,
          ),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => _later(skip: true), child: const Text('Skip this version'))),
            Expanded(child: TextButton(onPressed: _later, child: const Text('Later'))),
          ]),
        ];
      case _Stage.downloading:
        final mb = r.apkSize == null ? '' : ' of ${(r.apkSize! / 1048576).toStringAsFixed(0)} MB';
        return [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: _progress > 0 ? _progress : null, minHeight: 10, color: Brand.red),
          ),
          const SizedBox(height: 10),
          Text('Downloading… ${(100 * _progress).round()}%$mb', textAlign: TextAlign.center, style: t.bodySmall),
          TextButton(onPressed: () => _cancel = true, child: const Text('Cancel')),
        ];
      case _Stage.ready:
        return [
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.check_circle_rounded, color: Brand.good),
            SizedBox(width: 8),
            Text('Downloaded. Tap Install on the next screen.'),
          ]),
          const SizedBox(height: 12),
          PrimaryButton(label: 'Install', icon: Icons.install_mobile_rounded, onPressed: _install),
          TextButton(onPressed: _later, child: const Text('Close')),
        ];
      case _Stage.needsPermission:
        return [
          Text(
            'Android needs your OK first: in the screen that opened, turn on "Allow from this source" for SyncCam, '
            'then come back and tap Install.',
            textAlign: TextAlign.center,
            style: t.bodyMedium,
          ),
          const SizedBox(height: 12),
          PrimaryButton(label: 'Install', icon: Icons.install_mobile_rounded, onPressed: _install),
          TextButton(onPressed: _later, child: const Text('Later')),
        ];
      case _Stage.error:
        return [
          Text(_error ?? 'Something went wrong.', textAlign: TextAlign.center, style: const TextStyle(color: Brand.warn)),
          const SizedBox(height: 12),
          PrimaryButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: _update),
          TextButton(onPressed: _later, child: const Text('Later')),
        ];
    }
  }
}
