#!/usr/bin/env python3
"""Voice tools for Mario Kart Wii character mods in Retro Rewind.

  convert IN OUT [--remap DONOR:TARGET --sound-archive revo_kart.brsar]
      Re-encode the wave archive of a .brwsd/.brbnk to mono 16 kHz DSP-ADPCM, the format the
      game's own voices use. With --remap, also reorder a .brwsd's voice lines from the donor
      character's layout to the target's (e.g. CA:RS for a pack made over Birdo, installed
      over Rosalina), matching lines by their names in the sound archive.

  bank SRC OUT --clips N,N,...
      Build a voice bank (.brbnk) whose program i plays clip N[i] of SRC's wave archive.
      Rosalina's sequences use programs 0-2 for the star shout and 3-8 for the boost shout.

  clips FILE OUTDIR
      Export every clip of FILE's wave archive as a WAV, numbered, to pick clips for `bank`.

  lines FILE
      Print each voice line and the clip it plays, with clip formats.

Needs ffmpeg and dspenc (tools/build-dspenc.sh builds it into tools/bin/).
"""
import argparse, json, os, re, shutil, struct, subprocess, sys, tempfile, wave

RATE = 16000
HERE = os.path.dirname(os.path.abspath(__file__))

u32 = lambda b, o: struct.unpack_from(">I", b, o)[0]
u16 = lambda b, o: struct.unpack_from(">H", b, o)[0]
s16 = lambda b, o: struct.unpack_from(">h", b, o)[0]
pad = lambda n, a=0x20: (n + a - 1) // a * a

# Lines a donor character has no equivalent for, and the closest line it does have.
# Birdo (CA) is the case that needs them: she has no wheelie, bump, failed-start,
# medium-hit, freeze or respawn lines.
SUBSTITUTES = {"WLE": "DSH", "ATK": "OVTAK", "STR_FAIL": "DMG_S",
               "DMG_M": "DMG_L", "DMG_FRE": "DMG_S", "RET": "LND_S"}


def dspenc_path():
    for p in (os.environ.get("DSPENC"), os.path.join(HERE, "bin", "dspenc"), shutil.which("dspenc")):
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    sys.exit("dspenc not found: run tools/build-dspenc.sh, or set DSPENC")


# ---------------------------------------------------------------- wave archives

def archive_offset(b):
    """Offset of the RWAR that follows a .brwsd/.brbnk header (an optional LABL may sit between)."""
    r = u32(b, 8)
    if b[r:r + 4] == b"LABL":
        r += u32(b, r + 4)
    if b[r:r + 4] != b"RWAR":
        raise ValueError("no wave archive after the header")
    return r


def clip_offsets(b):
    r = archive_offset(b)
    t, d = r + u32(b, r + 0x10), r + u32(b, r + 0x18)
    return [d + u32(b, t + 12 + 12 * i + 4) for i in range(u32(b, t + 8))]


