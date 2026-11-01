// Renders the SyncCam logo in 3D: a glossy red aperture ring (a torus) with
// three pearl spheres (several cameras, one shutter) around a recessed glass
// lens, lit from the top left with specular highlights and soft shadows.
//
// It's a small height-field renderer: each element is a height function,
// normals come from its gradient, and Phong lighting shades it. Regenerate:
//   dart run tool/make_icon.dart && dart run flutter_launcher_icons
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const out = 1024;
const ss = 2; // supersampling
const n = out * ss;

// Geometry in units where the icon spans [-1, 1].
const ringCenter = 0.61, ringHalf = 0.115, lensR = 0.5, dotR = 0.11, dotDist = 0.25;

class Hit {
  Hit(this.h, this.material);
  final double h; // height above the base plane
  final int material; // 0 none, 1 ring, 2 dot, 3 lens
}

Hit sample(double x, double y, double scale) {
  x /= scale;
  y /= scale;
  final d = sqrt(x * x + y * y);
  // spheres on top
  for (var i = 0; i < 3; i++) {
    final a = -pi / 2 + i * 2 * pi / 3;
    final dx = x - cos(a) * dotDist, dy = y - sin(a) * dotDist;
    final r2 = dx * dx + dy * dy;
    if (r2 < dotR * dotR) return Hit(sqrt(dotR * dotR - r2) * scale + 0.02 * scale, 2);
  }
  // torus cross-section: a rounded tube
  final t = d - ringCenter;
  if (t.abs() < ringHalf) return Hit(sqrt(ringHalf * ringHalf - t * t) * 1.05 * scale, 1);
  // slightly concave glass lens inside the ring
  if (d < lensR + 0.005) return Hit(-0.035 * (1 - (d / lensR) * (d / lensR)) * scale, 3);
  return Hit(0, 0);
}

class V {
  V(this.x, this.y, this.z);
  double x, y, z;
  V norm() {
    final l = sqrt(x * x + y * y + z * z);
    return V(x / l, y / l, z / l);
  }

  double dot(V o) => x * o.x + y * o.y + z * o.z;
}

