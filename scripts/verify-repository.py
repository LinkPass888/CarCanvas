#!/usr/bin/env python3
"""Read-only acceptance checks for the CarCanvas source repository.

Runs on Linux / macOS / Windows with plain Python 3.8+ and zero third-party
dependencies. It deliberately does NOT require Xcode: the heavy build is
left to .github/workflows/build-ipa.yml.
"""
import plistlib
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except AttributeError:
    pass

ROOT = Path(__file__).resolve().parent.parent
FAILURES = []
CHECKS = 0


def check(condition, ok_message, fail_message):
    global CHECKS
    CHECKS += 1
    if condition:
        print("[OK]   " + ok_message)
        return True
    print("[FAIL] " + fail_message)
    FAILURES.append(fail_message)
    return False


def rel(path):
    try:
        return str(path.relative_to(ROOT)).replace("\\", "/")
    except ValueError:
        return str(path)


def iter_repo_files():
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        if ".git" in p.parts or ".build" in p.parts or "DerivedData" in p.parts:
            continue
        yield p


print("== 1. No signed/binary release artifacts in repository ==")
import subprocess

forbidden = (".ipa", ".mobileprovision", ".p12", ".p12.enc")


def zip_is_ipa(path):
    """Sniff a zip whose first entry is Payload/; renamed .ipa files still fail."""
    try:
        with path.open("rb") as fh:
            if fh.read(4) != b"PK":
                return False
        import zipfile
        with zipfile.ZipFile(path) as zf:
            names = zf.namelist()
            return bool(names) and (names[0] == "Payload/" or names[0].startswith("Payload/"))
    except Exception:
        return False


found = [rel(p) for p in iter_repo_files()
         if any(p.name.lower().endswith(suf) for suf in forbidden) or zip_is_ipa(p)]
check(not found, "no .ipa / profile / certificate files in working tree",
      "forbidden working-tree artifacts: " + ", ".join(found))

# Also inspect git HEAD and the index, not just the working tree. A deleted
# file can still be tracked (the classic `git rm --cached` trap).
tracked = []
try:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "-r", "--name-only", "HEAD"],
                         capture_output=True, text=True, check=True).stdout
    tracked += [n.strip() for n in out.splitlines() if n.strip()]
except Exception:
    pass
try:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files"],
                         capture_output=True, text=True, check=True).stdout
    tracked += [n.strip() for n in out.splitlines() if n.strip()]
except Exception:
    pass
bad_tracked = sorted({n for n in tracked if any(n.lower().endswith(suf) for suf in forbidden)})
check(not bad_tracked, "no .ipa / profile / certificate tracked in HEAD or index",
      "tracked forbidden artifacts: " + ", ".join(bad_tracked))


print()
print("== 2. Localizable.strings: keys, placeholders, encoding ==")
LANGS = ("en", "ja", "zh-Hans")
def _parse_line(line):
    """Parse a .strings entry without a backslash-heavy regex."""
    s = line.strip()
    if not s.endswith(";"):
        return None
    s = s[:-1].rstrip()
    if not s.startswith('"'):
        return None
    # key
    i, key = 1, []
    while i < len(s) and s[i] != '"':
        if s[i] == chr(92) and i + 1 < len(s):
            i += 1
        key.append(s[i]); i += 1
    if i >= len(s) or s[i] != '"':
        return None
    i += 1
    while i < len(s) and s[i].isspace():
        i += 1
    if i >= len(s) or s[i] != "=":
        return None
    i += 1
    while i < len(s) and s[i].isspace():
        i += 1
    if i >= len(s) or s[i] != '"':
        return None
    i += 1
    value = []
    while i < len(s) and s[i] != '"':
        if s[i] == chr(92) and i + 1 < len(s):
            i += 1
        value.append(s[i]); i += 1
    if i >= len(s) or s[i] != '"':
        return None
    return "".join(key), "".join(value)

def parse_strings(path):
    table = {}
    BS = chr(92)
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith(("/*", "//", "#")):
            continue
        pair = _parse_line(line)
        if pair is None:
            raise ValueError("%s:%d: cannot parse %r" % (rel(path), lineno, line))
        key, raw = pair
        # Unescape .strings sequences; keep escaped newlines as real newlines.
        # placeholder comparison sees it identically in every language.
        out, i = [], 0
        while i < len(raw):
            if raw[i] == BS and i + 1 < len(raw):
                nxt = raw[i + 1]
                out.append(chr(10) if nxt == "n" else nxt)
                i += 2
            else:
                out.append(raw[i]); i += 1
        table[key] = "".join(out)
    return table


tables = {}
for lang in LANGS:
    p = ROOT / "CarCanvas" / "Resources" / (lang + ".lproj") / "Localizable.strings"
    if not check(p.is_file(), "%s strings file exists" % lang, "missing " + rel(p)):
        continue
    try:
        tables[lang] = parse_strings(p)
    except Exception as exc:
        check(False, "%s parsed" % lang, "%s parse error: %s" % (lang, exc))

