import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bytes.dart';
import '../core/updater.dart';
import '../geo/compass.dart';
import '../geo/coords.dart';
import '../geo/tiles.dart';
import '../mesh/meshtastic.dart';
import '../state/app.dart';
import '../state/app_state.dart';
import '../state/models.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

class SettingsPage extends StatefulWidget {
  SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final st = app.settings;
  late final _long = TextEditingController(text: st.longName);
  late final _short = TextEditingController(text: st.shortName);
  late final _call = TextEditingController(text: st.callsign);
  late final _lat = TextEditingController(text: st.lat?.toStringAsFixed(6) ?? '');
  late final _lon = TextEditingController(text: st.lon?.toStringAsFixed(6) ?? '');
  late final _alt = TextEditingController(text: st.alt?.toString() ?? '');
  late final _pi = TextEditingController(text: st.piHost);
  late final _link = TextEditingController();
  late final _quick = TextEditingController(text: st.quickMsgs.join('\n'));

  @override
  void dispose() {
    for (final c in [_long, _short, _call, _lat, _lon, _alt, _pi, _quick, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() => app.changed(save: true);

  double? _num(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  Widget _drop<T>(String label, T value, Map<T, String> items, void Function(T v) set) => DropdownButtonFormField<T>(
        value: items.containsKey(value) ? value : items.keys.first,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [for (final e in items.entries) DropdownMenuItem<T>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
        onChanged: (v) {
          if (v == null) return;
          setState(() => set(v));
          _save();
        },
      );

  /// Alle Abschnitte (Reihenfolge = _Cat.sections).
  List<Widget> _sections(BuildContext context) {
    final rc = context.rc;
    return <Widget>[
      Section(
        title: tr('Eigener Knoten'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _long,
            maxLength: 39,
            decoration: InputDecoration(labelText: tr('Name')),
            onChanged: (v) {
              st.longName = v.trim().isEmpty ? tr('LR2021 Node') : v.trim();
              _save();
            },
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _short,
                maxLength: 4,
                decoration: InputDecoration(labelText: tr('Kürzel')),
                onChanged: (v) {
                  st.shortName = v.trim();
                  _save();
                },
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _call,
                maxLength: 12,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: tr('Rufzeichen')),
                onChanged: (v) {
                  st.callsign = v.trim().toUpperCase();
                  _save();
                },
              ),
            ),
          ]),
          KV('Knoten-ID', st.myNum == 0 ? tr('wird beim ersten Verbinden von ESP32 A gebildet') : nodeIdStr(st.myNum)),
          SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                st.myNum = 0x4C520000 | Random.secure().nextInt(0x10000);
                _save();
                setState(() {});
              },
              child: Text(tr('Neue Zufalls-ID')),
            ),
          ),
          Text(tr('Die Änderung des Namens geht mit der nächsten Visitenkarte raus (Chat → Menü → Visitenkarte senden).'),
              style: TextStyle(color: rc.muted, fontSize: 12)),
        ]),
      ),
      Section(
        title: tr('Meshtastic'),
        accent: rc.hf,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < st.channels.length; i++) _ChannelRow(key: ObjectKey(st.channels[i]), index: i, onChanged: () => setState(_save)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: st.channels.length >= 8
                  ? null
                  : () {
                      final key = List<int>.generate(16, (_) => Random.secure().nextInt(256));
                      st.channels.add(MtChannel(tr('Privat{0}', [st.channels.length]), base64Encode(key)));
                      setState(_save);
                    },
              icon: Icon(Icons.add),
              label: Text(tr('Kanal hinzufügen')),
            ),
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _link,
                decoration: InputDecoration(labelText: tr('Meshtastic-Kanal-Link einfügen'), hintText: 'https://meshtastic.org/e/#…'),
              ),
            ),
            SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                final l = parseChannelLink(_link.text);
                if (l == null) {
                  toast(context, tr('Kein gültiger Kanal-Link'), error: true);
                  return;
                }
                setState(() {
                  st.channels = l.channels.take(8).toList();
                  final pi = mtPresets.indexWhere((p) => p.name == l.presetName);
                  if (pi >= 0) st.mtPreset = pi;
                  _link.clear();
                  _save();
                });
                toast(context, tr('{0} Kanal/Kanäle übernommen', [l.channels.length]));
              },
              child: Text(tr('Übernehmen')),
            ),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                final link = buildChannelLink(st.channels, preset: mtPresets[st.mtPreset].name);
                Clipboard.setData(ClipboardData(text: link));
                toast(context, tr('Link kopiert – in der Meshtastic-App öffnen oder als QR teilen'));
              },
              icon: Icon(Icons.link, size: 18),
              label: Text(tr('Eigene Kanäle als Link kopieren')),
            ),
          ),
          SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: st.hopLimit,
                decoration: InputDecoration(labelText: tr('Max. Hops')),
                items: [for (var i = 1; i <= 7; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                onChanged: (v) {
                  st.hopLimit = v ?? 3;
                  _save();
                },
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                value: [0, 1, 3, 6, 12].contains(st.nodeInfoHours) ? st.nodeInfoHours : 3,
                decoration: InputDecoration(labelText: tr('Visitenkarte senden')),
                items: [
                  DropdownMenuItem(value: 0, child: Text(tr('nur beim Start'))),
                  DropdownMenuItem(value: 1, child: Text(tr('jede Stunde'))),
                  DropdownMenuItem(value: 3, child: Text(tr('alle 3 h'))),
                  DropdownMenuItem(value: 6, child: Text(tr('alle 6 h'))),
                  DropdownMenuItem(value: 12, child: Text(tr('alle 12 h'))),
                ],
                onChanged: (v) {
                  st.nodeInfoHours = v ?? 3;
                  _save();
                },
              ),
            ),
          ]),
          SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _drop<String>(tr('Rolle'), st.mtRole, {
                'client': tr('Client (leitet weiter)'),
                'client_mute': tr('Client stumm (leitet nicht weiter)'),
                'router': tr('Router (leitet bevorzugt weiter)'),
              }, (v) => st.mtRole = v),
            ),
            SizedBox(width: 12),
            Expanded(
              child: _drop<String>(tr('Weiterleiten'), st.rebroadcast, {
                'all': tr('alle Pakete'),
                'local': tr('nur eigene Kanäle'),
                'known': tr('nur bekannte Knoten'),
                'none': 'keine',
              }, (v) => st.rebroadcast = v),
            ),
          ]),
          Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(tr('{0} weitergeleitet, {1} unnötig (schon von anderen gesendet)', [app.relayed, app.relayCancelled]),
                style: TextStyle(color: rc.muted, fontSize: 12)),
          ),
          SizedBox(height: 12),
          _drop<int>(tr('Eigene Telemetrie senden'), st.telemetryMin, {
            0: 'aus',
            15: tr('alle 15 min'),
            30: tr('alle 30 min'),
            60: tr('jede Stunde'),
          }, (v) => st.telemetryMin = v),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Vor dem Senden Kanal prüfen (LBT)')),
            subtitle: Text(tr('Wartet vor dem Senden, bis der Kanal frei ist (Listen Before Talk).')),
            value: st.lbt,
            onChanged: (v) => setState(() {
              st.lbt = v;
              _save();
            }),
          ),
        ]),
      ),
      _PowerSection(),
      Section(
        title: tr('Position'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _drop<String>('GPS-Quelle', st.gpsSource, {
            'auto': tr('Automatisch (Node-GPS, sonst Gerät)'),
            'node': tr('Nur GPS der Node (über den Pi)'),
            'geraet': tr('Nur dieses Gerät (Handy/PC)'),
            'aus': tr('Aus – Position von Hand'),
          }, (v) {
            app.setGpsSource(v).then((err) {
              if (err != null && context.mounted) toast(context, err, error: true);
            });
          }),
          Padding(
            padding: EdgeInsets.only(top: 6, bottom: 6),
            child: Text(tr('Status: {0}{1}', [app.gpsStatus, app.gpsFrom.isNotEmpty ? tr(' · letzte Position von: {0}', [app.gpsFrom]) : '']),
                style: TextStyle(color: rc.muted, fontSize: 12)),
          ),
          if (st.gpsSource == 'aus')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final err = await app.locateOnce();
                  if (!context.mounted) return;
                  if (err != null) {
                    toast(context, err, error: true);
                  } else {
                    _lat.text = st.lat!.toStringAsFixed(6);
                    _lon.text = st.lon!.toStringAsFixed(6);
                    _alt.text = st.alt?.toString() ?? '';
                    toast(context, tr('Position übernommen'));
                  }
                },
                icon: Icon(Icons.gps_fixed, size: 18),
                label: Text(tr('Jetzt einmal orten')),
              ),
            ),
          if (st.gpsSource == 'aus')
          Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _lat,
                keyboardType: TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(labelText: tr('Breite'), suffixText: '°N'),
                onChanged: (v) {
                  st.lat = _num(v);
                  _save();
                },
              ),
            ),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _lon,
                keyboardType: TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(labelText: tr('Länge'), suffixText: '°O'),
                onChanged: (v) {
                  st.lon = _num(v);
                  _save();
                },
              ),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _alt,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('Höhe'), suffixText: 'm'),
                onChanged: (v) {
                  st.alt = int.tryParse(v.trim());
                  _save();
                },
              ),
            ),
          ]),
          if (st.lat != null && st.lon != null) ...[
            SizedBox(height: 8),
            KV('MGRS', toMgrs(st.lat!, st.lon!), color: rc.hf),
            KV(tr('Locator'), toMaidenhead(st.lat!, st.lon!)),
          ],
          Text(tr('Tipp: Auf der Karte lange drücken → „Hier bin ich“.'), style: TextStyle(color: rc.muted, fontSize: 12)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Position im Mesh teilen')),
            subtitle: Text(tr('Über Meshtastic an alle')),
            value: st.sharePosition,
            onChanged: (v) => setState(() {
              st.sharePosition = v;
              _save();
            }),
          ),
          if (st.sharePosition)
            Row(children: [
              Expanded(
                child: _drop<int>(tr('Intervall'), st.posIntervalMin, {
                  5: tr('alle 5 min'),
                  15: tr('alle 15 min'),
                  30: tr('alle 30 min'),
                  60: tr('jede Stunde'),
                  180: tr('alle 3 h'),
                }, (v) => st.posIntervalMin = v),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _drop<int>(tr('Genauigkeit'), st.posPrecision, {
                  32: 'genau',
                  19: tr('ca. 45 m'),
                  17: tr('ca. 180 m'),
                  15: tr('ca. 730 m'),
                  13: tr('ca. 3 km'),
                  11: tr('ca. 12 km'),
                }, (v) => st.posPrecision = v),
              ),
            ]),
        ]),
      ),
      Section(
        title: tr('LR-Funk 70 cm'),
        accent: rc.lf,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Empfang automatisch bestätigen')),
            value: st.lrAutoAck,
            onChanged: (v) => setState(() {
              st.lrAutoAck = v;
              _save();
            }),
          ),
          DropdownButtonFormField<int>(
            value: [0, 10, 30, 60].contains(st.lrBeaconMin) ? st.lrBeaconMin : 0,
            decoration: InputDecoration(labelText: tr('Bake mit Rufzeichen')),
            items: [
              DropdownMenuItem(value: 0, child: Text('aus')),
              DropdownMenuItem(value: 10, child: Text(tr('alle 10 min'))),
              DropdownMenuItem(value: 30, child: Text(tr('alle 30 min'))),
              DropdownMenuItem(value: 60, child: Text(tr('jede Stunde'))),
            ],
            onChanged: (v) {
              st.lrBeaconMin = v ?? 0;
              _save();
            },
          ),
          const SizedBox(height: 8),
          Text(tr('Klartext, jede Aussendung trägt dein Rufzeichen. Frequenz und Modulation unter Funk → LF 433.'),
              style: TextStyle(color: rc.muted, fontSize: 12)),
        ]),
      ),
      Section(
        title: tr('Chat'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Ton bei neuer Nachricht')),
            value: st.sound,
            onChanged: (v) => setState(() {
              st.sound = v;
              _save();
            }),
          ),
          TextField(
            controller: _quick,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(labelText: tr('Schnellnachrichten (eine pro Zeile)')),
            onChanged: (v) {
              st.quickMsgs = v.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              _save();
            },
          ),
        ]),
      ),
      const _MapCacheSection(),
      Section(
        title: tr('Verbindung'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Beim Start automatisch verbinden')),
            subtitle: Text(tr('Verbindet die zuletzt benutzten Modems und verbindet neu, wenn ein Kabel kurz weg war')),
            value: st.autoConnect,
            onChanged: (v) => setState(() {
              st.autoConnect = v;
              _save();
            }),
          ),
          TextField(
            controller: _pi,
            decoration: InputDecoration(labelText: tr('Adresse im WLAN'), hintText: '10.42.0.1', helperText: tr('Orange Pi im WLAN (Modems: Port 2021/2022, GPS: 2023)')),
            onChanged: (v) {
              st.piHost = v.trim();
              _save();
            },
          ),
          const SizedBox(height: 6),
          Text(tr('Funk → Verbindung „Netzwerk (Pi)“. Ports 2021 (HF) und 2022 (LF).'),
              style: TextStyle(color: rc.muted, fontSize: 12)),
          const SizedBox(height: 16),
          Text(tr('Node-Kabel (CP2102 / Konsole)'), style: TextStyle(fontWeight: FontWeight.w600, color: rc.muted)),
          Row(children: [
            Expanded(
              child: TextFormField(
                initialValue: st.nodeUser,
                decoration: InputDecoration(labelText: tr('Benutzer')),
                onChanged: (v) {
                  st.nodeUser = v.trim().isEmpty ? 'root' : v.trim();
                  _save();
                },
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                initialValue: st.nodePass,
                obscureText: true,
                decoration: InputDecoration(labelText: tr('Passwort')),
                onChanged: (v) {
                  st.nodePass = v;
                  _save();
                },
              ),
            ),
          ]),
          SizedBox(height: 6),
          Text(tr('Funk → Verbindung „Node-Kabel“: die App meldet sich damit an der Konsole an und startet die Brücke.'),
              style: TextStyle(color: rc.muted, fontSize: 12)),
        ]),
      ),
      Section(
        title: tr('Darstellung und Daten'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Sprache der App'), style: TextStyle(color: rc.muted, fontSize: 12.5)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'en', label: Text('English')),
              ButtonSegment(value: 'de', label: Text('Deutsch')),
            ],
            selected: {st.lang == 'de' ? 'de' : 'en'},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => app.setLanguage(v.first)),
          ),
          const SizedBox(height: 16),
          SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(tr('System'))),
              ButtonSegment(value: 1, label: Text(tr('Hell'))),
              ButtonSegment(value: 2, label: Text(tr('Dunkel'))),
            ],
            selected: {st.theme},
            showSelectedIcon: false,
            onSelectionChanged: (v) {
              st.theme = v.first;
              _save();
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(tr('Alles löschen?')),
                    content: Text(tr('Nachrichten, Knotenliste und Monitor werden gelöscht. Einstellungen bleiben.')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Löschen'))),
                    ],
                  ),
                );
                if (ok == true) await app.wipeAll();
              },
              icon: Icon(Icons.delete_forever_outlined, color: rc.crit),
              label: Text(tr('Nachrichten und Knoten löschen'), style: TextStyle(color: rc.crit)),
            ),
          ),
          const SizedBox(height: 12),
          Text(tr('LR2021 Node App {0} · Modem-Protokoll v1', [appVersion]), style: mono(context, size: 11.5, color: rc.muted)),
        ]),
      ),
      const _FreqCorrSection(), // 9
      const _MapSettingsSection(), // 10
      const _UpdateSection(), // 11
    ];
  }

  int? _cat; // gewählte Kategorie (breiter Bildschirm)

  List<_Cat> get _cats {
    final st = app.settings;
    return [
      _Cat(Icons.person_outline, tr('Mein Knoten'),
          '${st.longName}${st.callsign.isNotEmpty ? ' · ${st.callsign}' : ''} · ${st.myNum == 0 ? tr('ID folgt') : nodeIdStr(st.myNum)}', [0]),
      _Cat(Icons.forum_outlined, tr('Meshtastic'),
          tr('{0} Kanal/Kanäle · {1} · Rolle {2}', [st.channels.length, mtPresets[st.mtPreset].name, st.mtRole]), [1]),
      _Cat(Icons.settings_input_antenna, tr('Funk und Sendeleistung'),
          tr('{0}{1} · Korrektur {2} / {3} kHz', [st.powerAuto ? tr('Leistung automatisch') : tr('Leistung von Hand'), st.licensed ? tr(' · Lizenz') : '', (st.freqCorrA / 1000).toStringAsFixed(1), (st.freqCorrB / 1000).toStringAsFixed(1)]),
          [2, 9]),
      _Cat(Icons.my_location, tr('Position und GPS'), '${app.gpsStatus}${st.sharePosition ? tr(' · wird geteilt') : ''}', [3]),
      _Cat(Icons.cell_tower, tr('LR-Funk 70 cm'), st.lrBeaconMin > 0 ? tr('Bake alle {0} min', [st.lrBeaconMin]) : tr('Bake aus'), [4]),
      _Cat(Icons.chat_outlined, tr('Chat'), st.sound ? tr('Ton an') : tr('Ton aus'), [5]),
      _Cat(Icons.map_outlined, tr('Karte und Offline'), tr('{0} · Namen {1}', [st.mapOffline ? 'offline' : 'online', st.mapNames ? 'an' : 'aus']), [10, 6]),
      _Cat(Icons.lan_outlined, tr('Verbindung'), 'Pi ${st.piHost}${st.autoConnect ? tr(' · automatisch') : ''}', [7]),
      _Cat(Icons.palette_outlined, tr('Darstellung und Daten'), '${st.lang == 'de' ? 'Deutsch' : 'English'} · ${[tr('System'), tr('Hell'), tr('Dunkel')][st.theme.clamp(0, 2)]}', [8]),
      _Cat(Icons.system_update_outlined, tr('App-Update'),
          '${tr('Version {0}', [appVersion])}${updater.available != null ? ' · ${tr('Version {0} ist verfügbar.', [updater.available!.version])}' : ''}',
          [11]),
    ];
  }

  Widget _catBody(BuildContext context, int i) {
    final all = _sections(context);
    final c = _cats[i];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final k in c.sections) ...[
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: all[k]),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  void _open(BuildContext context, int i, bool wide) {
    if (wide) {
      setState(() => _cat = i);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: Text(_cats[i].title)),
        body: SafeArea(child: ListenableBuilder(listenable: app, builder: (ctx, _) => _catBody(context, i))),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final cats = _cats;
      final list = ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (var i = 0; i < cats.length; i++)
            ListTile(
              selected: wide && _cat == i,
              selectedTileColor: rc.hf.withValues(alpha: 0.12),
              leading: Icon(cats[i].icon),
              title: Text(cats[i].title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(cats[i].summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: rc.muted)),
              trailing: wide ? null : const Icon(Icons.chevron_right),
              onTap: () => _open(context, i, wide),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('LR2021 Node App {0} · Modem-Protokoll v1', [appVersion]), style: mono(context, size: 11.5, color: rc.muted)),
              const SizedBox(height: 2),
              SelectableText('LR2021 Node by Raviolimeister (RAV1805) · GPL-3.0 · github.com/$updateRepo',
                  style: TextStyle(fontSize: 11.5, color: rc.muted)),
            ]),
          ),
        ],
      );
      if (!wide) return list;
      final sel = _cat ?? 0;
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 320, child: list),
        const VerticalDivider(width: 1),
        Expanded(child: _catBody(context, sel)),
      ]);
    });
  }
}

