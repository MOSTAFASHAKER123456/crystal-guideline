#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# patch.sh — Crystal Official  |  Modded APK Builder
# Usage:  ./patch.sh <game.apk>
#
# Termux dependencies (run once):
#   pkg install apktool openjdk-17 zipalign apksigner python3
#   pkg install aapt  # optional, for manifest inspection
#
# Output:  dist/crystal_patched_signed.apk  (ready to install)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── colour helpers ───────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'
ok()   { echo -e "${GRN}[✓]${RST} $*"; }
info() { echo -e "${BLU}[i]${RST} $*"; }
warn() { echo -e "${YLW}[!]${RST} $*"; }
die()  { echo -e "${RED}[✗]${RST} $*" >&2; exit 1; }

BANNER=$(cat <<'EOF'
  ██████╗██████╗ ██╗   ██╗███████╗████████╗ █████╗ ██╗
 ██╔════╝██╔══██╗╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔══██╗██║
 ██║     ██████╔╝ ╚████╔╝ ███████╗   ██║   ███████║██║
 ██║     ██╔══██╗  ╚██╔╝  ╚════██║   ██║   ██╔══██║██║
 ╚██████╗██║  ██║   ██║   ███████║   ██║   ██║  ██║███████╗
  ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝
           Official Mod Builder v2.0  |  arm64-v8a
EOF
)
echo -e "${CYN}${BANNER}${RST}"

# ─── argument ─────────────────────────────────────────────────
APK_IN="${1:-}"
[[ -z "$APK_IN" ]] && die "Usage: ./patch.sh <game.apk>"
[[ ! -f "$APK_IN" ]] && die "APK not found: $APK_IN"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/dist/work"
DECOMPILED="$WORK_DIR/decompiled"
SO_SRC="$SCRIPT_DIR/dist/libcrystal_guideline.so"          # compiled by build.sh
SMALI_SRC="$SCRIPT_DIR/smali/com"
KEYSTORE="$SCRIPT_DIR/keystore/crystal.jks"
APK_UNSIGNED="$WORK_DIR/crystal_unsigned.apk"
APK_ALIGNED="$WORK_DIR/crystal_aligned.apk"
APK_OUT="$SCRIPT_DIR/dist/crystal_patched_signed.apk"

# ─── dependency check ─────────────────────────────────────────
info "Checking dependencies…"
for cmd in apktool java zipalign apksigner python3; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Missing: $cmd  →  pkg install ${cmd} (or brew install ${cmd})"
done
ok "All dependencies found"

# ─── compiled .so check ───────────────────────────────────────
if [[ ! -f "$SO_SRC" ]]; then
    warn "libcrystal_guideline.so not found at $SO_SRC"
    warn "Run ./build.sh first to compile the native library."
    die  "Missing .so — can't continue"
fi
ok "libcrystal_guideline.so found ($(du -sh "$SO_SRC" | cut -f1))"

# ─── clean workspace ──────────────────────────────────────────
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$SCRIPT_DIR/dist"

# ═══════════════════════════════════════════════════════════════
# STEP 1: DECOMPILE
# ═══════════════════════════════════════════════════════════════
info "Step 1/7 — Decompiling APK with apktool…"
apktool d "$APK_IN" -o "$DECOMPILED" \
    || die "apktool failed to decompile"
chmod -R 755 "$DECOMPILED"
ok "Decompiled to $DECOMPILED"

# ═══════════════════════════════════════════════════════════════
# STEP 2: FIND APPLICATION CLASS + INJECT loadLibrary
# ═══════════════════════════════════════════════════════════════
info "Step 2/7 — Finding Application class…"

MANIFEST="$DECOMPILED/AndroidManifest.xml"
[[ ! -f "$MANIFEST" ]] && die "AndroidManifest.xml not found after decompile"