final light = V(-0.55, -0.75, 1.0).norm();
final view = V(0, 0, 1);

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// Renders one image. [scale] shrinks the mark (adaptive icon safe zone),
/// [background] draws the dark rounded tile.
img.Image render({double scale = 1.0, bool background = true}) {
  final px = 2.0 / n;
  final heights = Float32List(n * n);
  final mats = Uint8List(n * n);
  for (var j = 0; j < n; j++) {
    for (var i = 0; i < n; i++) {
      final h = sample(-1 + (i + 0.5) * px, -1 + (j + 0.5) * px, scale);
      heights[j * n + i] = h.h;
      mats[j * n + i] = h.material;
    }
  }
  // Soft drop shadow: blurred mask of raised parts, offset down-right.
  final shadow = Float32List(n * n);
  for (var k = 0; k < n * n; k++) {
    shadow[k] = (mats[k] == 1 || mats[k] == 2) ? 1 : 0;
  }
  final blurred = _blur(_blur(_blur(shadow, (18 * ss * scale).round()), (18 * ss * scale).round()), (18 * ss * scale).round());
  final off = (0.05 * n / 2 * scale).round();

  final im = img.Image(width: n, height: n, numChannels: 4);
  for (var j = 0; j < n; j++) {
    for (var i = 0; i < n; i++) {
      final k = j * n + i;
      final m = mats[k];
      double r, g, b, a = 1;
      final sx = i - off, sy = j - (off * 1.3).round();
      final sh = (sx >= 0 && sy >= 0 && sx < n && sy < n) ? blurred[sy * n + sx] : 0.0;
      if (m == 0) {
        if (!background) {
          // transparent foreground keeps a faint contact shadow
          r = g = b = 0;
          a = 0.45 * sh;
        } else {
          final u = i / n, v = j / n;
          // charcoal tile: subtle top-left glow, darker bottom-right
          final glow = clamp01(1.0 - sqrt((u - 0.3) * (u - 0.3) + (v - 0.25) * (v - 0.25)) * 1.4);
          r = 20 + 22 * glow;
          g = 20 + 22 * glow;
          b = 26 + 28 * glow;
          final f = 1 - 0.55 * sh;
          r *= f;
          g *= f;
          b *= f;
        }
      } else {
        // normal from the height gradient (central differences)
        double h(int ii, int jj) {
          ii = ii.clamp(0, n - 1);
          jj = jj.clamp(0, n - 1);
          return mats[jj * n + ii] == m ? heights[jj * n + ii] : heights[k];
        }

        final dx = (h(i + 1, j) - h(i - 1, j)) / (2 * px);
        final dy = (h(i, j + 1) - h(i, j - 1)) / (2 * px);
        final nrm = V(-dx, -dy, 1).norm();
        final diff = clamp01(nrm.dot(light));
        // reflect light about the normal for the highlight
        final rl = V(2 * diff * nrm.x - light.x, 2 * diff * nrm.y - light.y, 2 * diff * nrm.z - light.z);
        final spec = pow(clamp01(rl.dot(view)), m == 2 ? 28 : 60).toDouble();
        final rim = pow(1 - clamp01(nrm.dot(view)), 3).toDouble();
        switch (m) {
          case 1: // glossy red ring, warmer at the top
            final v = j / n;
            final baseR = 255.0, baseG = 92 - 40 * v, baseB = 80 - 30 * v;
            final lit = 0.28 + 0.85 * diff;
            r = baseR * lit + 255 * spec * 0.9;
            g = baseG * lit + 255 * spec * 0.85;
            b = baseB * lit + 255 * spec * 0.85;
            r -= 60 * rim;
            g -= 30 * rim;
            b -= 30 * rim;
          case 2: // pearl spheres
            final lit = 0.35 + 0.7 * diff;
            r = 238 * lit + 255 * spec;
            g = 238 * lit + 255 * spec;
            b = 245 * lit + 255 * spec;
            r -= 40 * rim;
            g -= 40 * rim;
            b -= 30 * rim;
          default: // dark glass lens with a soft reflection band
            final u = i / n - 0.5, v = j / n - 0.5;
            final band = clamp01(1 - ((u + v + 0.18) * 7).abs()) * 0.18;
            final f = 1 - 0.6 * sh;
            r = (16 + 40 * band * 255 / 40 + 30 * spec) * f;
            g = (16 + 40 * band * 255 / 40 + 30 * spec) * f;
            b = (24 + 46 * band * 255 / 40 + 40 * spec) * f;
        }
      }
      im.setPixelRgba(i, j, r.clamp(0, 255).round(), g.clamp(0, 255).round(), b.clamp(0, 255).round(),
          (a * 255).clamp(0, 255).round());
    }
  }
  return img.copyResize(im, width: out, height: out, interpolation: img.Interpolation.average);
}

/// Separable box blur.
Float32List _blur(Float32List src, int r) {
  if (r < 1) return src;
  final tmp = Float32List(n * n), dst = Float32List(n * n);
  final w = 2 * r + 1;
  for (var j = 0; j < n; j++) {
    var acc = 0.0;
    for (var i = -r; i <= r; i++) {
      acc += src[j * n + i.clamp(0, n - 1)];
    }
    for (var i = 0; i < n; i++) {
      tmp[j * n + i] = acc / w;
      acc += src[j * n + (i + r + 1).clamp(0, n - 1)] - src[j * n + (i - r).clamp(0, n - 1)];
    }
  }
  for (var i = 0; i < n; i++) {
    var acc = 0.0;
    for (var j = -r; j <= r; j++) {
      acc += tmp[j.clamp(0, n - 1) * n + i];
    }
    for (var j = 0; j < n; j++) {
      dst[j * n + i] = acc / w;
      acc += tmp[(j + r + 1).clamp(0, n - 1) * n + i] - tmp[(j - r).clamp(0, n - 1) * n + i];
    }
  }
  return dst;
}

void main() {
  File('assets/icon/icon.png').writeAsBytesSync(img.encodePng(render()));
  File('assets/icon/foreground.png').writeAsBytesSync(img.encodePng(render(scale: 0.62, background: false)));
  final logo = render(scale: 0.98, background: false);
  File('assets/icon/logo3d.png').writeAsBytesSync(img.encodePng(logo));
  // small copy for the browser camera page
  File('assets/web/logo.png').writeAsBytesSync(img.encodePng(img.copyResize(logo, width: 256, interpolation: img.Interpolation.average)));
  stdout.writeln('wrote icon.png, foreground.png, logo3d.png');
}
