import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n.dart';

/// Version dieser App (beim Bauen per --dart-define=APP_VERSION=… gesetzt).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.6.3');

/// GitHub-Repository mit den Releases (beim Bauen per --dart-define=UPDATE_REPO=besitzer/name gesetzt).
const updateRepo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'TheRaviolimeister/LR2021-Node');

class UpdateInfo {
  final String version, notes, assetName, assetUrl, pageUrl;
  final int size;
  final String mirrorUrl; // Ausweich-Download (Zweig „dist“ über raw.githubusercontent.com)
  final String sha256; // Prüfsumme der Datei (aus latest.json), leer = unbekannt
  UpdateInfo(this.version, this.notes, this.assetName, this.assetUrl, this.pageUrl, this.size,
      {this.mirrorUrl = '', this.sha256 = ''});
}

/// Sucht neue Versionen in den GitHub-Releases und installiert sie.
///   Android: APK laden und den System-Installer öffnen
///   Windows: ZIP laden, nach dem Beenden der App ersetzen und neu starten
///   Linux:   tar.gz laden, nach dem Beenden ersetzen und neu starten
///   iOS:     Download-Seite öffnen; mit AltStore/SideStore (Quelle im Zweig „dist“) kommen Updates automatisch
/// Ist die GitHub-Schnittstelle gestört, kommen Versionsinfo und Dateien aus dem Zweig „dist“
/// (raw.githubusercontent.com bzw. jsDelivr). Heruntergeladene Dateien werden per SHA-256 geprüft.
class Updater extends ChangeNotifier {
  UpdateInfo? available;
  String status = '';
  double? progress;
  bool busy = false;
  DateTime? lastCheck;

  static const rawBase = 'https://raw.githubusercontent.com/$updateRepo/dist';
  static const cdnBase = 'https://cdn.jsdelivr.net/gh/$updateRepo@dist';

  static String get platformAsset {
    if (Platform.isAndroid) return 'LR2021-Node-android.apk';
    if (Platform.isWindows) return 'LR2021-Node-windows-x64.zip';
    if (Platform.isLinux) return 'LR2021-Node-linux-x64.tar.gz';
    if (Platform.isIOS) return 'LR2021-Node-ios.ipa';
    return '';
  }

  static bool get supported => platformAsset.isNotEmpty;

