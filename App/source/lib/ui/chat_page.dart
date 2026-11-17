import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../geo/coords.dart' show toMgrs;
import '../i18n.dart';
import '../mesh/lr_file.dart';
import '../state/app.dart';
import '../state/app_state.dart';
import '../state/models.dart';
import 'theme.dart';
import 'widgets.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 860;
    final open = app.openChat;
    if (wide) {
      final chat = open ?? 'mt:0';
      app.openChat = chat;
      app.unread.remove(chat);
      return Row(children: [
        SizedBox(width: 320, child: _ChatList(selected: chat, onOpen: (c) => setState(() => app.markRead(c)))),
        const VerticalDivider(width: 1),
        Expanded(child: _Thread(key: ValueKey(chat), chat: chat)),
      ]);
    }
    if (open == null) {
      return _ChatList(selected: null, onOpen: (c) => setState(() => app.markRead(c)));
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => app.openChat = null);
      },
      child: _Thread(
        key: ValueKey(open),
        chat: open,
        onBack: () => setState(() => app.openChat = null),
      ),
    );
  }
}

Color netColor(BuildContext c, Net n) => switch (n) {
      Net.mt => c.rc.hf,
      Net.lr => c.rc.lf,
      Net.mc => c.rc.warn,
    };

class _ChatList extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onOpen;
  const _ChatList({required this.selected, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final chats = app.chats;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: chats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final c = chats[i];
        final last = app.lastMessage(c.id);
        final unread = app.unread[c.id] ?? 0;
        final col = netColor(context, c.net);
        final isDm = c.id.startsWith('dm:');
        return Material(
          color: selected == c.id ? rc.panelHi : Colors.transparent,
          child: ListTile(
            onTap: () => onOpen(c.id),
            leading: NodeBadge(
              isDm ? (app.nodes[c.id.substring(3)]?.badge ?? '?') : (c.net == Net.lr ? '70' : '#'),
              col,
              size: 40,
            ),
            title: Row(children: [
              Expanded(
                child: Text(c.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (last != null) Text(hhmm(last.at), style: mono(context, size: 11, color: rc.muted)),
            ]),
            subtitle: Row(children: [
              Expanded(
                child: Text(
                  last == null ? c.subtitle : '${last.mine ? tr('Ich') : last.fromName}: ${last.text}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: rc.muted, fontSize: 13),
                ),
              ),
              if (unread > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(10)),
                  child: Text('$unread',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).scaffoldBackgroundColor)),
                ),
            ]),
          ),
        );
      },
    );
  }
}

class _Thread extends StatefulWidget {
  final String chat;
  final VoidCallback? onBack;
  const _Thread({super.key, required this.chat, this.onBack});
  @override
  State<_Thread> createState() => _ThreadState();
}

