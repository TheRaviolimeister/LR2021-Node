import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../geo/compass.dart';
import '../geo/coords.dart';
import '../geo/tiles.dart';
import '../state/app.dart';
import '../state/models.dart';
import 'chat_page.dart' show netColor;
import 'radar_page.dart';
import 'node_sheet.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

/// Karte (Topo / Satellit / Hybrid / Straße, offline) und Radar-Ansicht.
class MapPage extends StatefulWidget {
  final ValueChanged<String>? onOpenChat;
  const MapPage({super.key, this.onOpenChat});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  static bool _radar = false;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 520;
    if (app.mapFocus != null) _radar = false;
    if (app.wantRadar) {
      _radar = true;
      app.wantRadar = false;
    }
    return Stack(children: [
      Positioned.fill(child: _radar ? RadarView(onOpenChat: widget.onOpenChat) : _MapView(onOpenChat: widget.onOpenChat)),
      Positioned(
        top: 10,
        right: 10,
        child: Material(
          color: Colors.transparent,
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                  value: false,
                  label: narrow ? null : Text(tr('Karte')),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  tooltip: tr('Karte')),
              ButtonSegment(
                  value: true,
                  label: narrow ? null : Text(tr('Radar')),
                  icon: const Icon(Icons.radar, size: 18),
                  tooltip: tr('Radar')),
            ],
            selected: {_radar},
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              backgroundColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? context.rc.hf.withValues(alpha: 0.35) : context.rc.panel.withValues(alpha: 0.94)),
            ),
            onSelectionChanged: (v) => setState(() => _radar = v.first),
          ),
        ),
      ),
    ]);
  }
}

class _MapView extends StatefulWidget {
  final ValueChanged<String>? onOpenChat;
  const _MapView({this.onOpenChat});
  @override
  State<_MapView> createState() => _MapViewState();
}

class _MapViewState extends State<_MapView> {
  final MapController _mc = MapController();
  LatLng _center = const LatLng(51.2, 10.4);
  double _zoom = 6;
  bool _measure = false;
  bool _follow = false; // Karte dreht mit dem Gerät
  final List<LatLng> _measurePts = [];
  AreaDownload? _dl;
  Timer? _saveCam;
  String? _selected;

