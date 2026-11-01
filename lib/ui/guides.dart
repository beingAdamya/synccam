import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// One how-to guide: a goal, numbered steps, and tips.
class Guide {
  const Guide({required this.icon, required this.color, required this.title, required this.summary, required this.steps, this.tips = const []});
  final IconData icon;
  final Color color;
  final String title;
  final String summary;
  final List<String> steps;
  final List<String> tips;
}

const guides = <Guide>[
  Guide(
    icon: Icons.play_circle_fill_rounded,
    color: Brand.red,
    title: 'Start a shoot',
    summary: 'Use one phone to control all the cameras.',
    steps: [
      'Put every phone on the same Wi-Fi. No Wi-Fi? Turn on a hotspot on the phone you\'ll use to control the shoot, and connect the others to it.',
      'On the controlling phone, tap Start a shoot and give it a name.',
      'Add cameras (see the guides below). Each one appears as a live picture on your screen.',
      'Wait until the top says "All in sync", then press the big shutter button. Every camera shoots at the same moment.',
    ],
    tips: [
      'Turn on "Use this phone as a camera too" if the controlling phone should film as well.',
      'Keep phones plugged in for long shoots. SyncCam keeps their screens awake.',
    ],
  ),
  Guide(
    icon: Icons.phone_android_rounded,
    color: Brand.good,
    title: 'Add phones that have the app',
    summary: 'Android phones, and iPhones with SyncCam installed.',
    steps: [
      'Connect the phone to the same Wi-Fi or hotspot as the controlling phone.',
      'Open SyncCam and tap Join as a camera.',
      'Tap your shoot when it appears in the list. If it doesn\'t appear, tap Scan code and point at the QR code on the controlling phone.',
      'Allow camera and microphone access when asked. The phone now shows "Controlled by host".',
    ],
  ),
  Guide(
    icon: Icons.language_rounded,
    color: Brand.sky,
    title: 'Add an iPhone without the app',
    summary: 'Nothing to install: it works in Safari.',
    steps: [
      'Connect the iPhone to the same Wi-Fi or hotspot. It needs internet just for joining.',
      'On the controlling phone, tap Add cameras and choose iPhone, no app.',
      'Point the iPhone\'s Camera app at the QR code and tap the link that appears.',
      'In Safari, tap Start camera and allow camera access. Done.',
    ],
    tips: [
      'Keep Safari open with the screen on while you shoot.',
      'To keep a copy of a photo or video on the iPhone, tap "save" at the bottom of the page.',
    ],
  ),
  Guide(
    icon: Icons.wifi_off_rounded,
    color: Brand.violet,
    title: 'iPhones with no internet',
    summary: 'For shoots far from any internet. Needs a one-time setup.',
    steps: [
      'On the controlling phone, tap Add cameras and choose Offline.',
      'Scan the QR code with the iPhone and open the link in Safari.',
      'Tap Download certificate, then Allow.',
      'Open Settings → General → VPN & Device Management, tap SyncCam and Install.',
      'Open Settings → General → About → Certificate Trust Settings and turn SyncCam on.',
      'Go back to Safari and tap Check & open camera.',
    ],
    tips: ['You only do this once per iPhone. You can remove it later in the same Settings screen.'],
  ),
  Guide(
    icon: Icons.photo_camera_rounded,
    color: Brand.warn,
    title: 'Connect a pro camera',
    summary: 'Sony, Canon, Nikon, Fujifilm, Panasonic, GoPro, Blackmagic and more.',
    steps: [
      'Turn on the camera\'s Wi-Fi remote control. Look for "Remote control", "PC Remote" or "Connect to smartphone/computer" in its network menu.',
      'Connect the phones to the camera\'s Wi-Fi, or connect the camera to your Wi-Fi.',
      'On the controlling phone, open the menu (⋮) and choose Pro camera.',
      'Pick your camera, check the address (filled in for you), and tap Connect.',
      'Turn on "Camera starts the phones" to start every phone by pressing record on the camera.',
    ],
    tips: [
      'If it won\'t connect, tap Connection log. It shows exactly what the camera answered.',
      'Not listed, or no Wi-Fi? Choose "Any camera: sync by sound" instead.',
    ],
  ),
  Guide(
    icon: Icons.graphic_eq_rounded,
    color: Brand.coral,
    title: 'Any camera: sync by sound',
    summary: 'Works with every camera that records sound. No connection needed.',
    steps: [
      'Start recording on your camera before or after you start the phones.',
      'SyncCam plays a short beep just after recording starts. Make sure the camera can hear it.',
      'After the shoot, copy the camera\'s video to a computer with the SyncCam files.',
      'Run the line-up tool (see "Line up videos on a computer"). It finds the beep in every video and lines them up to the frame.',
    ],
  ),
  Guide(
    icon: Icons.timer_rounded,
    color: Brand.good,
    title: 'Get perfect timing',
    summary: 'Every phone model reacts slightly differently. Measure it once.',
    steps: [
      'On the controlling phone, open the menu (⋮) and choose Fine-tune timing.',
      'Point every camera at the controlling phone\'s screen, which shows a running clock.',
      'Tap Test shot.',
      'Tap Check results and type the time you see in each photo. SyncCam adjusts each phone for you.',
    ],
    tips: ['You only need to do this once per phone model.'],
  ),
  Guide(
    icon: Icons.photo_library_rounded,
    color: Brand.sky,
    title: 'Find, compare and share',
    summary: 'All angles of a shot, side by side.',
    steps: [
      'Open Gallery. Each press of the shutter is one "take" holding every camera\'s photo or video.',
      'Open a take to see all angles. Tap Compare to play the videos together, lined up.',
      'In Compare, switch between Grid, Side by side, Wipe, Overlay and Switcher.',
      'Tap Save to put everything in your Photos, or Share to send it.',
    ],
  ),
  Guide(
    icon: Icons.computer_rounded,
    color: Brand.violet,
    title: 'Line up videos on a computer',
    summary: 'Frame-perfect alignment for editing.',
    steps: [
      'Share a take to your computer. Keep the manifest.json file with the videos.',
      'Install Python and ffmpeg, then run: python align_clips.py <take folder>',
      'Add other cameras\' videos with --extra camera.mp4.',
      'Edit the lined-up copies in the "aligned" folder in any editor.',
    ],
  ),
  Guide(
    icon: Icons.help_rounded,
    color: Brand.textDim,
    title: 'Something not working?',
    summary: 'Quick fixes for the common problems.',
    steps: [
      'A phone can\'t find the shoot: check it\'s on the same Wi-Fi, or scan the QR code instead.',
      'A camera shows "out of sync": wait a few seconds, or move closer to the Wi-Fi router.',
      'Camera says access is off: allow Camera in the phone\'s Settings → SyncCam, then tap Try again.',
      'iPhone page says the host didn\'t answer: make sure both phones have internet while joining.',
      'Pro camera won\'t connect: check its remote control mode is on, then send us the Connection log.',
    ],
  ),
];

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & guides')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          for (final g in guides) ...[
            ActionCard(
              icon: g.icon,
              color: g.color,
              title: g.title,
              subtitle: g.summary,
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => GuideScreen(guide: g))),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key, required this.guide});
  final Guide guide;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Align(alignment: Alignment.centerLeft, child: IconBadge(guide.icon, color: guide.color, size: 64)),
          const SizedBox(height: 16),
          Text(guide.title, style: t.headlineSmall),
          const SizedBox(height: 6),
          Text(guide.summary, style: t.bodyMedium?.copyWith(color: Brand.textDim)),
          const SizedBox(height: 24),
          GlassCard(child: Steps(guide.steps)),
          if (guide.tips.isNotEmpty) ...[
            const SectionTitle('Tips'),
            for (final tip in guide.tips)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lightbulb_rounded, size: 18, color: Brand.warn),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tip, style: t.bodyMedium?.copyWith(color: Brand.textDim))),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}
