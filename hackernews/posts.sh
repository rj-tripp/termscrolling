#!/usr/bin/env bash
# hn.sh [mode=top|new|best|ask|show|job] [posts=15] [comments=5]

api="https://hacker-news.firebaseio.com/v0"
ua="curl/hn-tui"

# ---------- helpers ----------
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

# jq filter: flatten HN HTML-ish text to plain text (and strip tabs)
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
  | gsub("\t"; " ")
  | gsub("\\s+"; " ")
'

# ---------- rows ----------
# TSV per row:
# title \t by \t score \t descendants \t hn_url \t external_url \t id \t snippet
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

# ---------- rendering ----------
post_header() { # $1..$8 = title, by, score, desc, hn_url, ext_url, id, snippet
  printf '\e[1m%s\e[0m\n' "$1"
  printf 'u:%s  %s↑  💬 %s\n' "$2" "$3" "$4"
  [ -n "$6" ] && printf 'link: %s\n' "$6"
  printf 'HN:   %s\n' "$5"
  [ -n "$8" ] && printf '\n%s\n' "$8"
}

# Build "top N" comments: over-fetch kids, filter deleted/dead/empty, sort by score.
print_top_comments() { # $1 = story id
  sid="$1"
  kids=$(curl -sSLA "$ua" "$api/item/$sid.json" | jq -r '.kids? // [] | .[:200][]') || {
    echo "  (no comments)"; return
  }
  [ -z "$kids" ] && { echo "  (no comments)"; return; }

  # fetch each kid; failed requests emit null so jq can skip them
  tsv=$(
    while read -r kid; do
      [ -n "$kid" ] && curl -sSLA "$ua" "$api/item/$kid.json" || echo null
    done <<<"$kids" \
    | jq -s -r --argjson n "${comments:-5}" '
        def clean:
          ( . // "" )
          | gsub("<p>"; "\n\n")
          | gsub("<[^>]+>"; "")
          | gsub("&quot;"; "\"")
          | gsub("&amp;"; "&")
          | gsub("&lt;"; "<")
          | gsub("&gt;"; ">")
          | gsub("&#x2F;"; "/")
          | gsub("\t"; " ")
          | gsub("\\s+"; " ")
        ;
        map(select(. != null and .deleted!=true and .dead!=true
                   and .type=="comment" and ((.text // "") | length) > 0))
        | sort_by(-(.score // 0))
        | .[0:$n]
        | if length==0 then [] else
            map([ (.by // "[deleted]"),
                  ((.score // 0)|tostring),
                  (.text // "" | clean) ] | @tsv)
          end
        | .[]
      '
  )

  if [ -z "$tsv" ]; then
    echo "  (no comments)"
    return
  fi

  i=1
  while IFS=$'\t' read -r author score body; do
    printf '  \e[33m%u)\e[0m \e[32m%s\e[0m  (%s↑)\n' "$i" "$author" "$score"
    printf '    %s\n\n' "$body"
    i=$((i+1))
  done <<<"$tsv"
}

preview_block() { # TSV row -> header + top N
  IFS=$'\t' read -r title by score desc hn_url ext_url id snippet <<<"$1"
  post_header "$title" "$by" "$score" "$desc" "$hn_url" "$ext_url" "$id" "$snippet"
  printf '\n\e[36mTop %s comments\e[0m\n' "${comments:-5}"
  print_top_comments "$id"
}

show_post() { # TSV row -> full pager
  IFS=$'\t' read -r title by score desc hn_url ext_url id snippet <<<"$1"
  {
    post_header "$title" "$by" "$score" "$desc" "$hn_url" "$ext_url" "$id" "$snippet"
    printf '\n\e[36mTop %s comments\e[0m\n' "${comments:-5}"
    print_top_comments "$id"
    echo
  } | less -R
}

open_url() { # prefer external; fallback HN; with macOS fallback
  IFS=$'\t' read -r _ _ _ _ hn_url ext_url _ _ <<<"$1"
  url="${ext_url:-$hn_url}"
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$url"
  elif command -v open >/dev/null 2>&1; then
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1
  else
    printf 'Open this URL:\n%s\n' "$url"
  fi
}

# ---------- subcommand dispatch (must be BEFORE arg parsing) ----------
if [[ "$1" == "__preview" ]]; then
  idx="$2"; TSV="$3"; comments="${comments:-5}"
  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$TSV")
  preview_block "$row"
  exit
elif [[ "$1" == "__show" ]]; then
  idx="$2"; TSV="$3"; comments="${comments:-5}"
  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$TSV")
  show_post "$row"
  exit
fi

# ---------- normal arg parsing (not triggered for subcommands) ----------
mode="${1:-top}"
posts="${2:-15}"
comments="${3:-5}"

printf '\e[36mHN %s — showing %s stories\e[0m\n\n' "$mode" "$posts"

# ---------- interactive loop (full-title list; delimiter-free) ----------
tsv=$(mktemp)
trap 'rm -f "$tsv"' EXIT
get_posts > "$tsv"

while :; do
  sel=$(
    awk -F'\t' '{printf "%d\t%s\n", NR, $1}' "$tsv" |
    fzf --ansi --height=100% --reverse \
        --expect=enter,ctrl-o,ctrl-r \
        --prompt='Enter: comments • Ctrl-O: open • Ctrl-R: refresh • Esc: quit > ' \
        --preview 'bash -lc '\''i=$(cut -f1 <<<"$1"); '"$0"' __preview "$i" "'"$tsv"'"'\'' -- {} ' \
        --preview-window=down,70%,border
  ) || break

  key=$(printf '%s\n' "$sel" | sed -n '1p')
  idx=$(printf '%s\n' "$sel" | sed -n '2p' | cut -f1)
  [ -z "$idx" ] && break

  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$tsv")

  case "$key" in
    enter)  "$0" __show "$idx" "$tsv" ;;  # q returns to list
    ctrl-o) open_url "$row" ;;
    ctrl-r) get_posts > "$tsv" ;;         # refresh data
    *)      break ;;
  esac
done
