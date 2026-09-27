#!/bin/bash
# Dupli klik u Finder-u: napravi Touchpad Switcher iz ovog foldera,
# stavi ga u /Applications i pokrene ga.
cd "$(dirname "$0")" || exit 1

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Potrebni su Xcode Command Line Tools (alati za pravljenje aplikacije)."
    echo "Otvara se njihova instalacija. Kad se završi, ponovo pokreni ovaj fajl."
    xcode-select --install
    read -r -p "Pritisni Enter za zatvaranje."
    exit 1
fi

if make install-ring; then
    open -n "/Applications/Touchpad Switcher.app"
    echo
    echo "Instalirano. Ikonica šake je u gornjoj traci."
    echo "Dozvole i podešavanje trackpada: INSTALACIJA.md"
else
    echo
    echo "Instalacija nije uspela. Poruke iznad pokazuju zašto."
fi
read -r -p "Pritisni Enter za zatvaranje."
