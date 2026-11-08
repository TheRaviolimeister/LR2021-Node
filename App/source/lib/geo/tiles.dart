import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';

import 'coords.dart';

/// Kartenebenen. Jede angesehene Kachel wird auf der Festplatte gespeichert und
/// funktioniert danach ohne Internet. Größere Gebiete lassen sich vorab laden.
/// Fehlt eine Kachel (offline, zu nah herangezoomt), wird eine gröbere gespeicherte
/// Kachel vergrößert – so bleibt die Karte auch über die geladene Zoomstufe hinaus sichtbar.
class MapLayerDef {
  final String id;
  final String name;
  final String url;
  final String attribution;
  final int maxZoom; // höchste Zoomstufe, die der Server liefert
  final int maxDownloadZoom; // bis hierhin darf ein Gebiet vorab geladen werden
  final List<MapLayerDef> overlays; // durchsichtige Ebenen darüber (Straßen, Namen)
  final bool dark; // Bild ist dunkel -> helle Beschriftung
  const MapLayerDef(this.id, this.name, this.url, this.attribution, this.maxZoom, this.maxDownloadZoom,
      {this.overlays = const [], this.dark = false});

  /// Alle Ebenen, die gespeichert werden (Grundkarte + Überlagerungen).
  List<MapLayerDef> get all => [this, ...overlays];
}

const _esri = 'https://server.arcgisonline.com/ArcGIS/rest/services';
const _roads = MapLayerDef('esri_roads', 'Straßen', '$_esri/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}',
    '', 19, 17);
const _places = MapLayerDef('esri_places', 'Orte', '$_esri/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    '', 19, 17);

const mapLayers = <MapLayerDef>[
  MapLayerDef('topo', 'Topo', 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
      '© OpenStreetMap-Mitwirkende, SRTM · Kartendarstellung © OpenTopoMap (CC-BY-SA)', 17, 16),
  MapLayerDef('sat', 'Satellit', '$_esri/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'Bilder © Esri, Maxar, Earthstar Geographics', 19, 17, dark: true),
  MapLayerDef('hybrid', 'Hybrid', '$_esri/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'Bilder © Esri, Maxar, Earthstar Geographics · Straßen/Namen © Esri, HERE, Garmin', 19, 17,
      overlays: [_roads, _places], dark: true),
  MapLayerDef('street', 'Straße', '$_esri/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
      'Karte © Esri, HERE, Garmin, OpenStreetMap-Mitwirkende', 19, 17),
];

/// 'sat' und 'hybrid' teilen sich die Satellitenbilder im Speicher.
String _storeId(MapLayerDef l) => l.id == 'hybrid' ? 'sat' : l.id;

MapLayerDef layerById(String id) =>
    mapLayers.firstWhere((l) => l.id == (id == 'osm' ? 'street' : id), orElse: () => mapLayers.first);

const _userAgent = 'LR2021-Node/1.1 (privates Amateurfunk-Projekt)';

class TileStore {
  TileStore._();
  static final TileStore instance = TileStore._();

  Directory? _root;
  final HttpClient _http = HttpClient()
    ..userAgent = _userAgent
    ..maxConnectionsPerHost = 6
    ..connectionTimeout = const Duration(seconds: 8);
  bool offline = false; // true = nur Speicher benutzen

  Future<Directory> root() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}tiles');
    await d.create(recursive: true);
    _root = d;
    return d;
  }

  String _url(MapLayerDef l, int z, int x, int y) =>
      l.url.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');

  Future<File> _file(MapLayerDef l, int z, int x, int y) async {
    final r = await root();
    final s = Platform.pathSeparator;
    return File('${r.path}$s${_storeId(l)}$s$z$s$x$s$y.tile');
  }

  /// Nur aus dem Speicher.
  Future<Uint8List?> cached(MapLayerDef l, int z, int x, int y) async {
    final f = await _file(l, z, x, y);
    try {
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  /// Kachel aus dem Speicher oder aus dem Netz (und dann speichern).
  Future<Uint8List?> get(MapLayerDef l, int z, int x, int y) async {
    final c = await cached(l, z, x, y);
    if (c != null) return c;
    if (offline) return null;
    final data = await _download(_url(l, z, x, y));
    if (data != null) {
      try {
        final f = await _file(l, z, x, y);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(data, flush: false);
      } catch (_) {}
    }
    return data;
  }

  Future<bool> has(MapLayerDef l, int z, int x, int y) async => (await _file(l, z, x, y)).exists();

  Future<Uint8List?> _download(String url) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final req = await _http.getUrl(Uri.parse(url));
        final res = await req.close().timeout(const Duration(seconds: 15));
        if (res.statusCode == 404) {
          await res.drain<void>();
          return null; // gibt es nicht – nicht nochmal versuchen
        }
        if (res.statusCode != 200) {
          await res.drain<void>();
          continue;
        }
        final d = await consolidateHttpClientResponseBytes(res);
        if (d.length > 50) return d;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return null;
  }

  /// Anzahl und Größe der gespeicherten Kacheln.
  Future<(int, int)> usage() async {
    final r = await root();
    var n = 0, bytes = 0;
    await for (final e in r.list(recursive: true, followLinks: false)) {
      if (e is File) {
        n++;
        try {
          bytes += await e.length();
        } catch (_) {}
      }
    }
    return (n, bytes);
  }

  Future<void> clear() async {
    final r = await root();
    if (await r.exists()) await r.delete(recursive: true);
    _root = null;
    await root();
    PaintingBinding.instance.imageCache.clear();
  }

  /// Kacheln eines Gebiets für die Zoomstufen [zMin]..[zMax].
  static List<(int, int, int)> tilesFor(double north, double south, double west, double east, int zMin, int zMax) {
    final out = <(int, int, int)>[];
    for (var z = zMin; z <= zMax; z++) {
      final x0 = lonToTileX(west, z), x1 = lonToTileX(east, z);
      final y0 = latToTileY(north, z), y1 = latToTileY(south, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          out.add((z, x, y));
        }
      }
    }
    return out;
  }
}

