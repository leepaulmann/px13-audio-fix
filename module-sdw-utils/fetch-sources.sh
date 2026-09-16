#!/usr/bin/env bash
# Fetch sound/soc/sdw_utils from the linux-stable mirror for the RUNNING kernel,
# flatten it into ./src, apply the patches in ./patches and generate dkms.conf.
#
# Why this exists: the RESUME re-prepare fix (upstream 6fd1b9225de1, v7.3-rc1)
# lives in snd_soc_sdw_utils, a stock in-tree module, and kernels < 7.3 do not
# have it. The module only uses public headers, but its internals must match
# the running kernel exactly, so the sources are taken from the matching stable
# tag rather than carried in this repo.
#
#   ./fetch-sources.sh              # tag = v$(uname -r | cut -d- -f1)
#   SDW_UTILS_TAG=v7.2.3 ./fetch-sources.sh --force
#   ./fetch-sources.sh --record     # write SOURCES-<tag>.sha256 after reviewing
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/src"
KREL="${KVER:-$(uname -r)}"
TAG="${SDW_UTILS_TAG:-v${KREL%%-*}}"
MIRROR="${SDW_UTILS_MIRROR:-https://raw.githubusercontent.com/gregkh/linux}"
SUBDIR="sound/soc/sdw_utils"
MANIFEST="$HERE/SOURCES-$TAG.sha256"
FORCE=0 RECORD=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --record) RECORD=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

series() { local v="${1#v}"; echo "${v%.*}"; }   # 7.1.9 -> 7.1

HERE_LIB="$HERE/../lib/px13-detect.sh"
if [ "$FORCE" = 0 ] && [ -f "$HERE_LIB" ]; then
  # shellcheck source=../lib/px13-detect.sh
  . "$HERE_LIB"
  if px13_sdw_utils_has_resume_fix "$KREL"; then
    echo "$KREL: the in-tree snd_soc_sdw_utils already has the RESUME fix - nothing to build (--force to fetch anyway)"
    exit 0
  fi
fi

if [ "$(series "$TAG")" != "$(series "${KREL%%-*}")" ] && [ "$FORCE" = 0 ]; then
  echo "ERROR: tag $TAG is not the running kernel's series ($KREL); use --force" >&2
  exit 1
fi

fetch() { # $1 = path in the kernel tree, $2 = destination
  local url="$MIRROR/$TAG/$1"
  curl -fsSL --retry 3 --max-time 60 -o "$2" "$url" \
    || { echo "ERROR: cannot fetch $url" >&2; exit 1; }
}

echo "==> sdw_utils sources for $TAG -> $SRC"
rm -rf "$SRC"; mkdir -p "$SRC"
fetch "$SUBDIR/Makefile" "$SRC/Makefile.upstream"

# object list from the upstream Makefile: "snd-soc-sdw-utils-y := a.o b.o \ ..."
# (continuation lines joined until the first line without a trailing backslash)
OBJS=$(sed -n '/^snd-soc-sdw-utils-y/,/[^\\]$/p' "$SRC/Makefile.upstream" \
        | sed 's/^snd-soc-sdw-utils-y[[:space:]]*:\?=//; s/\\$//' | tr -s ' \t\n' ' ')
[ -n "$OBJS" ] || { echo "ERROR: no objects parsed from upstream Makefile" >&2; exit 1; }
echo "    objects: $OBJS"
echo "SDW_UTILS_OBJS := $OBJS" > "$SRC/objects.mk"

for o in $OBJS; do
  c="${o%.o}.c"
  fetch "$SUBDIR/$c" "$SRC/$c"
done

# quoted includes: same-dir headers are fetched as is; "../x/y.h" is fetched
# from its real location and the include rewritten to the flat layout.
resolve_includes() {
  local f="$1" inc path base
  { grep -oE '^#include[[:space:]]+"[^"]+"' "$f" || true; } | sed 's/.*"\(.*\)"/\1/' | while read -r inc; do
    base=$(basename "$inc")
    if [ ! -e "$SRC/$base" ]; then
      case "$inc" in
        ../*) path=$(realpath -m "$SUBDIR/$inc" --relative-to=. ) ;;
        *)    path="$SUBDIR/$inc" ;;
      esac
      echo "    header: $path"
      fetch "$path" "$SRC/$base"
      resolve_includes "$SRC/$base"
    fi
    [ "$inc" = "$base" ] || sed -i "s|#include[[:space:]]*\"$inc\"|#include \"$base\"|" "$f"
  done
}
for o in $OBJS; do resolve_includes "$SRC/${o%.o}.c"; done

if [ -f "$MANIFEST" ] && [ "$RECORD" = 0 ]; then
  ( cd "$SRC" && sha256sum -c --quiet "$MANIFEST" ) \
    || { echo "ERROR: fetched sources differ from $MANIFEST - the tag content drifted; review the patches, then rerun with --record" >&2; exit 1; }
  echo "    checksums OK ($MANIFEST)"
elif [ "$RECORD" = 1 ]; then
  ( cd "$SRC" && sha256sum *.c *.h objects.mk Makefile.upstream ) > "$MANIFEST"
  echo "    recorded $MANIFEST"
else
  echo "    NOTE: no $MANIFEST yet - review the fetched sources, then rerun with --record"
fi

echo "==> applying patches"
for p in "$HERE"/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "    $(basename "$p")"
  patch -p1 -d "$SRC" --no-backup-if-mismatch -s < "$p"
done

# dkms.conf: version = tag, BUILD_EXCLUSIVE_KERNEL = this series AND this
# kernel flavour only. A future series gets the stock module until this script
# is rerun for it. The flavour matters because distro kernels of the same
# series differ: linux-omarchy 7.2.5-3-omarchy carries the 7.3 SoundWire
# rework (other sdw_utils API, RESUME fix in-tree), so a series-only pin made
# DKMS build the Arch 7.2.3 sources there and fail on every kernel update.
# The flavour is the first alphabetic token of the release suffix
# (7.2.3-arch1-3 -> arch, 7.2.5-3-omarchy -> omarchy); a bare 7.2.3 pins the
# series with no suffix.
SER=$(series "$TAG")
SER_RE="${SER//./\\.}"
SUFFIX=""; case "$KREL" in *-*) SUFFIX="${KREL#*-}" ;; esac
FLAV="$(printf '%s' "$SUFFIX" | grep -oE '[A-Za-z]+' | head -1 || true)"
if [ -n "$FLAV" ]; then
  KRE="^${SER_RE}\\.[0-9]+-([0-9]+-)?${FLAV}[0-9.-]*\$"
else
  KRE="^${SER_RE}\\.[0-9]+\$"
fi
KRE_SED="$(printf '%s' "$KRE" | sed 's/[\\&|]/\\&/g')"
sed -e "s|@VERSION@|${TAG#v}|" -e "s|@KERNEL_REGEX@|$KRE_SED|" \
    "$HERE/dkms.conf.in" > "$HERE/dkms.conf"
echo "==> dkms.conf: $(grep -E 'PACKAGE_VERSION|BUILD_EXCLUSIVE' "$HERE/dkms.conf" | tr '\n' ' ')"
echo "done"
