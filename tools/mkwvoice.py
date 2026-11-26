#!/usr/bin/env python3
"""Voice tools for Mario Kart Wii character mods in Retro Rewind.

  build VOICES OUTDIR --name GRP_VO_RS-1 --sound-archive revo_kart.brsar
        [--donor CODE] [--layout MR] [--set LINE=N,N,...] [--loudness DB]
      Build a costume's full voice set from a pack's voice files. Retro Rewind reads a
      costume's voices in the 78-line layout most characters share (Mario's), not the
      base character's own: Rosalina's 48-line file is read as if it were Mario's.
      Every line of the layout is filled from the pack by name. The pack's own lines,
      its bank (Rosalina keeps her boost shouts there), then the closest line it does
      have. Clips are re-encoded to mono 16 kHz, the game's voice format, and quiet
      packs are raised to --loudness.
        --donor  the character the pack was made for (default: read from file names)
        --set    pick clips yourself, as clip numbers of the pack's PC .brwsd, for every
                 variant of a line: --set DSH=3,4,9,13,3,4 --set STRM=6,53,6

  clips FILE OUTDIR
      Export every clip of FILE's wave archive as a numbered WAV, to pick clips for --set.

  lines FILE
      Print a .brwsd's lines (as clip numbers) and its clip formats.

Needs ffmpeg and dspenc (tools/build-dspenc.sh builds it into tools/bin/).
"""
import argparse, glob, json, math, os, re, shutil, struct, subprocess, sys, tempfile, wave

RATE = 16000
HERE = os.path.dirname(os.path.abspath(__file__))

u32 = lambda b, o: struct.unpack_from(">I", b, o)[0]
u16 = lambda b, o: struct.unpack_from(">H", b, o)[0]
s16 = lambda b, o: struct.unpack_from(">h", b, o)[0]
pad = lambda n, a=0x20: (n + a - 1) // a * a

# Closest lines to use when a pack has no clip for an event, in order of preference.
SUBSTITUTES = {
    "ATK": ["DSH", "ITM_SCES"], "DSH": ["ATK", "ITM_SCES"], "WLE": ["DSH", "ATK"],
    "WLE_FAIL": ["DMG_S", "STR_FAIL"], "STR_FAIL": ["DMG_S", "WLE_FAIL"],
    "JP_L": ["JP_ACT", "JP_M"], "JP_M": ["JP_ACT", "JP_S", "JP_L"], "JP_S": ["JP_M", "JP_ACT"],
    "JP_ACT": ["JP_M", "DSH"], "LND_L": ["LND_S", "JP_S"], "LND_S": ["LND_L", "JP_S"],
    "OVTAK": ["ITM_SCES", "DSH"], "DMG_L": ["DMG_M", "DMG_S"], "DMG_M": ["DMG_L", "DMG_S"],
    "DMG_S": ["DMG_M", "DMG_L"], "DMG_SPN": ["DMG_M", "DMG_S"], "DMG_FRE": ["DMG_S", "DMG_M"],
    "FAL": ["FAL_W", "DMG_L"], "FAL_W": ["FAL", "DMG_L"], "RET": ["RET_W", "LND_S"],
    "RET_W": ["RET", "LND_S"], "ITM_PUT": ["ITM_TRW", "ITM_SCES"],
    "ITM_TRW": ["ITM_PUT", "ITM_SCES"], "ITM_SCES": ["ITM_PWUP", "DSH"],
    "ITM_PWUP": ["ITM_SCES", "DSH"], "STRM": ["ITM_PWUP", "DSH"],
}
VARIANT = re.compile(r"(.+?)(_?\d|_END)?$")


def dspenc_path():
    for p in (os.environ.get("DSPENC"), os.path.join(HERE, "bin", "dspenc"), shutil.which("dspenc")):
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    sys.exit("dspenc not found: run tools/build-dspenc.sh, or set DSPENC")


# ---------------------------------------------------------------- the sound archive