  @override
  void initState() {
    super.initState();
    final st = app.settings;
    final focus = app.mapFocus != null ? app.nodes[app.mapFocus!] : null;
    if (focus != null && focus.hasPos) {
      _center = LatLng(focus.lat!, focus.lon!);
      _zoom = (st.mapZoom ?? 14) < 13 ? 14 : st.mapZoom!;
      _selected = focus.key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showNodeSheet(context, focus, onOpenChat: widget.onOpenChat, fromMap: true);
      });
    } else if (st.mapLat != null && st.mapLon != null) {
      _center = LatLng(st.mapLat!, st.mapLon!);
      _zoom = st.mapZoom ?? 12;
    } else if (st.lat != null && st.lon != null) {
      _center = LatLng(st.lat!, st.lon!);
      _zoom = 12;
    } else {
      final withPos = app.nodes.values.where((n) => n.hasPos).toList();
      if (withPos.isNotEmpty) {
        _center = LatLng(withPos.first.lat!, withPos.first.lon!);
        _zoom = 11;
      }
    }
    app.mapFocus = null;
  }

  @override
  void dispose() {
    _saveCam?.cancel();
    if (_follow) {
      compass.removeListener(_onCompass);
      compass.release();
    }
    super.dispose();
  }

  void _onMove(LatLng c, double z) {
    _center = c;
    _zoom = z;
    _saveCam?.cancel();
    _saveCam = Timer(const Duration(seconds: 2), () {
      app.settings
        ..mapLat = c.latitude
        ..mapLon = c.longitude
        ..mapZoom = z;
      app.changed(save: true);
    });
    if (mounted) setState(() {});
  }

  void _toggleFollow() {
    if (!Compass.supported) {
      toast(context, tr('Dieses Gerät hat keinen Kompass'), error: true);
      return;
    }
    setState(() => _follow = !_follow);
    if (_follow) {
      compass.acquire();
      compass.addListener(_onCompass);
    } else {
      compass.removeListener(_onCompass);
      compass.release();
      _mc.rotate(0);
    }
  }

  void _onCompass() {
    if (!mounted || !_follow) return;
    final land = MediaQuery.orientationOf(context) == Orientation.landscape;
    final h = compass.screenHeading(land);
    if (h == null) return;
    _mc.rotate(-h);
  }

  LatLng? get _me => app.settings.lat != null && app.settings.lon != null ? LatLng(app.settings.lat!, app.settings.lon!) : null;

  void _goto(LatLng p, [double? z]) {
    _mc.move(p, z ?? (_zoom < 13 ? 14 : _zoom));
  }

  void _fitAll() {
    final pts = <LatLng>[
      ...app.nodes.values.where((n) => n.hasPos && !n.ignored).map((n) => LatLng(n.lat!, n.lon!)),
      ...app.waypoints.map((w) => LatLng(w.lat, w.lon)),
      if (_me != null) _me!,
    ];
    if (pts.isEmpty) {
      toast(context, tr('Noch keine Positionen bekannt'));
      return;
    }
    if (pts.length == 1) {
      _goto(pts.first, 13);
      return;
    }
    _mc.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(60)));
  }

  double get _measureKm {
    var d = 0.0;
    for (var i = 1; i < _measurePts.length; i++) {
      d += distBearing(_measurePts[i - 1].latitude, _measurePts[i - 1].longitude, _measurePts[i].latitude, _measurePts[i].longitude).$1;
    }
    return d;
  }

  // ------------------------------------------------------------------ Ebenen
  void _layerSheet() {
    final st = app.settings;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.rc.panel,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final rc = ctx.rc;
          void set(VoidCallback f) {
            f();
            app.changed(save: true);
            setS(() {});
            setState(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr('Kartenart'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final l in mapLayers)
                    _LayerTile(
                      layer: l,
                      selected: layerById(st.mapLayer).id == l.id,
                      onTap: () => set(() => st.mapLayer = l.id),
                    ),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Offline')),
                  subtitle: Text(tr('Nur gespeicherte Kacheln, kein Internet. Fehlende Kacheln werden aus gröberen vergrößert.')),
                  value: st.mapOffline,
                  onChanged: (v) => set(() => st.mapOffline = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Knotennamen anzeigen')),
                  subtitle: Text(tr('Ab mittlerem Zoom')),
                  value: st.mapNames,
                  onChanged: (v) => set(() => st.mapNames = v),
                ),
                Text(tr('Tipp: „Gebiet speichern“ (Download-Knopf) lädt das sichtbare Gebiet für unterwegs.'),
                    style: TextStyle(fontSize: 12, color: rc.muted)),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------ Gebiet laden
  Future<void> _downloadArea() async {
    final layer = layerById(app.settings.mapLayer);
    final b = _mc.camera.visibleBounds;
    final zMin = _zoom.floor().clamp(3, layer.maxDownloadZoom);
    var zMax = layer.maxDownloadZoom;
    var tiles = TileStore.tilesFor(b.north, b.south, b.west, b.east, zMin, zMax);
    final perTile = layer.all.length;
    while (tiles.length * perTile > 8000 && zMax > zMin) {
      zMax--;
      tiles = TileStore.tilesFor(b.north, b.south, b.west, b.east, zMin, zMax);
    }
    final total = tiles.length * perTile;
    final (n, bytes) = await TileStore.instance.usage();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Sichtbares Gebiet speichern')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('{0}, Zoom {1} bis {2}', [tr(layer.name), zMin, zMax])),
          const SizedBox(height: 6),
          Text(tr('{0} Kacheln, ca. {1} MB, Dauer ca. {2} min', [total, (total * 22 / 1024).toStringAsFixed(0), (total / 5 / 60).ceil()])),
          const SizedBox(height: 10),
          Text(tr('Bereits gespeichert: {0} Kacheln, {1} MB', [n, (bytes / 1048576).toStringAsFixed(0)]),
              style: TextStyle(color: ctx.rc.muted, fontSize: 12.5)),
          if (zMax < layer.maxDownloadZoom)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(tr('Für Zoom bis {0}: näher heranzoomen und kleineres Gebiet laden.', [layer.maxDownloadZoom]),
                  style: TextStyle(color: ctx.rc.warn, fontSize: 12.5)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tr('Weiter hineinzoomen geht offline trotzdem – dann wird die feinste gespeicherte Stufe vergrößert.'),
                style: TextStyle(color: ctx.rc.muted, fontSize: 12)),
          ),
          const SizedBox(height: 8),
          Text(tr('Die Kartendienste sind kostenlos – bitte nur Gebiete laden, die du wirklich brauchst.'),
              style: TextStyle(color: ctx.rc.muted, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Laden'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final dl = AreaDownload(layer, tiles);
    setState(() => _dl = dl);
    await dl.start();
    if (!mounted) return;
    toast(context, dl.cancelled
        ? tr('Abgebrochen')
        : tr('Gebiet gespeichert: {0} Kacheln{1}', [dl.done - dl.failed, dl.failed > 0 ? tr(', {0} fehlgeschlagen', [dl.failed]) : '']));
    setState(() => _dl = null);
  }

  // ------------------------------------------------------------------ Punkt-Menü
  void _pointSheet(LatLng p, {String? title}) {
    final rc = context.rc;
    final me = _me;
    final db = me == null ? null : distBearing(me.latitude, me.longitude, p.latitude, p.longitude);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: rc.panel,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null) Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            CoordBlock(p.latitude, p.longitude),
            if (db != null) KV(tr('Von mir'), '${fmtKm(db.$1)} · ${db.$2.toStringAsFixed(0)}° · ${toMils(db.$2)} ‰'),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _newWaypoint(p);
                },
                icon: const Icon(Icons.flag_outlined),
                label: Text(tr('Wegpunkt')),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  app.setMyPosition(p.latitude, p.longitude);
                  Navigator.pop(ctx);
                  toast(context, tr('Eigene Position gesetzt'));
                },
                icon: const Icon(Icons.my_location),
                label: Text(tr('Hier bin ich')),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '${toMgrs(p.latitude, p.longitude)}\n' '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}'));
                  Navigator.pop(ctx);
                  toast(context, tr('Koordinaten kopiert'));
                },
                icon: const Icon(Icons.copy),
                label: Text(tr('Kopieren')),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _newWaypoint(LatLng p) async {
    final name = TextEditingController(text: tr('Punkt {0}', [app.waypoints.where((w) => w.from == 'ich').length + 1]));
    final desc = TextEditingController();
    var send = app.meshtasticSlot != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr('Wegpunkt')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, maxLength: 30, decoration: InputDecoration(labelText: tr('Name'))),
            TextField(controller: desc, maxLength: 100, decoration: InputDecoration(labelText: tr('Beschreibung'))),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: send,
              onChanged: (v) => setD(() => send = v ?? false),
              title: Text(tr('An alle im Mesh senden')),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Speichern'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final w = app.addWaypoint(p.latitude, p.longitude, name.text.trim().isEmpty ? tr('Wegpunkt') : name.text.trim(),
        description: desc.text.trim());
    if (send) {
      final err = app.sendWaypoint(w);
      if (err != null && mounted) toast(context, err, error: true);
    }
  }

  void _waypointSheet(Waypoint w) {
    final rc = context.rc;
    final me = _me;
    final db = me == null ? null : distBearing(me.latitude, me.longitude, w.lat, w.lon);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: rc.panel,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${w.icon}  ${w.name}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            if (w.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(w.description)),
            Text(w.from == 'ich' ? tr('eigener Wegpunkt') : tr('von {0} · {1}', [app.nodes[w.from]?.display ?? w.from, ago(w.at)]),
                style: TextStyle(color: rc.muted, fontSize: 12.5)),
            const SizedBox(height: 8),
            CoordBlock(w.lat, w.lon),
            if (db != null) KV(tr('Von mir'), '${fmtKm(db.$1)} · ${db.$2.toStringAsFixed(0)}° · ${toMils(db.$2)} ‰'),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(ctx);
                  app.setNavTarget('wp:${w.id}');
                },
                icon: const Icon(Icons.navigation_outlined),
                label: Text(tr('Hinführen')),
              ),
              FilledButton.icon(
                onPressed: () {
                  final err = app.sendWaypoint(w);
                  Navigator.pop(ctx);
                  toast(context, err ?? tr('Wegpunkt gesendet'), error: err != null);
                },
                icon: const Icon(Icons.send),
                label: Text(tr('An alle senden')),
              ),
              TextButton.icon(
                onPressed: () {
                  app.deleteWaypoint(w);
                  Navigator.pop(ctx);
                },
                icon: Icon(Icons.delete_outline, color: rc.crit),
                label: Text(tr('Löschen'), style: TextStyle(color: rc.crit)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  void _openNode(Node n) {
    setState(() => _selected = n.key);
    showNodeSheet(context, n, onOpenChat: widget.onOpenChat, fromMap: true);
  }

  // ------------------------------------------------------------------ Aufbau
  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final st = app.settings;
    final layer = layerById(st.mapLayer);
    TileStore.instance.offline = st.mapOffline;
    final me = _me;
    final nodes = app.nodes.values.where((n) => n.hasPos && !n.ignored).toList()
      ..sort((a, b) => a.lastHeard.compareTo(b.lastHeard)); // neueste oben
    final names = st.mapNames && _zoom >= 10;
    final size = MediaQuery.sizeOf(context);
    final short = size.height < 520;

    final markers = <Marker>[
      for (final w in app.waypoints)
        Marker(
          point: LatLng(w.lat, w.lon),
          width: 140,
          height: 52,
          alignment: Alignment.topCenter,
          child: GestureDetector(
            onTap: () => _waypointSheet(w),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _Label(w.name, rc.warn),
              Text(w.icon, style: const TextStyle(fontSize: 22)),
            ]),
          ),
        ),
      for (final n in nodes)
        Marker(
          point: LatLng(n.lat!, n.lon!),
          width: 140,
          height: names ? 66 : 44,
          alignment: names ? const Alignment(0, 0.35) : Alignment.center,
          child: GestureDetector(
            onTap: () => _openNode(n),
            child: NodeMarker(n, showName: names, selected: _selected == n.key),
          ),
        ),
      if (me != null)
        Marker(
          point: me,
          width: 30,
          height: 30,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: rc.hf,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [BoxShadow(color: rc.hf.withValues(alpha: 0.6), blurRadius: 10)],
            ),
          ),
        ),
      for (final p in _measurePts)
        Marker(
          point: p,
          width: 14,
          height: 14,
          child: Container(
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: Colors.white, border: Border.all(color: rc.crit, width: 3))),
        ),
    ];

    final lines = <Polyline>[
      if (me != null)
        for (final n in nodes)
          if (DateTime.now().difference(n.lastHeard).inHours < 2 && (n.hops ?? 9) == 0)
            Polyline(
                points: [me, LatLng(n.lat!, n.lon!)],
                color: netColor(context, n.net).withValues(alpha: _selected == n.key ? 0.9 : 0.45),
                strokeWidth: _selected == n.key ? 3 : 1.5),
      if (_measurePts.length > 1) Polyline(points: _measurePts, color: rc.crit, strokeWidth: 3),
    ];

    final wide = size.width >= 700;
    TileLayer tiles(MapLayerDef l) => TileLayer(
          key: ValueKey('${l.id}-${st.mapOffline}'),
          urlTemplate: l.url,
          userAgentPackageName: 'de.lr2021.lr2021_app',
          tileProvider: CachedTileProvider(l),
          maxNativeZoom: l.maxZoom,
          keepBuffer: 3,
          panBuffer: 1,
          evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
        );

    final tools = <Widget>[
      _MapButton(me == null ? Icons.gps_not_fixed : Icons.my_location, me == null ? tr('Orten') : tr('Zu mir'), () async {
        if (me != null) {
          _goto(me);
          return;
        }
        final err = await app.locateOnce();
        if (!mounted) return;
        if (err != null) {
          toast(context, err, error: true);
        } else if (_me != null) {
          _goto(_me!, 15);
        }
      }),
      if (Compass.supported)
        _MapButton(_follow ? Icons.explore : Icons.explore_outlined, _follow ? tr('Norden oben') : tr('Mit Gerät drehen'), _toggleFollow,
            active: _follow),
      _MapButton(Icons.fit_screen_outlined, tr('Alle zeigen'), _fitAll),
      _MapButton(Icons.straighten, tr('Messen'), () => setState(() {
            _measure = !_measure;
            _measurePts.clear();
          }), active: _measure),
      _MapButton(Icons.download_for_offline_outlined, tr('Gebiet offline speichern'), _dl == null ? _downloadArea : null),
      _MapButton(Icons.add_location_alt_outlined, tr('Punkt in der Mitte'), () => _pointSheet(_center, title: tr('Kartenmitte'))),
    ];

    return Stack(children: [
      FlutterMap(
        mapController: _mc,
        options: MapOptions(
          initialCenter: _center,
          initialZoom: _zoom,
          minZoom: 3,
          maxZoom: 20,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          onPositionChanged: (cam, _) => _onMove(cam.center, cam.zoom),
          onTap: (_, p) {
            if (_measure) {
              setState(() => _measurePts.add(p));
            } else if (_selected != null) {
              setState(() => _selected = null);
            }
          },
          onLongPress: (_, p) => _pointSheet(p),
          backgroundColor: layer.dark ? const Color(0xFF1B1F24) : const Color(0xFFE8E6E1),
        ),
        children: [
          tiles(layer),
          for (final o in layer.overlays) tiles(o),
          PolylineLayer(polylines: lines),
          MarkerLayer(markers: markers, rotate: true),
        ],
      ),
      // Fadenkreuz in der Mitte
      IgnorePointer(
        child: Center(
          child: Icon(Icons.add, size: 28, color: layer.dark ? Colors.white : rc.crit.withValues(alpha: 0.85)),
        ),
      ),
      // Ebenen (links oben) – der Karte/Radar-Schalter sitzt rechts oben
      Positioned(
        top: 10,
        left: 10,
        child: Material(
          color: rc.panel.withValues(alpha: 0.94),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: rc.line)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _layerSheet,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.layers_outlined, size: 20),
                const SizedBox(width: 6),
                Text(tr(layer.name), style: const TextStyle(fontWeight: FontWeight.w600)),
                if (st.mapOffline) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.cloud_off, size: 16, color: rc.warn),
                ],
              ]),
            ),
          ),
        ),
      ),
      // Werkzeuge rechts (scrollbar, falls die Höhe im Querformat nicht reicht)
      Positioned(
        top: 60,
        right: 10,
        bottom: 46,
        child: SingleChildScrollView(
          child: short
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Column(children: tools.sublist(0, (tools.length + 1) ~/ 2)),
                  const SizedBox(width: 6),
                  Column(children: tools.sublist((tools.length + 1) ~/ 2)),
                ])
              : Column(children: tools),
        ),
      ),
      // Nordpfeil, wenn die Karte gedreht ist
      if (_follow)
        Positioned(
          top: 60,
          left: 10,
          child: ListenableBuilder(
            listenable: compass,
            builder: (context, _) => Transform.rotate(
              angle: _mc.camera.rotationRad,
              child: Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: rc.panel.withValues(alpha: 0.94), shape: BoxShape.circle, border: Border.all(color: rc.line)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.navigation, size: 18, color: rc.crit),
                  Text('N', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: rc.crit, height: 1)),
                ]),
              ),
            ),
          ),
        ),
      // Download-Fortschritt
      if (_dl != null)
        Positioned(
          top: _follow ? 108 : 60,
          left: 10,
          child: ListenableBuilder(
            listenable: _dl!,
            builder: (context, _) => Container(
              width: 260,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: rc.panel.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(10), border: Border.all(color: rc.line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Text(tr('Lade {0}: {1}/{2}', [tr(_dl!.layer.name), _dl!.done, _dl!.total]), style: mono(context, size: 12)),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: _dl!.progress, color: rc.hf, backgroundColor: rc.panelHi),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: () => _dl!.cancelled = true, child: Text(tr('Abbrechen'))),
                ),
              ]),
            ),
          ),
        ),
      // Ziel der Kompass-Navigation (antippen = Radar)
      if (app.navPoint != null)
        Positioned(
          left: 10,
          bottom: 44,
          child: NavTargetCard(compact: true, onTap: () => app.setNavTarget(app.settings.navTarget)),
        ),
      // Koordinatenleiste unten
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          color: rc.panel.withValues(alpha: 0.94),
          child: Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(toMgrs(_center.latitude, _center.longitude), style: mono(context, size: 13, weight: FontWeight.w700, color: rc.hf)),
            Text(toMaidenhead(_center.latitude, _center.longitude), style: mono(context, size: 12.5, color: rc.lf)),
            if (wide) Text('${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}', style: mono(context, size: 12, color: rc.muted)),
            if (me != null)
              Builder(builder: (context) {
                final db = distBearing(me.latitude, me.longitude, _center.latitude, _center.longitude);
                return Text(tr('Mitte: {0} · {1}°', [fmtKm(db.$1), db.$2.toStringAsFixed(0)]), style: mono(context, size: 12, color: rc.muted));
              }),
            Text('Z ${_zoom.toStringAsFixed(1)}', style: mono(context, size: 11.5, color: rc.muted)),
            if (_measure)
              Text(_measurePts.length < 2 ? tr('Messen: Punkte antippen') : tr('Strecke {0}', [fmtKm(_measureKm)]),
                  style: mono(context, size: 12.5, weight: FontWeight.w700, color: rc.crit)),
            if (wide) Text(tr('Lange drücken = Punkt-Menü'), style: TextStyle(fontSize: 11, color: rc.muted)),
          ]),
        ),
      ),
      Positioned(
        right: 6,
        bottom: 36,
        left: 60,
        child: Text(tr(layer.attribution),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.5, color: layer.dark ? Colors.white70 : Colors.black87)),
      ),
    ]);
  }
}