class _ThreadState extends State<_Thread> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Büroklammer: kleines Menü mit Kamera, Galerie, Sprachaufnahme und Datei.
  Future<void> _attach() async {
    final mobile = Platform.isAndroid || Platform.isIOS;
    final lr = widget.chat == 'lr'; // Dateien nur über LR-Funk
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.my_location),
            title: Text(tr('Position senden')),
            subtitle: Text(tr('vom GPS der Node')),
            onTap: () => Navigator.pop(ctx, 'position'),
          ),
          if (mobile && lr)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Foto aufnehmen')),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          if (lr)
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Bild oder Video aus der Galerie')),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
          if (lr)
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: Text(tr('Sprachnachricht aufnehmen')),
              onTap: () => Navigator.pop(ctx, 'audio'),
            ),
          if (lr)
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(tr('Datei auswählen')),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      switch (choice) {
        case 'position':
          await _sharePosition();
        case 'camera':
          final x = await ImagePicker().pickImage(source: ImageSource.camera, requestFullMetadata: false);
          if (x != null) await _sendData(await x.readAsBytes(), _stampName('Foto', 'jpg', x.name));
        case 'gallery':
          if (mobile) {
            final x = await ImagePicker().pickMedia(requestFullMetadata: false);
            if (x != null) await _sendData(await x.readAsBytes(), x.name);
          } else {
            await _pickFile(FileType.media);
          }
        case 'audio':
          final path = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => const _RecordDialog());
          if (path == null) return;
          final f = File(path);
          final data = await f.readAsBytes();
          try {
            await f.delete();
          } catch (_) {}
          await _sendData(data, _stampName('Sprachnachricht', 'm4a', null));
        case 'file':
          await _pickFile(FileType.any);
      }
    } catch (e) {
      if (mounted) toast(context, tr('Dateiauswahl nicht möglich: {0}', [e]), error: true);
    }
  }

  /// Eigene Position teilen, bevorzugt vom GPS-Modul der Node.
  Future<void> _sharePosition() async {
    var fix = app.nodeFix;
    if (fix == null) {
      final src = app.settings.gpsSource;
      if (src != 'node' && src != 'auto') {
        await app.setGpsSource(src == 'geraet' ? 'auto' : 'node');
        if (mounted) toast(context, tr('GPS der Node eingeschaltet (Einstellungen → Position).'));
      }
      if (!mounted) return;
      final r = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => const _WaitFixDialog());
      if (r == 'cancel' || !mounted) return;
      fix = app.nodeFix;
    }
    final st = app.settings;
    double lat, lon;
    double? alt;
    String from;
    if (fix != null) {
      (lat, lon, alt) = (fix.lat, fix.lon, fix.alt);
      from = tr('GPS der Node');
    } else if (st.lat != null && st.lon != null) {
      (lat, lon, alt) = (st.lat!, st.lon!, st.alt?.toDouble());
      from = tr('letzte bekannte Position ({0})', [app.gpsFrom.isEmpty ? tr('von Hand gesetzt') : app.gpsFrom]);
    } else {
      toast(context, tr('Keine Position: das GPS der Node hat noch keinen Fix.'), error: true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Position senden?')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(toMgrs(lat, lon), style: mono(ctx, size: 16)),
          const SizedBox(height: 4),
          Text('${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}${alt == null ? '' : ' · ${alt.round()} m'}', style: mono(ctx, size: 13)),
          const SizedBox(height: 8),
          Text(tr('Quelle: {0}', [from]), style: TextStyle(fontSize: 12, color: fix == null ? ctx.rc.warn : ctx.rc.muted)),
          if (fix == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(tr('Das GPS der Node hat gerade keinen Fix.'), style: TextStyle(fontSize: 12, color: ctx.rc.warn)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Senden'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = app.sharePosition(widget.chat, lat, lon, alt);
    if (err != null && mounted) toast(context, err, error: true);
  }

  /// Dateiname mit Datum und Uhrzeit, z. B. Foto_20261117_143005.jpg.
  static String _stampName(String base, String ext, String? original) {
    if (original != null && original.isNotEmpty && !original.startsWith('image_picker') && !original.startsWith('scaled_')) {
      return original;
    }
    String two(int v) => v.toString().padLeft(2, '0');
    final t = DateTime.now();
    return '${base}_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.$ext';
  }

  Future<void> _pickFile(FileType type) async {
    final res = await FilePicker.platform.pickFiles(type: type, withData: true);
    if (res == null || res.files.isEmpty || !mounted) return;
    final f = res.files.first;
    Uint8List? data = f.bytes;
    if (data == null && f.path != null) data = await File(f.path!).readAsBytes();
    if (data == null) return;
    await _sendData(data, f.name);
  }

  /// Vorschau mit Größe und Sendezeit; Bilder in wählbarer Größe. Dann über LR-Funk senden.
  Future<void> _sendData(Uint8List original, String name) async {
    if (!mounted) return;
    var mime = mimeFor(name);
    const limit = NodeApp.maxFileBytes;
    // Bildgrößen: (Name, Daten, Dateiname, MIME)
    final options = <(String, Uint8List, String, String)>[];
    if (mime.startsWith('image/') && mime != 'image/gif') {
      final dot = name.lastIndexOf('.');
      final jpgName = '${dot > 0 ? name.substring(0, dot) : name}.jpg';
      for (final (label, side, q) in imageSizes) {
        final small = await compute(shrinkImage, (original, side, q));
        if (small == null) continue;
        if (small.length >= original.length && original.length <= limit) {
          options.add((label, original, name, mime));
          break;
        }
        options.add((label, small, jpgName, 'image/jpeg'));
      }
      if (options.isNotEmpty && original.length <= limit && options.last.$2 != original) {
        options.add(('Original', original, name, mime));
      }
    }
    if (options.isEmpty) {
      if (original.length > limit) {
        if (mounted) toast(context, tr('Die Datei ist zu groß (höchstens {0} KB).', [limit ~/ 1024]), error: true);
        return;
      }
      options.add(('', original, name, mime));
    }
    if (!mounted) return;
    var sel = options.length > 1 ? 1 : 0;   // Standard: „Mittel“
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final o = options[sel];
        final kb = (o.$2.length / 1024).toStringAsFixed(1);
        final parts = (o.$2.length / LrFileProto.chunkSize).ceil();
        final t = app.fileAirtimeS(o.$2.length);
        final tooBig = o.$2.length > limit;
        return AlertDialog(
          title: Text(tr('Über LR-Funk senden?')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(o.$3, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (options.length > 1) ...[
              const SizedBox(height: 10),
              Text(tr('Bildgröße'), style: TextStyle(fontSize: 12, color: ctx.rc.muted)),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var i = 0; i < options.length; i++)
                  ChoiceChip(
                    label: Text('${tr(options[i].$1)} · ${(options[i].$2.length / 1024).toStringAsFixed(0)} KB'),
                    selected: sel == i,
                    onSelected: (_) => setD(() => sel = i),
                  ),
              ]),
            ],
            const SizedBox(height: 10),
            Text(tr('{0} KB · {1} Teile{2}', [kb, parts, t == null ? '' : tr(' · Sendezeit ca. {0}', [_dur(t)])])),
            if (tooBig)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Die Datei ist zu groß (höchstens {0} KB).', [limit ~/ 1024]),
                    style: TextStyle(fontSize: 12, color: ctx.rc.crit)),
              )
            else if (t != null && t > 600)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Lange Sendezeit – der Kanal ist so lange belegt.'), style: TextStyle(fontSize: 12, color: ctx.rc.warn)),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
            FilledButton(onPressed: tooBig ? null : () => Navigator.pop(ctx, true), child: Text(tr('Senden'))),
          ],
        );
      }),
    );
    if (ok != true || !mounted) return;
    final o = options[sel];
    final data = o.$2;
    name = o.$3;
    mime = o.$4;
    String? local;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final d = Directory('${dir.path}${Platform.pathSeparator}LR2021${Platform.pathSeparator}sent');
      await d.create(recursive: true);
      final file = File('${d.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$name');
      await file.writeAsBytes(data);
      local = file.path;
    } catch (_) {}
    final err = app.sendFile(data, name, mime, localPath: local);
    if (err != null && mounted) toast(context, err, error: true);
  }

  static String _dur(double s) {
    final n = s.round();
    if (n < 90) return tr('{0} s', [n]);
    return tr('{0} min', [(n / 60).toStringAsFixed(n < 600 ? 1 : 0)]);
  }

  void _send() {
    final err = app.sendText(widget.chat, _ctrl.text);
    if (err != null) {
      toast(context, err, error: true);
      return;
    }
    _ctrl.clear();
    _focus.requestFocus();
  }

  ChatInfo? get _info {
    for (final c in app.chats) {
      if (c.id == widget.chat) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final info = _info;
    final msgs = app.messagesOf(widget.chat).reversed.toList();
    final isLr = widget.chat == 'lr';
    final ready = isLr ? app.lrSlot != null : app.meshtasticSlot != null;
    final col = netColor(context, info?.net ?? Net.mt);
    return Column(children: [
      // Kopf
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
        child: Row(children: [
          if (widget.onBack != null) IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back)),
          if (widget.onBack == null) const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(info?.title ?? widget.chat, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(info?.subtitle ?? '', style: TextStyle(color: rc.muted, fontSize: 12)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: (ready ? col : rc.muted).withValues(alpha: 0.12),
            ),
            child: Text(ready ? tr('sendebereit') : tr('Modul nicht verbunden'),
                style: TextStyle(fontSize: 11.5, color: ready ? col : rc.muted, fontWeight: FontWeight.w600)),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'clear') app.deleteChat(widget.chat);
              if (v == 'nodeinfo') app.sendNodeInfo(wantResponse: true);
              if (v == 'beacon') app.sendBeacon();
            },
            itemBuilder: (_) => [
              if (!isLr) PopupMenuItem(value: 'nodeinfo', child: Text(tr('Visitenkarte senden'))),
              if (isLr) PopupMenuItem(value: 'beacon', child: Text(tr('Bake senden'))),
              PopupMenuItem(value: 'clear', child: Text(tr('Verlauf löschen'))),
            ],
          ),
        ]),
      ),
      const Divider(),
      Expanded(
        child: msgs.isEmpty
            ? EmptyState(
                icon: isLr ? Icons.cell_tower : Icons.forum_outlined,
                title: tr('Noch keine Nachrichten'),
                text: isLr
                    ? tr('Hier landet der Verkehr auf deinem eigenen 70-cm-Kanal. Jede Station bestätigt den Empfang automatisch.')
                    : tr('Empfangene Meshtastic-Nachrichten erscheinen hier. Unten schreiben, Enter sendet an alle auf diesem Kanal.'),
              )
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: msgs.length,
                itemBuilder: (context, i) {
                  final m = msgs[i];
                  final older = i + 1 < msgs.length ? msgs[i + 1] : null;
                  final showName = !m.mine && (older == null || older.from != m.from || older.mine);
                  final dayBreak = older == null || older.at.day != m.at.day;
                  return Column(children: [
                    if (dayBreak) _DayLabel(m.at),
                    _Bubble(m, showName: showName),
                  ]);
                },
              ),
      ),
      SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: Icon(Icons.sos, size: 16, color: context.rc.crit),
                  label: Text(tr('Notruf'), style: TextStyle(color: context.rc.crit, fontWeight: FontWeight.w700)),
                  side: BorderSide(color: context.rc.crit.withValues(alpha: 0.6)),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(tr('Notruf senden?')),
                        content: Text(tr('Sendet „NOTRUF“ mit deinem Namen und deiner Position an alle im Netz.')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: ctx.rc.crit),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(tr('Senden')),
                          ),
                        ],
                      ),
                    );
                    if (ok != true || !context.mounted) return;
                    final err = app.sendSos();
                    toast(context, err ?? tr('Notruf gesendet'), error: err != null);
                  },
                ),
              ),
              for (final q in app.settings.quickMsgs)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    label: Text(q),
                    onPressed: () {
                      final err = app.sendText(widget.chat, q);
                      if (err != null) toast(context, err, error: true);
                    },
                  ),
                ),
            ],
          ),
        ),
      _Composer(ctrl: _ctrl, focus: _focus, onSend: _send, maxBytes: isLr ? 180 : 200, accent: col, onAttach: _attach),
    ]);
  }
}