class _Cat {
  final IconData icon;
  final String title, summary;
  final List<int> sections;
  const _Cat(this.icon, this.title, this.summary, this.sections);
}

/// Frequenzkorrektur aus empfangenen Paketen messen und übernehmen.
class _FreqCorrSection extends StatelessWidget {
  const _FreqCorrSection();

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final st = app.settings;
    return Section(
      title: tr('Frequenzkorrektur (Quarz)'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Der LR2021-Quarz weicht etwas ab (beim Core2021-HF ca. +30 kHz). Die App misst die Abweichung an empfangenen Meshtastic-Paketen (direkt gehört, gutes Signal) und gleicht sie aus.'),
            style: TextStyle(fontSize: 12, color: rc.muted)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Automatisch nachführen')),
          subtitle: Text(tr('Übernimmt die Messung, wenn 8 Pakete mehr als 1,5 kHz Abweichung zeigen')),
          value: st.autoFreqCorr,
          onChanged: (v) {
            st.autoFreqCorr = v;
            app.changed(save: true);
          },
        ),
        for (final s in app.slots)
          Builder(builder: (context) {
            final avg = app.freqErrAvg(s, minCount: 1);
            final n = app.freqErr[s.role]!.length;
            final corr = s.role == 'A' ? st.freqCorrA : st.freqCorrB;
            return Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: rc.band(s.role).withValues(alpha: 0.5))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Text(s.band, style: mono(context, size: 14, weight: FontWeight.w700, color: rc.band(s.role))),
                  const Spacer(),
                  Text(tr('Korrektur {0}{1} kHz', [corr >= 0 ? '+' : '', (corr / 1000).toStringAsFixed(1)]), style: mono(context, size: 13, weight: FontWeight.w700)),
                ]),
                const SizedBox(height: 4),
                Text(
                    n == 0
                        ? tr('Noch keine Messung (braucht Meshtastic-Empfang auf diesem Modul).')
                        : tr('Gemessen: {0}{1} kHz Rest-Abweichung aus {2} Paket{3}', [avg! >= 0 ? '+' : '', (avg / 1000).toStringAsFixed(2), n, n == 1 ? '' : 'en']),
                    style: TextStyle(fontSize: 12.5, color: n == 0 ? rc.muted : (avg!.abs() > 1500 ? rc.warn : rc.ok))),
                if (app.corrInfo[s.role] != null)
                  Text(tr('Zuletzt: {0}', [app.corrInfo[s.role]]), style: TextStyle(fontSize: 11.5, color: rc.muted)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: n < 3
                        ? null
                        : () async {
                            final t = await app.applyFreqCorr(s);
                            if (context.mounted) toast(context, t);
                          },
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(tr('Messung übernehmen')),
                  ),
                ),
              ]),
            );
          }),
      ]),
    );
  }
}