# Parse android:name on <application> tag
APP_CLASS=$(python3 - <<'PYEOF'
import re, sys

with open(sys.argv[1]) as f:
    content = f.read()

# Match android:name inside <application ... > block
m = re.search(r'<application[^>]+android:name="([^"]+)"', content)
if m:
    cls = m.group(1)
    # Handle relative class names (.MyApp → com.mobile.legends.MyApp)
    if cls.startswith('.'):
        pkg_m = re.search(r'package="([^"]+)"', content)
        if pkg_m:
            cls = pkg_m.group(1) + cls
    print(cls)
else:
    print("NOT_FOUND")
PYEOF
"$MANIFEST")

if [[ "$APP_CLASS" == "NOT_FOUND" || -z "$APP_CLASS" ]]; then
    warn "No custom Application class found — will inject into launcher Activity"
    INJECT_TARGET="ACTIVITY"
else
    ok "Application class: $APP_CLASS"
    INJECT_TARGET="APPLICATION"
fi

# Convert class name to smali path  (com.mobile.legends.App → com/mobile/legends/App)
to_smali_path() {
    echo "${1//./\/}.smali"
}

# Search for the smali file across all smali dirs (multidex support)
find_smali_file() {
    local target_path="$1"
    for dir in "$DECOMPILED"/smali*/; do
        local f="$dir/$target_path"
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

if [[ "$INJECT_TARGET" == "APPLICATION" ]]; then
    SMALI_REL=$(to_smali_path "$APP_CLASS")
    TARGET_SMALI=$(find_smali_file "$SMALI_REL") \
        || die "Smali file not found for $APP_CLASS (path: $SMALI_REL)"
    ok "Target smali: $TARGET_SMALI"
else
    # Find launcher activity from manifest
    LAUNCHER_ACT=$(python3 - <<'PYEOF'
import re, sys

with open(sys.argv[1]) as f:
    content = f.read()

pkg_m = re.search(r'package="([^"]+)"', content)
pkg = pkg_m.group(1) if pkg_m else ""

# Find activity with MAIN + LAUNCHER intent
pattern = r'<activity[^>]+android:name="([^"]+)"[^>]*>.*?android\.intent\.action\.MAIN.*?android\.intent\.category\.LAUNCHER'
m = re.search(pattern, content, re.DOTALL)
if not m:
    # Try reversed order
    pattern2 = r'<activity[^>]+android:name="([^"]+)"[^>]*>.*?android\.intent\.category\.LAUNCHER.*?android\.intent\.action\.MAIN'
    m = re.search(pattern2, content, re.DOTALL)

if m:
    cls = m.group(1)
    if cls.startswith('.'):
        cls = pkg + cls
    print(cls)
else:
    print("NOT_FOUND")
PYEOF
"$MANIFEST")

    [[ "$LAUNCHER_ACT" == "NOT_FOUND" ]] && die "Cannot find launcher Activity in manifest"
    SMALI_REL=$(to_smali_path "$LAUNCHER_ACT")
    TARGET_SMALI=$(find_smali_file "$SMALI_REL") \
        || die "Smali file not found for $LAUNCHER_ACT"
    ok "Launcher Activity smali: $TARGET_SMALI"
fi

# ── The actual smali injection ────────────────────────────────
# Inject before invoke-super in onCreate()V
# If onCreate doesn't exist, we append it.

INJECT_SNIPPET='
    const-string v0, "crystal_guideline"
    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V
    invoke-static {p0}, Lcom/crystal/CrystalGuideline;->init(Landroid/content/Context;)V'

python3 - "$TARGET_SMALI" "$INJECT_SNIPPET" "$INJECT_TARGET" <<'PYEOF'
import sys, re

smali_path = sys.argv[1]
snippet    = sys.argv[2]
mode       = sys.argv[3]   # APPLICATION or ACTIVITY

with open(smali_path) as f:
    content = f.read()

# Check if .locals 0 needs bumping — our snippet uses v0
# We'll ensure .locals is at least 1 in the onCreate method

ON_CREATE_SIG = ".method public onCreate()V" if mode == "APPLICATION" \
    else ".method public onCreate(Landroid/os/Bundle;)V"

if ON_CREATE_SIG not in content:
    # No onCreate — append one
    print(f"[patch.py] No {ON_CREATE_SIG} found — injecting fresh method", file=sys.stderr)
    if mode == "APPLICATION":
        new_method = f"""
{ON_CREATE_SIG}
    .locals 1
    invoke-super {{p0}}, Landroid/app/Application;->onCreate()V
{snippet}
    return-void
.end method
"""
    else:
        new_method = f"""
{ON_CREATE_SIG}
    .locals 2
    invoke-super {{p0, p1}}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V
{snippet}
    return-void
.end method
"""
    # Insert before last .end class
    content = content.rstrip()
    if content.endswith(".end class"):
        content = content[: -len(".end class")].rstrip() + "\n" + new_method + "\n.end class\n"
    else:
        content += "\n" + new_method
else:
    # Find the method and patch inside it
    # First ensure .locals >= 1
    def bump_locals(block):
        def fix(m):
            n = int(m.group(1))
            return f".locals {max(n, 1)}"
        return re.sub(r'\.locals (\d+)', fix, block, count=1)

    # Split out the onCreate block
    start_idx = content.index(ON_CREATE_SIG)
    end_idx   = content.index(".end method", start_idx) + len(".end method")
    method_block = content[start_idx:end_idx]

    # Check already patched
    if "crystal_guideline" in method_block:
        print("[patch.py] Already patched — skipping", file=sys.stderr)
        sys.exit(0)

    method_block = bump_locals(method_block)

    # Inject before first invoke-super
    if "invoke-super" in method_block:
        method_block = method_block.replace(
            "invoke-super",
            snippet.lstrip("\n") + "\n    invoke-super",
            1
        )
    else:
        # No invoke-super: inject before return-void
        method_block = method_block.replace(
            "return-void",
            snippet.lstrip("\n") + "\n    return-void",
            1
        )

    content = content[:start_idx] + method_block + content[end_idx:]

with open(smali_path, "w") as f:
    f.write(content)

print("[patch.py] Injection successful", file=sys.stderr)
PYEOF

ok "Smali injection complete"

# ═══════════════════════════════════════════════════════════════
# STEP 3: COPY OUR SMALI FILES INTO DECOMPILED APK
# ═══════════════════════════════════════════════════════════════
info "Step 3/7 — Injecting com/crystal/ smali files…"

# Use the LAST smali_classes* dir (avoids conflict with game's own DEX)
LAST_SMALI_DIR=$(ls -d "$DECOMPILED"/smali*/ 2>/dev/null | sort | tail -1)
[[ -z "$LAST_SMALI_DIR" ]] && LAST_SMALI_DIR="$DECOMPILED/smali/"

mkdir -p "$LAST_SMALI_DIR/com/crystal"
cp -r "$SMALI_SRC/crystal/"* "$LAST_SMALI_DIR/com/crystal/"
ok "Copied smali: CrystalGuideline, GuidelineService, ShowGuidelineRunnable → $LAST_SMALI_DIR/com/crystal/"

# ═══════════════════════════════════════════════════════════════
# STEP 4: COPY .SO INTO APK LIB FOLDER
# ═══════════════════════════════════════════════════════════════
info "Step 4/7 — Placing libcrystal_guideline.so…"
mkdir -p "$DECOMPILED/lib/arm64-v8a"
cp "$SO_SRC" "$DECOMPILED/lib/arm64-v8a/libcrystal_guideline.so"
ok "Copied .so → lib/arm64-v8a/"

# ═══════════════════════════════════════════════════════════════
# STEP 5: PATCH AndroidManifest.xml
# Add SYSTEM_ALERT_WINDOW permission + register GuidelineService
# ═══════════════════════════════════════════════════════════════
info "Step 5/7 — Patching AndroidManifest.xml…"

python3 - "$MANIFEST" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# ── SYSTEM_ALERT_WINDOW permission ───────────────────────────
PERM = '    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>'
if "SYSTEM_ALERT_WINDOW" not in content:
    # Insert after <manifest ...> or first existing <uses-permission>
    insert_after = re.search(r'<manifest[^>]+>', content)
    if insert_after:
        pos = insert_after.end()
        content = content[:pos] + "\n" + PERM + content[pos:]
    print("[manifest] Added SYSTEM_ALERT_WINDOW permission", file=sys.stderr)
else:
    print("[manifest] SYSTEM_ALERT_WINDOW already present", file=sys.stderr)

# ── FOREGROUND_SERVICE permission (API 28+) ──────────────────
FG_PERM = '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>'
if "FOREGROUND_SERVICE" not in content:
    insert_after = re.search(r'<manifest[^>]+>', content)
    if insert_after:
        pos = insert_after.end()
        content = content[:pos] + "\n" + FG_PERM + content[pos:]

# ── Register GuidelineService inside <application> ─────────────────
SERVICE_TAG = '''        <service
            android:name="com.crystal.GuidelineService"
            android:enabled="true"
            android:exported="false"
            android:stopWithTask="true"/>'''

if "com.crystal.GuidelineService" not in content:
    # Insert before </application>
    content = content.replace("</application>", SERVICE_TAG + "\n    </application>", 1)
    print("[manifest] Registered GuidelineService", file=sys.stderr)
else:
    print("[manifest] GuidelineService already registered", file=sys.stderr)

with open(path, "w") as f:
    f.write(content)
print("[manifest] Done", file=sys.stderr)
PYEOF

ok "Manifest patched"

# ═══════════════════════════════════════════════════════════════
# STEP 6: RECOMPILE
# ═══════════════════════════════════════════════════════════════
info "Step 6/7 — Recompiling with apktool…"
apktool b "$DECOMPILED" -o "$APK_UNSIGNED" \
    || die "apktool build failed — check smali syntax above"
ok "Recompiled → $APK_UNSIGNED"

# ─── zipalign ─────────────────────────────────────────────────
info "       zipalign…"
zipalign -v 4 "$APK_UNSIGNED" "$APK_ALIGNED" >/dev/null \
    || die "zipalign failed"
ok "Aligned"

# ═══════════════════════════════════════════════════════════════
# STEP 7: SIGN
# ═══════════════════════════════════════════════════════════════
info "Step 7/7 — Signing APK…"

# Generate keystore if not already present
if [[ ! -f "$KEYSTORE" ]]; then
    warn "No keystore found — generating debug keystore (crystal.jks)…"
    mkdir -p "$(dirname "$KEYSTORE")"
    keytool -genkey -v \
        -keystore "$KEYSTORE" \
        -alias crystal \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -storepass crystal2024 \
        -keypass   crystal2024 \
        -dname "CN=Crystal, OU=Mod, O=Crystal, L=ID, S=ID, C=ID" \
        2>/dev/null \
        || die "keytool failed — is java installed?"
    ok "Keystore generated: $KEYSTORE"
fi

apksigner sign \
    --ks         "$KEYSTORE" \
    --ks-pass    pass:crystal2024 \
    --key-pass   pass:crystal2024 \
    --ks-key-alias crystal \
    --out        "$APK_OUT" \
    "$APK_ALIGNED" \
    || die "apksigner failed"

ok "Signed APK → $APK_OUT"

# ─── final summary ────────────────────────────────────────────
SIZE=$(du -sh "$APK_OUT" | cut -f1)
echo ""
echo -e "${GRN}══════════════════════════════════════════════${RST}"
echo -e "${GRN}  Crystal Guideline v1.0 — Build Complete!    ${RST}"
echo -e "${GRN}  Output: ${CYN}$APK_OUT${RST}"
echo -e "${GRN}  Size:   ${CYN}$SIZE${RST}"
echo -e "${GRN}══════════════════════════════════════════════${RST}"
echo ""
echo -e "Install:  ${YLW}adb install -r \"$APK_OUT\"${RST}"
echo -e "Or copy the APK to your device and install via file manager."
echo ""
echo -e "${YLW}⚠  On Android 6.0+: grant 'Draw over other apps'${RST}"
echo -e "${YLW}   Settings → Apps → [Game] → Display over other apps → ON${RST}"
echo ""
