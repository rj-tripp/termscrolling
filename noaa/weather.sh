# weather-tui.sh [lat lon]
# Needs: curl jq fzf
# Current conditions shown in °F; wind in mph; pressure in inHg.

DEFAULT_LAT="42.27"
DEFAULT_LON="-89.02"

set -euo pipefail

lat="${1:-$DEFAULT_LAT}"
lon="${2:-$DEFAULT_LON}"
ua="TermuxWeather/1.0 (you@example.com)"

# Global variables
forecast_url=""
hourly_url=""
stations_url=""
office=""
gridxy=""
station="" # Station ID (e.g., KRFD)
city=""
state=""
station_name="" # Human-readable station name

# ---------- helpers ----------
jqn() { jq -r "$@" 2>/dev/null; } # quiet jq helper

fetch_points() {
  curl -sS -H "User-Agent: $ua" "https://api.weather.gov/points/$lat,$lon" || echo "{}"
}

resolve_meta() {
  local meta="$1"
  forecast_url=$(echo "$meta" | jqn '.properties.forecast')
  hourly_url=$(echo "$meta"   | jqn '.properties.forecastHourly')
  stations_url=$(echo "$meta" | jqn '.properties.observationStations')
  office=$(echo "$meta"       | jqn '.properties.gridId')
  gridxy=$(echo "$meta"       | jqn '("\(.properties.gridX),\(.properties.gridY)")')
}

nearest_station() {
  # FIX: Add || true to prevent immediate exit on error
  curl -sS -H "User-Agent: $ua" "$stations_url" \
    | jqn '.features[0].properties.stationIdentifier' || true
}

resolve_location() {
  local meta="$1"
  # Use coordinates as fallback if city/state are null or empty
  city_raw=$(echo "$meta" | jqn '.properties.relativeLocation.properties.city')
  state_raw=$(echo "$meta" | jqn '.properties.relativeLocation.properties.state')

  city="${city_raw:-$lat}"
  state="${state_raw:-$lon}"
  
  # Fetch the human-readable station name
  station_name=$(
    curl -sS -H "User-Agent: $ua" "$stations_url" \
    | jqn '.features[0].properties.name' || echo "Unknown Station"
  )
}

# °C -> °F, m/s -> mph, Pa -> inHg, m -> miles (do inside jq)
current_conditions() {
  local st="$1"
  # FIX: Ensure curl in current_conditions is robust
  curl -sS -H "User-Agent: $ua" "https://api.weather.gov/stations/$st/observations/latest?require_qc=false" \
  | jq -r '
    def nf(x): if (x|type)=="number" then x else null end;
    def c2f: ( . * 9/5 + 32 );
    def ms2mph: ( . * 2.23693629 );
    def pa2inhg: ( . * 0.000295299830714 );
    def m2mi: ( . / 1609.344 );

    .properties as $p |
    [
      ($p.textDescription // "—"),
      ( (nf($p.temperature.value))        | if .==null then "—" else (c2f|round|tostring) + "°F" end),
      ( (nf($p.windSpeed.value))          | if .==null then "—" else (ms2mph|.*100|round/100|tostring) + " mph" end),
      ( (nf($p.windGust.value))           | if .==null then "—" else (ms2mph|.*100|round/100|tostring) + " mph" end),
      ( (nf($p.relativeHumidity.value))   | if .==null then "—" else (round|tostring) + "%" end),
      ( (nf($p.barometricPressure.value)) | if .==null then "—" else (pa2inhg|.*100|round/100|tostring) + " inHg" end),
      ( (nf($p.visibility.value))         | if .==null then "—" else (m2mi|.*100|round/100|tostring) + " mi" end),
      ($p.station // "—"),
      ($p.timestamp // "—")
    ] | @tsv' || echo "—	—	—	—	—	—	—	—	—"
}

daily_forecast() {
  curl -sS -H "User-Agent: $ua" "$forecast_url" \
  | jq -r '.properties.periods[]
           | "\(.name): \(.temperature)°\(.temperatureUnit)  \(.shortForecast)"' || echo "Failed to fetch daily forecast."
}

hourly_forecast() {
  curl -sS -H "User-Agent: $ua" "$hourly_url" \
  | jq -r '.properties.periods[0:12][] 
           | "\(.startTime | sub("T";" ") | .[0:16])  \(.temperature)°\(.temperatureUnit)  \(.shortForecast)"' || echo "Failed to fetch hourly forecast."
}

alerts_list() {
  curl -sS -H "User-Agent: $ua" "https://api.weather.gov/alerts?point=$lat,$lon&status=actual&message_type=alert" \
  | jq -r '
      .features
      | if length==0 then "No active alerts"
        else .[] | .properties as $p
             | "* \($p.event): \($p.headline // $p.description // "—")"
        end' || echo "Failed to fetch alerts."
}

weather_art() {
  local desc="${1,,}" # Convert to lowercase for matching
  local art=""

  case "$desc" in
    *sunny*|*clear*)
      # Simplified Sun Art
      art="\e[33m  \\ / \n  -- \n  / \\ \e[0m"
      ;;
    *cloudy*|*overcast*)
      art="\e[37m     _.-'\n  / / / \n | | | \n  \\ \\_\\ \e[0m"
      ;;
    *rain*|*drizzle*|*shower*)
      art="\e[34m     .-.   \n    (   )  \n   (.-. ) \n  (\`-\`\`\` ) \n   \`-\'-\'  \e[0m"
      ;;
    *snow*|*flurry*|*ice*)
      art="\e[36m     .-.   \n    (   )  \n   (.-. ) \n  (* * *) \n   \`-\'-\'  \e[0m"
      ;;
    *thunder*)
      art="\e[33m   /\\/\\/\\/\\\n  / / / /\e[37m \n \e[33m| | | |\e[37m \n  \\ \\_\\_\\⚡\e[0m"
      ;;
    *)
      art="   (???)" # Default for unknown
      ;;
  esac
  printf '%b' "$art"
}


