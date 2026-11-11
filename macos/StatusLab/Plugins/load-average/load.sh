#!/bin/sh
# Load average: an example Ghostty Status Lab plugin package, in plain sh.
#
# Writes one status protocol v1 record every 5 seconds; the host stops a plugin that is
# silent for 10 seconds. Exits when Ghostty closes the pipe.
while :; do
  # "{ 1.52 1.73 1.80 }": the 1, 5 and 15 minute averages.
  set -- $(sysctl -n vm.loadavg)
  printf '{"version":1,"widgets":[{"id":"load","label":"LOAD","value":"%s %s %s","color":"8BE9FD"}]}\n' \
    "$2" "$3" "$4" || exit 0
  sleep 5
done
