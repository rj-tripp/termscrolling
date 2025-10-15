# IPTV TUI (Termux/Linux/macOS)
# deps: curl jq fzf awk sed (Requires a media player app like VLC for Android)

set -Eeuo pipefail
# Set the trap on ERR for the main body
trap 'c=$?; echo "Error at line $LINENO: $BASH_COMMAND (exit $c)" >&2; exit $c' ERR
export LC_ALL=C

# -------- Config --------
M3U_URL="${M3U_URL:-https://iptv-org.github.io/iptv/index.category.m3u}"
CACHE_FILE="${HOME}/.iptv_channels_cache.json"
CACHE_EXPIRY_SECONDS=86400   # 24h

# -------- Main Functions --------
die(){ echo "ERROR: $*" >&2; exit 1; }

check_deps(){
  local -a miss=()
  for c in curl jq fzf awk sed; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  if [ "${#miss[@]}" -gt 0 ]; then die "Missing dependencies: ${miss[*]}"; fi
}

# ---------- Parser (one jq pass; fast) ----------
build_cache_from_m3u(){
  echo "--- Fetching IPTV playlist (M3U) ---" >&2
  
  local m3u_tmp=""
  m3u_tmp=$(mktemp) || die "mktemp failed"
  [ -n "$m3u_tmp" ] || die "mktemp failed to return a filename"
  
  trap 'rm -f "$m3u_tmp"' RETURN

  curl -fSL --retry 3 --retry-delay 1 -# "$M3U_URL" -o "$m3u_tmp" || die "Failed to download M3U"
  [ -s "$m3u_tmp" ] || die "Empty M3U"

  echo "Parsing M3U and building cache..." >&2
  awk '
    function reset(){ id=name=cat=cc="" }
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    BEGIN{ OFS="\t"; reset(); expect_url=0 }
    { gsub(/\r/,"") }
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
        if ($0 ~ /^#/) next
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
        | {
            name:      (.[1] // (.[4] | sub("^https?://";"") | split("/")[0])),
            url:        .[4],
            category:  ((.[2] // "Uncategorized") | if .=="" then "Uncategorized" else . end),
            country:   ((.[3] // "Unknown") | if .=="" then "Unknown" else . end)
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
    local mod_time=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mod_time ))
  else
    age=$((CACHE_EXPIRY_SECONDS + 1))
  fi

  if [ "$age" -gt "$CACHE_EXPIRY_SECONDS" ]; then
    build_cache_from_m3u
  else
    echo "Using cached data (age: $((age/3600))h)" >&2
  fi

  if ! jq -e 'length>0' "$CACHE_FILE" >/dev/null 2>&1; then
    echo "Cache invalid/empty — rebuilding..." >&2
    rm -f "$CACHE_FILE"
    build_cache_from_m3u
  fi
}

pick_and_play(){
  local mode group_key group_name_prompt line name url

  local country_key="country"
  local category_key="category"

  mode=$(printf "By Category\nBy Country" | fzf --prompt="🔎 Browse Mode > " --height=10% --layout=reverse) || exit 0

  if [ "$mode" = "By Country" ]; then
    group_key="$country_key"
    group_name_prompt="Country"
  else
    group_key="$category_key"
    group_name_prompt="Category"
  fi

  local selected_group
  selected_group=$(jq -r --arg k "$group_key" '.[][$k]' "$CACHE_FILE" | sort -u | fzf --prompt="🌏 Select $group_name_prompt > " --height=40% --layout=reverse) || exit 0

  line=$(
    jq -r --arg g "$selected_group" --arg k "$group_key" '
      .[]
      | select(.[$k] == $g)
      | "\(.name)\t\(.url)"
    ' "$CACHE_FILE" |
    fzf --prompt="📺 Select Channel ($selected_group) > " --with-nth=1 --delimiter=$'\t' --height=70% --layout=reverse
  ) || exit 0

  if [ -n "$line" ]; then
    name=$(echo "$line" | cut -f1)
    url=$(echo "$line" | cut -f2-)
    echo "▶️ Launching media player for: $name"
    echo "   URL: $url"

    # CRITICAL FIX: Use the short '-t' flag for MIME type, which is
    # compatible with the older version of 'am' in the Play Store Termux.
    am start \
      -a android.intent.action.VIEW \
      -d "$url" \
      -t "video/*" \
      --activity-clear-task
  fi
}

# -------- Entrypoint --------
main(){
  check_deps
  case "${1:-}" in
    --refresh) ensure_cache --refresh ;;
    *)         ensure_cache ;;
  esac
  pick_and_play
}

main "$@"
