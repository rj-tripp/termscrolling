# tv.sh — IPTV TUI (Termux/Linux/macOS)
# deps: curl jq fzf mpv awk sed

set -Eeuo pipefail
trap 'c=$?; echo "Error at line $LINENO: $BASH_COMMAND (exit $c)" >&2; exit $c' ERR
export LC_ALL=C

# -------- Config --------
M3U_URL="${M3U_URL:-https://iptv-org.github.io/iptv/index.category.m3u}"
CACHE_FILE="${HOME}/.iptv_channels_cache.json"
CACHE_EXPIRY_SECONDS=86400   # 24h

die(){ echo "ERROR: $*" >&2; exit 1; }

check_deps(){
  local -a miss=()
  for c in curl jq fzf mpv awk sed; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  if [ "${#miss[@]}" -gt 0 ]; then die "Missing: ${miss[*]}"; fi
}

# ---------- Parser (one jq pass; fast) ----------
build_cache_from_m3u(){
  echo "--- Fetching IPTV playlist (M3U) ---" >&2
  local m3u_tmp; m3u_tmp=$(mktemp) || die "mktemp failed"
  trap 'rm -f "$m3u_tmp"' RETURN

  curl -fSL --retry 3 --retry-delay 1 -# "$M3U_URL" -o "$m3u_tmp" || die "Failed to download M3U"
  [ -s "$m3u_tmp" ] || die "Empty M3U"

  echo "Parsing M3U and building cache..." >&2
  # Emit one TSV per channel: id \t name \t category \t country \t url
  awk '
    function reset(){ id=name=cat=cc="" }
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    BEGIN{ OFS="\t"; reset(); expect_url=0 }
    { gsub(/\r/,"") }                         # normalize CRLF
    /^#EXTINF/{
      reset(); expect_url=1
      if (match($0,/tvg-id="([^"]*)"/,m))      id=m[1]
      if (match($0,/tvg-name="([^"]*)"/,m))    name=m[1]
      if (match($0,/group-title="([^"]*)"/,m)) cat=m[1]
      if (match($0,/tvg-country="([^"]*)"/,m)) cc=m[1]
      if (!name) {
        split($0, parts, /,/); if (length(parts)>=2) name=trim(parts[length(parts)])
      }
      next
    }
    {
      if (expect_url) {
        if ($0 ~ /^#/) next                    # skip comments like #EXTVLCOPT
        if ($0 ~ /^https?:\/\//) { print id, name, cat, cc, $0; expect_url=0 }
        next
      }
    }
  ' "$m3u_tmp" \
  | jq -Rn '
      [ inputs
        | gsub("\r$";"")
        | select(length>0)
        | split("\t")
        | { # fields: 0=id, 1=name, 2=cat, 3=cc, 4=url
            name:      (.[1] // (.[4] | sub("^https?://";"") | split("/")[0])),
            url:        .[4],
            category:  ((.[2] // "Uncategorized") | if .=="" then "Uncategorized" else . end),
            country:   { code: (.[3] // "Unknown" | if .=="" then "Unknown" else . end) }
          }
      ]' > "$CACHE_FILE"

  jq -e 'length>0' "$CACHE_FILE" >/dev/null || die "No channels parsed from M3U"
  echo "Cache updated: $CACHE_FILE" >&2
}

ensure_cache(){
  local force="${1:-}"
  if [ "$force" = "--refresh" ]; then rm -f "$CACHE_FILE"; fi

  local age
  if [ -f "$CACHE_FILE" ]; then
    local mod=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mod ))
  else
    age=$((CACHE_EXPIRY_SECONDS + 1))
  fi

  if [ "$age" -gt "$CACHE_EXPIRY_SECONDS" ]; then
    build_cache_from_m3u
  else
    echo "Using cached data (age: $((age/3600))h)" >&2
  fi

  # self-heal
  if ! jq -e 'length>0' "$CACHE_FILE" >/dev/null 2>&1; then
    echo "Cache invalid/empty — rebuilding..." >&2
    rm -f "$CACHE_FILE"
    build_cache_from_m3u
  fi
}

pick_and_play(){
  local mode line name url
  mode=$(printf "By Country\nBy Category" | fzf --prompt="Browse Mode > " --height=10% --reverse) || exit 0

  case "$mode" in
    "By Country")
      mapfile -t countries < <(jq -r '.[].country.code // "Unknown"' "$CACHE_FILE" | sed '/^$/d' | sort -u)
      [ "${#countries[@]}" -gt 0 ] || die "No countries found"
      local sel_country
      sel_country=$(printf "%s\n" "${countries[@]}" | fzf --prompt="Select Country (ISO code) > " --height=50% --reverse) || exit 0
      line=$(
        jq -r --arg c "$sel_country" '.[] | select((.country.code // "Unknown")==$c) | "\(.name)\t\(.url)"' "$CACHE_FILE" |
        fzf --prompt="Select Channel ($sel_country) > " --with-nth=1 --delimiter=$'\t' --height=80% --reverse
      ) || exit 0
      name=$(cut -f1 <<<"$line"); url=$(cut -f2- <<<"$line")
      ;;
    "By Category")
      mapfile -t cats < <(jq -r '.[].category // "Uncategorized"' "$CACHE_FILE" | sort -u)
      [ "${#cats[@]}" -gt 0 ] || die "No categories found"
      local sel_cat
      sel_cat=$(printf "%s\n" "${cats[@]}" | fzf --prompt="Select Category > " --height=50% --reverse) || exit 0
      line=$(
        jq -r --arg c "$sel_cat" '.[] | select((.category // "Uncategorized")==$c) | "\(.name)\t\(.country.code // "Unknown")\t\(.url)"' "$CACHE_FILE" |
        fzf --prompt="Select Channel ($sel_cat) > " --with-nth='1,2' --delimiter=$'\t' --height=80% --reverse
      ) || exit 0
      name=$(cut -f1 <<<"$line"); url=$(cut -f3- <<<"$line")
      ;;
  esac

  if [ -n "${url:-}" ]; then
    echo "Launching: $name"
    echo "URL: $url"
    mpv --title="$name" "$url" || echo "mpv failed (offline/geo-blocked)" >&2
  fi
}

# -------- Main --------
check_deps
case "${1:-}" in
  --refresh) ensure_cache --refresh ;;
  *)         ensure_cache ;;
esac
pick_and_play