class Brsar:
    """Names, voice lines, sequences and group files of revo_kart.brsar."""

    def __init__(self, path):
        self.b = b = open(path, "rb").read()
        symb, info = u32(b, 0x10), u32(b, 0x18)
        sb = symb + 8; nt = sb + u32(b, sb); self.names = []
        for i in range(u32(b, nt)):
            s = sb + u32(b, nt + 4 + 4 * i); self.names.append(b[s:b.index(b"\0", s)].decode("latin1"))
        self.base = base = info + 8
        self.groups = {}
        gt = base + u32(b, base + 0x24)
        for g in range(u32(b, gt)):
            e = base + u32(b, gt + 4 + 8 * g + 4)
            self.groups[self._name(u32(b, e))] = e
        ft = base + u32(b, base + 0x1C)
        self.file_entries = [base + u32(b, ft + 4 + 8 * i + 4) for i in range(u32(b, ft))]
        self.waves, self.seqs = [], []  # (name, fileId, index) and (name, fileId, label, program)
        st = base + u32(b, base + 4)
        for i in range(u32(b, st)):
            e = base + u32(b, st + 4 + 8 * i + 4)
            name, fid, kind, si = self._name(u32(b, e)), u32(b, e + 4), b[e + 0x16], base + u32(b, e + 0x1C)
            if kind == 3:
                self.waves.append((name, fid, u32(b, si)))
            elif kind == 1 and name.startswith("VO_"):
                self.seqs.append((name, fid, u32(b, si)))

    def _name(self, i):
        return self.names[i] if i < len(self.names) else ""

    def group_files(self, group):
        """{'brwsd': bytes, 'brbnk': bytes} of a group, header and wave data joined."""
        b, base, e = self.b, self.base, self.groups[group]
        goff, gwoff, it = u32(b, e + 0x10), u32(b, e + 0x18), base + u32(b, e + 0x24)
        out = {}
        for i in range(u32(b, it)):
            x = base + u32(b, it + 4 + 8 * i + 4)
            off, size, woff, wsize = (u32(b, x + k) for k in (4, 8, 12, 16))
            head = b[goff + off:goff + off + size]
            ext = {b"RWSD": "brwsd", b"RBNK": "brbnk"}.get(head[:4])
            if ext and ext not in out:
                out[ext] = head + b[gwoff + woff:gwoff + woff + wsize]
        return out

    def file_bytes(self, fid):
        b, base = self.b, self.base
        pos = base + u32(b, self.file_entries[fid] + 0x18)
        fp = base + u32(b, pos + 8)
        g = self.groups_by_index()[u32(b, fp)]
        goff, it = u32(b, g + 0x10), base + u32(b, g + 0x24)
        x = base + u32(b, it + 4 + 8 * u32(b, fp + 4) + 4)
        return b[goff + u32(b, x + 4):goff + u32(b, x + 4) + u32(b, x + 8)]

    def groups_by_index(self):
        if not hasattr(self, "_gidx"):
            gt = self.base + u32(self.b, self.base + 0x24)
            self._gidx = [self.base + u32(self.b, gt + 4 + 8 * g + 4) for g in range(u32(self.b, gt))]
        return self._gidx

    def lines(self, code, npc):
        """Line names of a character's main (or opponent) voice file, in file order."""
        pre = f"VO_{code}_NPC_" if npc else f"VO_{code}_"
        files = {}
        for name, fid, idx in self.waves:
            if name.startswith(pre) and (npc or not name.startswith(f"VO_{code}_NPC_")):
                files.setdefault(fid, {})[idx] = name[len(pre):]
        if not files:
            return []
        d = max(files.values(), key=len)
        return [d.get(i, "?") for i in range(max(d) + 1)]

    def bank_programs(self, code, npc):
        """{line name: program} for the voice sequences that play from a character's bank."""
        pre = f"VO_{code}_NPC_" if npc else f"VO_{code}_"
        out = {}
        for name, fid, label in self.seqs:
            if not name.startswith(pre) or (not npc and name.startswith(f"VO_{code}_NPC_")):
                continue
            seq = self.file_bytes(fid)
            code_at = u32(seq, 0x10) + 0x0C + label
            ops = seq[code_at:code_at + 16]
            if 0x81 in ops:  # program change
                out[name[len(pre):]] = ops[ops.index(0x81) + 1]
        return out


# ---------------------------------------------------------------- wave archives

def archive_offset(b):
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


def rms_db(pcm):
    return 20 * math.log10(max(1.0, math.sqrt(sum(v * v for v in pcm) / max(1, len(pcm)))) / 32768)


def write_wav(path, pcm, rate):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))


def encode_clip(pcm, rate, tmp, gain_db=0.0):
    src, mid, dsp = (os.path.join(tmp, x) for x in ("src.wav", "mid.wav", "out.dsp"))
    write_wav(src, pcm, rate)
    af = "aresample=resampler=soxr"
    if gain_db > 0.05:
        af = f"volume={gain_db:.2f}dB,alimiter=limit=0.97:level=false," + af
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", str(RATE),
                    "-af", af, "-c:a", "pcm_s16le", mid], check=True)
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


# ---------------------------------------------------------------- lines and banks