class _DayLabel extends StatelessWidget {
  final DateTime d;
  const _DayLabel(this.d);
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    final t = diff == 0 ? tr('Heute') : (diff == 1 ? tr('Gestern') : '${d.day}.${d.month}.${d.year}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(t, style: TextStyle(fontSize: 11.5, color: context.rc.muted, letterSpacing: 0.6)),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message m;
  final bool showName;
  const _Bubble(this.m, {required this.showName});

  Color _nameColor(BuildContext c) {
    const palette = [
      Color(0xFF6FB3E0), Color(0xFFD98BC2), Color(0xFF8BC48A), Color(0xFFE0A86F), Color(0xFFA99BE6), Color(0xFF5FC2B5)
    ];
    return palette[m.from.hashCode.abs() % palette.length];
  }

  Widget _status(BuildContext context) {
    final rc = context.rc;
    final (IconData icon, Color col, String tip) = switch (m.status) {
      MsgStatus.pending => (Icons.schedule, rc.muted, tr('wartet auf Senden')),
      MsgStatus.sent => (Icons.check, rc.muted, tr('gesendet')),
      MsgStatus.relayed => (Icons.done_all, rc.muted, tr('weitergeleitet')),
      MsgStatus.acked => (Icons.done_all, rc.ok, tr('bestätigt')),
      MsgStatus.failed => (Icons.error_outline, rc.crit, tr('fehlgeschlagen')),
      MsgStatus.received => (Icons.check, rc.muted, ''),
    };
    return Tooltip(message: m.info.isNotEmpty ? '$tip · ${m.info}' : tip, child: Icon(icon, size: 14, color: col));
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final maxW = MediaQuery.sizeOf(context).width * 0.78;
    final meta = <Widget>[
      Text(hhmm(m.at), style: mono(context, size: 10.5, color: m.mine ? rc.mineText.withValues(alpha: 0.7) : rc.muted)),
    ];
    if (!m.mine && m.snr != null) {
      meta.addAll([
        const SizedBox(width: 8),
        SignalBars(snr: m.snr, size: 11),
        const SizedBox(width: 4),
        Text(tr('{0} dBm · {1} dB{2}', [m.rssi?.toStringAsFixed(0), m.snr?.toStringAsFixed(1), (m.hops ?? 0) > 0 ? tr(' · {0} Hop', [m.hops]) : '']),
            style: mono(context, size: 10.5, color: rc.muted)),
      ]);
    }
    if (m.mine) {
      meta.addAll([const SizedBox(width: 6), _status(context)]);
    }
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW > 560 ? 560 : maxW),
        child: Container(
          margin: EdgeInsets.only(top: showName ? 8 : 3, bottom: 1),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: m.mine ? rc.mine : rc.panel,
            border: m.mine ? null : Border.all(color: rc.line),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(m.mine ? 12 : 3),
              bottomRight: Radius.circular(m.mine ? 3 : 12),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (showName)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(m.fromName,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _nameColor(context))),
              ),
            if (m.fileSize != null)
              _Attachment(m)
            else
              SelectableText(m.text, style: TextStyle(fontSize: 15, height: 1.3, color: m.mine ? rc.mineText : null)),
            const SizedBox(height: 4),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: meta),
            if (m.mine && m.info.isNotEmpty && m.status != MsgStatus.sent)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(m.info,
                    style: TextStyle(
                        fontSize: 11, color: m.status == MsgStatus.failed ? rc.crit : rc.mineText.withValues(alpha: 0.75))),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  final TextEditingController ctrl;
  final FocusNode focus;
  final VoidCallback onSend;
  final int maxBytes;
  final Color accent;
  final VoidCallback? onAttach;
  const _Composer(
      {required this.ctrl, required this.focus, required this.onSend, required this.maxBytes, required this.accent, this.onAttach});
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_upd);
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_upd);
    super.dispose();
  }

  void _upd() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final n = utf8.encode(widget.ctrl.text).length;
    final parts = n == 0 ? 0 : (n / widget.maxBytes).ceil();
    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + MediaQuery.paddingOf(context).bottom * 0),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: rc.line))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (widget.onAttach != null)
          IconButton(
            onPressed: widget.onAttach,
            icon: const Icon(Icons.attach_file),
            tooltip: tr('Foto, Sprachnachricht oder Datei senden'),
          ),
        Expanded(
          child: TextField(
            controller: widget.ctrl,
            focusNode: widget.focus,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => widget.onSend(),
            decoration: InputDecoration(
              hintText: tr('Nachricht'),
              suffixText: n == 0 ? null : (parts > 1 ? tr('{0} B · {1} Teile', [n, parts]) : tr('{0}/{1} B', [n, widget.maxBytes])),
              suffixStyle: mono(context, size: 11, color: parts > 1 ? rc.warn : rc.muted),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: n == 0 ? null : widget.onSend,
          style: IconButton.styleFrom(backgroundColor: widget.accent, foregroundColor: const Color(0xFF11161C)),
          icon: const Icon(Icons.send),
          tooltip: tr('Senden'),
        ),
      ]),
    );
  }
}

