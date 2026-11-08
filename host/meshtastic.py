"""
meshtastic.py – Meshtastic-Pakete entschlüsseln und lesbar machen (reines Python, keine Zusatzpakete).

Aufbau eines Meshtastic-LoRa-Pakets:
  16 Byte Kopf (unverschlüsselt):
    dest u32, sender u32, packet_id u32, flags u8, channel_hash u8, next_hop u8, relay_node u8
  danach Nutzdaten, AES-CTR-verschlüsselt (protobuf "Data").
"""
import struct

# Standardschlüssel ("AQ==" in der App) für den Kanal LongFast usw.
DEFAULT_PSK = bytes([0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
                     0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01])

PORTNUM = {0: "UNKNOWN", 1: "TEXT", 2: "REMOTE_HW", 3: "POSITION", 4: "NODEINFO", 5: "ROUTING",
           6: "ADMIN", 7: "TEXT_COMPRESSED", 8: "WAYPOINT", 9: "AUDIO", 10: "DETECTION_SENSOR",
           32: "REPLY", 33: "IP_TUNNEL", 34: "PAXCOUNTER", 64: "SERIAL", 65: "STORE_FORWARD",
           66: "RANGE_TEST", 67: "TELEMETRY", 68: "ZPS", 69: "SIMULATOR", 70: "TRACEROUTE",
           71: "NEIGHBORINFO", 72: "ATAK", 73: "MAP_REPORT", 74: "POWERSTRESS", 256: "PRIVATE"}

HW_MODEL = {0: "UNSET", 4: "TBEAM", 9: "RAK4631", 10: "HELTEC_V2_1", 25: "STATION_G1",
            31: "STATION_G2", 39: "DIY_V1", 43: "HELTEC_V3", 44: "HELTEC_WSL_V3", 48: "HELTEC_WIRELESS_TRACKER",
            49: "HELTEC_WIRELESS_PAPER", 50: "T_DECK", 51: "T_WATCH_S3", 63: "SEEED_XIAO_S3",
            64: "TRACKER_T1000_E", 71: "RAK11310", 88: "WIO_WM1110", 255: "PRIVATE_HW"}


# ---------------------------------------------------------------------------
# AES (nur Verschlüsselung eines Blocks; CTR braucht nichts anderes)
# ---------------------------------------------------------------------------
def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _make_sbox():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1 | q >> 7) & 0xFF) ^ ((q << 2 | q >> 6) & 0xFF) ^ ((q << 3 | q >> 5) & 0xFF) ^ ((q << 4 | q >> 4) & 0xFF)
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    return sbox


_SBOX = _make_sbox()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D]


class AES:
    def __init__(self, key: bytes):
        if len(key) not in (16, 32):
            raise ValueError("AES-Schlüssel muss 16 oder 32 Byte lang sein")
        nk = len(key) // 4
        self.nr = nk + 6
        w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
        for i in range(nk, 4 * (self.nr + 1)):
            t = list(w[i - 1])
            if i % nk == 0:
                t = t[1:] + t[:1]
                t = [_SBOX[b] for b in t]
                t[0] ^= _RCON[i // nk - 1]
            elif nk > 6 and i % nk == 4:
                t = [_SBOX[b] for b in t]
            w.append([w[i - nk][j] ^ t[j] for j in range(4)])
        self.rk = [sum(w[4 * r:4 * r + 4], []) for r in range(self.nr + 1)]

    def encrypt_block(self, block: bytes) -> bytes:
        s = [block[i] ^ self.rk[0][i] for i in range(16)]
        for r in range(1, self.nr + 1):
            s = [_SBOX[b] for b in s]
            # ShiftRows (Spaltenweise Anordnung: Index = Spalte*4 + Zeile)
            s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
            if r != self.nr:
                t = []
                for c in range(4):
                    a = s[4 * c:4 * c + 4]
                    x = a[0] ^ a[1] ^ a[2] ^ a[3]
                    t += [a[0] ^ x ^ _xtime(a[0] ^ a[1]), a[1] ^ x ^ _xtime(a[1] ^ a[2]),
                          a[2] ^ x ^ _xtime(a[2] ^ a[3]), a[3] ^ x ^ _xtime(a[3] ^ a[0])]
                s = t
            s = [s[i] ^ self.rk[r][i] for i in range(16)]
        return bytes(s)


def aes_ctr(key: bytes, nonce: bytes, data: bytes) -> bytes:
    aes = AES(key)
    ctr = bytearray(nonce)
    out = bytearray()
    for i in range(0, len(data), 16):
        ks = aes.encrypt_block(bytes(ctr))
        chunk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(chunk, ks))
        for j in range(15, -1, -1):           # Zähler big-endian erhöhen (wie mbedtls)
            ctr[j] = (ctr[j] + 1) & 0xFF
            if ctr[j]:
                break
    return bytes(out)


