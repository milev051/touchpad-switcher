#!/bin/bash
# Dupli klik u Finder-u: preuzmi izmene sa GitHub-a, napravi aplikaciju
# ponovo i pokreni novu verziju. Isto radi dugme "Ažuriraj" u meniju aplikacije.
cd "$(dirname "$0")" || exit 1

if make update; then
    echo
    echo "Ažurirano. Nova verzija je pokrenuta."
else
    echo
    echo "Ažuriranje nije uspelo. Poruke iznad pokazuju zašto."
fi
read -r -p "Pritisni Enter za zatvaranje."