print_current() {
  # FIX: Explicitly set IFS to tab for correct TSV parsing.
  local IFS=$'\t'
  if ! read -r desc tempF wind gust rh press vis station_id ts <<<"$(current_conditions "$1")"; then
    printf '\e[31mError: Could not retrieve current conditions data.\e[0m\n'
    return 1
  fi
  # IFS is restored automatically when the function exits

  local art
  art=$(weather_art "$desc")

  printf '\e[1mCurrent Conditions for %s, %s\e[0m\n' "$city" "$state"
  printf '\n%s\n' "$art"
  printf 'Desc: %s\n' "$desc"
  printf 'Temp: %s\n' "$tempF"
  printf 'Wind: %s' "$wind"
  [ "$gust" != "—" ] && printf ' (gust %s)' "$gust"
  printf '\n'
  # Now the variables should be correctly assigned: RH, Pressure, Visibility
  printf 'RH:   %s   Pressure: %s   Vis: %s\n' "$rh" "$press" "$vis"
  printf 'Station: %s (%s)\n' "$station_name" "$station_id"
  # FIX: Only the timestamp is printed on the final line
  printf 'At: %s\n' "$ts"
}

print_hourly() {
  printf '\e[1mHourly (next 12)\e[0m\n'
  hourly_forecast
}

print_daily() {
  printf '\e[1mDaily (7-day)\e[0m\n'
  daily_forecast
}

print_alerts() {
  printf '\e[1mActive Alerts\e[0m\n'
  alerts_list
}

# ----------------- RE-ENTRANT LOGIC -----------------
# $1 = __preview or __show
# $2 = command (current, hourly, etc.)
# $3 = station (station ID)
# $4 = original_lat (used for re-bootstrap)
# $5 = original_lon (used for re-bootstrap)

if [[ "${1-}" == "__preview" ]] || [[ "${1-}" == "__show" ]]; then
  
  # 1. Use passed lat/lon to re-bootstrap metadata in the sub-shell
  if [[ -n "${4-}" ]] && [[ -n "${5-}" ]]; then
      lat="$4"
      lon="$5"
      meta="$(fetch_points)"
      resolve_meta "$meta"
      resolve_location "$meta" || true 
      station="$3"
  fi

  # 2. Handle the __show command (opens less pager)
  if [[ "${1-}" == "__show" ]]; then
    { "$0" __preview "$2" "$3" "$4" "$5"; echo; } | less -R
    exit
  fi

  # 3. Handle the __preview command
  case "$2" in
    current) print_current "$3" ;;
    hourly)  print_hourly ;;
    daily)   print_daily ;;
    alerts)  print_alerts ;;
  esac
  exit
fi
# --------------------------------------------------------

# ---------- bootstrap meta (main process) ----------
meta="$(fetch_points)"
resolve_meta "$meta"

station="$(nearest_station)" || station=""
resolve_location "$meta" || true

# FINAL FIX: Determine what to display in the header
if [[ "$city" == "$lat" ]] && [[ "$state" == "$lon" ]]; then
    location_display="at $lat, $lon"
else
    location_display="$city, $state"
fi

printf '\e[36mNOAA/NWS Weather — %s (office %s grid %s)\e[0m\n\n' "$location_display" "$office" "$gridxy"

# Clear screen to prevent display artifacts on re-draw
clear

# ---------- interactive fzf ----------
while :; do
  choice=$(
    printf "current\tCurrent Conditions (°F)\nhourly\tNext 12 Hours\ndaily\t7-Day Forecast\nalerts\tActive Alerts\nrefresh\tRefresh\nquit\tQuit\n" |
    fzf --ansi --height=60% --reverse \
        -d '\t' \
        --with-nth=2 \
        --expect=enter \
        --prompt='Select • Enter: open • Esc: quit > ' \
        --preview "$0 __preview {1} '$station' '$lat' '$lon'" \
        --preview-window=right,70%,border
  ) || break

  key=$(printf '%s\n' "$choice" | sed -n '1p')
  sel=$(printf '%s\n' "$choice" | sed -n '2p' | cut -f1)

  # For actions, we now pass lat/lon to the __show command
  case "$sel" in
    current) "$0" __show current "$station" "$lat" "$lon" ;;
    hourly)  "$0" __show hourly "$station" "$lat" "$lon" ;;
    daily)   "$0" __show daily "$station" "$lat" "$lon" ;;
    alerts)  "$0" __show alerts "$station" "$lat" "$lon" ;;
    refresh)
      meta="$(fetch_points)"; resolve_meta "$meta"; station="$(nearest_station)" || station=""; resolve_location "$meta" || true
      clear
      ;;
    quit|"") break ;;
  esac
done