def decode_channel(data, coefs, nibbles):
    out, h1, h2 = [], 0, 0
    nsamp = nibbles - (nibbles + 15) // 16 * 2
    for f in range(0, len(data), 8):
        ps = data[f]
        c1, c2 = coefs[(ps >> 4) * 2], coefs[(ps >> 4) * 2 + 1]
        scale = 1 << (ps & 0xF)
        for i in range(14):
            n = data[f + 1 + i // 2]
            n = (n >> 4) if i % 2 == 0 else (n & 0xF)
            if n >= 8:
                n -= 16
            v = (((n * scale) << 11) + 1024 + c1 * h1 + c2 * h2) >> 11
            v = max(-32768, min(32767, v))
            h2, h1 = h1, v
            out.append(v)
            if len(out) >= nsamp:
                return out
    return out


def read_clip(b, rw):
    """Decode one RWAV to (mono int16 samples, sample rate)."""
    wi = rw + u32(b, rw + 0x10) + 8
    fmt, ch = b[wi], b[wi + 2]
    rate = (b[wi + 3] << 16) | u16(b, wi + 4)
    loop_end = u32(b, wi + 0x0C)
    if fmt != 2:
        raise ValueError(f"clip format {fmt} is not DSP-ADPCM")
    data = rw + u32(b, rw + 0x18) + 8
    table = wi + u32(b, wi + 0x10)
    chans = []
    for c in range(ch):
        ci = wi + u32(b, table + 4 * c)
        ai = wi + u32(b, ci + 4)
        coefs = [s16(b, ai + 2 * k) for k in range(16)]
        start = data + u32(b, ci)
        chans.append(decode_channel(b[start:start + pad((loop_end + 2) // 2, 8)], coefs, loop_end + 1))
    n = min(len(x) for x in chans)
    return [sum(x[i] for x in chans) // ch for i in range(n)], rate


def write_wav(path, pcm, rate):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))


def encode_clip(pcm, rate, tmp):
    src, mid, dsp = (os.path.join(tmp, x) for x in ("src.wav", "mid.wav", "out.dsp"))
    write_wav(src, pcm, rate)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", str(RATE),
                    "-af", "aresample=resampler=soxr", "-c:a", "pcm_s16le", mid], check=True)
    subprocess.run([dspenc_path(), mid, dsp], check=True, stdout=subprocess.DEVNULL)
    d = open(dsp, "rb").read()
    return build_rwav(nibbles=u32(d, 4), coefs=d[0x1C:0x3C], ps=u16(d, 0x3E), data=d[0x60:])


def build_rwav(nibbles, coefs, ps, data):
    """A mono RWAV laid out exactly like the retail voice clips."""
    data += b"\0" * (pad(len(data)) - len(data))
    wi = struct.pack(">BBBBHBBIIIII", 2, 0, 1, (RATE >> 16) & 0xFF, RATE & 0xFFFF, 0, 0,
                     2, nibbles - 1, 0x1C, 0x78, 0)
    body = (wi + struct.pack(">I", 0x20)
            + struct.pack(">7I", 0, 0x3C, 0x01000000, 0x01000000, 0x01000000, 0x01000000, 0)
            + coefs + struct.pack(">HHhhHhhH", 0, ps, 0, 0, 0, 0, 0, 0))
    info = b"INFO" + struct.pack(">I", 0x80) + body + b"\0" * (0x78 - len(body))
    dblk = b"DATA" + struct.pack(">I", 8 + len(data)) + data
    size = 0x20 + len(info) + len(dblk)
    head = b"RWAV" + struct.pack(">HHIHHIIII", 0xFEFF, 0x0102, size, 0x20, 2,
                                 0x20, len(info), 0x20 + len(info), len(dblk))
    return head + b"\0" * (0x20 - len(head)) + info + dblk


def build_rwar(rwavs):
    tabl_size = pad(12 + 12 * len(rwavs))
    entries, off = b"", 0x20
    for r in rwavs:
        entries += struct.pack(">III", 0x01000000, off, len(r)); off += len(r)
    tabl = b"TABL" + struct.pack(">II", tabl_size, len(rwavs)) + entries
    tabl += b"\0" * (tabl_size - len(tabl))
    dblk = b"DATA" + struct.pack(">I", off) + b"\0" * 0x18 + b"".join(rwavs)
    size = 0x20 + len(tabl) + len(dblk)
    head = b"RWAR" + struct.pack(">HHIHHIIII", 0xFEFF, 0x0100, size, 0x20, 2,
                                 0x20, len(tabl), 0x20 + len(tabl), len(dblk))
    return head + b"\0" * (0x20 - len(head)) + tabl + dblk


def reencode_clips(b, pick=None):
    offs = clip_offsets(b)
    pick = range(len(offs)) if pick is None else pick
    with tempfile.TemporaryDirectory() as tmp:
        return [encode_clip(*read_clip(b, offs[i]), tmp) for i in pick]


# ---------------------------------------------------------------- voice lines (RWSD)

def rwsd_lines(b):
    """For each voice line, the clips it plays."""
    data = u32(b, 0x10); base = data + 8
    lines = []
    for i in range(u32(b, data + 8)):
        e = base + u32(b, data + 12 + 8 * i + 4)
        notes = base + u32(b, e + 0x14)
        lines.append([u32(b, base + u32(b, notes + 8 + 8 * j)) for j in range(u32(b, notes))])
    return lines


def reorder_lines(head, order):
    """Point the RWSD's line table at the given old line numbers, in the new order."""
    h = bytearray(head)
    data = u32(h, 0x10); old = u32(h, data + 8)
    if len(order) > old:
        raise ValueError("the target layout has more lines than the pack; cannot reorder in place")
    refs = [bytes(h[data + 12 + 8 * i:data + 20 + 8 * i]) for i in range(old)]
    struct.pack_into(">I", h, data + 8, len(order))
    for i, j in enumerate(order):
        h[data + 12 + 8 * i:data + 20 + 8 * i] = refs[j]
    return bytes(h)


def sound_table(brsar):
    """(name, fileId, index) of every wave sound in revo_kart.brsar."""
    br = open(brsar, "rb").read()
    symb, info = u32(br, 0x10), u32(br, 0x18)
    sb = symb + 8; nt = sb + u32(br, sb); names = []
    for i in range(u32(br, nt)):
        s = sb + u32(br, nt + 4 + 4 * i); names.append(br[s:br.index(b"\0", s)].decode("latin1"))
    base = info + 8; st = base + u32(br, base + 4); out = []
    for i in range(u32(br, st)):
        e = base + u32(br, st + 4 + 8 * i + 4)
        if br[e + 0x16] == 3:  # wave sound
            out.append((names[u32(br, e)], u32(br, e + 4), u32(br, base + u32(br, e + 0x1C))))
    return out


def remap_order(table, donor, target, n_donor_lines):
    """Line order for the target's file, as donor line numbers. Picks the target file whose
    line count matches the target layout of this file type by finding the donor file with
    n_donor_lines lines."""
    def by_file(code):
        files = {}
        for name, fid, idx in table:
            m = re.match(rf"VO_{code}_(.+)$", name)
            if m:
                files.setdefault(fid, {})[m.group(1)] = idx
        return files
    dfiles, tfiles = by_file(donor), by_file(target)
    dfile = next((f for f in dfiles.values() if len(f) == n_donor_lines), None)
    if dfile is None:
        raise ValueError(f"no {donor} voice file with {n_donor_lines} lines in the sound archive")
    # the target file covering the same events: the one sharing the most line names
    tfile = max(tfiles.values(), key=lambda f: len(set(f) & set(dfile)))
    order, missing = [], []
    for name, _ in sorted(tfile.items(), key=lambda x: x[1]):
        m = re.match(r"(.+?)(\d|_END)?$", name)
        alt = SUBSTITUTES.get(m.group(1), m.group(1)) + (m.group(2) or "")
        pick = name if name in dfile else alt if alt in dfile else None
        if pick is None:
            missing.append(name)
        else:
            order.append(dfile[pick])
    if missing:
        raise ValueError(f"{donor} has no line for: {', '.join(missing)}")
    return order


# ---------------------------------------------------------------- banks (RBNK)

def build_bank_header(n):
    """An RBNK with n programs, program i playing clip i: the retail instrument settings."""
    inst_off = 4 + 8 * n
    table = struct.pack(">I", n) + b"".join(struct.pack(">BBHI", 1, 1, 0, inst_off + 0x30 * i)
                                            for i in range(n))
    insts = b"".join(struct.pack(">I", i) + bytes.fromhex("7f7f7f78 7f000000 3c7f4000 3f800000")
                     + b"\0" * 0x1C for i in range(n))
    body = table + insts
    data = b"DATA" + struct.pack(">I", pad(8 + len(body))) + body
    data += b"\0" * (pad(len(data)) - len(data))
    size = 0x20 + len(data)
    head = b"RBNK" + struct.pack(">HHIHHII", 0xFEFF, 0x0102, size, 0x20, 1, 0x20, len(data))
    return head + b"\0" * (0x20 - len(head)) + data


# ---------------------------------------------------------------- commands

def cmd_convert(a):
    b = open(a.input, "rb").read()
    head = b[:u32(b, 8)]
    # one-line files (finish lines, cannon) are the same event in every layout
    if a.remap and head[:4] == b"RWSD" and len(rwsd_lines(b)) > 1:
        donor, target = a.remap.upper().split(":")
        if donor != target:
            if not a.sound_archive:
                sys.exit("--remap needs --sound-archive (revo_kart.brsar)")
            order = remap_order(sound_table(a.sound_archive), donor, target, len(rwsd_lines(b)))
            head = reorder_lines(head, order)
    out = head + build_rwar(reencode_clips(b))
    open(a.output, "wb").write(out)
    print(f"{os.path.basename(a.input)}: {len(b)} -> {len(out)} bytes")


def cmd_bank(a):
    b = open(a.source, "rb").read()
    pick = [int(x) for x in a.clips.split(",")]
    out = build_bank_header(len(pick)) + build_rwar(reencode_clips(b, pick))
    open(a.output, "wb").write(out)
    print(f"{os.path.basename(a.output)}: {len(pick)} programs, {len(out)} bytes")


def cmd_clips(a):
    b = open(a.file, "rb").read()
    os.makedirs(a.outdir, exist_ok=True)
    for i, off in enumerate(clip_offsets(b)):
        write_wav(os.path.join(a.outdir, f"{i:02d}.wav"), *read_clip(b, off))
    print(f"{len(clip_offsets(b))} clips -> {a.outdir}")


def cmd_lines(a):
    b = open(a.file, "rb").read()
    for i, off in enumerate(clip_offsets(b)):
        wi = off + u32(b, off + 0x10) + 8
        print(f"clip {i:2d}: {b[wi + 2]} ch, {(b[wi + 3] << 16) | u16(b, wi + 4)} Hz")
    if b[:4] == b"RWSD":
        print(json.dumps(rwsd_lines(b)))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert"); c.add_argument("input"); c.add_argument("output")
    c.add_argument("--remap"); c.add_argument("--sound-archive"); c.set_defaults(fn=cmd_convert)
    k = sub.add_parser("bank"); k.add_argument("source"); k.add_argument("output")
    k.add_argument("--clips", required=True); k.set_defaults(fn=cmd_bank)
    x = sub.add_parser("clips"); x.add_argument("file"); x.add_argument("outdir"); x.set_defaults(fn=cmd_clips)
    l = sub.add_parser("lines"); l.add_argument("file"); l.set_defaults(fn=cmd_lines)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
