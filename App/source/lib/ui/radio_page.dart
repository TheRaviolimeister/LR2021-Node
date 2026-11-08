import 'dart:math';

import 'package:flutter/material.dart';

import '../core/modem.dart';
import '../core/transport.dart';
import '../mesh/meshtastic.dart';
import '../state/app.dart';
import '../state/app_state.dart';
import '../state/models.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

class RadioPage extends StatelessWidget {
  const RadioPage({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 1000;
      if (wide) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _SlotPanel(app.a)),
            const SizedBox(width: 16),
            Expanded(child: _SlotPanel(app.b)),
          ]),
        );
      }
      return ListView(padding: const EdgeInsets.all(16), children: [
        _SlotPanel(app.a),
        const SizedBox(height: 24),
        _SlotPanel(app.b),
      ]);
    });
  }
}

class _SlotPanel extends StatelessWidget {
  final ModemSlot s;
  const _SlotPanel(this.s);

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final col = rc.band(s.role);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(width: 4, height: 34, color: col),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.band, style: mono(context, size: 20, weight: FontWeight.w700, color: col)),
            Text('${s.espName} · ${s.role == 'A' ? 'Core2021-HF' : 'Core2021-LF'} · ${s.status}',
                style: TextStyle(color: rc.muted, fontSize: 12.5)),
          ]),
        ),
        if (s.connected)
          OutlinedButton(onPressed: () => app.disconnect(s), child: Text(tr('Trennen')))
        else
          FilledButton(
            onPressed: s.connecting ? null : () => app.connect(s),
            style: FilledButton.styleFrom(backgroundColor: col, foregroundColor: const Color(0xFF11161C)),
            child: Text(s.connecting ? tr('Verbinde …') : tr('Verbinden')),
          ),
      ]),
      const SizedBox(height: 12),
      if (!s.connected) _ConnectBox(s),
      if (s.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: rc.crit.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: rc.crit.withValues(alpha: 0.4)),
            ),
            child: Text(s.error!, style: TextStyle(color: rc.crit)),
          ),
        ),
      if (s.connected) ...[
        const SizedBox(height: 4),
        _LiveBox(s),
        const SizedBox(height: 12),
        _ModeBox(s),
        const SizedBox(height: 12),
        _InfoBox(s),
        const SizedBox(height: 12),
        _ActionsBox(s),
      ],
    ]);
  }
}

class _ConnectBox extends StatelessWidget {
  final ModemSlot s;
  const _ConnectBox(this.s);

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Section(
      title: tr('Verbindung'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<TransportKind>(
          segments: [
            for (final k in availableTransportKinds) ButtonSegment(value: k, label: Text(transportKindName(k))),
          ],
          selected: {s.kind},
          showSelectedIcon: false,
          onSelectionChanged: (v) {
            s.kind = v.first;
            if (s.kind == TransportKind.usb || s.kind == TransportKind.node) app.refreshPorts(s);
            app.changed();
          },
        ),
        const SizedBox(height: 12),
        if (s.kind == TransportKind.usb || s.kind == TransportKind.node)
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                value: s.port?.id,
                hint: Text(tr('Kein Anschluss gefunden')),
                items: [
                  for (final p in s.ports)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text('${(s.kind == TransportKind.node ? p.cp210x : p.looksLikeEsp) ? '● ' : ''}${p.label}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  s.port = s.ports.where((p) => p.id == v).firstOrNull;
                  app.changed();
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: () => app.refreshPorts(s), icon: const Icon(Icons.refresh), tooltip: tr('Suchen')),
          ]),
        if (s.kind == TransportKind.usb)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('USB-Buchse „COM“ des {0}. Skripte und Arduino vorher schließen – der Anschluss kann nur von einem Programm benutzt werden.', [s.espName]),
              style: TextStyle(color: rc.muted, fontSize: 12.5),
            ),
          ),
        if (s.kind == TransportKind.node)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('Kabel vom PC zum CP2102 der Node (Debug-Konsole). Die App meldet sich an der Node an (Benutzer/Passwort unter Einstellungen → Verbindung) und verbindet ESP32 A und B zusammen, dazu das GPS der Node. Kein Konsolen-Programm (PuTTY, Skript) darf den Anschluss gleichzeitig offen haben.'),
              style: TextStyle(color: rc.muted, fontSize: 12.5),
            ),
          ),
        if (s.kind == TransportKind.network)
          Text(
            tr('Über den Orange Pi: {0}:{1}. Adresse unter Einstellungen. Funktioniert, sobald die Pi-Software läuft.', [app.settings.piHost, s.role == 'A' ? 2021 : 2022]),
            style: TextStyle(color: rc.muted, fontSize: 12.5),
          ),
        if (s.kind == TransportKind.demo)
          Text(tr('Simuliertes Modem mit Beispielverkehr – zum Ausprobieren ohne Hardware.'),
              style: TextStyle(color: rc.muted, fontSize: 12.5)),
      ]),
    );
  }
}