  /// Versionen vergleichen: >0, wenn [a] neuer ist als [b].
  static int compare(String a, String b) {
    List<int> p(String v) => v.replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[.+-]')).map((x) => int.tryParse(x) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  static Future<Map<String, dynamic>> _getJson(String url, {bool github = false}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'LR2021-Node-App/$appVersion');
      if (github) req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      c.close(force: true);
    }
  }

  /// Versionsinfo aus der GitHub-Schnittstelle.
  Future<UpdateInfo?> _fromApi() async {
    final j = await _getJson('https://api.github.com/repos/$updateRepo/releases/latest', github: true);
    final tag = (j['tag_name'] as String? ?? '').trim();
    final assets = (j['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
    final a = assets.where((x) => x['name'] == platformAsset).firstOrNull;
    return UpdateInfo(
      tag.replaceFirst(RegExp(r'^[vV]'), ''),
      j['body'] as String? ?? '',
      a?['name'] as String? ?? '',
      a?['browser_download_url'] as String? ?? '',
      j['html_url'] as String? ?? 'https://github.com/$updateRepo/releases',
      a?['size'] as int? ?? 0,
      mirrorUrl: a == null ? '' : '$rawBase/$platformAsset',
    );
  }

  /// Versionsinfo aus latest.json im Zweig „dist“.
  Future<UpdateInfo?> _fromManifest(String base) async {
    final j = await _getJson('$base/latest.json');
    final v = (j['version'] as String? ?? '').trim();
    final assets = (j['assets'] as Map?)?.cast<String, dynamic>() ?? const {};
    final a = (assets[platformAsset] as Map?)?.cast<String, dynamic>();
    return UpdateInfo(
      v,
      j['notes'] as String? ?? '',
      a == null ? '' : platformAsset,
      a == null ? '' : 'https://github.com/$updateRepo/releases/download/v$v/$platformAsset',
      j['page'] as String? ?? 'https://github.com/$updateRepo/releases',
      a?['size'] as int? ?? 0,
      mirrorUrl: a == null ? '' : '$rawBase/$platformAsset',
      sha256: a?['sha256'] as String? ?? '',
    );
  }

  Future<UpdateInfo?> check() async {
    if (busy) return available;
    busy = true;
    status = tr('suche nach Updates …');
    notifyListeners();
    final errors = <String>[];
    UpdateInfo? info;
    for (final src in [() => _fromApi(), () => _fromManifest(rawBase), () => _fromManifest(cdnBase)]) {
      try {
        info = await src();
        if (info != null && info.version.isNotEmpty) break;
      } catch (e) {
        errors.add(e.toString().replaceFirst('Exception: ', '').split('\n').first);
      }
    }
    try {
      if (info == null || info.version.isEmpty) {
        status = tr('Keine Verbindung zum Update-Server ({0}).', [errors.join(' / ')]);
        return null;
      }
      lastCheck = DateTime.now();
      if (compare(info.version, appVersion) <= 0) {
        available = null;
        status = tr('Die App ist aktuell ({0}).', [appVersion]);
        return null;
      }
      available = info;
      status = tr('Version {0} ist verfügbar.', [info.version]);
      return info;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _fetch(String url, File f, int sizeHint) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await c.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'LR2021-Node-App/$appVersion');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength > 0 ? res.contentLength : sizeHint;
      final sink = f.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && got < total) throw Exception(tr('Download unvollständig'));
    } finally {
      c.close(force: true);
    }
  }

  Future<File> _download(UpdateInfo u) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}lr2021_update');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}${u.assetName}');
    final urls = [u.assetUrl, u.mirrorUrl].where((x) => x.isNotEmpty).toList();
    Object? last;
    for (final url in urls) {
      try {
        await _fetch(url, f, u.size);
        if (u.sha256.isNotEmpty) {
          final digest = crypto.sha256.convert(await f.readAsBytes()).toString();
          if (digest.toLowerCase() != u.sha256.toLowerCase()) throw Exception(tr('Prüfsumme stimmt nicht'));
        }
        return f;
      } catch (e) {
        last = e;
      }
    }
    throw last ?? Exception(tr('Download fehlgeschlagen'));
  }

  /// Update laden und installieren. Gibt Fehlertext oder null zurück.
  /// Unter Windows/Linux beendet sich die App danach und startet neu.
  Future<String?> install() async {
    final u = available;
    if (u == null) return tr('Kein Update verfügbar.');
    if (Platform.isIOS) {
      // iOS erlaubt keine Installation aus der App heraus: Release-Seite öffnen (AltStore/SideStore installiert)
      final ok = await launchUrl(Uri.parse(u.pageUrl), mode: LaunchMode.externalApplication);
      return ok ? null : tr('Seite konnte nicht geöffnet werden: {0}', [u.pageUrl]);
    }
    if (u.assetUrl.isEmpty) return tr('Für dieses System gibt es in dieser Version kein Paket.');
    if (busy) return null;
    busy = true;
    progress = 0;
    status = tr('lade Version {0} …', [u.version]);
    notifyListeners();
    try {
      final f = await _download(u);
      status = tr('installiere …');
      notifyListeners();
      if (Platform.isAndroid) {
        final r = await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
        if (r.type != ResultType.done) return tr('Installation nicht gestartet: {0}', [r.message]);
        return null;
      }
      final exe = File(Platform.resolvedExecutable);
      final appDir = exe.parent.path;
      final newDir = Directory('${f.parent.path}${Platform.pathSeparator}neu');
      await newDir.create(recursive: true);
      final bytes = await f.readAsBytes();
      final Archive arch = Platform.isWindows ? ZipDecoder().decodeBytes(bytes) : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
      for (final e in arch) {
        final out = '${newDir.path}${Platform.pathSeparator}${e.name.replaceAll('/', Platform.pathSeparator)}';
        if (e.isFile) {
          final o = File(out);
          await o.parent.create(recursive: true);
          await o.writeAsBytes(e.content as List<int>);
        } else {
          await Directory(out).create(recursive: true);
        }
      }
      // Inhalt kann in einem Unterordner liegen: den Ordner mit der Programmdatei suchen
      final exeName = exe.uri.pathSegments.last;
      var src = newDir.path;
      await for (final e in newDir.list(recursive: true)) {
        if (e is File && e.uri.pathSegments.last == exeName) {
          src = e.parent.path;
          break;
        }
      }
      if (Platform.isWindows) {
        final bat = File('${f.parent.path}\\update.bat');
        await bat.writeAsString('@echo off\r\n'
            ':warten\r\n'
            'tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul && (timeout /t 1 /nobreak >nul & goto warten)\r\n'
            'robocopy "$src" "$appDir" /E /R:3 /W:1 /NFL /NDL /NJH /NJS >nul\r\n'
            'start "" "${exe.path}"\r\n');
        await Process.start('cmd', ['/c', 'start', '', '/min', bat.path], mode: ProcessStartMode.detached);
      } else {
        final sh = File('${f.parent.path}/update.sh');
        await sh.writeAsString('#!/bin/sh\n'
            'while kill -0 $pid 2>/dev/null; do sleep 1; done\n'
            'cp -rf "$src/." "$appDir/"\n'
            'chmod +x "${exe.path}"\n'
            'nohup "${exe.path}" >/dev/null 2>&1 &\n');
        await Process.run('chmod', ['+x', sh.path]);
        await Process.start('/bin/sh', [sh.path], mode: ProcessStartMode.detached);
      }
      exit(0);
    } catch (e) {
      status = tr('Update fehlgeschlagen: {0}', [e]);
      return status;
    } finally {
      busy = false;
      progress = null;
      notifyListeners();
    }
  }
}

/// Ein Updater für die ganze App.
final Updater updater = Updater();
