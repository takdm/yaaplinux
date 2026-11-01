#!/usr/bin/env bash
# lib/config.sh — minimal nested-YAML get/set for install-config.yaml.
#
# Assumptions (true for our template): 2-space indentation, scalar leaves,
# no flow collections on the paths we touch, no inline comments. Arrays
# (e.g. subvolumes, firmware_packages) are read as raw block text by
# cfg_array, and are never mutated by cfg_set.
#
# Provides:
#   cfg_path            -> current config file path
#   cfg_get <dotted>    -> value to stdout (empty if absent)
#   cfg_set <dotted> <value>   # atomic: temp file + mv
#   cfg_has <dotted>    -> success if key exists (even if empty)
#   cfg_array <dotted>  -> raw block body (lines) of a YAML sequence

_cfg_path() { echo "${YAAP_CONFIG:-/etc/yaaplinux/install-config.yaml}"; }

# Emit "dotted.path<TAB>value" for every scalar in the file.
_cfg_dump() {
    local file; file="$(_cfg_path)"
    [ -f "$file" ] || return 1
    awk '
    function ind(s,   c,i){ i=0; for(c=1;c<=length(s);c++){ if(substr(s,c,1)==" ") i++; else break } return i }
    {
        line=$0; sub(/\r$/,"",line)
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*#/) next
        d=ind(line)/2
        content=line; sub(/^ +/,"",content)
        ci=index(content,":")
        if (ci==0) next
        key=substr(content,1,ci-1)
        rest=substr(content,ci+1); sub(/^[[:space:]]+/,"",rest)
        sub(/[[:space:]]+#.*$/,"",rest)
        sub(/[[:space:]]+$/,"",rest)
        if (rest ~ /^".*"$/) rest=substr(rest,2,length(rest)-2)
        stack[d]=key
        p=stack[0]; for(i=1;i<=d;i++) p=p "." stack[i]
        print p "\t" rest
    }' "$file"
}

cfg_path() { _cfg_path; }

cfg_get() {
    _cfg_dump | awk -F'\t' -v t="$1" '$1==t{ print; exit }' | cut -f2-
}

cfg_has() {
    _cfg_dump | awk -F'\t' -v t="$1" '$1==t{ f=1 } END{ exit f?0:1 }'
}

# Quote a value for YAML if it needs it.
_cfg_yquote() {
    local v="$1"
    case "$v" in
        ''|*[[:space:]]*|*'"'*|*:*|*#*) printf '"%s"' "$v" ;;
        *) printf '%s' "$v" ;;
    esac
}