/// Bildgrößen für die Funkübertragung: (Name, längste Seite in px, JPEG-Qualität).
const imageSizes = <(String, int, int)>[
  ('Klein', 480, 55),
  ('Mittel', 800, 65),
  ('Groß', 1280, 75),
];

/// Bild für die Funkübertragung verkleinern (längste Seite, JPEG-Qualität). Läuft in einem eigenen Isolate.
Uint8List? shrinkImage((Uint8List, int, int) a) {
  final (data, maxSide, quality) = a;
  try {
    final im = img.decodeImage(data);
    if (im == null) return null;
    final o = img.bakeOrientation(im);   // Handyfotos: Drehung aus den EXIF-Daten übernehmen
    final r = math.max(o.width, o.height) <= maxSide
        ? o
        : (o.width >= o.height ? img.copyResize(o, width: maxSide) : img.copyResize(o, height: maxSide));
    return Uint8List.fromList(img.encodeJpg(r, quality: quality));
  } catch (_) {
    return null;
  }
}

/// Sprachnachricht aufnehmen (AAC, mono, 16 kHz, 24 kbit/s ≈ 3 KB pro Sekunde, höchstens 2 Minuten).
/// Gibt den Pfad der Aufnahme zurück oder null (abgebrochen).
class _RecordDialog extends StatefulWidget {
  const _RecordDialog();
  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  static const maxSeconds = 120;
  final _rec = AudioRecorder();
  Timer? _tick;
  String? _path;
  String? _error;
  int _secs = 0;
  double _level = 0;
  StreamSubscription<Amplitude>? _amp;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = tr('Kein Zugriff auf das Mikrofon. Bitte in den Einstellungen des Geräts erlauben.'));
        return;
      }
      if (!await _rec.isEncoderSupported(AudioEncoder.aacLc)) {
        setState(() => _error = tr('Sprachaufnahme wird auf diesem Gerät nicht unterstützt.'));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}${Platform.pathSeparator}lr2021_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 24000, sampleRate: 16000, numChannels: 1, noiseSuppress: true),
          path: path);
      _path = path;
      _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((a) {
        if (mounted) setState(() => _level = ((a.current + 50) / 50).clamp(0.0, 1.0));
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _secs++);
        if (_secs >= maxSeconds) _finish();
      });
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = tr('Aufnahme nicht möglich: {0}', [e]));
    }
  }

  Future<void> _finish() async {
    _tick?.cancel();
    await _amp?.cancel();
    String? p;
    try {
      p = await _rec.stop();
    } catch (_) {}
    if (mounted) Navigator.pop(context, (p != null && File(p).existsSync()) ? p : _path);
  }

  Future<void> _cancel() async {
    _tick?.cancel();
    await _amp?.cancel();
    try {
      await _rec.cancel();
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _amp?.cancel();
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    String two(int v) => v.toString().padLeft(2, '0');
    final running = _path != null && _error == null;
    return AlertDialog(
      title: Text(tr('Sprachnachricht')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_error != null)
          Text(_error!, style: TextStyle(color: rc.crit))
        else ...[
          Row(children: [
            Icon(Icons.fiber_manual_record, color: running ? rc.crit : rc.muted, size: 16),
            const SizedBox(width: 8),
            Text('${two(_secs ~/ 60)}:${two(_secs % 60)} / ${two(maxSeconds ~/ 60)}:${two(maxSeconds % 60)}',
                style: mono(context, size: 18)),
          ]),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: _level, color: rc.lf, backgroundColor: rc.line),
          const SizedBox(height: 8),
          Text(tr('ca. {0} KB', [(_secs * 3.1).toStringAsFixed(0)]), style: TextStyle(fontSize: 12, color: rc.muted)),
        ],
      ]),
      actions: [
        TextButton(onPressed: _cancel, child: Text(tr('Abbrechen'))),
        FilledButton.icon(
          onPressed: running && _secs >= 1 ? _finish : null,
          icon: const Icon(Icons.stop),
          label: Text(tr('Fertig')),
        ),
      ],
    );
  }
}