class _LiveBox extends StatelessWidget {
  final ModemSlot s;
  const _LiveBox(this.s);

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final col = rc.band(s.role);
    final rssi = s.liveRssi;
    final frac = rssi == null ? 0.0 : ((rssi + 130) / 90).clamp(0.0, 1.0);
    final cfg = s.config?.lora;
    return Section(
      title: tr('Kanal live'),
      accent: col,
      trailing: Text(s.transmitting ? 'SENDET' : (s.connected ? 'EMPFANG' : ''),
          style: mono(context, size: 11, color: s.transmitting ? rc.crit : rc.ok, weight: FontWeight.w700)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(rssi == null ? '—' : rssi.toStringAsFixed(1), style: mono(context, size: 30, weight: FontWeight.w700)),
          const SizedBox(width: 6),
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(tr('dBm Rauschen'), style: TextStyle(color: rc.muted))),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(tr('letztes Paket'), style: TextStyle(color: rc.muted, fontSize: 11.5)),
            Text(s.lastRx == null ? '–' : tr('{0} dBm · {1}', [s.lastRxRssi?.toStringAsFixed(0), ago(s.lastRx)]),
                style: mono(context, size: 12.5)),
          ]),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(children: [
            Container(height: 8, color: rc.panelHi),
            FractionallySizedBox(widthFactor: frac, child: Container(height: 8, color: col)),
          ]),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Text('-130', style: mono(context, size: 10, color: rc.muted)),
          const Spacer(),
          Text(tr('-40 dBm'), style: mono(context, size: 10, color: rc.muted)),
        ]),
        if (cfg != null) ...[
          const SizedBox(height: 10),
          Text(cfg.summary, style: mono(context, size: 12.5)),
          Text(
              tr('{0} dBm Sendeleistung · Präambel {1} · 50-Byte-Paket ≈ {2} ms', [cfg.powerDbm, cfg.preamble, cfg.airtimeMs(50).toStringAsFixed(0)]),
              style: TextStyle(color: rc.muted, fontSize: 12)),
        ],
      ]),
    );
  }
}

class _ModeBox extends StatefulWidget {
  final ModemSlot s;
  const _ModeBox(this.s);
  @override
  State<_ModeBox> createState() => _ModeBoxState();
}

class _ModeBoxState extends State<_ModeBox> {
  bool _busy = false;