/// Karten-Einstellungen.
class _MapSettingsSection extends StatelessWidget {
  const _MapSettingsSection();

  @override
  Widget build(BuildContext context) {
    final st = app.settings;
    void set(VoidCallback f) {
      f();
      app.changed(save: true);
    }

    return Section(
      title: tr('Karte'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<String>(
          value: layerById(st.mapLayer).id,
          decoration: InputDecoration(labelText: tr('Kartenart')),
          items: [for (final l in mapLayers) DropdownMenuItem(value: l.id, child: Text(tr(l.name)))],
          onChanged: (v) => set(() => st.mapLayer = v ?? 'topo'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Offline (nur gespeicherte Kacheln)')),
          value: st.mapOffline,
          onChanged: (v) => set(() => st.mapOffline = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Knotennamen auf der Karte')),
          value: st.mapNames,
          onChanged: (v) => set(() => st.mapNames = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Kompass benutzen')),
          subtitle: Text(Compass.supported
              ? tr('Radar und Peilpfeil drehen mit dem Gerät')
              : tr('Dieses Gerät hat keinen Kompass – Norden ist immer oben')),
          value: st.compass,
          onChanged: Compass.supported ? (v) => set(() => st.compass = v) : null,
        ),
      ]),
    );
  }
}

class _ChannelRow extends StatefulWidget {
  final int index;
  final VoidCallback onChanged;
  const _ChannelRow({super.key, required this.index, required this.onChanged});
  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  late final MtChannel ch = app.settings.channels[widget.index];
  late final _name = TextEditingController(text: ch.name);
  late final _psk = TextEditingController(text: ch.pskB64);

  @override
  void dispose() {
    _name.dispose();
    _psk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final keyLen = ch.key.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 28,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('${widget.index}', style: mono(context, size: 13, color: rc.hf, weight: FontWeight.w700)),
          ),
        ),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _name,
            maxLength: 11,
            decoration: InputDecoration(labelText: tr('Kanal'), counterText: ''),
            onChanged: (v) {
              ch.name = v.trim();
              setState(() {});
              widget.onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextField(
            controller: _psk,
            style: mono(context, size: 13),
            decoration: InputDecoration(
              labelText: tr('Schlüssel (Base64)'),
              helperText: tr('Hash {0} · {1}', [ch.hash, keyLen == 0 ? tr('unverschlüsselt') : 'AES-${keyLen * 8}']),
            ),
            onChanged: (v) {
              ch.pskB64 = v.trim();
              setState(() {});
              widget.onChanged();
            },
          ),
        ),
        if (widget.index > 0)
          IconButton(
            onPressed: () {
              app.settings.channels.removeAt(widget.index);
              widget.onChanged();
            },
            icon: const Icon(Icons.close),
            tooltip: tr('Entfernen'),
          ),
      ]),
    );
  }
}

