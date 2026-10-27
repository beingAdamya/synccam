// Draws the SyncCam app icon: a red camera aperture ring with three linked
// dots (several cameras, one shutter). Regenerate with:
//   dart run tool/make_icon.dart && dart run flutter_launcher_icons
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

const size = 1024;
final red = img.ColorRgb8(255, 77, 77);
final white = img.ColorRgb8(255, 255, 255);
final dark = img.ColorRgb8(22, 22, 26);

void drawMark(img.Image im, double scale) {
  final c = size ~/ 2;
  int r(double f) => (size * f * scale).round();
  img.fillCircle(im, x: c, y: c, radius: r(0.36), color: red, antialias: true);
  img.fillCircle(im, x: c, y: c, radius: r(0.25), color: dark, antialias: true);
  // Three cameras around the aperture, the shared shutter in the middle.
  for (var i = 0; i < 3; i++) {
    final a = -pi / 2 + i * 2 * pi / 3;
    img.fillCircle(im,
        x: c + (cos(a) * r(0.125)).round(), y: c + (sin(a) * r(0.125)).round(), radius: r(0.055), color: white, antialias: true);
  }
}

void main() {
  final full = img.Image(width: size, height: size)..clear(dark);
  drawMark(full, 1.0);
  File('assets/icon/icon.png').writeAsBytesSync(img.encodePng(full));

  // Android adaptive foreground: transparent, mark inside the safe zone.
  final fg = img.Image(width: size, height: size, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
  drawMark(fg, 0.62);
  File('assets/icon/foreground.png').writeAsBytesSync(img.encodePng(fg));
  stdout.writeln('wrote assets/icon/icon.png and foreground.png');
}
