import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../i18n.dart';
import '../mesh/lr_file.dart';
import '../state/app.dart';
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

  /// Datei oder Bild auswählen und über LR-Funk senden.
  Future<void> _attach() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(withData: true);
    } catch (e) {
      if (mounted) toast(context, tr('Dateiauswahl nicht möglich: {0}', [e]), error: true);
      return;
    }
    if (res == null || res.files.isEmpty || !mounted) return;
    final f = res.files.first;
    Uint8List? data = f.bytes;
    if (data == null && f.path != null) data = await File(f.path!).readAsBytes();
    if (data == null || !mounted) return;
    var name = f.name;
    var mime = mimeFor(name);
    if (mime.startsWith('image/')) {
      final small = await compute(shrinkImage, data);
      if (small != null && small.length < data.length) {
        data = small;
        final dot = name.lastIndexOf('.');
        name = '${dot > 0 ? name.substring(0, dot) : name}.jpg';
        mime = 'image/jpeg';
      }
    }
    if (!mounted) return;
    final kb = (data.length / 1024).toStringAsFixed(1);
    final parts = (data.length / LrFileProto.chunkSize).ceil();
    final t = app.fileAirtimeS(data.length);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Über LR-Funk senden?')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(tr('{0} KB · {1} Teile{2}', [kb, parts, t == null ? '' : tr(' · Sendezeit ca. {0} s', [t.toStringAsFixed(0)])])),
          if (mime.startsWith('image/'))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('Das Bild wurde für die Funkübertragung verkleinert.'), style: TextStyle(fontSize: 12, color: ctx.rc.muted)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Senden'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
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
      _Composer(ctrl: _ctrl, focus: _focus, onSend: _send, maxBytes: isLr ? 180 : 200, accent: col, onAttach: isLr ? _attach : null),
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
            tooltip: tr('Bild oder Datei senden'),
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

/// Bild für die Funkübertragung verkleinern (längste Seite 480 px, JPEG). Läuft in einem eigenen Isolate.
Uint8List? shrinkImage(Uint8List data) {
  try {
    final im = img.decodeImage(data);
    if (im == null) return null;
    const maxSide = 480;
    final r = math.max(im.width, im.height) <= maxSide
        ? im
        : (im.width >= im.height ? img.copyResize(im, width: maxSide) : img.copyResize(im, height: maxSide));
    return Uint8List.fromList(img.encodeJpg(r, quality: 55));
  } catch (_) {
    return null;
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
          Icon(m.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined, color: fg),
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
