#!/usr/bin/env bash
# mkw-costume-installer - install Mario Kart Wii character mods as Retro Rewind
# costume slots, on any RMC* disc and either launcher.
#
# See README.md for the reasoning behind every rule enforced here.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; RESTORE=0; DO_VOICES=1; DO_MODELS=1
declare -a SLOTS=() RR_ROOTS=() DVD_ROOTS=() VOICE_DIRS=() VOICE_PICKS=()
BRSAR=""; SOUND_ARCHIVE=""
MKWVOICE="$SELF/tools/mkwvoice.py"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "  !! $*" >&2; }
log()  { echo "$*"; }
run()  { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }

usage() {
  cat <<'EOF'
usage: install.sh --slot CODE:VARIANT:/path/to/mod [--slot ...] [options]

  --slot CODE:VARIANT:DIR  character code (rs, fk, ...), costume slot number,
                           and the unpacked mod folder. Repeatable.
  --voices CODE:VARIANT:DIR  take that slot's voices from DIR instead of the
                           mod's own Voices folder. Repeatable.
  --pick CODE:VARIANT:LINE=N,N,...  choose that slot's clips for one voice line
                           yourself, as clip numbers of its PC voice file:
                           DSH = boost, STRM = star, WLE = wheelie, ...
                           (list clips: tools/mkwvoice.py clips). Repeatable.
  --rr-root DIR            a Retro Rewind install to patch (default: autodetect)
  --dvd-root DIR           an extracted disc (default: autodetect WiiCompiled's)
  --sound-archive FILE     the game's revo_kart.brsar, for its voice-line names
                           (default: the extracted disc's files/sound/revo_kart.brsar)
  --brsar FILE             legacy: a prepared revo_kart.brsar to install into
                           the disc (see README: tools/patch-brsar.ps1)
  --no-voices              models and icons only
  --no-models              voices only
  --restore                put the backed-up originals back and remove our files
  --dry-run                print what would happen, change nothing
  -h, --help               this text

example:
  ./install.sh --slot rs:1:"~/Downloads/Hatsune Miku" \
               --slot rs:2:"~/Downloads/Kasane Teto"
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --slot)      SLOTS+=("$2"); shift 2 ;;
    --voices)    VOICE_DIRS+=("$2"); shift 2 ;;
    --rr-root)   RR_ROOTS+=("$2"); shift 2 ;;
    --dvd-root)  DVD_ROOTS+=("$2"); shift 2 ;;
    --pick)      VOICE_PICKS+=("$2"); shift 2 ;;
    --brsar)     BRSAR="$2"; shift 2 ;;
    --sound-archive) SOUND_ARCHIVE="$2"; shift 2 ;;
    --no-voices) DO_VOICES=0; shift ;;
    --no-models) DO_MODELS=0; shift ;;
    --restore)   RESTORE=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# finding things
# ---------------------------------------------------------------------------

# WiiCompiled keeps its settings in UserData/Config.toml next to the install when
# portable.txt is present, otherwise under LOCALAPPDATA on Windows and
# $XDG_DATA_HOME/WiiCompiled on Linux (inside Wheel Wizard's Flatpak data folder
# when installed from Flathub). They carry the absolute path of the Retro Rewind
# tree it loads, which is the one worth patching.
wiicompiled_configs() {
  printf '%s\n' \
      "${WIICOMPILED:-}/UserData/Config.toml" \
      "$HOME"/Documents/*/Recomp/UserData/Config.toml \
      "$HOME"/Documents/*/*/Recomp/UserData/Config.toml \
      "${LOCALAPPDATA:-$HOME/AppData/Local}"/WiiCompiled/Config.toml \
      "${XDG_DATA_HOME:-$HOME/.local/share}"/WiiCompiled/Config.toml \
      "$HOME"/.var/app/io.github.TeamWheelWizard.WheelWizard/data/WiiCompiled/Config.toml
}

