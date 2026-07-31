#!/bin/sh
# PLAT-PROC escalation helper: IGNORES SIGTERM, so a polite stop cannot end it and
# only SIGKILL will. Prints READY first so the parent can know it is running before
# stopping it. `sleep` children die on the group TERM; the loop just makes another.
trap '' TERM
printf 'READY\n'
while true; do
    sleep 0.05
done
