import 'dart:math';

import 'package:flutter/material.dart';

import '../geo/compass.dart';
import '../state/app.dart';
import '../state/models.dart';
import 'chat_page.dart' show netColor;
import 'node_sheet.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

/// Lagebild: eigene Position in der Mitte, Knoten nach Richtung und Entfernung.
/// Mit Kompass dreht sich das Bild mit dem Gerät (oben = Blickrichtung).
/// Funktioniert ohne Internet (keine Kartenkacheln).
class RadarView extends StatefulWidget {
  final ValueChanged<String>? onOpenChat;
  const RadarView({super.key, this.onOpenChat});
  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView> {
  double _zoom = 1.0;
  bool _acquired = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  void _sync() {
    final want = app.settings.compass && Compass.supported;
    if (want && !_acquired) {
      compass.acquire();
      _acquired = true;
    } else if (!want && _acquired) {
      compass.release();
      _acquired = false;
    }
  }

  @override
  void dispose() {
    if (_acquired) compass.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    return ListenableBuilder(listenable: compass, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final rc = context.rc;
    final withPos = app.nodes.values.where((n) => n.hasPos && !n.ignored).toList();
    final hasOwn = app.settings.lat != null && app.settings.lon != null;
    double? cLat = app.settings.lat, cLon = app.settings.lon;
    if (!hasOwn && withPos.isNotEmpty) {
      cLat = withPos.map((n) => n.lat!).reduce((a, b) => a + b) / withPos.length;
      cLon = withPos.map((n) => n.lon!).reduce((a, b) => a + b) / withPos.length;
    }
    if (cLat == null || cLon == null) {
      return EmptyState(
        icon: Icons.explore_outlined,
        title: tr('Noch keine Positionen'),
        text: tr('Trage unter Einstellungen deine Position ein oder warte, bis Knoten ihre Position senden.'),
      );
    }
    final land = MediaQuery.orientationOf(context) == Orientation.landscape;
    final heading = _acquired ? compass.screenHeading(land) : null;
    final pts = <_Pt>[];
    var maxKm = 0.5;
    for (final n in withPos) {
      final dy = (n.lat! - cLat) * 110.574;
      final dx = (n.lon! - cLon) * 111.320 * cos(cLat * pi / 180);
      final d = sqrt(dx * dx + dy * dy);
      if (d > maxKm) maxKm = d;
      pts.add(_Pt(n, dx, dy, d, (atan2(dx, dy) * 180 / pi + 360) % 360, label: n.badge));
    }
    final nav = app.navPoint;
    _Pt? target;
    if (nav != null) {
      final dy = (nav.$2 - cLat) * 110.574;
      final dx = (nav.$3 - cLon) * 111.320 * cos(cLat * pi / 180);
      final d = sqrt(dx * dx + dy * dy);
      final hit = pts.where((p) => p.n.lat == nav.$2 && p.n.lon == nav.$3).firstOrNull;
      target = hit ?? _Pt(null, dx, dy, d, (atan2(dx, dy) * 180 / pi + 360) % 360, label: nav.$1);
      if (d > maxKm) maxKm = d;
    }
    final range = _niceRange(maxKm * 1.12 / _zoom);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 760 || (land && box.maxWidth > box.maxHeight * 1.3);
      final plot = Padding(
        padding: EdgeInsets.fromLTRB(16, wide ? 56 : 60, 16, 16),
        child: AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(builder: (context, pb) {
            final size = Size(pb.maxWidth, pb.maxHeight);
            final painter = _PlotPainter(
              pts: pts,
              rangeKm: range,
              own: hasOwn,
              heading: heading,
              target: target,
              rc: rc,
              fg: Theme.of(context).colorScheme.onSurface,
              colorOf: (n) => netColor(context, n.net),
            );
            return GestureDetector(
              onScaleUpdate: (d) {
                if (d.scale != 1.0) setState(() => _zoom = (_zoom * (1 + (d.scale - 1) * 0.05)).clamp(0.25, 40.0));
              },
              onTapUp: (d) {
                final hit = painter.hit(size, d.localPosition);
                if (hit != null) showNodeSheet(context, hit, onOpenChat: widget.onOpenChat);
              },
              child: CustomPaint(painter: painter, size: size),
            );
          }),
        ),
      );
      final legend = Padding(
        padding: EdgeInsets.fromLTRB(16, wide ? 60 : 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (app.navPoint != null) ...[
            const NavTargetCard(),
            const SizedBox(height: 10),
          ] else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('Tipp: Knoten oder Wegpunkt antippen → „Hinführen“ – der Pfeil zeigt dann den Weg.'),
                  style: TextStyle(fontSize: 12, color: rc.muted)),
            ),
          Row(children: [
            Text(tr('Radius '), style: TextStyle(color: rc.muted)),
            Text(fmtKm(range), style: mono(context, size: 14, weight: FontWeight.w700)),
            const Spacer(),
            if (Compass.supported)
              IconButton(
                tooltip: app.settings.compass ? tr('Norden oben') : tr('Mit Gerät drehen'),
                onPressed: () {
                  app.settings.compass = !app.settings.compass;
                  app.changed(save: true);
                  setState(_sync);
                },
                icon: Icon(app.settings.compass ? Icons.explore : Icons.explore_outlined,
                    color: app.settings.compass ? rc.ok : null),
              ),
            IconButton(onPressed: () => setState(() => _zoom = (_zoom / 1.6).clamp(0.25, 40.0)), icon: const Icon(Icons.zoom_out)),
            IconButton(onPressed: () => setState(() => _zoom = (_zoom * 1.6).clamp(0.25, 40.0)), icon: const Icon(Icons.zoom_in)),
          ]),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              heading != null
                  ? tr('Oben = Blickrichtung {0}° {1} (magnetisch)', [heading.toStringAsFixed(0), _dir(heading)])
                  : (_acquired ? tr('Kompass wird gesucht … (Gerät kurz in Acht-Form bewegen)') : tr('Norden oben')),
              style: TextStyle(fontSize: 12.5, color: heading != null ? rc.ok : rc.muted),
            ),
          ),
          if (!hasOwn)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('Eigene Position fehlt – Mitte ist der Schwerpunkt der Knoten.'),
                  style: TextStyle(color: rc.warn, fontSize: 12.5)),
            ),
          ...([...pts]..sort((a, b) => a.d.compareTo(b.d))).map((p) {
            final rel = heading == null ? null : (p.brg - heading + 360) % 360;
            return InkWell(
              onTap: () => showNodeSheet(context, p.n, onOpenChat: widget.onOpenChat),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Dot(netColor(context, p.n.net)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(p.n.display, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (rel != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Transform.rotate(angle: rel * pi / 180, child: Icon(Icons.navigation, size: 16, color: rc.ok)),
                    ),
                  Text('${fmtKm(p.d)}  ${p.brg.toStringAsFixed(0).padLeft(3, '0')}°', style: mono(context, size: 12.5, color: rc.muted)),
                ]),
              ),
            );
          }),
          const SizedBox(height: 8),
          Text(tr('{0} weitere Knoten ohne Position · Punkt antippen = Details', [app.nodes.length - withPos.length]),
              style: TextStyle(color: rc.muted, fontSize: 12)),
        ]),
      );
      if (wide) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: Center(child: plot)),
          SizedBox(width: min(360, box.maxWidth * 0.42), child: SingleChildScrollView(child: legend)),
        ]);
      }
      return ListView(children: [plot, legend]);
    });
  }

  static String _dir(double deg) {
    const d = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return d[((deg + 22.5) % 360 ~/ 45)];
  }

  static double _niceRange(double km) {
    const steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000];
    for (final s in steps) {
      if (km <= s) return s.toDouble();
    }
    return 2000;
  }
}

