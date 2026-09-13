#!/bin/bash
# tc002-mkimage.sh: build a flashable UPDATE.img that boots the custom runtime persistently from
# the res partition. it takes a STOCK res (an update.img or a raw mtd3 dump), unpacks it, adds the
# runtime binaries + a static armv7 busybox + the boot scripts, repoints EasyUI.cfg at the
# bootstrap, keeps the stock libzkgui.so for the fallback, repacks the squashfs and wraps it in the
# ZKSWEV1.0 container. the whole flash story and the cold-boot reasoning are in ../../FIRMWARE.md.
#
#   TC002_BUSYBOX=/path/to/armv7-static-busybox \
#   runtime/tools/tc002-mkimage.sh <stock-res: update.img|mtd3.bin> <out UPDATE.img> [workdir]
#
# needs: zig 0.16 on PATH (or ZIG=/path/to/zig), mksquashfs/unsquashfs (squashfs-tools), python3.
# a static armv7 busybox is not vendored; get one with `docker create busybox:musl` + `docker cp`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$RUNTIME/.." && pwd)
ZIG=${ZIG:-zig}
MKIMG="$ROOT/tc002-update-img.py"

[ $# -ge 2 ] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
STOCK=$1; OUT=$2; WORK=${3:-$(mktemp -d)}
: "${TC002_BUSYBOX:?set TC002_BUSYBOX to a static armv7 busybox}"
[ -f "$TC002_BUSYBOX" ] || { echo "busybox not found: $TC002_BUSYBOX" >&2; exit 1; }
command -v mksquashfs >/dev/null || { echo "need squashfs-tools (mksquashfs)" >&2; exit 1; }
say() { echo "== $*"; }

say "build the runtime for the image (/res/bin layout)"
( cd "$RUNTIME" && "$ZIG" build -Dsupervisor_path=/res/bin/tc002-supervisor -Dbin_dir=/res/bin && "$ZIG" build check -Dsupervisor_path=/res/bin/tc002-supervisor -Dbin_dir=/res/bin )

RES="$WORK/res-root"; rm -rf "$RES"; mkdir -p "$WORK"
say "unpack the stock res from $STOCK"
# accept either an update.img (squashfs starts partway in) or a raw squashfs/mtd dump (starts at 0)
if python3 "$MKIMG" inspect "$STOCK" >/dev/null 2>&1; then
    python3 "$MKIMG" unpack "$STOCK" "$WORK/stock-res.sqsh"
    SRC="$WORK/stock-res.sqsh"
else
    SRC="$STOCK"   # already a squashfs (e.g. a raw mtd3 dump; unsquashfs reads the superblock)
fi
unsquashfs -f -d "$RES" "$SRC" >/dev/null

say "add the runtime, busybox and the boot scripts; keep the stock libzkgui.so"
cp "$RUNTIME"/zig-out/bin/tc002-supervisor "$RUNTIME"/zig-out/bin/tc002d \
   "$RUNTIME"/zig-out/bin/tc002-netd "$RUNTIME"/zig-out/bin/tc002-ntfy "$RES/bin/"
cp "$TC002_BUSYBOX" "$RES/bin/busybox"
cp "$RUNTIME"/boot/tc002-netup.sh "$RUNTIME"/boot/tc002-udhcpc.script "$RES/bin/"
cp "$RUNTIME"/zig-out/lib/libtc002-bootstrap.so "$RES/lib/"
[ -f "$RES/lib/libzkgui.so" ] || { echo "stock libzkgui.so missing from res — wrong stock image?" >&2; exit 1; }

say "point EasyUI.cfg at the bootstrap (new file; no in-place mode change)"
sed 's#"startupLibPath":"/res/lib/libzkgui.so"#"startupLibPath":"/res/lib/libtc002-bootstrap.so"#' \
    "$RES/etc/EasyUI.cfg" > "$WORK/EasyUI.cfg" && cat "$WORK/EasyUI.cfg" > "$RES/etc/EasyUI.cfg"
grep -q libtc002-bootstrap "$RES/etc/EasyUI.cfg" || { echo "failed to repoint EasyUI.cfg" >&2; exit 1; }

# 0755 on the added files AND the directories: netd/ntfy run as uid 1001 and must traverse /res/bin
# and exec their binaries, which a stock 0770 (owned 1000:1000) forbids for a non-owner. root (the
# renderer, the loader) is unaffected either way. see FIRMWARE.md.
say "set 0755 on the runtime files and the res directories"
chmod 0755 "$RES"/bin/tc002-supervisor "$RES"/bin/tc002d "$RES"/bin/tc002-netd "$RES"/bin/tc002-ntfy \
          "$RES"/bin/busybox "$RES"/bin/tc002-netup.sh "$RES"/bin/tc002-udhcpc.script "$RES"/lib/libtc002-bootstrap.so
chmod 0755 "$RES" "$RES/bin" "$RES/lib" "$RES/etc"

say "repack squashfs (xz, 128K, uid/gid 1000, no xattrs) and wrap in the ZKSWEV1.0 container"
rm -f "$WORK/res.sqsh"
mksquashfs "$RES" "$WORK/res.sqsh" -comp xz -b 131072 -no-xattrs -force-uid 1000 -force-gid 1000 -noappend >/dev/null
SZ=$(stat -c%s "$WORK/res.sqsh"); LIMIT=$((0x800000))
echo "   res.sqsh $SZ bytes (mtd3 limit $LIMIT)"
[ "$SZ" -le "$LIMIT" ] || { echo "image exceeds the res partition!" >&2; exit 1; }
python3 "$MKIMG" pack "$WORK/res.sqsh" "$OUT"
python3 "$MKIMG" inspect "$OUT" | tail -1
echo
echo "built $OUT — flash it per FIRMWARE.md (no-op rehearsal first; go to the stock loader, then"
echo "setprop sys.zkupgrade.dir /tmp; setprop sys.zkupgrade.flag 255; restart zkswe)."