/// Bild oder Datei in einer Nachricht.
class _Attachment extends StatelessWidget {
  final Message m;
  const _Attachment(this.m);

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final path = m.file;
    final exists = path != null && File(path).existsSync();
    final done = m.progress >= 1 || (m.mine && m.status != MsgStatus.pending);
    final kb = ((m.fileSize ?? 0) / 1024).toStringAsFixed(1);
    final fg = m.mine ? rc.mineText : null;
    Widget body;
    if (m.isImage && exists) {
      body = GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: InteractiveViewer(maxScale: 6, child: Image.file(File(path))),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
        ),
      );
    } else {
      body = InkWell(
        onTap: exists ? () => OpenFilex.open(path) : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
              m.isImage
                  ? Icons.image_outlined
                  : (m.mime ?? '').startsWith('audio/')
                      ? Icons.mic_none
                      : (m.mime ?? '').startsWith('video/')
                          ? Icons.movie_outlined
                          : Icons.insert_drive_file_outlined,
              color: fg),
          const SizedBox(width: 8),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: fg)),
              Text('$kb KB${exists ? tr(' · antippen zum Öffnen') : ''}', style: TextStyle(fontSize: 11.5, color: fg ?? rc.muted)),
            ]),
          ),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      body,
      if (!done || m.progress < 1)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SizedBox(
            width: 200,
            child: LinearProgressIndicator(value: m.progress.clamp(0.0, 1.0), color: rc.lf, backgroundColor: rc.line),
          ),
        ),
      if (!m.mine && m.info.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(m.info, style: TextStyle(fontSize: 11, color: rc.muted)),
        ),
    ]);
  }
}

/// Wartet bis zu 20 s auf einen Fix vom GPS der Node. Ergebnis: 'fix', 'none' (Zeit um) oder 'cancel'.
class _WaitFixDialog extends StatefulWidget {
  const _WaitFixDialog();
  @override
  State<_WaitFixDialog> createState() => _WaitFixDialogState();
}

class _WaitFixDialogState extends State<_WaitFixDialog> {
  Timer? _t;
  int _ms = 0;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      _ms += 500;
      if (app.nodeFix != null) {
        _t?.cancel();
        Navigator.pop(context, 'fix');
      } else if (_ms >= 20000) {
        _t?.cancel();
        Navigator.pop(context, 'none');
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Warte auf GPS der Node …')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        LinearProgressIndicator(value: _ms / 20000),
        const SizedBox(height: 10),
        Text(app.nodeGps.status, style: TextStyle(fontSize: 12, color: context.rc.muted)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: Text(tr('Abbrechen'))),
      ],
    );
  }
}
