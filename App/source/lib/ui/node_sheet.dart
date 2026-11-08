import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bytes.dart';
import '../geo/compass.dart';
import '../geo/coords.dart';
import '../state/app.dart';
import '../state/models.dart';
import 'chat_page.dart' show netColor;
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

/// Farbe nach Aktualität: grün < 15 min, gelb < 2 h, sonst grau.
Color freshColor(BuildContext context, DateTime t) {
  final m = DateTime.now().difference(t).inMinutes;
  final rc = context.rc;
  if (m < 15) return rc.ok;
  if (m < 120) return rc.warn;
  return rc.muted;
}

String fmtKm(double km) => km < 1 ? '${(km * 1000).toStringAsFixed(0)} m' : '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';

String fmtUptime(int s) {
  if (s < 3600) return '${s ~/ 60} min';
  if (s < 86400) return tr('{0} h {1} min', [s ~/ 3600, (s % 3600) ~/ 60]);
  return tr('{0} d {1} h', [s ~/ 86400, (s % 86400) ~/ 3600]);
}

/// Knoten-Details mit allen Aktionen (Liste und Karte benutzen dasselbe Fenster).
void showNodeSheet(BuildContext context, Node n, {ValueChanged<String>? onOpenChat, bool fromMap = false}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: context.rc.panel,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListenableBuilder(
        listenable: app,
        builder: (ctx, _) => _NodeSheetBody(n, scroll: scroll, onOpenChat: onOpenChat, fromMap: fromMap),
      ),
    ),
  );
}

class _NodeSheetBody extends StatelessWidget {
  final Node n;
  final ScrollController scroll;
  final ValueChanged<String>? onOpenChat;
  final bool fromMap;
  const _NodeSheetBody(this.n, {required this.scroll, this.onOpenChat, required this.fromMap});

