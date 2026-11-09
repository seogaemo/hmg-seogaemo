#!/bin/sh
set -eu

repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
VERSION_TOOL=$repo/tools/version.py
export VERSION_TOOL
scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-gen-modules.XXXXXX")
trap 'rm -rf "$scratch"' 0 HUP INT TERM
fixture=$scratch/project

reset_fixture() {
    rm -rf "$fixture"
    mkdir -p "$fixture/modules/alpha/src/com/example" "$fixture/modules/alpha/res/values" "$fixture/modules/alpha/root"
    printf '0.1.0\n' > "$fixture/VERSION"
    cat > "$fixture/modules/alpha/module.properties" <<'EOF'
id=alpha
class=com.example.Alpha
version=@VERSION@
requires_root=true
EOF
    : > "$fixture/modules/alpha/src/com/example/Alpha.java"
    printf '<resources><string name="alpha_name">Alpha</string></resources>\n' > "$fixture/modules/alpha/res/values/strings.xml"
    printf '#!/bin/sh\n' > "$fixture/modules/alpha/root/alpha.sh"
}

expect_failure() {
    expected=$1
    if PROJECT_ROOT="$fixture" VERSION_TOOL="$repo/tools/version.py" sh "$repo/tools/gen-modules.sh" > "$scratch/log" 2>&1; then
        echo "expected failure containing: $expected" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$scratch/log"; then
        cat "$scratch/log" >&2
        echo "missing expected error: $expected" >&2
        exit 1
    fi
}

reset_fixture
PROJECT_ROOT="$fixture" VERSION_TOOL="$repo/tools/version.py" sh "$repo/tools/gen-modules.sh"
grep -Fxq 'version=0.1.0' "$fixture/out/package/modules/alpha.properties"
grep -Fq 'new com.example.Alpha()' "$fixture/out/gen/com/seogaemo/hmg/module/GeneratedModules.java"
grep -Fxq alpha "$fixture/out/package/modules.list"
cmp "$fixture/modules/alpha/root/alpha.sh" "$fixture/out/package/modules/alpha.sh"
mkdir -p "$fixture/modules/zeta/src/com/example" "$fixture/modules/zeta/res/values"
printf 'id=zeta\nclass=com.example.Zeta\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/zeta/module.properties"
: > "$fixture/modules/zeta/src/com/example/Zeta.java"
printf '<resources><string name="zeta_name">Zeta</string></resources>\n' > "$fixture/modules/zeta/res/values/strings.xml"
PROJECT_ROOT="$fixture" VERSION_TOOL="$repo/tools/version.py" sh "$repo/tools/gen-modules.sh"
printf 'alpha\nzeta\npackage-compat\n' > "$scratch/expected-ids"
cmp "$scratch/expected-ids" "$fixture/out/package/modules.list"

# The dependency wins over lexical order; one-sided exclusion becomes symmetric.
reset_fixture
mkdir -p "$fixture/modules/beta/src/com/example" "$fixture/modules/zed/src/com/example"
printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\nexcludes=zed\n' > "$fixture/modules/beta/module.properties"
printf 'id=zed\nclass=com.example.Zed\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/zed/module.properties"
: > "$fixture/modules/beta/src/com/example/Beta.java"
: > "$fixture/modules/zed/src/com/example/Zed.java"
printf 'depends=zed\n' >> "$fixture/modules/alpha/module.properties"
PROJECT_ROOT="$fixture" sh "$repo/tools/gen-modules.sh"
printf 'beta\nzed\nalpha\npackage-compat\n' > "$scratch/expected-ids"
cmp "$scratch/expected-ids" "$fixture/out/package/modules.list"
grep -Fq 'alpha' "$fixture/out/package/modules.graph"
grep -Fq 'zed' "$fixture/out/package/modules.graph"
grep -Fq '"beta"' "$fixture/out/gen/com/seogaemo/hmg/module/GeneratedModules.java"
grep -Fq 'excludes=beta' "$fixture/out/package/modules.graph"

reset_fixture
printf 'depends=missing\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'unknown depends id'

