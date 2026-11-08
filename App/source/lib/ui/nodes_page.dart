import 'package:flutter/material.dart';

import '../state/app.dart';
import '../state/models.dart';
import 'chat_page.dart' show netColor;
import 'node_sheet.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

class NodesPage extends StatefulWidget {
  final ValueChanged<String> onOpenChat;
  const NodesPage({super.key, required this.onOpenChat});
  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final Set<Net> _nets = {Net.mt, Net.mc, Net.lr};
  String _q = '';
  int _sort = 0; // 0 zuletzt gehört, 1 Signal, 2 Name, 3 Entfernung, 4 Hops
  bool _favOnly = false;
  bool _showIgnored = false;

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    var list = app.nodes.values
        .where((n) => _nets.contains(n.net) && (!_favOnly || n.favorite) && (_showIgnored || !n.ignored))
        .toList();
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      list = list
          .where((n) => n.display.toLowerCase().contains(q) || n.key.contains(q) || n.shortName.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case 1:
        list.sort((a, b) => (b.snr ?? -99).compareTo(a.snr ?? -99));
        break;
      case 2:
        list.sort((a, b) => a.display.toLowerCase().compareTo(b.display.toLowerCase()));
        break;
      case 3:
        list.sort((a, b) => (app.distanceTo(a)?.$1 ?? 1e9).compareTo(app.distanceTo(b)?.$1 ?? 1e9));
        break;
      case 4:
        list.sort((a, b) => (a.hops ?? 99).compareTo(b.hops ?? 99));
        break;
      default:
        list.sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    }
    // Favoriten immer oben
    final favs = list.where((n) => n.favorite).toList();
    list = [...favs, ...list.where((n) => !n.favorite)];
    final active = app.nodes.values.where((n) => DateTime.now().difference(n.lastHeard).inMinutes < 120).length;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Text('${app.nodes.length}', style: mono(context, size: 22, weight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text(tr('Knoten'), style: TextStyle(color: rc.muted)),
          SizedBox(width: 16),
          Text('$active', style: mono(context, size: 22, weight: FontWeight.w700, color: rc.ok)),
          SizedBox(width: 6),
          Text(tr('in den letzten 2 h'), style: TextStyle(color: rc.muted)),
          Spacer(),
          PopupMenuButton<int>(
            tooltip: tr('Sortieren'),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            icon: Icon(Icons.sort),
            itemBuilder: (_) => [
              PopupMenuItem(value: 0, child: Text(tr('Zuletzt gehört'))),
              PopupMenuItem(value: 1, child: Text(tr('Bestes Signal'))),
              PopupMenuItem(value: 2, child: Text(tr('Name'))),
              PopupMenuItem(value: 3, child: Text(tr('Entfernung'))),
              PopupMenuItem(value: 4, child: Text(tr('Wenigste Hops'))),
            ],
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 220,
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: tr('Suchen')),
            ),
          ),
          for (final n in Net.values)
            FilterChip(
              label: Text(netName(n)),
              selected: _nets.contains(n),
              avatar: Dot(netColor(context, n)),
              showCheckmark: false,
              onSelected: (v) => setState(() => v ? _nets.add(n) : _nets.remove(n)),
            ),
          FilterChip(
            label: Text(tr('Favoriten')),
            avatar: Icon(Icons.star, size: 16, color: rc.warn),
            selected: _favOnly,
            showCheckmark: false,
            onSelected: (v) => setState(() => _favOnly = v),
          ),
          if (app.nodes.values.any((n) => n.ignored))
            FilterChip(
              label: Text(tr('Ignorierte')),
              avatar: const Icon(Icons.block, size: 16),
              selected: _showIgnored,
              showCheckmark: false,
              onSelected: (v) => setState(() => _showIgnored = v),
            ),
        ]),
      ),
      const Divider(),
      Expanded(
        child: list.isEmpty
            ? EmptyState(
                icon: Icons.hub_outlined,
                title: tr('Noch niemand gehört'),
                text: tr('Sobald ein Funkmodul empfängt, tauchen hier alle Knoten mit Signal, Hops und Position auf.'),
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: list.length,
                separatorBuilder: (_, __) => Divider(indent: 72, color: rc.line.withValues(alpha: 0.5)),
                itemBuilder: (context, i) => _NodeTile(list[i], onOpenChat: widget.onOpenChat),
              ),
      ),
    ]);
  }
}

class _NodeTile extends StatelessWidget {
  final Node n;
  final ValueChanged<String> onOpenChat;
  const _NodeTile(this.n, {required this.onOpenChat});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final col = netColor(context, n.net);
    final dist = app.distanceTo(n);
    final sub = <String>[
      n.key,
      if (n.hw.isNotEmpty) n.hw,
      if (n.hops != null) (n.hops == 0 ? 'direkt' : tr('{0} Hop{1}', [n.hops, n.hops == 1 ? '' : 's'])),
      if (dist != null) '${dist.$1.toStringAsFixed(dist.$1 < 10 ? 2 : 1)} km ${_dir(dist.$2)}',
      if (n.battery != null) tr('Akku {0}', [n.battery! > 100 ? tr('Netz') : '${n.battery} %']),
    ];
    return ListTile(
      onTap: () => showNodeSheet(context, n, onOpenChat: onOpenChat),
      leading: Stack(clipBehavior: Clip.none, children: [
        NodeBadge(n.badge, col, size: 42),
        Positioned(right: -1, bottom: -1, child: Dot(freshColor(context, n.lastHeard), size: 11)),
      ]),
      title: Row(children: [
        if (n.favorite) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.star, size: 15, color: rc.warn)),
        if (n.ignored) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.block, size: 14, color: rc.crit)),
        Flexible(
          child: Text(n.display, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ]),
      subtitle: Text(sub.join('  ·  '), maxLines: 2, overflow: TextOverflow.ellipsis, style: mono(context, size: 11.5, color: rc.muted)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          SignalBars(snr: n.snr),
          const SizedBox(width: 6),
          Text(n.snr != null ? '${n.snr!.toStringAsFixed(1)} dB' : '–', style: mono(context, size: 12)),
        ]),
        const SizedBox(height: 2),
        Text(ago(n.lastHeard), style: TextStyle(fontSize: 11.5, color: rc.muted)),
      ]),
    );
  }

  static String _dir(double deg) {
    const d = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return d[((deg + 22.5) % 360 ~/ 45)];
  }
}