class _MapCacheSection extends StatefulWidget {
  const _MapCacheSection();
  @override
  State<_MapCacheSection> createState() => _MapCacheSectionState();
}

class _MapCacheSectionState extends State<_MapCacheSection> {
  (int, int)? _usage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await TileStore.instance.usage();
    if (mounted) setState(() => _usage = u);
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final u = _usage;
    return Section(
      title: 'Offline-Karten',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KV(tr('Gespeichert'), u == null ? tr('wird gezählt …') : tr('{0} Kacheln · {1} MB', [u.$1, (u.$2 / 1048576).toStringAsFixed(1)])),
        const SizedBox(height: 6),
        Text(tr('Jede angesehene Kachel bleibt gespeichert. Ganze Gebiete: Karte → Download-Knopf. Danach „Offline“ einschalten, dann wird kein Internet mehr benutzt.'),
            style: TextStyle(color: rc.muted, fontSize: 12)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              await TileStore.instance.clear();
              await _load();
            },
            icon: Icon(Icons.delete_outline, color: rc.crit),
            label: Text(tr('Kartenspeicher leeren'), style: TextStyle(color: rc.crit)),
          ),
        ),
      ]),
    );
  }
}

/// Sendeleistung, Lizenz, Antennen, Frequenzkorrektur.
class _PowerSection extends StatefulWidget {
  const _PowerSection();
  @override
  State<_PowerSection> createState() => _PowerSectionState();
}

