#!/usr/bin/env python3
"""List the enabled device tree nodes that use given pins of the main pin controller.

Usage: dt_pin_users.py MERGED.dts PIN [PIN ...]     (e.g. PI7 PI8)
Reads the output of `dtc -I dtb -O dts` (after all overlays) and prints one line per user:
  <node path> pinctrl <group>            (pinctrl-N reference to a group that contains the pin)
  <node path> gpio <property>            (GPIO reference to the pin)
  <node path> irq                        (interrupt on the pin)
A node counts as enabled when it and all its parents have no status or status "okay".
Pin groups below the pin controller only count when an enabled node references them.
"""
import re
import sys

PIO_PATH = "/soc/pinctrl@300b000"


class Node:
    def __init__(self, name, parent):
        self.name, self.parent, self.props, self.children = name, parent, {}, []
        self.path = "/" if parent is None else (parent.path.rstrip("/") + "/" + name)

    def enabled(self):
        n = self
        while n is not None:
            st = n.props.get("status")
            if st is not None and st not in ('"okay"', '"ok"'):
                return False
            n = n.parent
        return True


def parse(text):
    root, cur = None, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("/dts-v1/") or line.startswith("/memreserve/"):
            continue
        m = re.match(r"^(?:[\w-]+:\s*)?([^\s=]+)\s*\{$", line)
        if m:
            n = Node(m.group(1), cur)
            if cur is None:
                root = n
            else:
                cur.children.append(n)
            cur = n
            continue
        if line == "};":
            cur = cur.parent
            continue
        m = re.match(r"^([^\s=]+)\s*=\s*(.*);$", line)
        if m and cur is not None:
            cur.props[m.group(1)] = m.group(2)
        elif line.endswith(";") and cur is not None:
            cur.props[line[:-1]] = ""
    return root


def walk(n):
    yield n
    for c in n.children:
        yield from walk(c)


def cells(v):
    return [int(x, 0) for x in re.findall(r"0x[0-9a-fA-F]+|\d+", " ".join(re.findall(r"<([^>]*)>", v)))]


def pin_name(bank, num):
    return "P%s%d" % (chr(ord("A") + bank), num)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    root = parse(open(sys.argv[1], encoding="utf-8").read())
    want = set(sys.argv[2:])
    nodes = list(walk(root))
    by_phandle = {}
    for n in nodes:
        if "phandle" in n.props:
            by_phandle[cells(n.props["phandle"])[0]] = n
    pio = next((n for n in nodes if n.path == PIO_PATH), None)
    if pio is None:
        print("pin controller %s not found" % PIO_PATH, file=sys.stderr)
        return 2
    pio_ph = cells(pio.props.get("phandle", "<0>"))[0]
    for n in nodes:
        if not n.enabled() or n.parent is pio:
            continue
        for k, v in n.props.items():
            if re.fullmatch(r"pinctrl-\d+", k):
                for ph in cells(v):
                    g = by_phandle.get(ph)
                    if g is None:
                        continue
                    pins = set(re.findall(r'"([^"]+)"', g.props.get("pins", "")))
                    if pins & want:
                        print("%s pinctrl %s %s" % (n.path, g.name, ",".join(sorted(pins & want))))
            elif k.endswith("gpios") or k == "gpio":
                c = cells(v)
                i = 0
                while i < len(c):
                    ctl = by_phandle.get(c[i])
                    nc = cells(ctl.props.get("#gpio-cells", "<2>"))[0] if ctl else 2
                    if c[i] == pio_ph and nc >= 2 and pin_name(c[i + 1], c[i + 2]) in want:
                        print("%s gpio %s %s" % (n.path, k, pin_name(c[i + 1], c[i + 2])))
                    i += 1 + nc
        ip = n.props.get("interrupt-parent")
        if ip and cells(ip)[0] == pio_ph and "interrupts" in n.props:
            c = cells(n.props["interrupts"])
            for i in range(0, len(c) - 2, 3):
                if pin_name(c[i], c[i + 1]) in want:
                    print("%s irq %s" % (n.path, pin_name(c[i], c[i + 1])))
        if "interrupts-extended" in n.props:
            c = cells(n.props["interrupts-extended"])
            i = 0
            while i < len(c):
                ctl = by_phandle.get(c[i])
                nc = cells(ctl.props.get("#interrupt-cells", "<1>"))[0] if ctl else 1
                if c[i] == pio_ph and nc >= 2 and pin_name(c[i + 1], c[i + 2]) in want:
                    print("%s irq %s" % (n.path, pin_name(c[i + 1], c[i + 2])))
                i += 1 + nc
    return 0


if __name__ == "__main__":
    sys.exit(main())