  Future<void> _apply() async {
    setState(() => _busy = true);
    final err = await app.applyMode(widget.s);
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, err == null ? tr('Übernommen') : tr('Fehler: {0}', [err]), error: err != null);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final rc = context.rc;
    final mode = app.modeOf(s);
    final st = app.settings;
    return Section(
      title: tr('Betriebsart'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<RadioMode>(
          value: mode,
          items: [for (final m in app.modesFor(s)) DropdownMenuItem(value: m, child: Text(radioModeName(m)))],
          onChanged: (m) {
            if (m != null) app.setMode(s, m);
          },
        ),
        const SizedBox(height: 12),
        if (mode == RadioMode.meshtastic) ...[
          DropdownButtonFormField<int>(
            value: st.mtPreset,
            decoration: InputDecoration(labelText: tr('Voreinstellung ({0})', [s.role == 'A' ? 'EU_868' : 'EU_433'])),
            items: [
              for (var i = 0; i < mtPresets.length; i++)
                DropdownMenuItem(value: i, child: Text(tr('{0}  ·  SF{1}', [mtPresets[i].name, mtPresets[i].sf]))),
            ],
            onChanged: (v) {
              st.mtPreset = v ?? 0;
              app.changed(save: true);
            },
          ),
          const SizedBox(height: 8),
          Text(tr('{0} · Frequenz wie Meshtastic aus dem Kanalnamen', [app.cfgFor(s, mode).summary]),
              style: TextStyle(color: rc.muted, fontSize: 12)),
          if (app.hamMode(s))
            Text(tr('Amateurfunk-Betrieb: unverschlüsselt, Rufzeichen in der Visitenkarte.'), style: TextStyle(color: rc.warn, fontSize: 12)),
        ],
        if (mode == RadioMode.meshcore)
          Text(tr('869,618 MHz · 62,5 kHz · SF8 · 4/8. Die App liest Ankündigungen (Namen, Positionen) mit; Nachrichten sind verschlüsselt.'),
              style: TextStyle(color: rc.muted, fontSize: 12.5)),
        if (mode == RadioMode.lrfunk && s.role == 'B') ...[
          LoraEditor(key: ObjectKey(st.lrCfg), cfg: st.lrCfg, showPower: false, onChanged: () => app.changed(save: true)),
          const SizedBox(height: 6),
          Text(tr('Klartext mit Rufzeichen. Alle Stationen im eigenen Netz brauchen dieselben Werte.'),
              style: TextStyle(color: rc.muted, fontSize: 12)),
        ],
        if (mode == RadioMode.lrfunk && s.role == 'A')
          Text(tr('LR-Funk-Test auf 869,525 MHz · 125 kHz · SF9.'), style: TextStyle(color: rc.muted, fontSize: 12.5)),
        if (mode == RadioMode.manual)
          LoraEditor(
              key: ObjectKey(s.role == 'A' ? st.manualA : st.manualB),
              cfg: s.role == 'A' ? st.manualA : st.manualB,
              onChanged: () => app.changed(save: true)),
        const SizedBox(height: 10),
        Builder(builder: (context) {
          final lim = app.limitFor(s);
          final p = app.cfgFor(s, mode).powerDbm;
          return Row(children: [
            Icon(lim.allowed ? Icons.bolt : Icons.block, size: 16, color: lim.allowed ? rc.band(s.role) : rc.crit),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  lim.allowed
                      ? tr('Sendeleistung {0} dBm ({1}) · erlaubt max. {2} dBm · {3}', [p, _PowerSlider._mw(p), lim.maxDbm, lim.reason])
                      : tr('Senden gesperrt: {0}', [lim.reason]),
                  style: TextStyle(fontSize: 12, color: lim.allowed ? rc.muted : rc.crit)),
            ),
          ]);
        }),
        Text(tr('Leistung, Lizenz und Antenne: Einstellungen → Sendeleistung und Lizenz'), style: TextStyle(fontSize: 11.5, color: rc.muted)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _busy ? null : _apply,
            icon: const Icon(Icons.check),
            label: Text(_busy ? tr('Stelle ein …') : tr('Übernehmen')),
          ),
        ),
      ]),
    );
  }
}

class _PowerSlider extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  static const int max = 22;
  const _PowerSlider({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final mw = _mw(value);
    return Row(children: [
      Text(tr('Leistung'), style: TextStyle(color: context.rc.muted)),
      Expanded(
        child: Slider(
          value: value.toDouble().clamp(-9, max.toDouble()),
          min: -9,
          max: max.toDouble(),
          divisions: max + 9,
          label: '$value dBm',
          onChanged: (v) => onChanged(v.round()),
        ),
      ),
      SizedBox(
        width: 96,
        child: Text(tr('{0} dBm · {1}', [value, mw]), textAlign: TextAlign.right, style: mono(context, size: 12)),
      ),
    ]);
  }

  static String _mw(int dbm) {
    final mw = pow(10, dbm / 10).toDouble();
    return mw >= 10 ? '${mw.toStringAsFixed(0)} mW' : '${mw.toStringAsFixed(1)} mW';
  }
}

/// Eingabe aller LoRa-Werte.
class LoraEditor extends StatefulWidget {
  final LoraCfg cfg;
  final VoidCallback onChanged;
  final bool showPower;
  const LoraEditor({super.key, required this.cfg, required this.onChanged, this.showPower = true});
  @override
  State<LoraEditor> createState() => _LoraEditorState();
}

class _LoraEditorState extends State<LoraEditor> {
  late final TextEditingController _f;
  late final TextEditingController _sync;
  late final TextEditingController _pre;

  @override
  void initState() {
    super.initState();
    _f = TextEditingController(text: (widget.cfg.freqHz / 1e6).toStringAsFixed(4));
    _sync = TextEditingController(text: widget.cfg.sync.toRadixString(16).toUpperCase().padLeft(2, '0'));
    _pre = TextEditingController(text: '${widget.cfg.preamble}');
  }