def rwsd_lines(b):
    """For each voice line of an RWSD, the clips it plays."""
    data = u32(b, 0x10); base = data + 8
    lines = []
    for i in range(u32(b, data + 8)):
        e = base + u32(b, data + 12 + 8 * i + 4)
        notes = base + u32(b, e + 0x14)
        lines.append([u32(b, base + u32(b, notes + 8 + 8 * j)) for j in range(u32(b, notes))])
    return lines


def bank_waves(b):
    """Program number -> clip number, for the single-clip programs voice banks use."""
    data = u32(b, 0x10); base = data + 8
    out = {}
    for i in range(u32(b, base)):
        kind, off = b[base + 4 + 8 * i + 1], u32(b, base + 4 + 8 * i + 4)
        if kind == 1:
            out[i] = u32(b, base + off)
    return out


def build_bank_header(n):
    """An RBNK with n programs, program i playing clip i, with the retail instrument settings."""
    table = struct.pack(">I", n) + b"".join(struct.pack(">BBHI", 1, 1, 0, 4 + 8 * n + 0x30 * i)
                                            for i in range(n))
    insts = b"".join(struct.pack(">I", i) + bytes.fromhex("7f7f7f78 7f000000 3c7f4000 3f800000")
                     + b"\0" * 0x1C for i in range(n))
    body = table + insts
    data = b"DATA" + struct.pack(">I", pad(8 + len(body))) + body
    data += b"\0" * (pad(len(data)) - len(data))
    head = b"RBNK" + struct.pack(">HHIHHII", 0xFEFF, 0x0102, 0x20 + len(data), 0x20, 1, 0x20, len(data))
    return head + b"\0" * (0x20 - len(head)) + data


class Pool:
    """Every clip a pack has for one voice file (main or opponent), by line name."""

    def __init__(self):
        self.clips = {}   # name -> (file bytes, clip offset): the pack's own lines
        self.picked = {}  # the same, from --set: used for exactly those lines

    def add(self, name, src, offset):
        self.clips.setdefault(name, (src, offset))

    def has(self, name):
        return name in self.clips or name in self.picked

    def find(self, name, fallback=None):
        if name in self.picked:
            return self.picked[name]
        m = VARIANT.match(name); base, tail = m.group(1), m.group(2) or ""
        tails = [tail, "", "2", "_END"]
        # stand-ins come from the pack's own clips first, so one --set pick
        # (say, every boost a "woohoo") doesn't spread to every event borrowing it
        for clips in (self.clips, self.picked):
            for cand in [base] + SUBSTITUTES.get(base, []):
                for t in tails:
                    if cand + t in clips:
                        return clips[cand + t]
        if fallback is not None:
            return fallback.find(name)
        raise KeyError(name)


def pack_files(voices):
    """{'PC.brwsd': path, ...} of a pack folder; also returns the character it was made for."""
    found, donors = {}, set()
    for p in sorted(glob.glob(os.path.join(voices, "*.brwsd")) + glob.glob(os.path.join(voices, "*.brbnk"))):
        stem, ext = os.path.splitext(os.path.basename(p))
        if re.match(r"\d+ ", stem):
            stem = stem.split(" ", 1)[1]
        m = re.match(r"GRP_VO_([A-Z]+)(?:-\d+)?_(.+)$", stem)
        if m:
            donors.add(m.group(1)); found[f"{m.group(2)}{ext}"] = p
    return found, donors


