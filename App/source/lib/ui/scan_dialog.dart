import 'package:flutter/material.dart';

import '../core/node_box.dart';
import '../core/regulatory.dart';
import '../state/app.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

/// Frequenzsuche: die Node misst über eine wählbare Zeit, wie oft welche Frequenz belegt ist, und schlägt die
/// ruhigsten vor. Eine davon (oder eine eigene) wird die LR-Funk-Frequenz.
Future<void> showScanDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ScanDialog());

class _Range {
  final String label;
  final double from, to;
  final bool licensed;
  const _Range(this.label, this.from, this.to, this.licensed);
}

class _ScanDialog extends StatefulWidget {
  const _ScanDialog();
  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  late final List<_Range> ranges = [
    _Range(tr('70 cm Amateurfunk 430–440 MHz (mit Lizenz)'), 430.0, 440.0, true),
    _Range(tr('lizenzfrei 433,05–434,79 MHz'), 433.05, 434.79, false),
  ];
  late int range = app.settings.licensed ? 0 : 1;
  double minutes = 5;
  final _own = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final r = ranges[range];
    final e = await app.startScan(r.from, r.to, minutes);
    if (mounted) setState(() => _err = e);
  }

  Future<void> _apply(double mhz) async {
    final lim = powerLimit((mhz * 1e6).round(), bwHz: app.settings.lrCfg.bwHz, licensed: app.settings.licensed);
    await app.setLrFrequency(mhz);
    if (!mounted) return;
    toast(context,
        lim.allowed
            ? tr('LR-Funk jetzt auf {0} MHz – alle Stationen im Netz brauchen dieselbe Frequenz.', [mhz.toStringAsFixed(4)])
            : tr('{0} MHz eingestellt, Senden dort aber nicht erlaubt: {1}', [mhz.toStringAsFixed(4), lim.reason]),
        error: !lim.allowed);
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final job = app.scanJob;
        final running = app.scanRunning;
        final res = app.scanResult;
        final cur = app.settings.lrCfg.freqHz / 1e6;
        return AlertDialog(
          title: Text(tr('Ruhigste Frequenz suchen')),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Text(
                  tr('Die Node hört mit ESP32 B nacheinander alle Kanäle ab und zählt, wie oft dort jemand sendet. Währenddessen empfängt B nichts. Je länger die Suche, desto verlässlicher – am besten zu der Tageszeit, zu der du funken willst.'),
                  style: TextStyle(color: rc.muted, fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                Text(tr('Aktuelle LR-Funk-Frequenz: {0} MHz', [cur.toStringAsFixed(4)])),
                const SizedBox(height: 10),
                if (!app.canScan)
                  Text(tr('Die Frequenzsuche braucht eine Verbindung über die Node (lr2021d 1.2 oder neuer).'),
                      style: TextStyle(color: rc.warn))
                else if (running && job != null) ...[
                  LinearProgressIndicator(value: (job['progress'] as num? ?? 0).toDouble()),
                  const SizedBox(height: 6),
                  Text('${job['info'] ?? ''}', style: TextStyle(color: rc.muted, fontSize: 12.5)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: app.cancelScan,
                      icon: const Icon(Icons.stop),
                      label: Text(tr('Abbrechen')),
                    ),
                  ),
                ] else ...[
                  DropdownButtonFormField<int>(
                    value: range,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: tr('Bereich')),
                    items: [
                      for (var i = 0; i < ranges.length; i++)
                        DropdownMenuItem(value: i, child: Text(ranges[i].label, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => range = v ?? range),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<double>(
                    value: minutes,
                    decoration: InputDecoration(labelText: tr('Dauer')),
                    items: [
                      for (final m in const [1.0, 5.0, 10.0, 20.0, 30.0, 60.0])
                        DropdownMenuItem(value: m, child: Text(tr('{0} min', [m.toStringAsFixed(0)]))),
                    ],
                    onChanged: (v) => setState(() => minutes = v ?? minutes),
                  ),
                  if (ranges[range].licensed && !app.settings.licensed)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(tr('Ohne Lizenz darfst du nur im lizenzfreien Bereich senden – suchen geht trotzdem.'),
                          style: TextStyle(color: rc.warn, fontSize: 12)),
                    ),
                  const SizedBox(height: 10),
                  FilledButton.icon(onPressed: _start, icon: const Icon(Icons.travel_explore), label: Text(tr('Suche starten'))),
                ],
                if (_err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_err!, style: TextStyle(color: rc.crit))),
                if (res != null && res.quiet.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(
                      tr('Ergebnis vom {0}: {1}–{2} MHz, {3} Durchgänge in {4} min, Rauschen {5} dBm', [
                        '${res.at.day}.${res.at.month}. ${res.at.hour.toString().padLeft(2, '0')}:${res.at.minute.toString().padLeft(2, '0')}',
                        res.fromMhz.toStringAsFixed(2),
                        res.toMhz.toStringAsFixed(2),
                        res.sweeps,
                        res.minutes.toStringAsFixed(0),
                        res.floorDbm?.toStringAsFixed(0) ?? '?',
                      ]),
                      style: TextStyle(color: rc.muted, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(tr('Ruhigste Frequenzen:'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  for (final q in res.quiet)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('{0} MHz · belegt {1} % · stärkstes Signal +{2} dB',
                          [q.mhz.toStringAsFixed(4), (q.busy * 100).toStringAsFixed(1), q.maxDb.toStringAsFixed(0)])),
                      subtitle: Text(bandHint(q.mhz), style: TextStyle(fontSize: 11.5, color: rc.muted)),
                      trailing: TextButton(onPressed: () => _apply(q.mhz), child: Text(tr('Übernehmen'))),
                    ),
                  _Busiest(res),
                ],
                const Divider(height: 24),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _own,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: tr('Eigene Frequenz (MHz)'), hintText: '433.650'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      final v = double.tryParse(_own.text.trim().replaceAll(',', '.'));
                      if (v == null || v < 150 || v > 960) {
                        setState(() => _err = tr('Bitte eine Frequenz in MHz eingeben, z. B. 433.650'));
                        return;
                      }
                      setState(() => _err = null);
                      _apply(v);
                    },
                    child: Text(tr('Übernehmen')),
                  ),
                ]),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Schließen')))],
        );
      },
    );
  }
}

class _Busiest extends StatelessWidget {
  final ScanResult res;
  const _Busiest(this.res);
  @override
  Widget build(BuildContext context) {
    final busy = [...res.channels]..sort((x, y) => y.busy.compareTo(x.busy));
    final top = busy.where((c) => c.busy > 0.01).take(6).toList();
    if (top.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        tr('Belegt: {0}', [top.map((c) => '${c.mhz.toStringAsFixed(3)} (${(c.busy * 100).toStringAsFixed(0)} %)').join(', ')]),
        style: TextStyle(color: context.rc.muted, fontSize: 12),
      ),
    );
  }
}
