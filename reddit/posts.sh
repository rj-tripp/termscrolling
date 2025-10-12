# reddit/posts.sh [sub] [mode=top|hot|new|rising|controversial] [posts=25] [time=""] [comments=5]

sub="${1:-all}"; mode="${2:-hot}"; posts="${3:-25}"; time="${4:-}"; comments="${5:-5}"
ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

base="https://old.reddit.com/r/$sub/$mode/.json?raw_json=1&limit=$posts"
[[ -n "$time" && ( "$mode" == "top" || "$mode" == "controversial" ) ]] && base="${base}&t=$time"

# TSV per row: title \t author \t score \t num_comments \t permalink \t selftext
get_posts() {
  curl -fsSL --compressed -A "$ua" -e "https://old.reddit.com/" "$base" |
  jq -r '.data.children[]? | select(.data.stickied|not) | .data as $d |
        [ ($d.title     // "" | gsub("\t";" ")),
          ($d.author    // ""),
          ($d.score     // 0 | tostring),
          ($d.num_comments // 0 | tostring),
          ($d.permalink // ""),
          ( ($d.selftext // "") | gsub("\r";"") | gsub("\n+";" ") | gsub("\t";" ") | gsub("  +";" ") )
        ] | @tsv'
}

# Print post header block for preview/pager
post_header() { # $1..$6 = title, author, score, comments, perma, selftext
  printf '\e[1m%s\e[0m\n' "$1"
  printf 'u:%s  %s↑  💬 %s\n' "$2" "$3" "$4"
  printf 'https://old.reddit.com%s\n' "$5"
  if [ -n "$6" ]; then
    printf '\n%s\n' "$6"
  fi
}

# Preview combines header + top comments (truncated to one line each)
preview_block() { # $line = full TSV row
  IFS=$'\t' read -r title author score ncom perma selftext <<<"$1"
  [[ "$perma" != /* ]] && perma="/$perma"

  post_header "$title" "$author" "$score" "$ncom" "$perma" "$selftext"

  printf '\n\e[36mTop %s comments\e[0m\n' "$comments"
  fetch=$(( comments * 6 ))               # overfetch to bypass "more" & removals (cap is ~200)
  curl -fsSL --compressed -A "$ua" -e "https://old.reddit.com/" \
    "https://old.reddit.com${perma}.json?raw_json=1&sort=top&depth=1&limit=${fetch}" |
  jq -r --argjson n "$comments" '
    .[1].data.children? // []                                       # the comments listing
    | map(select(.kind=="t1" and (.data.body // "") != ""))         # only real comments with text
    | sort_by(-.data.score // 0)                                    # ensure top by score
    | .[0:$n]
    | to_entries[]
    | "  \u001b[33m" + ((.key+1|tostring)) + ")\u001b[0m \u001b[32m" + (.value.data.author // "[deleted]") +
      "\u001b[0m  (" + ((.value.data.score // 0)|tostring) + "↑)\n    " +
      ((.value.data.body | gsub("\r";"") | gsub("\n+";" ") | gsub("\t";" ") | gsub("  +";" ")) // "") + "\n"
  '
}

# Pager view with wrapped comments
show_post() { # $line = full TSV row
  IFS=$'\t' read -r title author score ncom perma selftext <<<"$1"
  [[ "$perma" != /* ]] && perma="/$perma"

  {
    post_header "$title" "$author" "$score" "$ncom" "$perma" "$selftext"
    printf '\n\e[36mTop %s comments\e[0m\n' "$comments"
    fetch=$(( comments * 6 ))
    curl -fsSL --compressed -A "$ua" -e "https://old.reddit.com/" \
      "https://old.reddit.com${perma}.json?raw_json=1&sort=top&depth=1&limit=${fetch}" |
    jq -r --argjson n "$comments" '
      .[1].data.children? // []
      | map(select(.kind=="t1" and (.data.body // "") != "")) 
      | sort_by(-.data.score // 0)
      | .[0:$n]
      | to_entries[]
      | "\n  \u001b[33m" + ((.key+1|tostring)) + ")\u001b[0m \u001b[32m" + (.value.data.author // "[deleted]") + "\u001b[0m  (" +
        ((.value.data.score // 0)|tostring) + "↑)\n    " +
        ((.value.data.body | gsub("\r";"") | gsub("\n+";" ") | gsub("\t";" ") | gsub("  +";" ")) // "") + "\n"
    '
  } | less -R
}


open_url() { # $perma (may start without '/')
  perma="$1"
  [[ "$perma" != /* ]] && perma="/$perma"
  url="https://old.reddit.com$perma"

  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$url"
  elif command -v open >/dev/null 2>&1; then                # macOS
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then            # Linux
    xdg-open "$url" >/dev/null 2>&1
  else
    printf 'Open this URL:\n%s\n' "$url"
  fi
}


if [[ "$1" == "__preview" ]]; then
  idx="$2"; TSV="$3"
  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$TSV")
  preview_block "$row"
  exit
elif [[ "$1" == "__show" ]]; then
  idx="$2"; TSV="$3"
  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$TSV")
  show_post "$row"
  exit
fi

printf '\e[36mHere you go, %s %s posts from r/%s%s\e[0m\n\n' "$posts" "$mode" "$sub" \
  $([[ -n "$time" && ( "$mode" == top || "$mode" == controversial ) ]] && printf " (t=%s)" "$time")

# FZF: display full titles, keep all fields intact
# ----- interactive loop (full-title list, script-reentrant) -----
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

  case "$key" in
    enter)  "$0" __show "$idx" "$tsv" ;;      # q returns to list
    ctrl-o) row=$(awk -v n="$idx" 'NR==n{print;exit}' "$tsv")
            perma=$(printf '%s' "$row" | cut -f5)
            [[ "$perma" != /* ]] && perma="/$perma"
            open_url "$perma" ;;
    ctrl-r) get_posts > "$tsv" ;;
    *)      break ;;
  esac
done
