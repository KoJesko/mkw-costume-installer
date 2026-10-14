#!/usr/bin/env bash
# mkw-costume-installer - install Mario Kart Wii character mods as Retro Rewind
# costume slots, on any RMC* disc and either launcher.
#
# See README.md for the reasoning behind every rule enforced here.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; RESTORE=0; DO_VOICES=1; DO_MODELS=1
declare -a SLOTS=() RR_ROOTS=() DVD_ROOTS=() VOICE_DIRS=()
BRSAR=""; ICON_NAME=""

# Character code -> the name retail uses in its UI/minimap textures. These are NOT
# the same string as the file code, and retail misspells some of them (Funky Kong's
# minimap really is "st_fuky_32x32.tpl"). Only codes verified against real game
# files are listed; anything else needs --icon-name.
icon_name_for() {
  case "$1" in
    rs) echo roseta ;;
    fk) echo fuky   ;;
    *)  echo ""     ;;
  esac
}

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
  --rr-root DIR            a Retro Rewind install to patch (default: autodetect)
  --dvd-root DIR           an extracted disc to patch the brsar into
                           (default: autodetect WiiCompiled's GameAssets/DATA)
  --brsar FILE             a prepared revo_kart.brsar to install for the BASE
                           costume's voice (see README: tools/patch-brsar.ps1)
  --icon-name NAME         UI texture name for the character (rs -> roseta)
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
    --brsar)     BRSAR="$2"; shift 2 ;;
    --icon-name) ICON_NAME="$2"; shift 2 ;;
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
# portable.txt is present, otherwise under LOCALAPPDATA. Both carry the absolute
# path of the Retro Rewind tree it loads, which is the one worth patching.
wiicompiled_roots() {
  local cfg rr
  for cfg in \
      "${WIICOMPILED:-}/UserData/Config.toml" \
      "$HOME"/Documents/*/Recomp/UserData/Config.toml \
      "$HOME"/Documents/*/*/Recomp/UserData/Config.toml \
      "${LOCALAPPDATA:-$HOME/AppData/Local}"/WiiCompiled/Config.toml ; do
    [ -f "$cfg" ] || continue
    rr=$(sed -n 's/^[[:space:]]*retro_rewind_root[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$cfg" | head -1)
    [ -n "$rr" ] && to_unix_path "$rr"
  done
}

wiicompiled_dvd_roots() {
  local cfg d
  for cfg in \
      "${WIICOMPILED:-}/UserData/Config.toml" \
      "$HOME"/Documents/*/Recomp/UserData/Config.toml \
      "$HOME"/Documents/*/*/Recomp/UserData/Config.toml ; do
    [ -f "$cfg" ] || continue
    d=$(sed -n 's/^[[:space:]]*dvd_root[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$cfg" | head -1)
    [ -n "$d" ] || continue
    case "$d" in
      /*|[A-Za-z]:*) to_unix_path "$d" ;;
      # a relative dvd_root resolves against the folder holding Config.toml
      *) (cd "$(dirname "$cfg")" 2>/dev/null && cd "$d" 2>/dev/null && pwd) || true ;;
    esac
  done
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
    for sub in "" /AllKart /Driver /Map; do
      [ -d "$B/Character$sub" ] || continue
      for f in "$B/Character$sub"/*; do
        [ -f "$f" ] && run cp "$f" "$R/Character$sub/"
      done
    done
    [ -f "$B/manifest.txt" ] && while IFS= read -r p; do
      [ -n "$p" ] && [ ! -f "$B/${p#Character}" ] && run rm -f "$R/$p"
    done < "$B/manifest.txt"
    log "restored $R"
  done
  exit 0
fi

[ ${#SLOTS[@]} -gt 0 ] || die "nothing to do - pass at least one --slot (try --help)"
[ "$DO_MODELS" = 1 ] && { need_tool wszst; need_tool wimgt; }

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"/Character/{AllKart,Driver,Map} "$STAGE"/Patches

BASE_VARIANT=""
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

    mini=$(find_icon "$MOD" minimap); menu=$(find_icon "$MOD" menu)
    if [ -n "$mini" ]; then
      run wimgt ENCODE "$mini" --dest "$STAGE/Character/Map/${CODE}-${VAR}.tpl" \
          --transform TPL.RGB5A3 --overwrite
    fi
    # Award models and the character-select icon are per-character, not
    # per-costume: the game has one of each, so only the base slot supplies them.
    if [ "$VAR" = 1 ]; then
      for aw in "$MOD/Award/$CODE.brres" "$MOD/Award/${CODE}3.brres"; do
        [ -f "$aw" ] && run cp "$aw" "$STAGE/Patches/$(basename "$aw")"
      done
      iname="${ICON_NAME:-$(icon_name_for "$CODE")}"
      if [ -n "$iname" ]; then
        [ -n "$menu" ] && run wimgt ENCODE "$menu" --dest "$STAGE/Patches/tt_${iname}_64x64.tpl" \
            --transform TPL.RGB5A3 --overwrite
        [ -n "$mini" ] && run wimgt ENCODE "$mini" --dest "$STAGE/Patches/st_${iname}_32x32.tpl" \
            --transform TPL.RGB5A3 --overwrite
      else
        warn "no UI texture name known for '$CODE' - icons skipped (pass --icon-name)"
      fi
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

  if [ "$DO_VOICES" = 1 ] && [ -d "$VOICEDIR" ]; then
    n=0
    for f in "$VOICEDIR"/*.brwsd "$VOICEDIR"/*.brbnk; do
      [ -f "$f" ] || continue
      b=$(basename "$f"); ext="${b##*.}"; stem="${b%.*}"
      # "<index> GRP_VO_<CODE>_<TYPE>" - the index is the file's slot in the sound
      # archive, and <CODE> is whoever the pack was authored over, not necessarily
      # the character we are installing onto.
      id="${stem%% *}"
      type="${stem#"$id "}"; type="${type#GRP_VO_}"; type="${type#*_}"
      if [ "$VAR" = 1 ] && [[ "$id" =~ ^[0-9]+$ ]]; then
        # Base costume: a whole-file override keyed by the file's brsar index,
        # which is the convention the mod authors document and the one Pulsar
        # resolves as /patches/<fileId>.<ext>. It does not depend on knowing how
        # the pack numbers its costumes.
        run cp "$f" "$STAGE/Patches/${id}.${ext}"
      else
        # Extra costumes get a per-variant voice, the form Retro Rewind ships
        # for its own alternate costumes.
        run cp "$f" "$STAGE/Patches/GRP_VO_${UCODE}-${VAR}_${type}.${ext}"
      fi
      n=$((n+1))
    done
    log "   $n voice files"
    [ "$VAR" = 1 ] && BASE_VARIANT=1
  fi
done

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
for R in "${RR_ROOTS[@]}"; do
  [ -d "$R" ] || { warn "skipping missing $R"; continue; }
  B="$R/_backup_preCostumes"
  run mkdir -p "$B"/Character/{AllKart,Driver,Map} "$R"/{Patches,MyStuff} "$R"/Character/{AllKart,Driver,Map}

  # MyStuff wins over Character\ for files that exist on the retail disc, so a
  # stale costume file left there silently masks everything installed below.
  M="$R/MyStuff"
  run rm -f "$M"/*-[a-z][a-z]-[0-9].szs "$M"/[a-z][a-z]-[0-9].brres "$M"/[a-z][a-z]-[0-9].tpl

  : > "$STAGE/manifest.txt"
  for sub in "" /AllKart /Driver /Map; do
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
