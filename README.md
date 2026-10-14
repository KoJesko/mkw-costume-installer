# mkw-costume-installer

Installs Mario Kart Wii character mods as **Retro Rewind costume slots**, with their
voices, on any `RMC*` disc and under either launcher (Dolphin + Riivolution, or
WiiCompiled).

Two characters can share one base character's slots — one on costume 1, another on
costume 2 — instead of fighting over the same files. The installer also handles the
part that usually goes wrong: getting the **voices** to actually play.

> This repository contains scripts only. **No mod files and no game data are
> included or redistributed.** Download the mods from their authors, below.

---

## Credits

Everything this tool installs was made by other people. Please go give them a look.

### Character mods

| Mod | Authors | Notes |
|---|---|---|
| **Hatsune Miku** v1.7.1 | **Monxy**, **TailsCraft** & **King of Moe** | Goes over Rosalina on all vehicles. Custom icons, character-select model, award ceremony model, LOD models, vehicle recolors (v1.5+), custom voices (v1.7+). Based on her appearance in *Sonic Racing: CrossWorlds*. |
| ↳ Miku voice files | **Eydra** | Credited on the mod page for the voice files in v1.7, and the author of the voice install instructions bundled with the mod. |
| **Kasane Teto** v1.0 | **Monxy**, **TailsCraft** & **King of Moe** | Goes over Rosalina on all vehicles. Vehicle recolors, custom icons, character-select model, award ceremony model, LOD models. |
| ↳ Teto voice files | **BongoTheVocamotive** | From a *separate* Teto mod — [Kasane Teto Character Mod for MKWii](https://gamebanana.com/mods/634501) — which places Teto over **Birdo**. Its clips mostly came from the Teto mod for SM64, with the rest made in SynthV. |

Both character mods are documented on the Custom Mario Kart wiki, which carries their
Google Drive downloads:

- Hatsune Miku — <https://mkwiiki.org/wiki/Hatsune_Miku_(Monxy,_TailsCraft_%26_King_of_Moe)>
- Kasane Teto — <https://mkwiiki.org/wiki/Kasane_Teto_(Monxy,_TailsCraft_%26_King_of_Moe)>

The Miku page also offers an **"Additional `revo_kart.brsar`"** download — a
pre-patched sound archive. If you want her voice on the base costume and your pack
has no Patches support, grab that instead of building one yourself.

Character designs are the property of their respective owners — the mod pages list
Crypton Future Media, Sonic Team and SEGA.

### Projects this builds on

| Project | By | Link |
|---|---|---|
| **Retro Rewind** | ZPL and contributors | the distribution these costumes install into |
| **WiiCompiled** | **Patchzy** — a native PC port of Mario Kart Wii via static recompilation | <https://github.com/patchzyy/Wiicompiled> |
| **Wheel Wizard** | **Patchzy** and **WantToBeeMe**, with Ruben, Lasagna, Matellush and Jamie | installs and updates Retro Rewind |
| **Wiimms SZS / ISO Tools** | **Wiimm** | `wszst`, `wimgt`, `wit` | 
| **BrawlCrate** (and the BrawlLib it ships) | the BrawlCrate project | <https://github.com/soopercool101/BrawlCrate> |

---

## Requirements

- `bash` — Git Bash on Windows, or any Linux/macOS shell
- [Wiimms SZS Tools](https://szs.wiimm.de/) for `wszst` and `wimgt`, on your `PATH`
- A Retro Rewind install
- Only for building a sound archive yourself: BrawlCrate, and 32-bit PowerShell

## Usage

```bash
./install.sh --slot rs:1:"~/Downloads/Hatsune Miku" \
             --slot rs:2:"~/Downloads/Kasane Teto"
```

`--slot CODE:VARIANT:DIR` — the character code (`rs` is Rosalina), the costume slot,
and the unpacked mod folder. Repeat it for each costume.

The installer finds your Retro Rewind install on its own: it reads WiiCompiled's
`Config.toml` for the tree that launcher actually loads, and looks in the usual
Dolphin and SD-card locations. Override with `--rr-root`. Use `--dry-run` to see
what it would do, and `--restore` to put the originals back.

Mods are expected in the layout the MKWii character-mod scene uses — `Race/`,
`Driver/`, `Award/`, `Icons/`, `Voices/`, and `<code>-allkart.szs`. Both mods above
follow it.

### Voices

Voices install automatically when the mod has a `Voices/` folder, by whichever route
is correct for that slot:

- **Costume 1** (the base character) gets **whole-file overrides named by index** —
  `94.brwsd`, `471.brbnk` — the convention the mod authors document and the one the
  engine resolves as `/patches/<fileId>.<ext>`. It does not depend on knowing how a
  pack numbers its costumes.
- **Costume 2 and up** get `GRP_VO_<CODE>-<variant>_<TYPE>.<ext>`, the form Retro
  Rewind ships for its own alternate costumes.

If a voice still does not play, run the fit checker before anything else:

```powershell
powershell -File tools\slot-fit.ps1 -Brsar <revo_kart.brsar> -Dir <RetroRewind6\Patches>
```

---

## How it works, and why

Notes from getting this working, since most of it is not written down anywhere.

**Retro Rewind never loads the disc's base character files.** It ships only costume
variants and always resolves one: `Character/<kart>-<code>-<v>.szs`,
`Character/AllKart/<code>-<v>-allkart.szs`, `Character/Driver/<code>-<v>.brres`,
`Character/Map/<code>-<v>.tpl`. Dropping a model in as the plain base name does
nothing.

**MyStuff outranks `Character\`, which makes it a trap.** It replaces files by name,
but only names that exist on the retail disc — so costume variants there are inert,
while a stale leftover silently masks a correct install. The installer clears those
on every run.

**A model may only go over the character it was built for.** Putting a
Rosalina-rigged model on Funky Kong crashes with an invalid read even when the
animation sets match exactly, because the models carry different weights — Rosalina's
has ten textures against Funky's five.

**Voices are patched into the sound archive in place, so they have to fit.** Each
loose file needs both halves inside the slot the archive reserves: its own declared
header size, and the size of the `RWAR` wave block that follows. Overflow is handled,
not fatal — the engine bounds-checks first and either allocates an external buffer or
drops that one override — so it surfaces as a wrong or missing clip. A voice pack cut
for one character rarely fits another's slots: Teto's files were authored over Birdo,
and five of fifteen overflowed Rosalina's.

A pack's own archive is the exception. Build the brsar from the same files you install
loose and every slot is sized to fit them exactly, because that is where the sizes
came from.

**Rosalina's `CAN_PC` group is empty on retail** — a 64-byte header and a 96-byte wave
section, the only stub in the whole archive. Her cannon yell plays from the main `PC`
bank. Forcing a foreign file into that group is the one genuinely risky move here: the
game would index wave entries that are not there, which is a crash, not an overflow.

**WiiCompiled mounts only Retro Rewind's pack patch.** Its log says
`1 active patch(es)`, which means `MyStuff\` is never mounted and anything placed
there is ignored. It also boots from an extracted disc, not an ISO, so a patched
sound archive has to be written into `Install/GameAssets/DATA/files/sound/`. The
`--brsar` flag does that, keeping the original alongside it.

---

## Compatibility

Region-agnostic by construction: nothing it installs is region-specific. The sound
archive in particular is **byte-identical** between a USA dump and WiiCompiled's PAL
extract (same SHA-256), and character models, driver models and award models are the
same across discs.

- **Tested:** `RMCP01` under WiiCompiled, `RMCE01` under Dolphin with Riivolution.
- **Expected to work, untested:** `RMCJ01`, `RMCK01`, and custom distributions whose
  ID starts with `RMC`.
- WiiCompiled itself only accepts a clean `RMCP01` dump — that is its restriction,
  upstream, not this script's.

Character-select and minimap textures are named per character inside the game's UI
archives, and retail misspells some of them (Funky Kong's minimap really is
`st_fuky_32x32.tpl`). Only names verified against real game files are built in —
`rs` → `roseta`, `fk` → `fuky`. For any other character, pass `--icon-name`.

## License

Scripts are MIT, see [LICENSE](LICENSE). That covers this repository only — the mods,
the game and every project listed above belong to their respective authors.
