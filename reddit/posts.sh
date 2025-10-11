# reddit/posts.sh [sub] [mode=top|hot|new|rising|controversial] [posts=25] [time=""] [comments=5]

sub="${1:-programming}"; mode="${2:-top}"; posts="${3:-25}"; time="${4:-}"; comments="${5:-5}"
ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

base="https://old.reddit.com/r/$sub/$mode/.json?raw_json=1&limit=$posts"
[[ -n "$time" && ( "$mode" == "top" || "$mode" == "controversial" ) ]] && base="${base}&t=$time"

# TSV per row: title \t author \t score \t num_comments \t permalink \t selftext
get_posts() {
  curl -fsSL --compressed -A "$ua" -e "https://old.reddit.com/" "$base" |
  jq -r '.data.children[]? | select(.data.stickied|not) | .data as $d |
         [ $d.title,
           $d.author,
           ($d.score|tostring),
           ($d.num_comments|tostring),
           $d.permalink,
           ( ($d.selftext // "") | gsub("\r";"") | gsub("\n+";" ") | gsub("  +";" ") )
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
  post_header "$title" "$author" "$score" "$ncom" "$perma" "$selftext"
  printf '\n\e[36mTop %s comments\e[0m\n' "$comments"
  curl -fsSL --compressed -A "$ua" -e "https://old.reddit.com/" \
    "https://old.reddit.com${perma}.json?raw_json=1&limit=${comments}" |
  jq -r --argjson n "$comments" '
    .[1].data.children? // [] |
    map(select(.kind=="t1" and .data.body!=null)) |
    sort_by(-.data.score)[0:$n] |
    to_entries[] |
    "  \u001b[33m" + ((.key+1|tostring)) + ")\u001b[0m \u001b[32m" + .value.data.author +
    "\u001b[0m  (" + (.value.data.score|tostring) + "↑)\n    " +
    (.value.data.body | gsub("\r";"") | gsub("\n+";" ") | gsub("  +";" ")) + "\n"
  '
}

# Pager view with wrapped comments
show_post() { # $line = full TSV row
  IFS=$'\t' read -r title author score ncom perma selftext <<<"$1"
  { post_header "$title" "$author" "$score" "$ncom" "$perma" "$selftext"
    printf '\n\e[36mTop %s comments\e[0m\n' "$comments"
    curl -fsSL --compressed -A "$ua" -e "https://old.reddit.com/" \
      "https://old.reddit.com${perma}.json?raw_json=1&limit=${comments}" |
    jq -r --argjson n "$comments" '
      .[1].data.children? // [] |
      map(select(.kind=="t1" and .data.body!=null)) |
      sort_by(-.data.score)[0:$n] |
      to_entries[] |
      "  \u001b[33m" + ((.key+1|tostring)) + ")\u001b[0m \u001b[32m" + .value.data.author +
      "\u001b[0m  (" + (.value.data.score|tostring) + "↑)\n    " +
      (.value.data.body | gsub("\r";"") | gsub("\n+";" ") | gsub("  +";" ")) + "\n"
    '
  } | less -R
}

open_url() { # $perma
  url="https://old.reddit.com$1"
  if command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$url"
  elif command -v xdg-open       >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1
  fi
}

export ua comments
export -f preview_block show_post open_url post_header

printf '\e[36mHere you go, %s %s posts from r/%s%s\e[0m\n\n' "$posts" "$mode" "$sub" \
  $([[ -n "$time" && ( "$mode" == top || "$mode" == controversial ) ]] && printf " (t=%s)" "$time")

# FZF: display full titles, keep all fields intact
tsv=$(mktemp)
trap 'rm -f "$tsv"' EXIT
get_posts > "$tsv"
export TSV="$tsv"

while :; do
  sel=$(
    # show only "<idx>\t<title>" to fzf
    awk -F'\t' '{printf "%d\t%s\n", NR, $1}' "$TSV" |
    fzf --ansi --height=100% --reverse \
        --expect=enter,ctrl-o,ctrl-r \
        --prompt='Enter: comments • Ctrl-O: open • Ctrl-R: refresh • Esc: quit > ' \
        --preview 'bash -lc '\''idx=$(cut -f1 <<<"$1"); row=$(awk -v n="$idx" "NR==n{print;exit}" "$TSV"); preview_block "$row"'\'' -- {} ' \
        --preview-window=down,70%,border
  ) || exit 0

  key=$(printf '%s\n' "$sel" | sed -n '1p')
  idx=$(printf '%s\n' "$sel" | sed -n '2p' | cut -f1)
  [ -z "$idx" ] && exit 0

  row=$(awk -v n="$idx" 'NR==n{print;exit}' "$TSV")

  case "$key" in
    enter)  show_post "$row" ;;                                  # q returns to list
    ctrl-o) perma=$(printf '%s' "$row" | cut -f5); open_url "$perma" ;;
    ctrl-r) get_posts > "$TSV" ;;                                # refresh list/data
    *)      exit 0 ;;
  esac
done