  @override
  void dispose() {
    _f.dispose();
    _sync.dispose();
    _pre.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cfg;
    Widget box(Widget w) => SizedBox(width: 150, child: w);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        box(TextField(
          controller: _f,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('Frequenz'), suffixText: 'MHz'),
          onChanged: (v) {
            final mhz = double.tryParse(v.replaceAll(',', '.'));
            if (mhz != null) {
              c.freqHz = (mhz * 1e6).round();
              widget.onChanged();
            }
          },
        )),
        box(DropdownButtonFormField<int>(
          value: LoraCfg.bandwidths.contains(c.bwHz) ? c.bwHz : 125000,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr('Bandbreite')),
          items: [for (final b in LoraCfg.bandwidths) DropdownMenuItem(value: b, child: Text(fmtBw(b)))],
          onChanged: (v) {
            c.bwHz = v ?? 125000;
            widget.onChanged();
          },
        )),
        box(DropdownButtonFormField<int>(
          value: c.sf,
          decoration: InputDecoration(labelText: tr('Spreizfaktor')),
          items: [for (var i = 5; i <= 12; i++) DropdownMenuItem(value: i, child: Text('SF$i'))],
          onChanged: (v) {
            c.sf = v ?? 9;
            widget.onChanged();
          },
        )),
        box(DropdownButtonFormField<int>(
          value: c.cr,
          decoration: InputDecoration(labelText: tr('Fehlerschutz')),
          items: [for (var i = 5; i <= 8; i++) DropdownMenuItem(value: i, child: Text('4/$i'))],
          onChanged: (v) {
            c.cr = v ?? 5;
            widget.onChanged();
          },
        )),
        box(TextField(
          controller: _sync,
          decoration: const InputDecoration(labelText: 'Sync-Wort', prefixText: '0x'),
          onChanged: (v) {
            final x = int.tryParse(v, radix: 16);
            if (x != null && x >= 0 && x <= 255) {
              c.sync = x;
              widget.onChanged();
            }
          },
        )),
        box(TextField(
          controller: _pre,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: tr('Präambel'), suffixText: tr('Sym.')),
          onChanged: (v) {
            final x = int.tryParse(v);
            if (x != null && x >= 6 && x <= 65535) {
              c.preamble = x;
              widget.onChanged();
            }
          },
        )),
      ]),
      const SizedBox(height: 8),
      if (widget.showPower)
      _PowerSlider(
          value: c.powerDbm,
          onChanged: (v) {
            setState(() => c.powerDbm = v);
            widget.onChanged();
          }),
      Text(tr('50-Byte-Paket ≈ {0} ms Sendezeit', [c.airtimeMs(50).toStringAsFixed(0)]),
          style: mono(context, size: 11.5, color: context.rc.muted)),
    ]);
  }
}

class _InfoBox extends StatelessWidget {
  final ModemSlot s;
  const _InfoBox(this.s);

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final i = s.info;
    final st = s.stats;
    final up = i == null ? null : Duration(milliseconds: i.uptimeMs);
    return Section(
      title: tr('Modem'),
      child: Column(children: [
        if (i != null) ...[
          KV(tr('Firmware'), i.firmware),
          KV('Chip-ID', i.chipHex),
          KV(tr('Funkchip'), i.radioOk ? tr('bereit · {0}', [radioStateNames[i.radioState] != null ? tr(radioStateNames[i.radioState]!) : i.radioState]) : tr('Fehler {0}', [i.initCode]),
              color: i.radioOk ? null : rc.crit),
          KV(tr('Temperatur ESP32'), '${i.tempC.toStringAsFixed(1)} °C'),
          KV(tr('Versorgung'), '${(i.vbatMv / 1000).toStringAsFixed(2)} V'),
          KV(tr('Laufzeit'), up == null ? '–' : tr('{0} h {1} min', [up.inHours, up.inMinutes % 60])),
          KV(tr('Frequenzbereich'), tr('{0}–{1} MHz', [(i.subMinHz / 1e6).toStringAsFixed(0), (i.subMaxHz / 1e6).toStringAsFixed(0)])),
        ],
        if (st != null) ...[
          const Divider(height: 20),
          Row(children: [
            _Stat('empfangen', '${st.rxOk}', rc.ok),
            _Stat(tr('CRC-Fehler'), '${st.rxCrc}', st.rxCrc > 0 ? rc.warn : null),
            _Stat('gesendet', '${st.txOk}', null),
            _Stat('fehlgeschl.', '${st.txFail + st.txRejected}', st.txFail + st.txRejected > 0 ? rc.crit : null),
          ]),
          const SizedBox(height: 8),
          KV(tr('Sendezeit letzte Stunde'), tr('{0} s · {1} %', [(st.airtimeHourMs / 1000).toStringAsFixed(1), (st.airtimeHourMs / 36000).toStringAsFixed(2)])),
          KV(tr('Sendezeit gesamt'), '${(st.airtimeTotalMs / 1000).toStringAsFixed(1)} s'),
          KV(tr('Kanal belegt (LBT)'), '${st.cadBusy}'),
          KV(tr('Übertragungsfehler ESP↔App'), '${st.badFrames} / ${s.client?.badFrames ?? 0}'),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _Stat(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value, style: mono(context, size: 20, weight: FontWeight.w700, color: color)),
          Text(label, style: TextStyle(fontSize: 11, color: context.rc.muted)),
        ]),
      );
}

class _ActionsBox extends StatelessWidget {
  final ModemSlot s;
  const _ActionsBox(this.s);