/// Fortschritt eines Gebiets-Downloads (Grundkarte und Überlagerungen).
class AreaDownload extends ChangeNotifier {
  final MapLayerDef layer;
  final List<(int, int, int)> tiles;
  int done = 0, failed = 0, skipped = 0;
  bool running = false, cancelled = false;
  AreaDownload(this.layer, this.tiles);

  int get total => tiles.length * layer.all.length;
  double get progress => total == 0 ? 1 : done / total;

  Future<void> start() async {
    running = true;
    notifyListeners();
    final store = TileStore.instance;
    final wasOffline = store.offline;
    store.offline = false;
    try {
      for (final l in layer.all) {
        for (final t in tiles) {
          if (cancelled) break;
          if (await store.has(l, t.$1, t.$2, t.$3)) {
            skipped++;
          } else {
            final d = await store.get(l, t.$1, t.$2, t.$3);
            if (d == null) failed++;
            // Server schonen: höchstens etwa 5 Kacheln pro Sekunde
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          done++;
          if (done % 5 == 0 || done == total) notifyListeners();
        }
      }
    } finally {
      store.offline = wasOffline;
    }
    running = false;
    notifyListeners();
  }
}

// ---------------------------------------------------------------- flutter_map-Anbindung
class CachedTileProvider extends TileProvider {
  final MapLayerDef layer;
  CachedTileProvider(this.layer);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _CachedTileImage(layer, coordinates.z, coordinates.x, coordinates.y);
}

@immutable
class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  final MapLayerDef layer;
  final int z, x, y;
  const _CachedTileImage(this.layer, this.z, this.x, this.y);

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<_CachedTileImage>(this);

  @override
  ImageStreamCompleter loadImage(_CachedTileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final data = await TileStore.instance.get(layer, z, x, y);
    if (data != null) return decode(await ui.ImmutableBuffer.fromUint8List(data));
    // Ersatz: gröbere gespeicherte Kachel vergrößern (offline oder Server liefert nichts)
    final up = await _fromParent();
    if (up != null) {
      // nur vorläufig: später (z. B. wieder online) neu laden
      Timer(const Duration(seconds: 20), () => PaintingBinding.instance.imageCache.evict(this));
      return decode(await ui.ImmutableBuffer.fromUint8List(up));
    }
    throw StateError('Kachel nicht verfügbar');
  }

  Future<Uint8List?> _fromParent() async {
    for (var dz = 1; dz <= 8 && z - dz >= 0; dz++) {
      final pz = z - dz, px = x >> dz, py = y >> dz;
      final pd = await TileStore.instance.cached(layer, pz, px, py);
      if (pd == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(pd);
        final img = (await codec.getNextFrame()).image;
        final n = 1 << dz;
        final part = img.width / n;
        final sx = (x - (px << dz)) * part, sy = (y - (py << dz)) * part;
        final rec = ui.PictureRecorder();
        ui.Canvas(rec).drawImageRect(
          img,
          ui.Rect.fromLTWH(sx, sy, part, part),
          const ui.Rect.fromLTWH(0, 0, 256, 256),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final out = await rec.endRecording().toImage(256, 256);
        final bd = await out.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        out.dispose();
        if (bd != null) return bd.buffer.asUint8List();
      } catch (_) {}
      return null;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is _CachedTileImage && other.layer.id == layer.id && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(layer.id, z, x, y);
}
