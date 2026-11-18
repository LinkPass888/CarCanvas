#!/usr/bin/env bash
# Build CarCanvas.app and package an unsigned IPA. No certificates, profiles,
# exportOptions.plist, or secrets are used anywhere in this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/artifacts"
DERIVED="$ROOT/.build/DerivedData"
APP="$DERIVED/Build/Products/Release-iphoneos/CarCanvas.app"
STAGE="$ROOT/.build/ipa-stage"
LANGS=(en ja zh-Hans)

mkdir -p "$OUT" "$DERIVED" "$STAGE"
rm -f "$OUT"/CarCanvas*.ipa "$OUT/build-report.txt"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> xcodebuild (signing disabled)"
xcodebuild \
  -project CarCanvas.xcodeproj \
  -scheme CarCanvas \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_IDENTITY="" \
  CODE_SIGN_IDENTITY="" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  build

[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }

echo "==> inject localizations into the .app bundle"
for lang in "${LANGS[@]}"; do
  SRC="$ROOT/CarCanvas/Resources/$lang.lproj"
  DST="$APP/$lang.lproj"
  mkdir -p "$DST"
  for name in Localizable.strings InfoPlist.strings; do
    [ -s "$SRC/$name" ] || { echo "ERROR: missing $SRC/$name"; exit 1; }
    plutil -convert binary1 -o "$DST/$name" "$SRC/$name"
    [ -s "$DST/$name" ] || { echo "ERROR: empty $DST/$name"; exit 1; }
  done
done

PB=/usr/libexec/PlistBuddy
VERSION="$($PB -c "Print :CFBundleShortVersionString" "$APP/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "ERROR: invalid CFBundleShortVersionString: '$VERSION'"
  exit 1
fi
IPA="$OUT/CarCanvas-v${VERSION}-unsigned.ipa"

echo "==> package Payload/"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
find "$STAGE" -name '.DS_Store' -delete
(cd "$STAGE" && zip -qry "$IPA" Payload)

echo "==> self-check"
REPORT="$OUT/build-report.txt"
{
  echo "CarCanvas unsigned IPA build report"
  echo "commit:      ${GITHUB_SHA:-local}"
  echo "built (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Xcode:       $(xcodebuild -version | tr '\n' ' ')"
  echo "SDK:         $(xcrun --sdk iphoneos --show-sdk-version)"
  echo
  echo "-- archive integrity --"
  unzip -t "$IPA"
  echo
  echo "-- first entry --"
  LIST="$(mktemp)"
  unzip -Z1 "$IPA" > "$LIST"
  FIRST="$(head -n 1 "$LIST")"
  echo "$FIRST"
  [ "$FIRST" = "Payload/" ] || { echo "ERROR: first entry must be Payload/"; exit 1; }
  echo
  echo "-- forbidden entries --"
  if grep -E '(^|/)(embedded\.mobileprovision|__MACOSX|\.DS_Store)$' "$LIST"; then
    echo "ERROR: forbidden entry in archive"; exit 1
  else
    echo "none"
  fi
  echo
  echo "-- localizations in bundle --"
  for lang in "${LANGS[@]}"; do
    echo "$lang.lproj: $(ls -1 "$APP/$lang.lproj" | tr '\n' ' ')"
  done
  echo
  echo "-- signing (expected: NOT signed) --"
  if codesign -dv --verbose=2 "$APP" 2>&1; then
    echo "ERROR: .app is signed; CI must produce an unsigned build"; exit 1
  else
    echo "unsigned (expected)"
  fi
  echo
  echo "-- Info.plist --"
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleLocalizations MinimumOSVersion; do
    echo "$key = $($PB -c "Print :$key" "$APP/Info.plist" 2>&1 || true)"
  done
  echo
  echo "-- SHA-256 --"
  shasum -a 256 "$IPA"
} > "$REPORT" 2>&1
rm -f "$LIST"

echo "==> done"
sha="$(shasum -a 256 "$IPA" | awk '{print $1}')"
echo "IPA:    $IPA"
echo "SHA256: $sha"
echo "Report: $REPORT"