cfg_set() {
    local path="$1"; local val="$2"
    local file; file="$(_cfg_path)"
    [ -f "$file" ] || { log_err "config.sh: $file not found"; return 1; }

    local parent leaf
    if [[ "$path" == *.* ]]; then parent="${path%.*}"; leaf="${path##*.}"; else parent=""; leaf="$path"; fi

    local qval; qval="$(_cfg_yquote "$val")"
    local tmp; tmp="$(mktemp "$(dirname "$file")/.yaap-config.XXXXXX")"

    if cfg_has "$path"; then
        awk -v target="$path" -v nv="$qval" '
        function ind(s,   c,i){ i=0; for(c=1;c<=length(s);c++){ if(substr(s,c,1)==" ") i++; else break } return i }
        {
            line=$0; sub(/\r$/,"",line)
            if (line ~ /^[[:space:]]*$/) { print; next }
            if (line ~ /^[[:space:]]*#/) { print; next }
            d=ind(line)/2
            content=line; sub(/^ +/,"",content)
            ci=index(content,":")
            if (ci==0) { print; next }
            key=substr(content,1,ci-1)
            stack[d]=key
            p=stack[0]; for(i=1;i<=d;i++) p=p "." stack[i]
            if (p==target) { print substr(line,1,ind(line)) key ": " nv; next }
            print
        }' "$file" > "$tmp"
    else
        awk -v parentpath="$parent" -v leafk="$leaf" -v nv="$qval" '
        function ind(s,   c,i){ i=0; for(c=1;c<=length(s);c++){ if(substr(s,c,1)==" ") i++; else break } return i }
        {
            line=$0; sub(/\r$/,"",line)
            if (line ~ /^[[:space:]]*$/) { print; next }
            if (line ~ /^[[:space:]]*#/) { print; next }
            d=ind(line)/2
            content=line; sub(/^ +/,"",content)
            ci=index(content,":")
            if (ci==0) { print; next }
            key=substr(content,1,ci-1)
            stack[d]=key
            p=stack[0]; for(i=1;i<=d;i++) p=p "." stack[i]
            out=line
            if (parentpath != "" && p==parentpath && out ~ /:[[:space:]]*(\{\}|\[ *\])[[:space:]]*(#.*)?$/) {
                # Convert an empty flow collection (e.g. `env: {}`) into a block
                # parent so block children can be added under it.
                sub(/:[[:space:]]*(\{\}|\[ *\])[[:space:]]*(#.*)?$/, ":", out)
            }
            print out
            if (parentpath != "" && p==parentpath) {
                sp=""
                for(k=0;k<ind(line)+2;k++) sp=sp " "
                print sp leafk ": " nv
            }
        }
        END { if (parentpath=="") print leafk ": " nv }
        ' "$file" > "$tmp"
    fi

    mv "$tmp" "$file"
}

# Read a YAML sequence block (read-only; used for subvolumes, firmware list).
# Emits one item per line, "- " stripped.
cfg_array() {
    local path="$1"
    local file; file="$(_cfg_path)"
    [ -f "$file" ] || return 1
    local leaf="${path##*.}" in_block=0 base_indent=""
    while IFS= read -r line; do
        if [ "$in_block" = 0 ]; then
            # Match "<leaf>:" as a key at the start of a (possibly indented) line.
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            local lead="${line%%"$trimmed"}"
            if [ "$trimmed" = "${leaf}:" ]; then
                in_block=1
                base_indent="$lead"
                continue
            fi
        else
            # End of block: a non-empty line with indent <= base and not a "- " item.
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            if [ -z "$trimmed" ]; then printf '\n'; continue; fi
            local lead="${line%%"$trimmed"}"
            if [ "${trimmed:0:2}" != "- " ] && [ "${#lead}" -le "${#base_indent}" ]; then
                break
            fi
            # Emit item text.
            local item
            if [ "${trimmed:0:2}" = "- " ]; then
                item="${trimmed:2}"
            else
                item="$trimmed"
            fi
            item="${item%\"}"; item="${item#\"}"
            printf '%s\n' "$item"
        fi
    done < "$file"
}

# Emit KEY=VALUE lines for a YAML mapping subtree (read-only). Quotes and
# inline comments are stripped from values.
cfg_map() {
    local path="$1"
    local file; file="$(_cfg_path)"
    [ -f "$file" ] || return 1
    local leaf="${path##*.}" in_block=0 base_indent=""
    while IFS= read -r line; do
        if [ "$in_block" = 0 ]; then
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            if [ "$trimmed" = "${leaf}:" ]; then
                in_block=1; base_indent="${line%%"$trimmed"}"; continue
            fi
        else
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            [ -z "$trimmed" ] && continue
            local lead="${line%%"$trimmed"}"
            if [ "${#lead}" -le "${#base_indent}" ]; then break; fi
            local key="${trimmed%%:*}" val="${trimmed#*:}"
            val="${val#"${val%%[![:space:]]*}"}"      # ltrim
            val="${val%%#*}"                            # drop inline comment
            val="${val%"${val##*[![:space:]]}"}"       # rtrim
            val="${val%\"}"; val="${val#\"}"            # strip surrounding quotes
            printf '%s=%s\n' "$key" "$val"
        fi
    done < "$file"
}