def expand_psk(psk: bytes) -> bytes:
    """Kurzschlüssel wie in der App: 1 Byte = Standardschlüssel mit verändertem letzten Byte."""
    if len(psk) == 0:
        return b""
    if len(psk) == 1:
        if psk[0] == 0:
            return b""
        k = bytearray(DEFAULT_PSK)
        k[-1] = (k[-1] + psk[0] - 1) & 0xFF
        return bytes(k)
    if len(psk) < 16:
        return psk.ljust(16, b"\x00")
    if 16 < len(psk) < 32:
        return psk.ljust(32, b"\x00")
    return psk


def channel_hash(name: str, psk: bytes) -> int:
    h = 0
    for b in name.encode():
        h ^= b
    for b in expand_psk(psk):
        h ^= b
    return h


# ---------------------------------------------------------------------------
# minimaler protobuf-Leser
# ---------------------------------------------------------------------------
def _varint(b, i):
    v = s = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << s
        if not c & 0x80:
            return v, i
        s += 7


def pb_fields(b: bytes):
    """Gibt (feldnummer, wiretype, wert) zurück; wert = int, bytes oder 4/8-Byte-Rohwert."""
    i = 0
    out = []
    while i < len(b):
        key, i = _varint(b, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 1:
            v = b[i:i + 8]; i += 8
        elif wt == 2:
            n, i = _varint(b, i)
            v = b[i:i + n]; i += n
        elif wt == 5:
            v = b[i:i + 4]; i += 4
        else:
            raise ValueError("unbekannter protobuf-Typ %d" % wt)
        if i > len(b):
            raise ValueError("protobuf zu kurz")
        out.append((f, wt, v))
    return out


def _f32(v):
    return struct.unpack("<f", v)[0]


def _sint32(v):
    return struct.unpack("<i", v)[0] if isinstance(v, bytes) else v


def decode_payload(portnum: int, p: bytes) -> dict:
    """Die wichtigsten Anwendungen lesbar machen."""
    try:
        if portnum == 1:
            return {"text": p.decode("utf-8", "replace")}
        fl = pb_fields(p)
        d = {}
        if portnum == 4:                                   # NODEINFO -> User
            for f, wt, v in fl:
                if f == 1: d["id"] = v.decode(errors="replace")
                elif f == 2: d["long_name"] = v.decode(errors="replace")
                elif f == 3: d["short_name"] = v.decode(errors="replace")
                elif f == 5: d["hw"] = HW_MODEL.get(v, v)
                elif f == 7: d["role"] = v
        elif portnum == 3:                                 # POSITION
            for f, wt, v in fl:
                if f == 1: d["lat"] = _sint32(v) / 1e7
                elif f == 2: d["lon"] = _sint32(v) / 1e7
                elif f == 3: d["alt_m"] = v
                elif f == 4: d["time"] = struct.unpack("<I", v)[0] if isinstance(v, bytes) else v
                elif f == 14: d["sats"] = v
        elif portnum == 67:                                # TELEMETRY
            for f, wt, v in fl:
                if f == 2:                                 # device_metrics
                    for g, wt2, w in pb_fields(v):
                        if g == 1: d["batterie_%"] = w
                        elif g == 2: d["spannung_v"] = round(_f32(w), 2)
                        elif g == 3: d["kanal_last_%"] = round(_f32(w), 1)
                        elif g == 4: d["sende_last_%"] = round(_f32(w), 1)
                        elif g == 5: d["uptime_s"] = w
                elif f == 3:                               # environment_metrics
                    for g, wt2, w in pb_fields(v):
                        if g == 1: d["temp_c"] = round(_f32(w), 1)
                        elif g == 2: d["feuchte_%"] = round(_f32(w), 1)
                        elif g == 3: d["druck_hpa"] = round(_f32(w), 1)
        elif portnum == 5:                                 # ROUTING
            d["routing"] = [(f, v if not isinstance(v, bytes) else v.hex()) for f, wt, v in fl]
        else:
            d["felder"] = [(f, v if not isinstance(v, bytes) else v.hex()) for f, wt, v in fl]
        return d
    except Exception as e:
        return {"roh": p.hex(), "fehler": str(e)}


# ---------------------------------------------------------------------------
class MeshtasticDecoder:
    def __init__(self, channels=None):
        """channels: Liste von (name, psk_bytes). Standard: LongFast mit Standardschlüssel."""
        self.channels = []
        for name, psk in (channels or [("LongFast", b"\x01")]):
            key = expand_psk(psk)
            self.channels.append((name, key, channel_hash(name, psk)))
        self.nodes = {}                                    # Knoten-ID -> Name

    def decode(self, raw: bytes) -> dict:
        if len(raw) < 16:
            return {"fehler": "zu kurz"}
        dest, sender, pid, flags, chash, next_hop, relay = struct.unpack("<IIIBBBB", raw[:16])
        out = {"von": "!%08x" % sender, "an": "alle" if dest == 0xFFFFFFFF else "!%08x" % dest,
               "id": pid, "hops_rest": flags & 7, "hops_start": flags >> 5, "want_ack": bool(flags & 8),
               "via_mqtt": bool(flags & 16), "kanal_hash": chash, "relay": relay}
        name = self.nodes.get(sender)
        if name:
            out["name"] = name
        enc = raw[16:]
        for chname, key, h in self.channels:
            if h != chash or not key:
                continue
            nonce = struct.pack("<QI", pid, sender) + b"\x00" * 4
            plain = aes_ctr(key, nonce, enc)
            try:
                fl = pb_fields(plain)
                port = next((v for f, wt, v in fl if f == 1 and wt == 0), None)
                payload = next((v for f, wt, v in fl if f == 2 and wt == 2), b"")
                if port is None:
                    continue
            except Exception:
                continue
            out["kanal"] = chname
            out["app"] = PORTNUM.get(port, port)
            out["inhalt"] = decode_payload(port, payload)
            if port == 4 and out["inhalt"].get("long_name"):
                self.nodes[sender] = "%s (%s)" % (out["inhalt"]["long_name"], out["inhalt"].get("short_name", ""))
                out["name"] = self.nodes[sender]
            return out
        out["kanal"] = None
        out["hinweis"] = "Kanal unbekannt oder privater Schlüssel (Hash %d)" % chash
        return out


def format_packet(d: dict) -> str:
    who = d.get("name") or d["von"]
    hops = "%d/%d Hops" % (d["hops_start"] - d["hops_rest"], d["hops_start"]) if d.get("hops_start") else ""
    if not d.get("kanal"):
        return "%s -> %s  [%s]  %s" % (who, d["an"], hops, d.get("hinweis", ""))
    inh = d.get("inhalt", {})
    if d["app"] == "TEXT":
        body = "»%s«" % inh.get("text", "")
    else:
        body = ", ".join("%s=%s" % kv for kv in inh.items())
    return "%s -> %s  [%s, %s]  %s: %s" % (who, d["an"], d["kanal"], hops, d["app"], body)


def _pb_bytes(field: int, data: bytes) -> bytes:
    return _enc_varint(field << 3 | 2) + _enc_varint(len(data)) + data


def _pb_varint(field: int, value: int) -> bytes:
    return _enc_varint(field << 3) + _enc_varint(value)


def build_data_packet(portnum: int, payload: bytes, sender: int, packet_id: int, dest: int = 0xFFFFFFFF,
                      channel=("LongFast", b"\x01"), hop_limit: int = 3, want_response: bool = False) -> bytes:
    """Fertiges, verschlüsseltes Meshtastic-Paket (Data{portnum, payload}) für die Funkschnittstelle."""
    name, psk = channel
    key = expand_psk(psk)
    data = _pb_varint(1, portnum) + _pb_bytes(2, payload)
    if want_response:
        data += _pb_varint(3, 1)
    if len(data) > 233:
        raise ValueError("Nutzdaten zu lang")
    nonce = struct.pack("<QI", packet_id, sender) + b"\x00" * 4
    enc = aes_ctr(key, nonce, data)
    flags = (hop_limit & 7) | ((hop_limit & 7) << 5)
    head = struct.pack("<IIIBBBB", dest, sender, packet_id, flags, channel_hash(name, psk), 0, sender & 0xFF)
    return head + enc


def build_text_packet(text: str, sender: int, packet_id: int, dest: int = 0xFFFFFFFF,
                      channel=("LongFast", b"\x01"), hop_limit: int = 3) -> bytes:
    body = text.encode("utf-8")
    if len(body) > 200:
        raise ValueError("Text zu lang (max. 200 Byte)")
    return build_data_packet(1, body, sender, packet_id, dest, channel, hop_limit)


def build_nodeinfo_packet(sender: int, packet_id: int, long_name: str, short_name: str, dest: int = 0xFFFFFFFF,
                          channel=("LongFast", b"\x01"), hop_limit: int = 3, want_response: bool = False,
                          hw_model: int = 255) -> bytes:
    """Visitenkarte (User): ID, langer Name, Kürzel, Hardware (255 = Eigenbau)."""
    user = (_pb_bytes(1, ("!%08x" % sender).encode()) + _pb_bytes(2, long_name.encode("utf-8")[:39]) +
            _pb_bytes(3, short_name.encode("utf-8")[:4]) + _pb_varint(5, hw_model))
    return build_data_packet(4, user, sender, packet_id, dest, channel, hop_limit, want_response)


def _enc_varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)