class _LayerTile extends StatelessWidget {
  final MapLayerDef layer;
  final bool selected;
  final VoidCallback onTap;
  const _LayerTile({required this.layer, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final (icon, sub) = switch (layer.id) {
      'topo' => (Icons.terrain, tr('Höhenlinien, Wege')),
      'sat' => (Icons.satellite_alt, tr('Luftbild')),
      'hybrid' => (Icons.layers, tr('Luftbild + Straßennamen')),
      _ => (Icons.signpost_outlined, tr('Straßen, Orte')),
    };
    return SizedBox(
      width: 150,
      child: Material(
        color: selected ? rc.hf.withValues(alpha: 0.18) : rc.panelHi,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), side: BorderSide(color: selected ? rc.hf : rc.line, width: selected ? 2 : 1)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: selected ? rc.hf : null),
              const SizedBox(height: 6),
              Text(tr(layer.name), style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(sub, style: TextStyle(fontSize: 11.5, color: rc.muted)),
              Text(tr('bis Zoom {0}', [layer.maxZoom]), style: mono(context, size: 10.5, color: rc.muted)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  final Color color;
  const _Label(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: context.rc.panel.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      );
}

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final bool active;
  const _MapButton(this.icon, this.tip, this.onTap, {this.active = false});
  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: active ? rc.crit : rc.panel.withValues(alpha: 0.94),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: rc.line)),
        child: IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon, color: active ? Colors.white : null),
        ),
      ),
    );
  }
}

/// Koordinaten in allen gebräuchlichen Formaten.
class CoordBlock extends StatelessWidget {
  final double lat, lon;
  const CoordBlock(this.lat, this.lon, {super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
        KV('MGRS', toMgrs(lat, lon), color: context.rc.hf),
        KV(tr('Locator'), toMaidenhead(lat, lon)),
        KV(tr('Grad'), '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}'),
        KV('GMS', toDms(lat, lon)),
      ]);
}