reset_fixture
printf 'excludes=missing\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'unknown excludes id'

reset_fixture
printf 'depends=alpha\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'self-reference'

reset_fixture
printf 'excludes=alpha\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'self-reference'

reset_fixture
mkdir -p "$fixture/modules/beta/src/com/example"
printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\ndepends=alpha\n' > "$fixture/modules/beta/module.properties"
: > "$fixture/modules/beta/src/com/example/Beta.java"
printf 'depends=beta\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'dependency cycle'

reset_fixture
mkdir -p "$fixture/modules/beta/src/com/example"
printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/beta/module.properties"
: > "$fixture/modules/beta/src/com/example/Beta.java"
printf 'depends=beta\nexcludes=beta\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'depends on excluded id'

reset_fixture
mkdir -p "$fixture/modules/beta/src/com/example" "$fixture/modules/gamma/src/com/example"
printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\nexcludes=gamma\n' > "$fixture/modules/beta/module.properties"
printf 'id=gamma\nclass=com.example.Gamma\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/gamma/module.properties"
: > "$fixture/modules/beta/src/com/example/Beta.java"
: > "$fixture/modules/gamma/src/com/example/Gamma.java"
printf 'depends=beta,gamma\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'dependency exclusion conflict'

reset_fixture
mkdir -p "$fixture/modules/beta/src/com/example" "$fixture/modules/gamma/src/com/example"
printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\ndepends=gamma\n' > "$fixture/modules/beta/module.properties"
printf 'id=gamma\nclass=com.example.Gamma\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/gamma/module.properties"
: > "$fixture/modules/beta/src/com/example/Beta.java"
: > "$fixture/modules/gamma/src/com/example/Gamma.java"
printf 'depends=beta\nexcludes=gamma\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'depends on excluded id'

reset_fixture
sed 's/id=alpha/id=bad--id/' "$fixture/modules/alpha/module.properties" > "$scratch/properties"
cp "$scratch/properties" "$fixture/modules/alpha/module.properties"
expect_failure 'malformed id'

reset_fixture
sed 's/id=alpha/id=beta/' "$fixture/modules/alpha/module.properties" > "$scratch/properties"
cp "$scratch/properties" "$fixture/modules/alpha/module.properties"
expect_failure 'does not match directory'

reset_fixture
mkdir -p "$fixture/modules/beta"
printf 'id=alpha\nclass=com.example.Beta\nversion=@VERSION@\n' > "$fixture/modules/beta/module.properties"
expect_failure 'duplicate id'

reset_fixture
rm "$fixture/modules/alpha/src/com/example/Alpha.java"
expect_failure 'class file missing'

reset_fixture
rm "$fixture/modules/alpha/root/alpha.sh"
expect_failure 'root script missing'

reset_fixture
printf '<resources><string name="wrong_name">Wrong</string></resources>\n' > "$fixture/modules/alpha/res/values/strings.xml"
expect_failure 'lacks prefix'

reset_fixture
printf '0.1000.0\n' > "$fixture/VERSION"
expect_failure 'out of range'

reset_fixture
printf '0.0.0\n' > "$fixture/VERSION"
expect_failure 'outside Android'


# Line claims are literal after the first colon and independent of exclusions.
reset_fixture
mkdir -p "$fixture/modules/beta/src/com/example"
printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/beta/module.properties"
: > "$fixture/modules/beta/src/com/example/Beta.java"
printf 'owns_lines.1=/system/shared:  a,b:c=d\\x  \n' >> "$fixture/modules/alpha/module.properties"
printf 'owns_lines.1=/system/shared:other\n' >> "$fixture/modules/beta/module.properties"
PROJECT_ROOT="$fixture" sh "$repo/tools/gen-modules.sh"
printf 'alpha\t1\t/system/shared:  a,b:c=d\\x  \nbeta\t1\t/system/shared:other\n' > "$scratch/expected-lines"
cmp "$scratch/expected-lines" "$fixture/out/package/modules.lines"
printf 'owns_lines.2=/system/shared:  a,b:c=d\\x  \nexcludes=alpha\n' >> "$fixture/modules/beta/module.properties"
expect_failure 'duplicate line ownership'

