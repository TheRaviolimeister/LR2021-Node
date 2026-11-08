import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bytes.dart';
import '../state/app.dart';
import '../state/models.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});
  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  final Set<LogKind> _kinds = LogKind.values.toSet();
  final Set<String> _slots = {'A', 'B', tr('App')};
  final _tx = TextEditingController();
  String _txSlot = 'A';
  bool _txHex = false;

  @override
  void dispose() {
    _tx.dispose();
    super.dispose();
  }

  static const _kindLabel = {
    LogKind.rx: 'RX',
    LogKind.tx: 'TX',
    LogKind.log: 'Modem',
    LogKind.warn: 'Warnung',
    LogKind.err: 'Fehler',
    LogKind.info: 'Info',
  };

  Color _kindColor(BuildContext c, LogKind k) => switch (k) {
        LogKind.rx => c.rc.ok,
        LogKind.tx => c.rc.hf,
        LogKind.log => c.rc.muted,
        LogKind.warn => c.rc.warn,
        LogKind.err => c.rc.crit,
        LogKind.info => c.rc.lf,
      };

  void _sendRaw() {
    final s = app.slot(_txSlot);
    Uint8List data;
    try {
      data = _txHex ? unhex(_tx.text) : Uint8List.fromList(utf8.encode(_tx.text));
    } catch (_) {
      toast(context, tr('Hex-Eingabe ungültig'), error: true);
      return;
    }
    if (data.isEmpty || data.length > 255) {
      toast(context, tr('1 bis 255 Byte erlaubt'), error: true);
      return;
    }
    app.rawTx(s, data).then((err) {
      if (err != null && mounted) toast(context, err, error: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final list = app.log.where((e) => _kinds.contains(e.kind) && _slots.contains(e.slot)).toList().reversed.toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final k in LogKind.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(tr(_kindLabel[k]!)),
                      avatar: Dot(_kindColor(context, k)),
                      showCheckmark: false,
                      selected: _kinds.contains(k),
                      onSelected: (v) => setState(() => v ? _kinds.add(k) : _kinds.remove(k)),
                    ),
                  ),
                const SizedBox(width: 8),
                for (final sl in ['A', 'B', tr('App')])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(sl == 'A' ? 'HF' : (sl == 'B' ? 'LF' : tr('App'))),
                      showCheckmark: false,
                      selected: _slots.contains(sl),
                      onSelected: (v) => setState(() => v ? _slots.add(sl) : _slots.remove(sl)),
                    ),
                  ),
              ]),
            ),
          ),
          IconButton(
            tooltip: app.monitorPaused ? tr('Fortsetzen') : tr('Anhalten'),
            onPressed: () {
              app.monitorPaused = !app.monitorPaused;
              app.changed();
            },
            icon: Icon(app.monitorPaused ? Icons.play_arrow : Icons.pause),
          ),
          IconButton(tooltip: tr('Leeren'), onPressed: app.clearLog, icon: const Icon(Icons.delete_sweep_outlined)),
          IconButton(
            tooltip: tr('Alles kopieren'),
            onPressed: () {
              final t = app.log.map((e) => '${hhmmss(e.at)} [${e.slot}] ${_kindLabel[e.kind]} ${e.title} ${e.detail}').join('\n');
              Clipboard.setData(ClipboardData(text: t));
              toast(context, tr('{0} Zeilen kopiert', [app.log.length]));
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ]),
      ),
      if (app.debugLogPath != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            Icon(Icons.description_outlined, size: 14, color: rc.muted),
            const SizedBox(width: 6),
            Expanded(
              child: SelectableText('Debug-Log: ${app.debugLogPath}${app.csvPath != null ? tr('\nEmpfangsprotokoll (CSV, für Reichweitentests): {0}', [app.csvPath]) : ''}',
                  style: mono(context, size: 11, color: rc.muted)),
            ),
          ]),
        ),
      const Divider(),
      Expanded(
        child: list.isEmpty
            ? EmptyState(
                icon: Icons.terminal,
                title: tr('Noch nichts empfangen'),
                text: tr('Hier erscheint jedes Paket roh und entschlüsselt, dazu alle Meldungen der Modems.'),
              )
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final e = list[i];
                  final col = _kindColor(context, e.kind);
                  return InkWell(
                    onLongPress: () {
                      Clipboard.setData(ClipboardData(text: '${e.title}\n${e.detail}'));
                      toast(context, tr('Kopiert'));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: col, width: 3), bottom: BorderSide(color: rc.line.withValues(alpha: 0.4))),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(hhmmss(e.at), style: mono(context, size: 11.5, color: rc.muted)),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 28,
                            child: Text(e.slot == 'A' ? 'HF' : (e.slot == 'B' ? 'LF' : '··'),
                                style: mono(context, size: 11.5, color: e.slot == 'A' ? rc.hf : (e.slot == 'B' ? rc.lf : rc.muted))),
                          ),
                          SizedBox(
                            width: 62,
                            child: Text(tr(_kindLabel[e.kind]!), style: mono(context, size: 11.5, color: col, weight: FontWeight.w700)),
                          ),
                          Expanded(child: Text(e.title, style: const TextStyle(fontSize: 13))),
                        ]),
                        if (e.detail.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 106, top: 2),
                            child: Text(e.detail,
                                maxLines: 3, overflow: TextOverflow.ellipsis, style: mono(context, size: 11, color: rc.muted)),
                          ),
                      ]),
                    ),
                  );
                },
              ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: rc.line))),
        child: Row(children: [
          DropdownButton<String>(
            value: _txSlot,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'A', child: Text('HF')),
              DropdownMenuItem(value: 'B', child: Text('LF')),
            ],
            onChanged: (v) => setState(() => _txSlot = v ?? 'A'),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: Text(tr('Hex')),
            selected: _txHex,
            showCheckmark: false,
            onSelected: (v) => setState(() => _txHex = v),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _tx,
              style: mono(context, size: 13),
              onSubmitted: (_) => _sendRaw(),
              decoration: InputDecoration(hintText: _txHex ? tr('Rohpaket als Hex, z. B. 48 61 6C 6C 6F') : tr('Rohpaket als Text senden')),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(onPressed: _sendRaw, icon: const Icon(Icons.send), tooltip: tr('Roh senden')),
        ]),
      ),
    ]);
  }
}