class _PowerSectionState extends State<_PowerSection> {
  final st = app.settings;
  late final _gainA = TextEditingController(text: st.antGainHf.toStringAsFixed(2));
  late final _gainB = TextEditingController(text: st.antGainLf.toStringAsFixed(2));
  late final _corrA = TextEditingController(text: (st.freqCorrA / 1000).toStringAsFixed(1));
  late final _corrB = TextEditingController(text: (st.freqCorrB / 1000).toStringAsFixed(1));
  late final _ovrA = TextEditingController(text: st.overrideFreqA == 0 ? '' : (st.overrideFreqA / 1e6).toStringAsFixed(4));
  late final _ovrB = TextEditingController(text: st.overrideFreqB == 0 ? '' : (st.overrideFreqB / 1e6).toStringAsFixed(4));

  @override
  void dispose() {
    for (final c in [_gainA, _gainB, _corrA, _corrB, _ovrA, _ovrB]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _num(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
  void _save() => app.changed(save: true);

  Widget _module(BuildContext context, ModemSlot s) {
    final rc = context.rc;
    final col = rc.band(s.role);
    final lim = app.limitFor(s);
    final cfg = app.cfgFor(s, app.modeOf(s));
    final ham = app.hamMode(s);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: col.withValues(alpha: 0.5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(s.band, style: mono(context, size: 14, weight: FontWeight.w700, color: col)),
          const SizedBox(width: 8),
          Expanded(child: Text(radioModeName(app.modeOf(s)), style: TextStyle(color: rc.muted, fontSize: 12.5))),
          Text(lim.allowed ? '${cfg.powerDbm} dBm' : tr('Senden gesperrt'),
              style: mono(context, size: 14, weight: FontWeight.w700, color: lim.allowed ? null : rc.crit)),
        ]),
        const SizedBox(height: 4),
        Text(tr('{0} MHz · erlaubt max. {1} dBm · {2}', [(cfg.freqHz / 1e6).toStringAsFixed(4), lim.maxDbm, lim.reason]),
            style: TextStyle(color: rc.muted, fontSize: 12)),
        if (ham)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr('Amateurfunk-Betrieb: Meshtastic hier unverschlüsselt, Rufzeichen in der Visitenkarte.'),
                style: TextStyle(color: rc.warn, fontSize: 12)),
          ),
        if (!st.powerAuto && lim.allowed)
          Row(children: [
            Text(tr('Leistung'), style: TextStyle(color: rc.muted)),
            Expanded(
              child: Slider(
                value: app.manualPower(s).clamp(-9, lim.maxDbm).toDouble(),
                min: -9,
                max: lim.maxDbm.toDouble() <= -9 ? -8 : lim.maxDbm.toDouble(),
                divisions: (lim.maxDbm + 9).clamp(1, 40).toInt(),
                label: '${app.manualPower(s)} dBm',
                onChanged: (v) => setState(() => app.setManualPower(s, v.round())),
              ),
            ),
            SizedBox(width: 60, child: Text('${app.manualPower(s).clamp(-9, lim.maxDbm)} dBm', style: mono(context, size: 12))),
          ]),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(
            width: 150,
            child: TextField(
              controller: s.role == 'A' ? _gainA : _gainB,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('Antennengewinn'), suffixText: 'dBi'),
              onChanged: (v) {
                final x = _num(v);
                if (x == null) return;
                setState(() {
                  if (s.role == 'A') {
                    st.antGainHf = x;
                  } else {
                    st.antGainLf = x;
                  }
                });
                _save();
              },
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              controller: s.role == 'A' ? _corrA : _corrB,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(labelText: tr('Frequenzkorrektur'), suffixText: 'kHz'),
              onChanged: (v) {
                final x = _num(v);
                if (x == null) return;
                setState(() {
                  if (s.role == 'A') {
                    st.freqCorrA = (x * 1000).round();
                  } else {
                    st.freqCorrB = (x * 1000).round();
                  }
                });
                _save();
              },
            ),
          ),
          SizedBox(
            width: 190,
            child: TextField(
              controller: s.role == 'A' ? _ovrA : _ovrB,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('Meshtastic-Frequenz fest'), suffixText: 'MHz', hintText: 'automatisch'),
              onChanged: (v) {
                final x = _num(v);
                final hz = x == null ? 0 : (x * 1e6).round();
                setState(() {
                  if (s.role == 'A') {
                    st.overrideFreqA = hz;
                  } else {
                    st.overrideFreqB = hz;
                  }
                });
                _save();
              },
            ),
          ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Section(
      title: tr('Sendeleistung und Lizenz'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Höchste erlaubte Leistung (automatisch)')),
          subtitle: Text(tr('Rechnet das gesetzliche Maximum für Frequenz und Antenne aus. Aus = Leistung von Hand.')),
          value: st.powerAuto,
          onChanged: (v) => setState(() {
            st.powerAuto = v;
            _save();
          }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Amateurfunk-Lizenz vorhanden')),
          subtitle: Text(
              tr('Gibt in Amateurfunkbändern (70 cm, 13 cm) die volle Chip-Leistung frei. Dort ist Verschlüsselung verboten: Meshtastic läuft auf diesen Bändern dann unverschlüsselt mit Rufzeichen. 868 MHz bleibt verschlüsselt (dort gilt die Lizenz nicht, LongFast hat ohnehin schon volle Leistung).'),
              style: TextStyle(fontSize: 12, color: rc.muted)),
          value: st.licensed,
          onChanged: (v) {
            if (v && st.callsign.trim().isEmpty) {
              toast(context, tr('Bitte zuerst oben dein Rufzeichen eintragen'), error: true);
              return;
            }
            setState(() {
              st.licensed = v;
              _save();
            });
          },
        ),
        for (final s in app.slots) _module(context, s),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () async {
              var n = 0;
              for (final s in app.slots) {
                if (s.connected) {
                  await app.applyMode(s);
                  n++;
                }
              }
              if (context.mounted) toast(context, n == 0 ? tr('Gespeichert – gilt beim nächsten Verbinden') : tr('Auf {0} Modul(e) angewendet', [n]));
            },
            icon: const Icon(Icons.check),
            label: Text(tr('Auf Funkmodule anwenden')),
          ),
        ),
        const SizedBox(height: 6),
        Text(tr('Frequenzkorrektur: gleicht die Quarz-Abweichung aus (Monitor zeigt „Δf“ bei jedem Paket, Messen und Übernehmen weiter unten). Die ERP-Grenze gilt inkl. Antennengewinn; bei 2,15 dBi (Dipol) entspricht sie der Leistung am Chip.'),
            style: TextStyle(color: rc.muted, fontSize: 12)),
      ]),
    );
  }
}