  void _do(BuildContext context, String? err, String ok) => toast(context, err ?? ok, error: err != null);

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final dist = app.distanceTo(n);
    final mt = n.net == Net.mt;
    final col = netColor(context, n.net);
    return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
      Row(children: [
        Stack(clipBehavior: Clip.none, children: [
          NodeBadge(n.badge, col, size: 54),
          Positioned(right: 0, bottom: 0, child: Dot(freshColor(context, n.lastHeard), size: 13)),
        ]),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(n.display,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              if (n.favorite) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.star, size: 18, color: rc.warn)),
              if (n.ignored) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.block, size: 16, color: rc.crit)),
            ]),
            Text('${netName(n.net)} · ${n.key}${n.role.isNotEmpty ? ' · ${n.role}' : ''}',
                style: mono(context, size: 12, color: rc.muted)),
          ]),
        ),
        IconButton(
          tooltip: n.favorite ? tr('Kein Favorit mehr') : tr('Als Favorit markieren'),
          onPressed: () => app.setFavorite(n, !n.favorite),
          icon: Icon(n.favorite ? Icons.star : Icons.star_border, color: n.favorite ? rc.warn : null),
        ),
      ]),
      if (dist != null) ...[
        const SizedBox(height: 14),
        _Peilung(bearing: dist.$2, km: dist.$1),
      ],
      const SizedBox(height: 14),
      // ---- Aktionen
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (mt && onOpenChat != null)
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              onOpenChat!('dm:${n.key}');
            },
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            label: Text(tr('Nachricht')),
          ),
        if (n.hasPos)
          FilledButton.tonalIcon(
            onPressed: () {
              Navigator.pop(context);
              app.setNavTarget('node:${n.key}');
            },
            icon: const Icon(Icons.navigation_outlined, size: 18),
            label: Text(tr('Hinführen')),
          ),
        if (n.hasPos && !fromMap)
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              app.showOnMap(n);
            },
            icon: const Icon(Icons.map_outlined, size: 18),
            label: Text(tr('Auf Karte')),
          ),
        if (mt) ...[
          OutlinedButton.icon(
            onPressed: () => _do(context, app.requestNodeInfo(n), tr('Visitenkarte angefordert – Antwort erscheint hier')),
            icon: const Icon(Icons.badge_outlined, size: 18),
            label: Text(tr('Visitenkarte')),
          ),
          OutlinedButton.icon(
            onPressed: () => _do(context, app.requestPosition(n), tr('Position angefordert')),
            icon: const Icon(Icons.location_searching, size: 18),
            label: Text(tr('Position')),
          ),
          OutlinedButton.icon(
            onPressed: () => _do(context, app.requestTelemetry(n), tr('Gerätewerte angefordert')),
            icon: const Icon(Icons.battery_unknown_outlined, size: 18),
            label: Text(tr('Telemetrie')),
          ),
          OutlinedButton.icon(
            onPressed: () => _do(context, app.traceroute(n), tr('Route wird ermittelt …')),
            icon: const Icon(Icons.alt_route, size: 18),
            label: Text(tr('Route')),
          ),
        ],
      ]),
      const SizedBox(height: 16),
      // ---- Werte
      KV(tr('Zuletzt gehört'), '${ago(n.lastHeard)} (${hhmmss(n.lastHeard)})'),
      KV(tr('Signal'), n.rssi != null ? tr('{0} dBm · SNR {1} dB', [n.rssi!.toStringAsFixed(0), n.snr?.toStringAsFixed(1) ?? '–']) : '–'),
      KV(tr('Weg'), n.hops == null ? '–' : (n.hops == 0 ? 'direkt' : tr('{0} Hop{1}', [n.hops, n.hops == 1 ? '' : 's']))),
      KV(tr('Gehört über'), n.via.isEmpty ? '–' : tr('{0} · {1} Pakete', [n.via, n.packets])),
      if (n.hw.isNotEmpty) KV(tr('Gerät'), n.hw),
      if (mt)
        KV(tr('Schlüssel'), n.pubKey != null ? tr('bekannt – Direktnachrichten Ende-zu-Ende') : tr('unbekannt – Visitenkarte anfordern'),
            color: n.pubKey != null ? rc.ok : rc.warn),
      if (n.askedInfo != null && n.infoAt == null) KV(tr('Visitenkarte'), 'angefordert ${ago(n.askedInfo)}', color: rc.warn),
      if (n.battery != null) KV(tr('Akku'), n.battery! > 100 ? tr('Netzbetrieb') : '${n.battery} %'),
      if (n.voltage != null) KV(tr('Spannung'), '${n.voltage!.toStringAsFixed(2)} V'),
      if (n.chUtil != null) KV(tr('Kanalauslastung'), '${n.chUtil!.toStringAsFixed(1)} %'),
      if (n.airUtil != null) KV(tr('Eigene Sendezeit'), '${n.airUtil!.toStringAsFixed(1)} %'),
      if (n.temp != null) KV(tr('Temperatur'), '${n.temp!.toStringAsFixed(1)} °C'),
      if (n.uptimeS != null) KV(tr('Laufzeit'), fmtUptime(n.uptimeS!)),
      if (n.telAt != null) KV(tr('Telemetrie'), ago(n.telAt)),
      if (n.hasPos) ...[
        KV(tr('Position'), '${n.lat!.toStringAsFixed(5)}, ${n.lon!.toStringAsFixed(5)}${n.alt != null ? tr(' · {0} m', [n.alt]) : ''}' '${n.posAt != null ? ' · ${ago(n.posAt)}' : ''}'),
        KV('MGRS', toMgrs(n.lat!, n.lon!), color: rc.hf),
        KV(tr('Locator'), toMaidenhead(n.lat!, n.lon!)),
      ],
      if (n.route.isNotEmpty) KV(tr('Route'), n.route),
      if (n.rttMs != null) KV(tr('Laufzeit hin+zurück'), '${(n.rttMs! / 1000).toStringAsFixed(1)} s'),
      if (n.history.length >= 2) ...[
        const SizedBox(height: 12),
        Text(tr('SNR-Verlauf (direkt gehört)'), style: TextStyle(fontSize: 12, color: rc.muted)),
        const SizedBox(height: 4),
        SizedBox(height: 56, child: CustomPaint(painter: SnrSpark(n.history.map((h) => h.$2).toList(), rc), size: Size.infinite)),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: n.hasPos
                ? '${n.display} ${n.key}\n${toMgrs(n.lat!, n.lon!)}\n${n.lat!.toStringAsFixed(6)}, ${n.lon!.toStringAsFixed(6)}'
                : '${n.display} ${n.key}'));
            toast(context, tr('Kopiert'));
          },
          icon: const Icon(Icons.copy, size: 18),
          label: Text(tr('Kopieren')),
        ),
        TextButton.icon(
          onPressed: () => app.setIgnored(n, !n.ignored),
          icon: Icon(n.ignored ? Icons.check_circle_outline : Icons.block, size: 18),
          label: Text(n.ignored ? tr('Nicht mehr ignorieren') : tr('Ignorieren')),
        ),
        TextButton.icon(
          onPressed: () {
            app.forgetNode(n.key);
            Navigator.pop(context);
          },
          icon: Icon(Icons.delete_outline, color: rc.crit, size: 18),
          label: Text(tr('Vergessen'), style: TextStyle(color: rc.crit)),
        ),
      ]),
      if (n.num != 0 && mt)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('Knotennummer {0} · {1}', [n.num, nodeIdStr(n.num)]), style: mono(context, size: 11, color: rc.muted)),
        ),
    ]);
  }
}

