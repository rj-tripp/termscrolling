# .sh [mode=top|new|best|ask|show|job] [posts=30] [comments=5]

mode="${1:-top}"
posts="${2:-30}"
comments="${3:-5}"
api="https://hacker-news.firebaseio.com/v0"
ua="curl/hn-tui"

# ----- helpers -----
endpoint() {
  case "$mode" in
    top)  echo "$api/topstories.json" ;;
    new)  echo "$api/newstories.json" ;;
    best) echo "$api/beststories.json" ;;
    ask)  echo "$api/askstories.json" ;;
    show) echo "$api/showstories.json" ;;
    job)  echo "$api/jobstories.json" ;;
    *)    echo "$api/topstories.json" ;;
  esac
}
item() { curl -fsSL -A "$ua" "$api/item/$1.json"; }

# jq filter to flatten HN HTML-ish text to plain text
clean_html='
  ( . // "" )
  | gsub("<p>"; "\n\n")
  | gsub("<[^>]+>"; "")
  | gsub("&quot;"; "\"")
  | gsub("&apos;|&#39;|&#x27;"; "'\''")
  | gsub("&amp;"; "&")
  | gsub("&lt;"; "<")
  | gsub("&gt;"; ">")
  | gsub("&#x2F;"; "/")
  | gsub("\\s+"; " ")
'

# TSV per row:
# title \t by \t score \t descendants \t hn_url \t external_url \t id \t text_snippet
get_posts() {
  ids=$(curl -fsSL -A "$ua" "$(endpoint)" | jq -r ".[:$posts][]")
  for id in $ids; do
    item "$id" | jq -r "
      . as \$d |
      [
        (\$d.title // \"(no title)\" | $clean_html),
        (\$d.by // \"\"),
        (\$d.score // 0 | tostring),
        (\$d.descendants // 0 | tostring),
        (\"https://news.ycombinator.com/item?id=\" + (\$d.id|tostring)),
        (\$d.url // \"\"),
        (\$d.id|tostring),
        ((\$d.text // \"\" | $clean_html) | .[0:280])
      ] | @tsv"
  done
}

# ----- rendering -----
post_header() { # $1..$8 = title, by, score, desc, hn_url, ext_url, id, snippet
  printf '\e[1m%s\e[0m\n' "$1"
  printf 'u:%s  %s↑  💬 %s\n' "$2" "$3" "$4"
  [ -n "$6" ] && printf 'link: %s\n' "$6"
  printf 'HN:   %s\n' "$5"
  [ -n "$8" ] && printf '\n%s\n' "$8"
}

preview_block() { # TSV row -> header + top N comments (1 line each)
  IFS=$'\t' read -r title by score desc hn_url ext_url id snippet <<<"$1"
  post_header "$title" "$by" "$score" "$desc" "$hn_url" "$ext_url" "$id" "$snippet"
  printf '\n\e[36mTop %s comments\e[0m\n' "$comments"

  # first N top-level kids
  while read -r kid; do
    [ -z "$kid" ] && continue
    item "$kid" | jq -r "
      select(. != null and .deleted!=true and .dead!=true) |
      \"  \u001b[33m•\u001b[0m \u001b[32m\" + (.by // \"[deleted]\") + \"\u001b[0m  \" +
      ( .text // \"[no text]\" | $clean_html )"
  done < <(item "$id" | jq -r ".kids? // [] | .[:$comments][]")
}

show_post() { # TSV row -> full pager with wrapped comments
  IFS=$'\t' read -r title by score desc hn_url ext_url id snippet <<<"$1"
  {
    post_header "$title" "$by" "$score" "$desc" "$hn_url" "$ext_url" "$id" "$snippet"
    printf '\n\e[36mTop %s comments\e[0m\n' "$comments"
    while read -r kid; do
      [ -z "$kid" ] && continue
      item "$kid" | jq -r "
        select(. != null and .deleted!=true and .dead!=true) |
        \"\n  \u001b[33m\" + (.id|tostring) + \")\u001b[0m \u001b[32m\" + (.by // \"[deleted]\") + \"\u001b[0m\n    \" +
        ( .text // \"[no text]\" | $clean_html )"
    done < <(item "$id" | jq -r ".kids? // [] | .[:$comments][]")
    echo
  } | less -R
}

open_url() { # prefer external; fallback HN link
  IFS=$'\t' read -r _ _ _ _ hn_url ext_url _ _ <<<"$1"
  url="${ext_url:-$hn_url}"
  if command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$url"
  elif command -v xdg-open       >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1
  fi
}

export api ua comments clean_html
export -f item preview_block show_post open_url post_header

printf '\e[36mHN %s — showing %s stories\e[0m\n\n' "$mode" "$posts"

# ----- interactive loop -----
tsv=$(mktemp)
trap 'rm -f "$tsv"' EXIT
get_posts > "$tsv"
export TSV="$tsv"

while :; do
  sel=$(
    # Feed fzf only "<idx>\t<title>"
    awk -F'\t' '{printf "%d\t%s\n", NR, $1}' "$TSV" |
    fzf --ansi --height=100% --reverse \
        --expect=enter,ctrl-o,ctrl-r \
        --prompt='Enter: comments • Ctrl-O: open • Ctrl-R: refresh • Esc: quit > ' \
        --preview 'bash -lc '\''i=$(cut -f1 <<<"$1"); r=$(awk -v n="$i" "NR==n{print;exit}" "$TSV"); preview_block "$r"'\'' -- {} ' \
        --preview-window=down,70%,border
  ) || break

  key=$(printf '%s\n' "$sel" | sed -n '1p')
  idx=$(printf '%s\n' "$sel" | sed -n '2p' | cut -f1)
  [ -z "$idx" ] && break

  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$TSV")

  case "$key" in
    enter)  show_post "$row" ;;     # q returns to list
    ctrl-o) open_url "$row" ;;      # prefer external, fallback HN
    ctrl-r) get_posts > "$TSV" ;;   # refresh data and re-list
    *)      break ;;
  esac
done