if len(tables) == 3:
    en = tables["en"]
    keys = set(en)
    print("       key counts: " + ", ".join("%s=%d" % (k, len(v)) for k, v in tables.items()))
    check(all(set(t) == keys for t in tables.values()),
          "all three languages have identical key sets (%d keys)" % len(keys),
          "key sets differ across languages")

    PH = re.compile(r"%(?:@|ld|d)|\n")

    def ph_seq(s):
        return [m.group(0) for m in PH.finditer(s)]

    bad = []
    for lang in ("ja", "zh-Hans"):
        for k in keys:
            if ph_seq(en[k]) != ph_seq(tables[lang][k]):
                bad.append("%s:%s" % (lang, k))
    check(not bad, "placeholder sequences match English in every key",
          "placeholder mismatch: " + ", ".join(bad[:12]))

    stray = []
    for k, v in tables["zh-Hans"].items():
        for m in re.finditer(r"%(?![@ld%])", v):
            stray.append("%s:%s" % (k, m.group(0)))
    check(not stray, "no illegal % specifier in zh-Hans",
          "illegal printf specifiers: " + ", ".join(stray[:12]))


print()
print("== 3. InfoPlist.strings ==")
for lang in LANGS:
    p = ROOT / "CarCanvas" / "Resources" / (lang + ".lproj") / "InfoPlist.strings"
    ok = p.is_file() and "NSPhotoLibraryUsageDescription" in p.read_text(encoding="utf-8")
    check(ok, "%s photo permission localized" % lang, "missing/incomplete " + rel(p))


print()
print("== 4. App Group is discovered at runtime ==")
aga_h = ROOT / "CarCanvas" / "Features" / "Backend" / "CCAppGroup.h"
aga_m = ROOT / "CarCanvas" / "Features" / "Backend" / "CCAppGroup.m"
ent = ROOT / "CarCanvas" / "CarCanvas.entitlements"
info = ROOT / "CarCanvas" / "Info.plist"
if check(aga_h.is_file() and aga_m.is_file(), "runtime App Group resolver present",
         "CCAppGroup.h/.m missing"):
    m_text = aga_m.read_text(encoding="utf-8")
    check("SecTaskCopyValueForEntitlement" in m_text,
          "reads the entitlement from its own signature",
          "does not read the signed entitlement")
    check("containerURLForSecurityApplicationGroupIdentifier" in m_text,
          "only accepts a reachable group (entitled != reachable)",
          "reachability check missing")
    check("CCAppGroupResetCachesDirectory" in m_text and "rename(" in m_text,
          "stale Caches symlink is moved aside, not deleted",
          "no interrupted-swap recovery")
    # Private API must be resolved dynamically, never via a private header.
    check("dlopen(\"/System/Library/Frameworks/Security.framework/Security\"" in m_text,
          "SecTask resolved with dlopen/dlsym (no private header)",
          "SecTask is not resolved dynamically")
    check("#import <Security/SecTask.h>" not in m_text,
          "no private SecTask header imported",
          "private SecTask header imported")
if check(ent.is_file() and info.is_file(), "entitlements and Info.plist exist",
         "entitlements or Info.plist missing"):
    import plistlib as _pl
    ent_groups = _pl.loads(ent.read_bytes()).get("com.apple.security.application-groups") or []
    check(bool(ent_groups),
          "entitlements declares at least one App Group capability (%s)" % (ent_groups[0] if ent_groups else "-"),
          "entitlements declares no App Group")
    check("CCAppGroupIdentifier" not in _pl.loads(info.read_bytes()),
          "Info.plist no longer hard-codes a group identifier",
          "Info.plist still hard-codes CCAppGroupIdentifier")


print()
print("== 5. GitHub Actions workflow ==")
wf = ROOT / ".github" / "workflows" / "build-ipa.yml"
bld = ROOT / "scripts" / "build-unsigned-ipa.sh"
if check(wf.is_file() and bld.is_file(), "workflow + build script exist",
         "workflow or build script missing"):
    wf_text = wf.read_text(encoding="utf-8")
    sh_text = bld.read_text(encoding="utf-8")
    for token, needle, hay in (
        ("macos-26", "macos-26", wf_text),
        ("xcodegen generate", "xcodegen generate", wf_text),
        ("artifact upload", "upload-artifact", wf_text),
        ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=NO", sh_text),
        ("CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_REQUIRED=NO", sh_text),
        ("generic/platform=iOS", "generic/platform=iOS", sh_text),
        ("Payload packaging", "Payload/", sh_text),
    ):
        check(needle in hay, "%s present" % token, "%s missing" % token)
    check("verify-repository.py" in wf_text,
          "verify job runs before build", "workflow missing verification step")


print()
print("== 6. Vendored worse_query / GPL ==")
VENDOR = ROOT / "vendor" / "worse_query"
for name in ("worse_query.m", "worse_query.h", "pathleak.m", "pathleak.h"):
    check((VENDOR / name).is_file(), "vendored " + name, "missing vendor file " + name)