/// Ziel-Navigation: großer Pfeil zum gewählten Knoten/Wegpunkt (mit Kompass relativ zum Gerät).
class NavTargetCard extends StatefulWidget {
  final bool compact;
  final VoidCallback? onTap;
  const NavTargetCard({super.key, this.compact = false, this.onTap});
  @override
  State<NavTargetCard> createState() => _NavTargetCardState();
}

class _NavTargetCardState extends State<NavTargetCard> {
  bool _acq = false;

  @override
  void initState() {
    super.initState();
    if (app.settings.compass && Compass.supported) {
      compass.acquire();
      _acq = true;
    }
  }

  @override
  void dispose() {
    if (_acq) compass.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final t = app.navPoint;
    if (t == null) return const SizedBox.shrink();
    final lat = app.settings.lat, lon = app.settings.lon;
    return ListenableBuilder(
      listenable: compass,
      builder: (context, _) {
        final land = MediaQuery.orientationOf(context) == Orientation.landscape;
        final h = _acq ? compass.screenHeading(land) : null;
        (double, double)? db;
        if (lat != null && lon != null) db = distBearing(lat, lon, t.$2, t.$3);
        final rel = db == null ? null : (h == null ? db.$2 : (db.$2 - h + 360) % 360);
        final size = widget.compact ? 40.0 : 84.0;
        return Material(
          color: rc.panel.withValues(alpha: 0.96),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: rc.ok.withValues(alpha: 0.6))),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onTap,
            child: Padding(
              padding: EdgeInsets.all(widget.compact ? 8 : 14),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: size,
                  height: size,
                  child: rel == null
                      ? Icon(Icons.gps_off, color: rc.warn, size: size * 0.6)
                      : CustomPaint(painter: _ArrowPainter(rel, rc, h != null)),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(tr('Ziel: {0}', [t.$1]),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: widget.compact ? 13 : 15)),
                    if (db != null)
                      Text(fmtKm(db.$1), style: mono(context, size: widget.compact ? 14 : 24, weight: FontWeight.w800, color: rc.ok)),
                    if (db != null && !widget.compact)
                      Text('${db.$2.toStringAsFixed(0)}° · ${toMils(db.$2)} ‰${h == null ? tr(' · Norden oben') : ''}',
                          style: mono(context, size: 12, color: rc.muted)),
                    if (db == null)
                      Text(tr('Eigene Position unbekannt'), style: TextStyle(fontSize: 12, color: rc.warn)),
                  ]),
                ),
                if (!widget.compact)
                  IconButton(
                    tooltip: tr('Ziel löschen'),
                    onPressed: () => app.setNavTarget(''),
                    icon: const Icon(Icons.close),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Peilung: Pfeil zeigt zum Knoten (mit Kompass relativ zum Gerät, sonst Nord oben).
class _Peilung extends StatefulWidget {
  final double bearing, km;
  const _Peilung({required this.bearing, required this.km});
  @override
  State<_Peilung> createState() => _PeilungState();
}

class _PeilungState extends State<_Peilung> {
  @override
  void initState() {
    super.initState();
    if (app.settings.compass) compass.acquire();
  }

  @override
  void dispose() {
    if (app.settings.compass) compass.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return ListenableBuilder(
      listenable: compass,
      builder: (context, _) {
        final land = MediaQuery.orientationOf(context) == Orientation.landscape;
        final h = app.settings.compass ? compass.screenHeading(land) : null;
        final rel = h == null ? widget.bearing : (widget.bearing - h + 360) % 360;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: rc.panelHi, borderRadius: BorderRadius.circular(12), border: Border.all(color: rc.line)),
          child: Row(children: [
            SizedBox(
              width: 64,
              height: 64,
              child: CustomPaint(painter: _ArrowPainter(rel, rc, h != null)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(fmtKm(widget.km), style: mono(context, size: 20, weight: FontWeight.w700)),
                Text('${widget.bearing.toStringAsFixed(0)}° · ${toMils(widget.bearing)} ‰ · ${_dir(widget.bearing)}',
                    style: mono(context, size: 12.5, color: rc.muted)),
                Text(h == null ? tr('Pfeil: Norden oben') : tr('Pfeil zeigt zum Knoten (Kompass)'),
                    style: TextStyle(fontSize: 11.5, color: h == null ? rc.muted : rc.ok)),
              ]),
            ),
          ]),
        );
      },
    );
  }

  static String _dir(double deg) {
    const d = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return d[((deg + 22.5) % 360 ~/ 45)];
  }
}

