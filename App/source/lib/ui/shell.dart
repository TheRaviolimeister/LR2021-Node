// ignore_for_file: prefer_const_constructors
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bytes.dart';
import '../core/updater.dart';
import '../state/app.dart';
import 'chat_page.dart';
import 'map_page.dart';
import 'monitor_page.dart';
import 'nodes_page.dart';
import 'radio_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';
import '../i18n.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _Dest {
  final String label;
  final IconData icon, active;
  const _Dest(this.label, this.icon, this.active);
}

const _dests = [
  _Dest('Chat', Icons.forum_outlined, Icons.forum),
  _Dest('Knoten', Icons.hub_outlined, Icons.hub),
  _Dest('Karte', Icons.map_outlined, Icons.map),
  _Dest('Funk', Icons.settings_input_antenna_outlined, Icons.settings_input_antenna),
  _Dest('Monitor', Icons.terminal_outlined, Icons.terminal),
  _Dest('Einstellungen', Icons.tune_outlined, Icons.tune),
];

class _ShellState extends State<Shell> {
  int _index = 0;
  StreamSubscription<String>? _noticeSub;

  @override
  void initState() {
    super.initState();
    app.tabRequest.addListener(_onTabRequest);
    updater.addListener(_onUpdate);
    _noticeSub = app.notices.listen((t) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 4)));
    });
  }

  @override
  void dispose() {
    app.tabRequest.removeListener(_onTabRequest);
    updater.removeListener(_onUpdate);
    _noticeSub?.cancel();
    super.dispose();
  }

  String _offered = '';

  void _onUpdate() {
    final u = updater.available;
    if (u == null || u.version == _offered || u.version == app.settings.skipVersion || !mounted) return;
    _offered = u.version;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Update verfügbar')),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Version {0} ist verfügbar (installiert: {1}).', [u.version, appVersion])),
            if (u.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(u.notes.trim(), style: const TextStyle(fontSize: 12.5)),
            ],
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              app.settings.skipVersion = u.version;
              app.changed(save: true);
              Navigator.pop(ctx);
            },
            child: Text(tr('Diese überspringen')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Später'))),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final err = await updater.install();
              if (err != null && mounted) toast(context, err, error: true);
            },
            child: Text(tr('Jetzt installieren')),
          ),
        ],
      ),
    );
  }

  void _onTabRequest() {
    final t = app.tabRequest.value;
    if (t == null) return;
    app.tabRequest.value = null;
    go(t);
  }

  void _openChat(String chat) {
    app.openChat = chat;
    go(0);
  }

  void go(int i) {
    setState(() => _index = i);
    app.rssiPolling = i == 3;
    if (i != 0) app.openChat = null;
  }

  // bewusst ohne const: die Seiten sollen bei jeder Änderung neu zeichnen
  Widget _page() => switch (_index) {
        0 => ChatPage(),
        1 => NodesPage(onOpenChat: _openChat),
        2 => MapPage(onOpenChat: _openChat),
        3 => RadioPage(),
        4 => MonitorPage(),
        _ => SettingsPage(),
      };

  Widget _icon(int i, bool active) {
    final d = _dests[i];
    final icon = Icon(active ? d.active : d.icon);
    if (i == 0 && app.unreadTotal > 0) {
      return Badge(label: Text('${app.unreadTotal}'), child: icon);
    }
    return icon;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final size = MediaQuery.sizeOf(context);
        // Querformat (auch am Handy): Leiste links statt unten, damit die Höhe für den Inhalt bleibt
        final landscape = size.width > size.height && size.width >= 560;
        final wide = size.width >= 860 || landscape;
        final short = size.height < 520; // Handy quer: alles platzsparend
        final body = Column(children: [
          _TopBar(onModemTap: () => go(3), compact: !wide || short, dense: short),
          const Divider(height: 1),
          Expanded(child: _page()),
        ]);
        if (wide) {
          final rail = NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: go,
            minWidth: short ? 56 : 72,
            labelType: short ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            leading: short
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 16),
                    child: _Logo(),
                  ),
            destinations: [
              for (var i = 0; i < _dests.length; i++)
                NavigationRailDestination(
                  icon: Tooltip(message: tr(_dests[i].label), child: _icon(i, false)),
                  selectedIcon: _icon(i, true),
                  label: Text(tr(_dests[i].label)),
                ),
            ],
          );
          return Scaffold(
            body: SafeArea(
              child: Row(children: [
                // scrollbar, falls die Höhe nicht für alle Einträge reicht
                LayoutBuilder(
                  builder: (context, c) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight),
                      child: IntrinsicHeight(child: rail),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ]),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(bottom: false, child: body),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: go,
            labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
            destinations: [
              for (var i = 0; i < _dests.length; i++)
                NavigationDestination(
                  icon: _icon(i, false),
                  selectedIcon: _icon(i, true),
                  label: tr(_dests[i].label),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset('assets/icon.png', width: 44, height: 44, filterQuality: FilterQuality.medium),
      );
}

class _TopBar extends StatelessWidget {
  final VoidCallback onModemTap;
  final bool compact;
  final bool dense;
  const _TopBar({required this.onModemTap, required this.compact, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final id = app.settings.myNum == 0 ? tr('ID folgt') : nodeIdStr(app.settings.myNum);
    if (dense) {
      // eine schmale Zeile (Handy quer)
      return SizedBox(
        height: 44,
        child: Row(children: [
          const SizedBox(width: 12),
          Flexible(
            child: Text(app.settings.longName,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(id, style: mono(context, size: 11, color: rc.muted)),
          const Spacer(),
          ModemChip(app.a, onTap: onModemTap),
          const SizedBox(width: 6),
          ModemChip(app.b, onTap: onModemTap),
          const SizedBox(width: 10),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (compact) ...[_Logo(), const SizedBox(width: 10)],
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(app.settings.longName,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
              Text(
                  '$id${app.settings.callsign.isNotEmpty ? '  ·  ${app.settings.callsign.toUpperCase()}' : ''}',
                  style: mono(context, size: 11.5, color: rc.muted)),
            ]),
          ]),
          Wrap(spacing: 8, runSpacing: 6, children: [
            ModemChip(app.a, onTap: onModemTap),
            ModemChip(app.b, onTap: onModemTap),
          ]),
        ],
      ),
    );
  }
}
