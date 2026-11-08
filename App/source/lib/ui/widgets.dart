import 'package:flutter/material.dart';

import '../state/app.dart';
import '../state/app_state.dart';
import 'theme.dart';
import '../i18n.dart';

String ago(DateTime? t) {
  if (t == null) return '–';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return tr('gerade eben');
  if (d.inMinutes < 60) return tr('vor {0} min', [d.inMinutes]);
  if (d.inHours < 24) return tr('vor {0} h', [d.inHours]);
  return tr('vor {0} d', [d.inDays]);
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String hhmmss(DateTime t) => '${hhmm(t)}:${t.second.toString().padLeft(2, '0')}';

/// Signalbalken nach SNR (LoRa ist bis weit unter 0 dB lesbar).
class SignalBars extends StatelessWidget {
  final double? snr;
  final double size;
  const SignalBars({super.key, this.snr, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final s = snr;
    final level = s == null ? 0 : (s > 5 ? 4 : s > 0 ? 3 : s > -7 ? 2 : s > -14 ? 1 : 0);
    final col = level >= 3 ? rc.ok : (level == 2 ? rc.warn : rc.crit);
    return SizedBox(
      width: size,
      height: size,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(4, (i) {
          return Container(
            width: size / 5,
            height: size * (i + 1) / 4,
            decoration: BoxDecoration(
              color: i < level ? col : rc.line,
              borderRadius: BorderRadius.circular(1),
            ),
          );
        }),
      ),
    );
  }
}

class Dot extends StatelessWidget {
  final Color color;
  final double size;
  final bool glow;
  const Dot(this.color, {super.key, this.size = 8, this.glow = false});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: glow ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)] : null,
        ),
      );
}

/// Abschnitt mit Überschrift.
class Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final Color? accent;
  const Section({super.key, required this.title, required this.child, this.trailing, this.accent});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(title.toUpperCase(),
                    style: TextStyle(
                        fontSize: 11.5,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                        color: accent ?? rc.muted)),
              ),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// Zeile „Bezeichnung … Wert“.
class KV extends StatelessWidget {
  final String k;
  final String v;
  final Color? color;
  const KV(this.k, this.v, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(color: context.rc.muted, fontSize: 13))),
          Flexible(
            child: Text(v, textAlign: TextAlign.right, style: mono(context, size: 13, color: color)),
          ),
        ]),
      );
}

/// Kleines Statusfeld für ein Modem in der Kopfzeile.
class ModemChip extends StatelessWidget {
  final ModemSlot slot;
  final VoidCallback? onTap;
  const ModemChip(this.slot, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final col = rc.band(slot.role);
    final rxRecent = slot.lastRx != null && DateTime.now().difference(slot.lastRx!).inMilliseconds < 1500;
    Color dot;
    String state;
    if (slot.connecting) {
      dot = rc.warn;
      state = 'verbinde';
    } else if (!slot.connected) {
      dot = rc.line;
      state = slot.error != null ? tr('Fehler') : 'aus';
    } else if (slot.transmitting) {
      dot = rc.crit;
      state = 'sendet';
    } else {
      dot = rxRecent ? col : rc.ok;
      state = app.modeOf(slot).name == 'meshtastic'
          ? tr('Meshtastic')
          : app.modeOf(slot).name == 'meshcore'
              ? 'MeshCore'
              : app.modeOf(slot).name == 'lrfunk'
                  ? 'LR-Funk'
                  : 'manuell';
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: slot.connected ? col.withValues(alpha: 0.6) : rc.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Dot(dot, glow: slot.connected),
          const SizedBox(width: 8),
          Text(slot.band, style: mono(context, size: 12, color: col, weight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text(state, style: TextStyle(fontSize: 12, color: rc.muted)),
        ]),
      ),
    );
  }
}

/// Runder Knoten-Kennzeichner (Kürzel).
class NodeBadge extends StatelessWidget {
  final String text;
  final Color color;
  final double size;
  const NodeBadge(this.text, this.color, {super.key, this.size = 40});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(fontSize: size * 0.28, fontWeight: FontWeight.w700, color: color),
        ),
      );
}

void toast(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(text, style: TextStyle(color: error ? context.rc.crit : null)),
    duration: Duration(seconds: error ? 5 : 2),
  ));
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.action});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 40, color: context.rc.muted),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(text, style: TextStyle(color: context.rc.muted), textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ]),
          ),
        ),
      );
}