class _ArrowPainter extends CustomPainter {
  final double deg;
  final RadioColors rc;
  final bool live;
  _ArrowPainter(this.deg, this.rc, this.live);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r - 1, Paint()
      ..color = rc.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(deg * pi / 180);
    final p = Path()
      ..moveTo(0, -r + 6)
      ..lineTo(r * 0.38, r * 0.45)
      ..lineTo(0, r * 0.2)
      ..lineTo(-r * 0.38, r * 0.45)
      ..close();
    canvas.drawPath(p, Paint()..color = live ? rc.ok : rc.hf);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => old.deg != deg || old.live != live;
}

/// SNR-Verlauf als kleine Kurve.
class SnrSpark extends CustomPainter {
  final List<double> v;
  final RadioColors rc;
  SnrSpark(this.v, this.rc);

  @override
  void paint(Canvas canvas, Size size) {
    const lo = -20.0, hi = 12.0;
    double y(double s) => size.height - ((s.clamp(lo, hi) - lo) / (hi - lo)) * size.height;
    final grid = Paint()
      ..color = rc.line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), grid);
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = v.length == 1 ? 0.0 : i / (v.length - 1) * size.width;
      if (i == 0) {
        path.moveTo(x, y(v[i]));
      } else {
        path.lineTo(x, y(v[i]));
      }
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = rc.lf.withValues(alpha: 0.15));
    canvas.drawPath(path, Paint()
      ..color = rc.lf
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    canvas.drawCircle(Offset(size.width, y(v.last)), 3.5, Paint()..color = rc.lf);
    final tp = TextPainter(
      text: TextSpan(text: '${v.last.toStringAsFixed(1)} dB', style: TextStyle(fontSize: 10, color: rc.muted)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width, 0));
  }

  @override
  bool shouldRepaint(covariant SnrSpark old) => true;
}

/// Knoten-Markierung auf der Karte: Kürzel im Kreis, Ring = Aktualität, Zahl = Hops.
class NodeMarker extends StatelessWidget {
  final Node n;
  final bool showName;
  final bool selected;
  const NodeMarker(this.n, {super.key, this.showName = true, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final col = netColor(context, n.net);
    final fresh = freshColor(context, n.lastHeard);
    final old = DateTime.now().difference(n.lastHeard).inHours >= 12;
    final size = selected ? 40.0 : 34.0;
    return Opacity(
      opacity: old ? 0.6 : 1,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Stack(clipBehavior: Clip.none, children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Color.alphaBlend(col.withValues(alpha: 0.25), rc.panel),
              shape: BoxShape.circle,
              border: Border.all(color: fresh, width: selected ? 4 : 3),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 4, offset: const Offset(0, 1))],
            ),
            child: Text(n.badge,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(fontSize: size * 0.3, fontWeight: FontWeight.w800, color: col)),
          ),
          if (n.hops != null && n.hops! > 0)
            Positioned(
              right: -5,
              top: -5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: rc.panelHi, borderRadius: BorderRadius.circular(8), border: Border.all(color: rc.line)),
                child: Text('${n.hops}', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: rc.muted)),
              ),
            ),
          if (n.favorite)
            Positioned(left: -6, top: -6, child: Icon(Icons.star, size: 15, color: rc.warn)),
        ]),
        if (showName)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            constraints: const BoxConstraints(maxWidth: 130),
            decoration: BoxDecoration(
              color: rc.panel.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(n.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
          ),
      ]),
    );
  }
}