  Future<void> _do(BuildContext context, String what, Future<void> Function(ModemClient c) f) async {
    final err = await app.run(s, what, f);
    if (context.mounted) toast(context, err == null ? what : '$what: $err', error: err != null);
  }

  Future<bool> _confirm(BuildContext context, String title, String text) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ja')),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final lim = s.config?.limits;
    return Section(
      title: tr('Werkzeuge'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => _do(context, tr('Empfang gestartet'), (c) => c.rxStart()),
              icon: const Icon(Icons.hearing, size: 18),
              label: Text(tr('Empfang'))),
          OutlinedButton.icon(
              onPressed: () => _do(context, tr('Standby'), (c) => c.standby()),
              icon: const Icon(Icons.pause_circle_outline, size: 18),
              label: Text(tr('Standby'))),
          OutlinedButton.icon(
              onPressed: () async {
                final c = s.client;
                if (c == null) return;
                try {
                  final busy = await c.cad();
                  await c.rxStart();
                  if (context.mounted) toast(context, busy ? tr('Kanal belegt') : tr('Kanal frei'));
                } catch (e) {
                  if (context.mounted) toast(context, tr('Kanalprüfung: {0}', [e]), error: true);
                }
              },
              icon: const Icon(Icons.radar, size: 18),
              label: Text(tr('Kanal prüfen'))),
          OutlinedButton.icon(
              onPressed: () => _do(context, tr('Als Startwert gespeichert'), (c) => c.save()),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(tr('Als Startwert'))),
          OutlinedButton.icon(
              onPressed: () => _do(context, tr('Statistik zurückgesetzt'), (c) async {
                    await c.resetStats();
                    await app.refreshStats(s);
                  }),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(tr('Statistik 0'))),
          OutlinedButton.icon(
              onPressed: () => _do(context, tr('Funkchip neu gestartet'), (c) async {
                    await c.resetRadio();
                    await app.applyMode(s);
                  }),
              icon: const Icon(Icons.memory, size: 18),
              label: Text(tr('Funkchip neu'))),
          OutlinedButton.icon(
              onPressed: () async {
                if (await _confirm(context, tr('ESP32 neu starten?'), tr('Die Verbindung bricht kurz ab und wird danach wieder eingestellt.'))) {
                  await _do(context, tr('Neustart ausgelöst'), (c) => c.reboot());
                }
              },
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: Text(tr('ESP neu'))),
        ]),
        if (lim != null) ...[
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Senden auf 2,4 GHz erlauben')),
            subtitle: Text(lim.allow24 ? 'freigegeben' : tr('gesperrt, bis die 2,4-GHz-Antennen dran sind')),
            value: lim.allow24,
            onChanged: (v) async {
              if (v && !await _confirm(context, tr('2,4 GHz freigeben?'), tr('Nur mit angeschlossener 2,4-GHz-Antenne! Ohne Antenne kann die Endstufe Schaden nehmen.'))) {
                return;
              }
              if (!context.mounted) return;
              await _do(context, v ? tr('2,4 GHz freigegeben') : tr('2,4 GHz gesperrt'), (c) async {
                lim.allowMask = v ? (lim.allowMask | 2) : (lim.allowMask & ~2);
                await c.setLimits(lim);
              });
            },
          ),
        ],
      ]),
    );
  }
}
