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
- A Retro Rewind install, 6.13.5 or newer (costume voices and icons)
- For voices: Python 3, `ffmpeg`, and `dspenc`. Build `dspenc` once with
  `tools/build-dspenc.sh` (it downloads and compiles
  [gc-dspadpcm-encode](https://github.com/jackoalan/gc-dspadpcm-encode), MIT).

## Usage

```bash
./install.sh --slot rs:1:"~/Downloads/Hatsune Miku" \
             --slot rs:2:"~/Downloads/Kasane Teto" \
             --voices rs:2:"~/Downloads/Teto over Birdo/Voices" \
             --pick rs:2:DSH=3,4,9,13,3,4 --pick rs:2:STRM=6,53,6
```

`--slot CODE:VARIANT:DIR` — the character code (`rs` is Rosalina), the costume slot,
and the unpacked mod folder. Repeat it for each costume.

The installer finds your Retro Rewind install on its own: it reads WiiCompiled's
`Config.toml` for the tree that launcher actually loads (on Windows, and on Linux
including Wheel Wizard's Flatpak), and looks in the usual Dolphin and SD-card
locations. Override with `--rr-root`. Use `--dry-run` to see what it would do, and
`--restore` to put the originals back.

Mods are expected in the layout the MKWii character-mod scene uses — `Race/`,
`Driver/`, `Award/`, `Icons/`, `Voices/`, and `<code>-allkart.szs`. Both mods above
follow it.

### Icons

Each costume gets its own icons: `Character/Portrait/<code>-<v>-css.tpl` on the
character-select screen and `Character/Map/<code>-<v>.tpl` on the minimap. The base
character keeps its stock icons.

### Voices

Voices install when the mod has a `Voices/` folder, or from `--voices`. The installer
builds the costume's whole voice set into `Character/Sound/` as
`GRP_VO_<CODE>-<variant>_<TYPE>.<ext>`, where Retro Rewind loads costume voices:

- **In Mario's layout.** Retro Rewind reads a costume's voice file as Mario's 78-line
  file (the layout most characters share), whatever the base character: a Rosalina
  costume's line 31 is Mario's second wheelie line, not Rosalina's. Packs come in their
  character's own layout (Rosalina's has 48 lines, Birdo's 54), so every line is
  filled by name from the game's sound archive: `VO_RS_DMG_L` goes to Mario's
  `DMG_L`. Lines the pack keeps in its voice bank, like Rosalina's boost shouts, are
  taken from there.
- **Missing events get the closest line the pack has.** Rosalina never had landing or
  item-throw lines; Birdo has no wheelie or rocket-start lines. The installer prints
  which lines got a stand-in.
- **In the game's format.** Every clip is re-encoded to mono 16 kHz, and a pack quieter
  than the game's voices is raised to match, with a limiter so nothing clips.

The installer reads the line names from the extracted disc's `revo_kart.brsar`, or from
`--sound-archive`.

To choose clips yourself, export a pack's clips, listen, and pass their numbers with
`--pick`, one per variant of the line (most lines have 3, the boost shout `DSH` has 6):

```bash
python3 tools/mkwvoice.py clips "<Voices>/659 GRP_VO_CA_PC.brwsd" clips/
./install.sh ... --pick rs:2:DSH=3,4,9,13,3,4 --pick rs:2:STRM=6,53,6
```

`DSH` is the boost shout, `STRM` the star, `WLE` a wheelie and `WLE_FAIL` a wheelie
that is cancelled, like the wiggle at the start line. A pick only replaces that line:
events that borrow it as a stand-in still use the pack's own clips.

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

**Voice files in `Patches/` are patched into the sound archive in place, and an
oversized one plays other sounds.** Earlier versions of this installer put voices
there. Mod voice packs are often stereo 48 kHz, while the game's voices are mono
16 kHz: Miku's main voice file was 3.4 MB against Rosalina's 410 KB slot. Clips past
the slot point into whatever sound data follows, so one event played a mix of
unrelated sounds. Retro Rewind 6.13.5 loads costume voices from `Character/Sound/`
instead, and the installer now re-encodes them to the game's format (Miku's main file
is 583 KB). It also removes what earlier versions left in `Patches/`, if its manifest
lists them.

**Voice lines are picked by position, and Retro Rewind uses Mario's positions.** Found
with diagnostic voice files whose every line says its own number: the start-line wiggle
played lines 31 and 33 (Mario's `WLE2` and `WLE_FAIL`) and the costume select 4 and 5
(`DSH2`, `DSH3`). Rosalina's own file has 48 lines and Birdo's 54, each in its own
order, so a pack installed as it is plays the wrong line for most events. Retro
Rewind's own Rosalina costumes ship Mario's voice file (`GRP_VO_RS-3_PC.brwsd.mario`).

**The star shout is a sequence.** Mario's star shout plays programs 0-2 of his voice
bank (`STRM`), and his boost shouts are ordinary lines. Rosalina is the odd one out:
her boost shouts are bank programs 3-8, which is where her packs keep them.

**Rosalina's `CAN_PC` group is empty on retail** — a 64-byte header and a 96-byte wave
section, the only stub in the whole archive. Her cannon yell plays from the main `PC`
bank.

**WiiCompiled mounts only Retro Rewind's pack patch.** Its log says
`1 active patch(es)`, which means `MyStuff\` is never mounted and anything placed
there is ignored. It also boots from an extracted disc, not an ISO, so a patched
sound archive has to be written into `Install/GameAssets/DATA/files/sound/`. The
`--brsar` flag does that, keeping the original alongside it. With Retro Rewind
6.13.5's `Character/Sound/` this is no longer needed for costume voices.

---

## Compatibility

Region-agnostic by construction: nothing it installs is region-specific. The sound
archive in particular is **byte-identical** between a USA dump and WiiCompiled's PAL
extract (same SHA-256), and character models, driver models and award models are the
same across discs.

- **Tested:** models on `RMCP01` under WiiCompiled and `RMCE01` under Dolphin with
  Riivolution. Voices and costume icons: Miku (a Rosalina pack) and Teto (a Birdo pack)
  over Rosalina on Retro Rewind 6.13.5 under WiiCompiled on Linux, played in races.
  Only Rosalina costumes have been tried; other characters should work the same way.
- **Expected to work, untested:** `RMCJ01`, `RMCK01`, and custom distributions whose
  ID starts with `RMC`.
- WiiCompiled itself only accepts a clean `RMCP01` dump — that is its restriction,
  upstream, not this script's.

`tools/slot-fit.ps1` and `tools/patch-brsar.ps1` are for the older in-place route
(`Patches/` and a patched `revo_kart.brsar`). The installer no longer needs them.

## License

Scripts are MIT, see [LICENSE](LICENSE). That covers this repository only — the mods,
the game and every project listed above belong to their respective authors.