/// Nach neuen App-Versionen suchen und installieren.
class _UpdateSection extends StatelessWidget {
  const _UpdateSection();

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final st = app.settings;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final u = updater.available;
        return Section(
          title: tr('App-Update'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KV(tr('Installiert'), appVersion),
            if (u != null) KV(tr('Verfügbar'), u.version, color: rc.ok),
            if (updater.status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(updater.status, style: TextStyle(fontSize: 12.5, color: rc.muted)),
              ),
            if (updater.progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(value: updater.progress, color: rc.hf, backgroundColor: rc.panelHi),
              ),
            if (Platform.isIOS)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    tr('iPhone/iPad: Mit AltStore oder SideStore und der LR2021-Quelle kommen Updates automatisch. '
                        'Sonst öffnet „Installieren“ die Download-Seite.'),
                    style: TextStyle(fontSize: 12.5, color: rc.muted)),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Beim Start nach Updates suchen')),
              value: st.autoUpdate,
              onChanged: Updater.supported
                  ? (v) {
                      st.autoUpdate = v;
                      app.changed(save: true);
                    }
                  : null,
            ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: updater.busy || !Updater.supported ? null : () => updater.check(),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(tr('Jetzt suchen')),
              ),
              if (u != null)
                FilledButton.icon(
                  onPressed: updater.busy
                      ? null
                      : () async {
                          final err = await updater.install();
                          if (err != null && context.mounted) toast(context, err, error: true);
                        },
                  icon: const Icon(Icons.system_update, size: 18),
                  label: Text(tr('Version {0} installieren', [u.version])),
                ),
            ]),
            const SizedBox(height: 8),
            Text(tr('Updates kommen aus den Releases auf GitHub ({0}).', [updateRepo]), style: TextStyle(fontSize: 12, color: rc.muted)),
          ]),
        );
      },
    );
  }
}