def build(a):
    sa = Brsar(a.sound_archive)
    files, donors = pack_files(a.voices)
    if not files:
        sys.exit(f"no voice files in {a.voices}")
    donor = (a.donor or (donors.pop() if len(donors) == 1 else sys.exit(
        f"voice files name several characters ({', '.join(sorted(donors))}): pass --donor"))).upper()
    read = lambda key: open(files[key], "rb").read() if key in files else None

    pools = {}
    for npc in (False, True):
        tag = "NPC" if npc else "PC"
        pool = Pool()
        wsd, bnk = read(f"{tag}.brwsd"), read(f"{tag}.brbnk")
        if wsd:
            names, lines, offs = sa.lines(donor, npc), rwsd_lines(wsd), clip_offsets(wsd)
            if len(names) != len(lines):
                sys.exit(f"{files[tag + '.brwsd']}: {len(lines)} lines, but {donor}'s {tag} file has {len(names)}")
            for name, clips in zip(names, lines):
                pool.add(name, wsd, offs[clips[0]])
        if bnk:
            waves, offs = bank_waves(bnk), clip_offsets(bnk)
            for name, prog in sa.bank_programs(donor, npc).items():
                if prog in waves and waves[prog] < len(offs):
                    pool.add(name, bnk, offs[waves[prog]])
        pools[tag] = pool
    # --set picks win over anything the pack had: LINE, LINE2, ... LINE_END in order
    main = read("PC.brwsd")
    for spec in a.set or []:
        line, nums = spec.split("=")
        picks, offs = [int(x) for x in nums.split(",")], clip_offsets(main)
        for i, n in enumerate(picks):
            name = line if i == 0 else f"{line}_END" if i == len(picks) - 1 else f"{line}{i + 1}"
            for pool in pools.values():
                pool.picked[name] = (main, offs[n])

    # one gain for the whole pack, so its lines keep their balance
    sample = [read_clip(*pools["PC"].clips[k]) for k in list(pools["PC"].clips)[:40]]
    level = sorted(rms_db(p) for p, _ in sample)[len(sample) // 2] if sample else a.loudness
    gain = max(0.0, a.loudness - level)

    os.makedirs(a.outdir, exist_ok=True)
    cache, keep = {}, []
    with tempfile.TemporaryDirectory() as tmp:
        def clip(src):
            # keyed by the source's identity, so every source stays referenced: a freed
            # file's id can be reused by the next one, which would return the wrong clip
            key = (id(src[0]), src[1])
            if key not in cache:
                keep.append(src[0])
                cache[key] = encode_clip(*read_clip(*src), tmp, gain)
            return cache[key]

        report = []
        for npc in (False, True):
            tag = "NPC" if npc else "PC"
            groups = sa.group_files(f"GRP_VO_{a.layout}_{tag}")
            names = sa.lines(a.layout, npc)
            template = groups["brwsd"]
            lines = rwsd_lines(template)
            line_of = {}
            for li, clips in enumerate(lines):
                for c in clips:
                    line_of.setdefault(c, li)
            fb = pools["PC"] if npc else None
            rw = []
            for c in range(len(clip_offsets(template))):
                name = names[line_of[c]]
                rw.append(clip(pools[tag].find(name, fb)))
                if not pools[tag].has(name) and (fb is None or not fb.has(name)):
                    report.append(f"{tag} {name}")
            out = template[:u32(template, 8)] + build_rwar(rw)
            open(os.path.join(a.outdir, f"{a.name}_{tag}.brwsd"), "wb").write(out)
            # the star shout comes from the bank, by the layout's own program numbers
            progs = sa.bank_programs(a.layout, npc)
            if progs:
                order = sorted(progs.items(), key=lambda x: x[1])
                n = max(progs.values()) + 1
                by_prog = {p: name for name, p in order}
                rw = [clip(pools[tag].find(by_prog.get(p, order[0][0]), fb)) for p in range(n)]
                open(os.path.join(a.outdir, f"{a.name}_{tag}.brbnk"), "wb").write(build_bank_header(n) + build_rwar(rw))
        # one-line files (finish lines, cannon) are the same event in every layout
        for key, path in files.items():
            stem, ext = os.path.splitext(key)
            if stem in ("PC", "NPC"):
                continue
            b = open(path, "rb").read()
            head = b[:u32(b, 8)]
            rw = [clip((b, o)) for o in clip_offsets(b)]
            open(os.path.join(a.outdir, f"{a.name}_{stem}{ext}"), "wb").write(head + build_rwar(rw))
    print(f"{a.name}: {donor} pack in {a.layout} layout, gain {gain:+.1f} dB"
          + (f"; stand-ins for {len(report)} lines: {', '.join(report)}" if report else ""))


# ---------------------------------------------------------------- commands

def cmd_clips(a):
    b = open(a.file, "rb").read()
    os.makedirs(a.outdir, exist_ok=True)
    offs = clip_offsets(b)
    for i, off in enumerate(offs):
        write_wav(os.path.join(a.outdir, f"{i:02d}.wav"), *read_clip(b, off))
    print(f"{len(offs)} clips -> {a.outdir}")


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
    b = sub.add_parser("build"); b.add_argument("voices"); b.add_argument("outdir")
    b.add_argument("--name", required=True); b.add_argument("--sound-archive", required=True)
    b.add_argument("--donor"); b.add_argument("--layout", default="MR")
    b.add_argument("--set", action="append"); b.add_argument("--loudness", type=float, default=-7.0)
    b.set_defaults(fn=build)
    x = sub.add_parser("clips"); x.add_argument("file"); x.add_argument("outdir"); x.set_defaults(fn=cmd_clips)
    l = sub.add_parser("lines"); l.add_argument("file"); l.set_defaults(fn=cmd_lines)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