lic = ROOT / "THIRD_PARTY_LICENSES" / "worse_query-GPL-3.0.txt"
root_lic = ROOT / "LICENSE"
check(lic.is_file() and "GNU GENERAL PUBLIC LICENSE" in lic.read_text(encoding="utf-8", errors="replace"),
      "GPL-3.0 text present", "GPL license text missing")
check(root_lic.is_file(), "root LICENSE exists", "root LICENSE missing")
if root_lic.is_file() and lic.is_file():
    check(root_lic.read_bytes() == lic.read_bytes(),
          "root LICENSE matches GPL text", "root LICENSE differs from GPL text")
check((VENDOR / "NOTICE.md").is_file(), "vendor NOTICE.md exists", "vendor NOTICE.md missing")
pm = VENDOR / "pathleak.m"
if pm.is_file():
    t = pm.read_text(encoding="utf-8")
    check("#include <sys/fsgetpath.h>" not in t and "dlsym(RTLD_DEFAULT, \"fsgetpath\")" in t,
          "pathleak.m resolves fsgetpath at runtime (no private header / link-time SPI)",
          "pathleak.m still has a private-header or link-time dependency")


print()
print("== 7. Objective-C bridging header ==")
bh = ROOT / "CarCanvas" / "CarCanvas-Bridging-Header.h"
if check(bh.is_file(), "bridging header exists", "bridging header missing"):
    t = bh.read_text(encoding="utf-8")
    check("worse_query.h" in t and "pathleak.h" in t,
          "both C headers exposed to Swift", "bridging header incomplete")


print()
print("== 8. Xcode project spec ==")
spec = ROOT / "project.yml"
if check(spec.is_file(), "project.yml exists", "project.yml missing"):
    t = spec.read_text(encoding="utf-8")
    for token in ("name: CarCanvas", "26.0", "CarCanvas.entitlements"):
        check(token in t, "project.yml contains %r" % token,
              "project.yml missing %r" % token)


print()
print("== 9. Security boundary ==")
wl = ROOT / "CarCanvas" / "Features" / "Backend" / "WQWhitelist.swift"
wa = ROOT / "CarCanvas" / "Features" / "Backend" / "WQAccess.swift"
if check(wl.is_file() and wa.is_file(), "backend whitelist + access wrapper exist",
         "backend files missing"):
    wl_text = wl.read_text(encoding="utf-8")
    wa_text = wa.read_text(encoding="utf-8")
    check("allowedContainerPrefixes" in wl_text,
          "static container whitelist defined", "allowedContainerPrefixes missing")
    check("func withAccess" in wa_text and "worse_query_release" in wa_text,
          "scoped withAccess + unconditional release", "withAccess incomplete")
    check("requireSupported" in wa_text,
          "version gate called before access", "version gate not called")
    check("isAllowedContainer" in wa_text and "isAllowedCacheFile" in wl_text,
          "path validation present in both layers", "path validation missing")

swift_files = [p for p in iter_repo_files() if p.suffix == ".swift"]
ui_files = [p for p in swift_files if "/Features/" in rel(p) or "/UI/" in rel(p)]
path_fields = [rel(p) for p in ui_files
               if re.search(r"TextField\([^)]*\$?\w*path", p.read_text(encoding="utf-8"), re.I)]
check(not path_fields,
      "no arbitrary path input field in UI (%d Swift files scanned)" % len(swift_files),
      "path TextField found: " + ", ".join(path_fields))
callers = [rel(p) for p in swift_files
           if re.search(r"\bworse_query\s*\(", p.read_text(encoding="utf-8"))
           and p.name != "WQAccess.swift"]
check(not callers,
      "worse_query() called only from WQAccess.swift",
      "unexpected direct worse_query() calls: " + ", ".join(callers))


print()
print("== 10. Documentation ==")
for name in ("README.md", "README.zh.md", "README.ja.md"):
    p = ROOT / name
    if check(p.is_file(), name + " exists", name + " missing"):
        t = p.read_text(encoding="utf-8")
        check("26.0" in t and "26.7.2" in t,
              "%s states the supported version range" % name,
              "%s missing version range" % name)
        check("worse_query" in t,
              "%s documents the backend" % name, "%s missing backend docs" % name)
        # The current-language entry is bold text, not a self-link, so require
        # the two *other* files as links plus the current file's own name.
        others = [f for f in ("README.md", "README.zh.md", "README.ja.md") if f != name]
        current = {"README.md": "English",
                   "README.zh.md": "简体中文",
                   "README.ja.md": "日本語"}[name]
        checks = [(f in t, f) for f in others]
        checks.append(("<strong>" + current + "</strong>" in t, "bold current-language label"))
        check(all(ok for ok, _ in checks),
              "%s has complete three-language nav" % name,
              "%s missing: %s" % (name, ", ".join(label for ok, label in checks if not ok)))


print()
print("=" * 60)
print("Checks run: %d   Failures: %d" % (CHECKS, len(FAILURES)))
if FAILURES:
    for f in FAILURES:
        print("  - " + f)
    print("RESULT: FAILED")
    sys.exit(1)
print("RESULT: PASSED")
sys.exit(0)