class _Pt {
  final Node? node;
  final double dx, dy, d, brg;
  final String label;
  _Pt(this.node, this.dx, this.dy, this.d, this.brg, {this.label = ''});
  Node get n => node!;
}

class _PlotPainter extends CustomPainter {
  final List<_Pt> pts;
  final double rangeKm;
  final bool own;
  final double? heading; // null = Norden oben
  final _Pt? target; // Ziel der Navigation
  final RadioColors rc;
  final Color fg;
  final Color Function(Node) colorOf;
  _PlotPainter({
    required this.pts,
    required this.rangeKm,
    required this.own,
    required this.heading,
    this.target,
    required this.rc,
    required this.fg,
    required this.colorOf,
  });

  double get _rot => heading ?? 0;

  /// Bildschirmposition eines Punkts und ob er außerhalb des Radius liegt.
  (Offset, bool) _pos(Size size, _Pt p) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 18;
    final a = (p.brg - _rot) * pi / 180;
    var len = p.d * (r / rangeKm);
    final out = len > r;
    if (out) len = r;
    return (c + Offset(sin(a) * len, -cos(a) * len), out);
  }

  /// Knoten unter dem Finger (bis 26 px).
  Node? hit(Size size, Offset at) {
    Node? best;
    var bestD = 26.0;
    for (final p in pts) {
      final d = (_pos(size, p).$1 - at).distance;
      if (d < bestD) {
        bestD = d;
        best = p.n;
      }
    }
    return best;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 18;
    final ring = Paint()
      ..color = rc.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(c, r, Paint()..color = rc.panel);
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(c, r * i / 4, ring);
      _text(canvas, fmtKm(rangeKm * i / 4), c + Offset(4, -r * i / 4 + 2), rc.muted, 10);
    }
    // Gradteilung (dreht mit)
    for (var deg = 0; deg < 360; deg += 10) {
      final a = (deg - _rot) * pi / 180;
      final inner = deg % 90 == 0 ? 0.0 : (deg % 30 == 0 ? r - 10 : r - 5);
      final p1 = c + Offset(sin(a) * inner, -cos(a) * inner);
      final p2 = c + Offset(sin(a) * r, -cos(a) * r);
      canvas.drawLine(p1, p2, deg == 0 ? (Paint()
        ..color = rc.crit.withValues(alpha: 0.6)
        ..strokeWidth = 1.5) : ring);
    }
    const names = {0: 'N', 90: 'O', 180: 'S', 270: 'W'};
    for (final e in names.entries) {
      final a = (e.key - _rot) * pi / 180;
      _text(canvas, e.value, c + Offset(sin(a) * (r + 11), -cos(a) * (r + 11)), e.key == 0 ? rc.crit : rc.muted, e.key == 0 ? 13 : 11,
          center: true, bold: e.key == 0);
    }
    // Blickrichtung (oben) markieren
    if (heading != null) {
      final tri = Path()
        ..moveTo(c.dx, c.dy - r - 2)
        ..lineTo(c.dx - 7, c.dy - r - 14)
        ..lineTo(c.dx + 7, c.dy - r - 14)
        ..close();
      canvas.drawPath(tri, Paint()..color = rc.ok);
    }
    // eigene Position
    if (own) {
      canvas.drawCircle(c, 7, Paint()..color = rc.hf);
      canvas.drawCircle(c, 12, Paint()
        ..color = rc.hf.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    } else {
      canvas.drawLine(c - const Offset(6, 0), c + const Offset(6, 0), ring..color = rc.muted);
      canvas.drawLine(c - const Offset(0, 6), c + const Offset(0, 6), ring);
    }
    // Ziel: Linie und Ring
    final t = target;
    if (t != null) {
      final (tp, _) = _pos(size, t);
      canvas.drawLine(c, tp, Paint()
        ..color = rc.ok
        ..strokeWidth = 2.5);
      canvas.drawCircle(tp, 13, Paint()
        ..color = rc.ok
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
      if (t.node == null) {
        canvas.drawCircle(tp, 5, Paint()..color = rc.ok);
        _text(canvas, t.label, tp + const Offset(14, -7), rc.ok, 11, bold: true);
      }
    }
    for (final p in pts) {
      final (pos, out) = _pos(size, p);
      final col = colorOf(p.n);
      final age = DateTime.now().difference(p.n.lastHeard).inMinutes;
      final fresh = age < 30;
      if (own && !out) {
        canvas.drawLine(c, pos, Paint()
          ..color = col.withValues(alpha: 0.18)
          ..strokeWidth = 1);
      }
      final rad = out ? 4.0 : 7.0;
      canvas.drawCircle(pos, rad, Paint()..color = fresh ? col : col.withValues(alpha: 0.45));
      canvas.drawCircle(pos, rad, Paint()
        ..color = age < 15 ? rc.ok : (age < 120 ? rc.warn : rc.panel)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      _text(canvas, p.n.badge, pos + const Offset(10, -7), fg, 11, bold: true);
    }
  }

  void _text(Canvas canvas, String s, Offset at, Color col, double size, {bool center = false, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: col, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center ? at - Offset(tp.width / 2, tp.height / 2) : at);
  }

  @override
  bool shouldRepaint(covariant _PlotPainter old) => true;
}
