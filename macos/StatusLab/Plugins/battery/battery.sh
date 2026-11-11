#!/bin/sh
# Battery: an example Ghostty Status Lab plugin package, in plain sh.
#
# Writes one status protocol v1 record every 5 seconds; the host stops a plugin that is
# silent for 10 seconds. Exits when Ghostty closes the pipe.
while :; do
  info=$(pmset -g batt 2>/dev/null)
  percent=$(printf '%s\n' "$info" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%.*/\1/p' | head -n 1)
  if [ -z "$percent" ]; then
    value="AC"
    symbol="powerplug"
    color="8E8E93"
  else
    value="$percent%"
    case "$info" in
      *"AC Power"*) symbol="battery.100.bolt" ;;
      *)
        if [ "$percent" -ge 75 ]; then symbol="battery.100"
        elif [ "$percent" -ge 50 ]; then symbol="battery.75"
        elif [ "$percent" -ge 25 ]; then symbol="battery.50"
        else symbol="battery.25"
        fi ;;
    esac
    if [ "$percent" -le 15 ]; then color="FF6B6B"; else color="7BD88F"; fi
  fi
  printf '{"version":1,"widgets":[{"id":"battery","label":"BAT","value":"%s","color":"%s","symbol":"%s"}]}\n' \
    "$value" "$color" "$symbol" || exit 0
  sleep 5
done