wiicompiled_roots() {
  local cfg rr
  while IFS= read -r cfg; do
    [ -f "$cfg" ] || continue
    rr=$(sed -n 's/^[[:space:]]*retro_rewind_root[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$cfg" | head -1)
    [ -n "$rr" ] && to_unix_path "$rr"
  done < <(wiicompiled_configs)
}

wiicompiled_dvd_roots() {
  local cfg d
  while IFS= read -r cfg; do
    [ -f "$cfg" ] || continue
    d=$(sed -n 's/^[[:space:]]*dvd_root[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$cfg" | head -1)
    [ -n "$d" ] || continue
    case "$d" in
      /*|[A-Za-z]:*) to_unix_path "$d" ;;
      # a relative dvd_root resolves against the folder holding Config.toml
      *) (cd "$(dirname "$cfg")" 2>/dev/null && cd "$d" 2>/dev/null && pwd) || true ;;
    esac
  done < <(wiicompiled_configs)
}

to_unix_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"
  else printf '%s\n' "$1" | sed 's|\\|/|g'; fi
}

find_rr_roots() {
  local d
  wiicompiled_roots
  # Dolphin, and anything laid out like an SD card
  for d in \
      "$HOME"/Documents/Dolphin*/Load/Riivolution/*/RetroRewind6 \
      "$HOME"/AppData/Roaming/Dolphin*/Load/Riivolution/*/RetroRewind6 \
      /[a-zA-Z]/*/User/Load/Riivolution/*/RetroRewind6 \
      /[a-zA-Z]/Riivolution/RetroRewind6 \
      /[a-zA-Z]/RetroRewind6 ; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

find_dvd_roots() {
  local d
  wiicompiled_dvd_roots
  for d in "$HOME"/Documents/*/Recomp/Install/GameAssets/DATA; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# A disc is fair game if its ID starts with RMC: that covers RMCE/RMCP/RMCJ/RMCK
# and custom distributions like RMCE51. Nothing this script installs is
# region-specific - the sound archive is byte-identical between a USA dump and
# WiiCompiled's PAL extract (verified by sha256) - so the ID is only reported.
disc_id() {
  local boot="$1/sys/boot.bin"
  [ -f "$boot" ] || return 1
  head -c 6 "$boot" | tr -d '\0'
}

# ---------------------------------------------------------------------------
# mod layout
# ---------------------------------------------------------------------------
# Mods from the main MKWii character-mod scene share a layout:
#   Race/<prefix>-<code>.szs   the 12 kart+bike models
#   <code>-allkart.szs         the character-select vehicle set (and _BT variant)
#   Driver/<code>_menu.brres   the menu/character-select model
#   Award/<code>.brres         award ceremony models (plus <code>3.brres)
#   Icons/*.png                menu/award icon and minimap icon
#   Voices/<id> GRP_VO_<CODE>_<TYPE>.<ext>   voice files, named by brsar index
first_existing() { local f; for f in "$@"; do [ -e "$f" ] && { printf '%s\n' "$f"; return 0; }; done; return 1; }

find_icon() { # $1 mod dir, $2 "minimap"|"menu"
  local d="$1" want="$2" f
  if [ "$want" = minimap ]; then
    f=$(ls "$d"/Icons/*[Mm]inimap*.png "$d"/Icons/*[Mm]ap*.png 2>/dev/null | head -1) || true
  else
    f=$(ls "$d"/Icons/*[Mm]enu*.png "$d"/Icons/*[Ii]con*.png 2>/dev/null | head -1) || true
  fi
  [ -z "${f:-}" ] && f=$(ls "$d"/Icons/*.png 2>/dev/null | head -1) || true
  printf '%s\n' "${f:-}"
}

need_tool() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH (Wiimms SZS Tools)"; }

# Voices are re-encoded, which needs Python 3, ffmpeg and dspenc.
PY=$(command -v python3 || command -v python || true)
need_voice_tools() {
  [ -n "$PY" ] || die "python3 not found (needed to convert voices; or pass --no-voices)"
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found (needed to convert voices; or pass --no-voices)"
  [ -x "${DSPENC:-}" ] || [ -x "$SELF/tools/bin/dspenc" ] || command -v dspenc >/dev/null 2>&1 \
    || die "dspenc not found - run tools/build-dspenc.sh once (or pass --no-voices)"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
[ ${#RR_ROOTS[@]} -gt 0 ] || mapfile -t RR_ROOTS < <(find_rr_roots | awk '!seen[$0]++')
[ ${#DVD_ROOTS[@]} -gt 0 ] || mapfile -t DVD_ROOTS < <(find_dvd_roots | awk '!seen[$0]++')
[ ${#RR_ROOTS[@]} -gt 0 ] || die "no Retro Rewind install found - pass --rr-root"

log "Retro Rewind installs:"; for r in "${RR_ROOTS[@]}"; do log "   $r"; done
if [ ${#DVD_ROOTS[@]} -gt 0 ]; then
  log "extracted discs:"
  for d in "${DVD_ROOTS[@]}"; do log "   $d  [$(disc_id "$d" || echo 'id?')]"; done
fi

if [ "$RESTORE" = 1 ]; then
  for R in "${RR_ROOTS[@]}"; do
    B="$R/_backup_preCostumes"
    [ -d "$B" ] || { warn "no backup in $R"; continue; }
    for sub in "" /AllKart /Driver /Map /Portrait /Sound; do
      [ -d "$B/Character$sub" ] || continue
      for f in "$B/Character$sub"/*; do
        [ -f "$f" ] && run cp "$f" "$R/Character$sub/"
      done
    done
    [ -f "$B/manifest.txt" ] && while IFS= read -r p; do
      [ -n "$p" ] || continue
      # Only ever delete files this script installs: Character/... or Patches/...,
      # never an absolute path or one that climbs out of the install.
      case "$p" in
        /*|*..*|*\\*) warn "skipping unsafe manifest entry: $p"; continue ;;
        Character/*|Patches/*) ;;
        *) warn "skipping unexpected manifest entry: $p"; continue ;;
      esac
      # Backups mirror the install layout ($B/Character/...), so a file that has
      # one was just restored above and must not be deleted.
      [ ! -f "$B/$p" ] && run rm -f "$R/$p"
    done < "$B/manifest.txt"
    log "restored $R"
  done
  exit 0
fi

[ ${#SLOTS[@]} -gt 0 ] || die "nothing to do - pass at least one --slot (try --help)"
[ "$DO_MODELS" = 1 ] && { need_tool wszst; need_tool wimgt; }
[ "$DO_VOICES" = 1 ] && need_voice_tools

# Voice-line names and layouts live in the game's sound archive.
if [ -z "$SOUND_ARCHIVE" ]; then
  for D in "${DVD_ROOTS[@]:-}"; do
    [ -f "$D/files/sound/revo_kart.brsar" ] && { SOUND_ARCHIVE="$D/files/sound/revo_kart.brsar"; break; }
  done
fi

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"/Character/{AllKart,Driver,Map,Portrait,Sound} "$STAGE"/Patches

for spec in "${SLOTS[@]}"; do
  CODE="${spec%%:*}"; rest="${spec#*:}"; VAR="${rest%%:*}"; MOD="${rest#*:}"
  MOD="${MOD/#\~/$HOME}"
  [ -d "$MOD" ] || die "mod folder not found: $MOD"
  [[ "$VAR" =~ ^[0-9]+$ ]] || die "variant must be a number: $spec"
  UCODE=$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]')
  log "-- $CODE-$VAR <- $(basename "$MOD")"

  if [ "$DO_MODELS" = 1 ]; then
    n=0
    for f in "$MOD"/Race/*-"$CODE".szs "$MOD"/*-"$CODE".szs; do
      [ -f "$f" ] || continue
      b=$(basename "$f"); stem="${b%-$CODE.szs}"
      case "$stem" in *allkart*) continue ;; esac
      run cp "$f" "$STAGE/Character/${stem}-${CODE}-${VAR}.szs"; n=$((n+1))
    done
    [ "$n" -gt 0 ] || warn "no race models found for code '$CODE'"

    if ak=$(first_existing "$MOD/$CODE-allkart.szs" "$MOD/Race/$CODE-allkart.szs"); then
      run cp "$ak" "$STAGE/Character/AllKart/${CODE}-${VAR}-allkart.szs"
    else warn "no $CODE-allkart.szs"; fi
    if akb=$(first_existing "$MOD/$CODE-allkart_BT.szs" "$MOD/Race/$CODE-allkart_BT.szs" 2>/dev/null); then
      run cp "$akb" "$STAGE/Character/AllKart/${CODE}-${VAR}-allkart_BT.szs"
    fi
    if dv=$(first_existing "$MOD/Driver/${CODE}_menu.brres" "$MOD/Driver/${CODE}.brres"); then
      run cp "$dv" "$STAGE/Character/Driver/${CODE}-${VAR}.brres"
    else warn "no menu model in Driver/"; fi

    # Icons are per costume: Retro Rewind shows Character/Portrait/<code>-<v>-css.tpl
    # on the costume's select screen and Character/Map/<code>-<v>.tpl on the
    # minimap, so the base character keeps its own icons.
    mini=$(find_icon "$MOD" minimap); menu=$(find_icon "$MOD" menu)
    [ -n "$mini" ] && run wimgt ENCODE "$mini" --dest "$STAGE/Character/Map/${CODE}-${VAR}.tpl" \
        --transform TPL.RGB5A3 --overwrite
    [ -n "$menu" ] && run wimgt ENCODE "$menu" --dest "$STAGE/Character/Portrait/${CODE}-${VAR}-css.tpl" \
        --transform TPL.RGB5A3 --overwrite
    # Award models are per character, not per costume: only the base slot supplies them.
    if [ "$VAR" = 1 ]; then
      for aw in "$MOD/Award/$CODE.brres" "$MOD/Award/${CODE}3.brres"; do
        [ -f "$aw" ] && run cp "$aw" "$STAGE/Patches/$(basename "$aw")"
      done
    fi
  fi

  # Voices may ship with the mod, or come from a different one entirely - Teto's
  # only existing voice pack is part of a mod that places her over Birdo.
  VOICEDIR="$MOD/Voices"
  for v in "${VOICE_DIRS[@]:-}"; do
    [ -n "$v" ] || continue
    vc="${v%%:*}"; vrest="${v#*:}"; vv="${vrest%%:*}"; vd="${vrest#*:}"
    [ "$vc" = "$CODE" ] && [ "$vv" = "$VAR" ] && VOICEDIR="${vd/#\~/$HOME}"
  done

  # --pick CODE:VARIANT:LINE=N,N,... for this slot
  declare -a PICKS=()
  for k in "${VOICE_PICKS[@]:-}"; do
    [ -n "$k" ] || continue
    kc="${k%%:*}"; krest="${k#*:}"; kv="${krest%%:*}"
    [ "$kc" = "$CODE" ] && [ "$kv" = "$VAR" ] && PICKS+=(--set "${krest#*:}")
  done

  if [ "$DO_VOICES" = 1 ] && [ -d "$VOICEDIR" ]; then
    # Retro Rewind reads a costume's voices in Mario's 78-line layout, whatever the
    # base character, so the whole set is rebuilt in that layout from the pack's
    # lines by name. See README: How it works.
    [ -n "$SOUND_ARCHIVE" ] || die "voices need the game's revo_kart.brsar for its voice-line names: pass --sound-archive"
    out="$STAGE/Character/Sound"
    if [ "$DRY" = 1 ]; then
      echo "    [dry-run] build voices from $VOICEDIR as GRP_VO_${UCODE}-${VAR}"
    else
      "$PY" "$MKWVOICE" build "$VOICEDIR" "$out" --name "GRP_VO_${UCODE}-${VAR}" \
          --sound-archive "$SOUND_ARCHIVE" ${PICKS[@]+"${PICKS[@]}"} | sed 's/^/   /'
    fi
  fi
done

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
for R in "${RR_ROOTS[@]}"; do
  [ -d "$R" ] || { warn "skipping missing $R"; continue; }
  B="$R/_backup_preCostumes"
  run mkdir -p "$B"/Character/{AllKart,Driver,Map,Portrait,Sound} "$R"/{Patches,MyStuff} \
      "$R"/Character/{AllKart,Driver,Map,Portrait,Sound}

  # MyStuff wins over Character\ for files that exist on the retail disc, so a
  # stale costume file left there silently masks everything installed below.
  M="$R/MyStuff"
  run rm -f "$M"/*-[a-z][a-z]-[0-9].szs "$M"/[a-z][a-z]-[0-9].brres "$M"/[a-z][a-z]-[0-9].tpl

  # Earlier versions of this installer put voices and the base character's icons in
  # Patches/. Patches/ is patched into the sound archive in place, where a voice
  # larger than its slot plays other sound data; the icons replaced the base
  # character's own. Remove those, but only files our previous manifest lists.
  if [ -f "$B/manifest.txt" ]; then
    while IFS= read -r p; do
      case "$p" in
        Patches/GRP_VO_*|Patches/[0-9]*.brwsd|Patches/[0-9]*.brbnk|Patches/tt_*_64x64.tpl|Patches/st_*_32x32.tpl)
          [ -f "$R/$p" ] && run rm -f "$R/$p" ;;
      esac
    done < "$B/manifest.txt"
  fi

  : > "$STAGE/manifest.txt"
  for sub in "" /AllKart /Driver /Map /Portrait /Sound; do
    for f in "$STAGE/Character$sub"/*; do
      [ -f "$f" ] || continue
      o="$R/Character$sub/$(basename "$f")"
      [ -f "$o" ] && [ ! -f "$B/Character$sub/$(basename "$f")" ] && run cp "$o" "$B/Character$sub/"
      echo "Character$sub/$(basename "$f")" >> "$STAGE/manifest.txt"
      run cp "$f" "$o"
    done
  done
  for f in "$STAGE/Patches"/*; do
    [ -f "$f" ] || continue
    echo "Patches/$(basename "$f")" >> "$STAGE/manifest.txt"
    run cp "$f" "$R/Patches/"
  done
  run cp "$STAGE/manifest.txt" "$B/manifest.txt"
  log "installed into $R  (Patches: $(ls "$R/Patches" 2>/dev/null | wc -l) files)"
done

# The base costume's voice can also come from a patched sound archive. Under
# WiiCompiled that is the ONLY route for it, because WiiCompiled mounts just the
# Retro Rewind pack patch - MyStuff is never mounted - so the archive has to go
# into the extracted disc itself.
if [ -n "$BRSAR" ]; then
  [ -f "$BRSAR" ] || die "--brsar file not found: $BRSAR"
  for D in "${DVD_ROOTS[@]}"; do
    t="$D/files/sound/revo_kart.brsar"
    [ -f "$t" ] || { warn "no sound archive under $D"; continue; }
    [ -f "$D/../revo_kart.brsar.orig" ] || run cp "$t" "$D/../revo_kart.brsar.orig"
    run cp "$BRSAR" "$t"
    log "installed sound archive into $D  (original kept as revo_kart.brsar.orig)"
  done
  for R in "${RR_ROOTS[@]}"; do run cp "$BRSAR" "$R/MyStuff/revo_kart.brsar"; done
fi

log "done"
