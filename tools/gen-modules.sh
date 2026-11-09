#!/bin/sh
set -eu
OWNERSHIP_TOOL=$(CDPATH= cd "$(dirname "$0")" && pwd)/module-ownership.py

PROJECT_ROOT=${PROJECT_ROOT:-$(CDPATH= cd "$(dirname "$0")/.." && pwd)}
OUT_DIR=${OUT_DIR:-$PROJECT_ROOT/out}
cd "$PROJECT_ROOT"
if [ -d core/hookpoints ]; then
    python3 tools/validate-maps.py catalogue
fi
VERSION_FILE=${VERSION_FILE:-$PROJECT_ROOT/VERSION}
version=$(python3 "${VERSION_TOOL:-$PROJECT_ROOT/tools/version.py}" --version-file "$VERSION_FILE")
LC_ALL=C
export LC_ALL

work=$(mktemp -d "${TMPDIR:-/tmp}/gen-modules.XXXXXX")
trap 'rm -rf "$work"' 0 HUP INT TERM

: > "$work/properties"
for props in modules/*/module.properties; do
    [ -f "$props" ] || continue
    # Modules in package form (api=) ship as bundled/<id>.hsm instead (tools/package.py).
    ! grep -q '^api=' "$props" || continue
    printf '%s\n' "$props" >> "$work/properties"
done
: > "$work/ids"
: > "$work/records"
: > "$work/scripts"

property() {
    awk -F= -v key="$2" '
        /^[[:space:]]*#/ { next }
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            sub(/^[^=]*=/, "")
            sub(/^[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
        }
    ' "$1"
}

while IFS= read -r props; do
    dir=${props%/module.properties}
    dirname=${dir##*/}
    id=$(property "$props" id)
    class=$(property "$props" class)
    requires_root=$(property "$props" requires_root)
    depends=$(property "$props" depends)
    excludes=$(property "$props" excludes)
    services=$(property "$props" services)
    service_calls=$(property "$props" service_calls)
    watch=$(property "$props" watch)
    restore=$(property "$props" restore)
    reassert_props=$(property "$props" reassert_props)
    module_version=$(property "$props" version)
    if [ "$module_version" != '@VERSION@' ]; then
        echo "gen-modules: version must be @VERSION@ in $props" >&2
        exit 1
    fi

    if ! printf '%s\n' "$id" | LC_ALL=C grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
        echo "gen-modules: malformed id '$id' in $props" >&2
        exit 1
    fi
    if grep -Fxq "$id" "$work/ids"; then
        echo "gen-modules: duplicate id '$id' in $props" >&2
        exit 1
    fi
    if [ "$id" != "$dirname" ]; then
        echo "gen-modules: id '$id' does not match directory '$dirname'" >&2
        exit 1
    fi
    if ! printf '%s\n' "$class" | LC_ALL=C grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$'; then
        echo "gen-modules: missing or malformed class in $props" >&2
        exit 1
    fi
    class_path=$(printf '%s' "$class" | tr . /)
    if [ ! -f "$dir/src/$class_path.java" ]; then
        echo "gen-modules: class file missing: $dir/src/$class_path.java" >&2
        exit 1
    fi
    if [ "$requires_root" = true ] && [ ! -f "$dir/root/$id.sh" ]; then
        echo "gen-modules: root script missing: $dir/root/$id.sh" >&2
        exit 1
    fi
    if [ -n "$services" ]; then
        old_ifs=$IFS; IFS=,
        for service in $services; do
            if ! printf '%s\n' "$service" | grep -Eq '^[a-zA-Z0-9_]+([.-][a-zA-Z0-9_]+)*$'; then
                echo "gen-modules: malformed service '$service' in $props" >&2
                exit 1
            fi
        done
        IFS=$old_ifs
    fi
    case "$restore" in ''|exact|reboot) ;; *) echo "gen-modules: invalid restore class in $props" >&2; exit 1;; esac
    if [ "$restore" = reboot ] && { [ -n "$(property "$props" owns_props)" ] || [ -n "$(property "$props" owns_files)" ]; }; then
        echo "gen-modules: reboot restore cannot own persistent targets in $props" >&2
        exit 1
    fi
    if [ -n "$watch" ]; then
        [ "$restore" = reboot ] || [ -n "$reassert_props" ] || { echo "gen-modules: watch requires reboot restore or reassert_props in $props" >&2; exit 1; }
        case "$watch" in ,*|*,|*,,*) echo "gen-modules: invalid watch events in $props" >&2; exit 1;; esac
        old_ifs=$IFS; IFS=,
        watch_seen=,
        for event in $watch; do
            case "$event" in boot|screen_on|usb_change) ;; *) echo "gen-modules: invalid watch events in $props" >&2; exit 1;; esac
            case "$watch_seen" in *,$event,*) echo "gen-modules: invalid watch events in $props" >&2; exit 1;; esac
            watch_seen=$watch_seen$event,
        done
        IFS=$old_ifs
    fi
    if [ -n "$service_calls" ]; then
        old_ifs=$IFS; IFS=,
        for call in $service_calls; do
            if ! printf '%s\n' "$call" | grep -Eq '^[a-zA-Z0-9_]+([.-][a-zA-Z0-9_]+)*:[1-9][0-9]{0,4}$'; then
                echo "gen-modules: invalid service call '$call' in $props" >&2; exit 1
            fi
            code=${call##*:}
            [ "$code" -le 65535 ] || { echo "gen-modules: service code out of range in $props" >&2; exit 1; }
        done
        IFS=$old_ifs
    fi

    prefix=$(printf '%s' "$id" | tr - _)_
    if [ -d "$dir/res" ]; then
        find "$dir/res" -type f -name '*.xml' | LC_ALL=C sort > "$work/resources"
        while IFS= read -r resource; do
            awk -v prefix="$prefix" '
                {
                    rest = $0
                    while (match(rest, /name[[:space:]]*=[[:space:]]*["\047]/)) {
                        start = RSTART + RLENGTH
                        quote = substr(rest, start - 1, 1)
                        rest = substr(rest, start)
                        end = index(rest, quote)
                        if (!end) break
                        name = substr(rest, 1, end - 1)
                        if (index(name, prefix) != 1) {
                            printf "gen-modules: resource name \047%s\047 lacks prefix \047%s\047 in %s\n", name, prefix, FILENAME > "/dev/stderr"
                            exit 1
                        }
                        rest = substr(rest, end + 1)
                    }
                }
            ' "$resource" || exit 1
        done < "$work/resources"
    fi

    printf '%s\n' "$id" >> "$work/ids"
    printf '%s\t%s\t%s\t%s\n' "$id" "$class" "$depends" "$excludes" >> "$work/records"
    if [ -f "$dir/root/$id.sh" ]; then
        printf '%s %s\n' "$id" "$dir/root/$id.sh" >> "$work/scripts"
    fi
done < "$work/properties"

# With no built-in module the awk pass writes nothing; the outputs still exist.
: > "$work/ordered"; : > "$work/ordered-ids"; : > "$work/graph"
awk -F '\t' -v ordered="$work/ordered" -v ids_file="$work/ordered-ids" -v graph="$work/graph" '
function fail(message) { print "gen-modules: " message > "/dev/stderr"; exit 1 }
function parse(id, value, kind, parts, count, i, ref, key) {
    if (value == "") return
    count = split(value, parts, ",")
    for (i = 1; i <= count; i++) {
        ref = parts[i]
        if (ref !~ /^[a-z0-9]+(-[a-z0-9]+)*$/) fail("malformed " kind " id \047" ref "\047 in " id)
        if (ref == id) fail("self-reference in " id)
        key = id SUBSEP ref
        if (kind == "depends") {
            if (key in dep) fail("duplicate depends id \047" ref "\047 in " id)
            dep[key] = 1
        } else {
            if (key in exc) fail("duplicate excludes id \047" ref "\047 in " id)
            exc[key] = 1
        }
    }
}
function visit(id, target, key) {
    key = id SUBSEP target
    if (key in dep) return 1
    if (checked[key] == stamp) return 0
    checked[key] = stamp
    for (key in dep) {
        split(key, edge, SUBSEP)
        if (edge[1] == id && visit(edge[2], target)) return 1
    }
    return 0
}
function relation(id, matrix, result, i, ref) {
    result = ""
    for (i = 1; i <= n; i++) {
        ref = sorted[i]
        if ((id SUBSEP ref) in matrix) result = result (result == "" ? "" : ",") ref
    }
    return result
}
{
    id = $1
    ids[id] = 1
    classes[id] = $2
    raw_dep[id] = $3
    raw_exc[id] = $4
    sorted[++n] = id
}
END {
    for (i = 1; i <= n; i++) {
        id = sorted[i]
        parse(id, raw_dep[id], "depends")
        parse(id, raw_exc[id], "excludes")
    }
    for (key in dep) {
        split(key, edge, SUBSEP)
        if (!(edge[2] in ids)) fail("unknown depends id \047" edge[2] "\047 in " edge[1])
    }
    for (key in exc) {
        split(key, edge, SUBSEP)
        if (!(edge[2] in ids)) fail("unknown excludes id \047" edge[2] "\047 in " edge[1])
        mirror[edge[2] SUBSEP edge[1]] = 1
    }
    for (key in mirror) exc[key] = 1
    for (i = 1; i <= n; i++) {
        id = sorted[i]
        stamp++
        if (visit(id, id)) fail("dependency cycle involving " id)
    }
    for (key in exc) {
        split(key, edge, SUBSEP)
        stamp++
        if (visit(edge[1], edge[2])) fail("depends on excluded id \047" edge[2] "\047 in " edge[1])
    }
    for (i = 1; i <= n; i++) {
        id = sorted[i]
        for (key in exc) {
            split(key, edge, SUBSEP)
            stamp++
            has_left = (id == edge[1] || visit(id, edge[1]))
            stamp++
            has_right = (id == edge[2] || visit(id, edge[2]))
            if (has_left && has_right) fail("dependency exclusion conflict in " id)
        }
    }
    for (step = 1; step <= n; step++) {
        chosen = ""
        for (i = 1; i <= n; i++) {
            id = sorted[i]
            if (done[id]) continue
            ready = 1
            for (key in dep) {
                split(key, edge, SUBSEP)
                if (edge[1] == id && !done[edge[2]]) ready = 0
            }
            if (ready) { chosen = id; break }
        }
        if (chosen == "") fail("dependency cycle")
        done[chosen] = 1
        d = relation(chosen, dep)
        e = relation(chosen, exc)
        print chosen "\t" classes[chosen] "\t" d "\t" e > ordered
        print chosen > ids_file
        print chosen "\tdepends=" d "\texcludes=" e > graph
    }
}' "$work/records"

python3 "$OWNERSHIP_TOOL" "$PROJECT_ROOT" "$work/ordered-ids" "$work/lines"

mkdir -p "$OUT_DIR/gen/com/seogaemo/hmg/module" "$OUT_DIR/package/modules"
{
    echo 'package com.seogaemo.hmg.module;'
    echo
    echo '/** Generated by tools/gen-modules.sh; do not edit. */'
    echo 'public final class GeneratedModules {'
    echo '    private GeneratedModules() { }'
    echo '    public static final Module[] ALL = {'
    awk -F '\t' '{ printf "        new %s(),\n", $2 }' "$work/ordered"
    echo '    };'
    echo '    public static final String[] IDS = {'
    awk -F '\t' '{ printf "        \"%s\",\n", $1 }' "$work/ordered"
    echo '    };'
    echo '    public static final String[][] DEPENDS = {'
    awk -F '\t' '{ printf "        {%s},\n", quoted($3) } function quoted(csv, a,n,i,s) { s=""; if (csv != "") { n=split(csv,a,","); for(i=1;i<=n;i++) s=s (i==1?"":",") "\"" a[i] "\"" } return s }' "$work/ordered"
    echo '    };'
    echo '    public static final String[][] EXCLUDES = {'
    awk -F '\t' '{ printf "        {%s},\n", quoted($4) } function quoted(csv, a,n,i,s) { s=""; if (csv != "") { n=split(csv,a,","); for(i=1;i<=n;i++) s=s (i==1?"":",") "\"" a[i] "\"" } return s }' "$work/ordered"
    echo '    };'
    echo '}'
} > "$OUT_DIR/gen/com/seogaemo/hmg/module/GeneratedModules.java"
# Every module now ships as a bundled package. The compatibility entry package-compat keeps
# modules.list and modules.graph non-empty with a valid stub script, which installs from 0.1.33 and
# older require of an OTA payload (lib/payload.sh, core/update.sh); the runtime ignores it.
{ cat "$work/ordered-ids"; echo package-compat; } > "$OUT_DIR/package/modules.list"
{ cat "$work/graph"; printf 'package-compat\tdepends=\texcludes=\n'; } > "$OUT_DIR/package/modules.graph"
cp "$work/lines" "$OUT_DIR/package/modules.lines"
rm -f "$OUT_DIR/package/modules/"*.sh "$OUT_DIR/package/modules/"*.properties
# Left by builds where a module was still built in (its payload now ships inside its .hsm).
rm -rf "$OUT_DIR/package/modules/"*.d
while IFS=' ' read -r id script; do
    [ -n "$id" ] || continue
    cp "$script" "$OUT_DIR/package/modules/$id.sh"
done < "$work/scripts"
printf '#!/system/bin/sh\n# Compatibility entry for OTA payload checks of older installs; not a module.\nexit 2\n' > "$OUT_DIR/package/modules/package-compat.sh"
printf 'id=package-compat\nversion=%s\nservices=\n' "$version" > "$OUT_DIR/package/modules/package-compat.properties"
for props in modules/*/module.properties; do
    [ -f "$props" ] || continue
    # Bundled modules (api=) also keep their declared manifest here: the shared-line and
    # whole-file ownership checks read every module's manifest from the package.
    id=${props%/module.properties}
    id=${id##*/}
    sed "s/^version=@VERSION@$/version=$version/" "$props" > "$OUT_DIR/package/modules/$id.properties"
    if ! grep -q '^services=' "$OUT_DIR/package/modules/$id.properties"; then
        printf 'services=\n' >> "$OUT_DIR/package/modules/$id.properties"
    fi
done