reset_fixture
printf 'owns_lines.1=/system/shared:stock\nowns_lines.1=/system/shared:other\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'invalid or duplicate line key'

reset_fixture
printf 'owns_lines.01=/system/shared:stock\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'invalid or duplicate line key'

reset_fixture
printf 'owns_lines.1=/system/shared:stock\nowns_lines.2=/system/shared:stock\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'duplicate line ownership'

reset_fixture
printf 'owns_lines.1=/system/shared:stock\nrestore=reboot\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'reboot restore cannot own persistent targets'

reset_fixture
printf 'owns_lines.1=/system/shared:bad\tline\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'invalid stock line'
reset_fixture
printf 'owns_lines.1=/system/shared:bad\rline\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'invalid stock line'

for first in alpha beta; do
    reset_fixture
    mkdir -p "$fixture/modules/beta/src/com/example"
    printf 'id=beta\nclass=com.example.Beta\nversion=@VERSION@\nrequires_root=false\n' > "$fixture/modules/beta/module.properties"
    : > "$fixture/modules/beta/src/com/example/Beta.java"
    if [ "$first" = alpha ]; then second=beta; else second=alpha; fi
    printf 'owns_files=/system/shared\n' >> "$fixture/modules/$first/module.properties"
    printf 'owns_lines.1=/system/shared:stock\n' >> "$fixture/modules/$second/module.properties"
    expect_failure 'whole-file ownership conflict'
    printf 'owns_files=/system/shared\n' >> "$fixture/modules/$second/module.properties"
    expect_failure 'whole-file ownership conflict'
done

echo 'gen-modules tests passed'

# Property watch policy must be explicit and a unique subset of ownership.
reset_fixture
printf 'owns_props=demo\nreassert_props=demo\nwatch=boot,screen_on\n' >> "$fixture/modules/alpha/module.properties"
PROJECT_ROOT="$fixture" sh "$repo/tools/gen-modules.sh"
reset_fixture
printf 'owns_props=demo\nreassert_props=other\nwatch=boot\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'invalid reassert_props'
reset_fixture
printf 'owns_props=demo\nreassert_props=demo,demo\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'invalid reassert_props'
reset_fixture
printf 'owns_props=demo\nwatch=boot\n' >> "$fixture/modules/alpha/module.properties"
expect_failure 'watch requires reboot restore or reassert_props'

# USB watch is a fixed event; all subsets and orderings are accepted, no duplicates.
for events in usb_change boot,usb_change usb_change,screen_on screen_on,usb_change,boot; do
    reset_fixture
    printf 'restore=reboot\nwatch=%s\n' "$events" >> "$fixture/modules/alpha/module.properties"
    PROJECT_ROOT="$fixture" sh "$repo/tools/gen-modules.sh"
    grep -Fxq "watch=$events" "$fixture/out/package/modules/alpha.properties"
done
for events in usb_change,usb_change usb_change,bogus usb_change, ,usb_change boot,,usb_change; do
    reset_fixture
    printf 'restore=reboot\nwatch=%s\n' "$events" >> "$fixture/modules/alpha/module.properties"
    expect_failure 'invalid watch events'
done

# App-private generated directories: exact project-named getDir paths only.
reset_fixture
printf 'owns_generated_dirs=/data/data/com.example.app/app_hmg-seogaemo-demo\n' >> "$fixture/modules/alpha/module.properties"
PROJECT_ROOT="$fixture" sh "$repo/tools/gen-modules.sh"
for bad in '/data/data/com.example.app/other' '/data/data/com.example.app/app_hmg-seogaemo-a/b' '/system/app_hmg-seogaemo-a' \
    '/data/data/com.example.app/app_hmg-seogaemo-a,/data/data/com.example.app/app_hmg-seogaemo-a'; do
    reset_fixture
    printf 'owns_generated_dirs=%s\n' "$bad" >> "$fixture/modules/alpha/module.properties"
    expect_failure 'invalid owns_generated_dirs'
done
