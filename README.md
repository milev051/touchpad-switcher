# Touchpad Switcher

> **English:** A macOS menu-bar app (macOS 14+) for switching windows and Chrome
> tabs with a three-finger trackpad gesture: a radial menu of live window
> thumbnails opens, you move your fingers toward a card and lift to switch, no
> clicks needed. Written in Objective-C (Cocoa/AppKit, Core Animation,
> ScreenCaptureKit, Accessibility API, AppleScript) and reads raw touches from
> the private MultitouchSupport framework. The rest of this README is in Serbian.

macOS aplikacija za prebacivanje između prozora i tabova gestom sa tri prsta
na trackpadu, bez klikova i bez tastature. Kad se tri prsta spuste na trackpad,
na sredini ekrana se otvara kružni meni sa karticama otvorenih prozora i
Chrome tabova (sa sličicama). Pomeranjem prstiju bira se kartica, a podizanjem
prstiju aplikacija prelazi na izabrani prozor.

Aplikacija radi u gornjoj traci (ikonica šake), nema ikonicu u Dock-u i
instalira se kao `/Applications/Touchpad Switcher.app` (bundle ID
`com.milev.touchpad-switcher`, trenutna verzija 1.0.6).

Napisana je u **Objective-C** (Cocoa/AppKit, Core Animation), kompajlira se sa
`clang` preko `Makefile`-a. Dodire čita direktno iz privatnog okvira
`MultitouchSupport`, sličice pravi preko `ScreenCaptureKit`, prozore prati
preko Accessibility (AX) API-ja, a Chrome tabove preko AppleScript-a
(Apple Events).

## Zahtevi

- macOS 14 (Sonoma) ili noviji; Apple Silicon ili Intel.
- Trackpad (ugrađeni ili Magic Trackpad). Bez trackpada meni može da se otvara
  dugmetom miša (vidi Aktivacija mišem).
- Xcode Command Line Tools za pravljenje aplikacije iz izvornog koda.
- Tri prsta ne smeju biti zauzeta sistemskim gestovima (vidi niže).

### Dozvole

| dozvola | čemu služi |
|---|---|
| Screen Recording | sličice prozora na karticama i zamućena pozadina menija |
| Accessibility (na macOS-u 27: Device Control and Data Access) | precizniji prelazak na prozor, Finder i Terminal tabovi, događaji prozora, aktivacija mišem, „Spusti sve prozore” |
| Automation → Google Chrome | spisak Chrome tabova, izbor taba, pravila za video |

Posle uključivanja Screen Recording ili Accessibility dozvole aplikaciju treba
ponovo pokrenuti. Dozvole ostaju posle ažuriranja, jer se aplikacija uvek
potpisuje istim identifikatorom.

### Sistemski gestovi sa tri prsta

Ako macOS koristi tri prsta za Mission Control, App Exposé, prelazak između
ekrana, listanje stranica ili prevlačenje, meni ostaje zaključan i aplikacija
prikazuje obaveštenje sa dugmadima za odgovarajuća podešavanja. Rešenje:

- **System Settings → Trackpad → More Gestures**: Mission Control, App Exposé i
  prelazak između ekrana na četiri prsta, listanje stranica na dva prsta.
- **System Settings → Accessibility → Pointer Control → Trackpad Options**:
  isključiti Three Finger Drag.

Provera se radi pri pokretanju, jednom u sekundi i pre svakog otvaranja menija,
posebno za ugrađeni i Bluetooth trackpad. Meni se otključava sam čim se konflikt
ukloni.

## Kako se koristi

### Gest sa tri prsta

1. **Spusti tri prsta** na trackpad (bilo gde, položaj kursora nije bitan).
   Otvara se kružni meni: kartice prozora i tabova raspoređene u krug oko
   centra ekrana, ekran iza njih je zatamnjen i zamućen.
2. **Pomeri prste** u smeru kartice. Pokazivač menija kreće iz centra i bira
   najbližu karticu; izabrana kartica se uveća. Pokret ima ubrzanje kao miš:
   spor pokret je precizan, brz prebacuje na drugu stranu kruga.
3. **Podigni prste** (dovoljno je da ostanu jedan ili dva). Aplikacija prelazi
   na izabrani prozor ili tab, a kartica se animirano uveća do pravog položaja
   prozora.

Ostala pravila geste:

- **Odustajanje**: podizanje prstiju dok je pokazivač u centralnom krugu (X i
  poruka „Otpusti za izlazak”) ne bira ništa.
- **Brzi tap**: tap sa tri prsta kraći od 0,5 s, bez pomeranja, vraća prethodni
  prozor. Uzastopni tapovi prebacuju između poslednja dva prozora.
- **Četiri prsta** poništavaju trenutni izbor (osim kad su podešena za meni
  prečica). Vraćanje na tri prsta odmah otvara nov meni.
- **Ponovni izbor bez podizanja ruke**: sa jednog ili dva prsta nazad na tri
  otvara nov meni.
- **Više od 10 kartica**: meni ih deli na stranice; leva i desna strelica na
  tastaturi menjaju stranicu.
- Dok je meni otvoren, sistemski kursor je sakriven, a skrol i pomeranje
  pokazivača su blokirani za aplikaciju ispod.

### Šta se nalazi na karticama

- Svaki otvoren prozor, uključujući minimizovane i prozore na drugim desktopima.
  Prelazak radi i na drugi Space i u full screen.
- Svaki Chrome tab kao zasebna kartica, sa sopstvenom sličicom i ikonicom sajta.
- Aplikacija bez otvorenih prozora nema karticu.
- Opciono: režim „samo aplikacije” (jedna kartica po aplikaciji, Chrome po
  prozoru), Finder tabovi jednog prozora kao jedna kartica, trenutni prozor u
  centru umesto X-a.

Sličice se snimaju u smanjenoj rezoluciji i čuvaju samo u memoriji. Snimaju se
prozori sa trenutnog desktopa; Chrome tab koji nikad nije bio vidljiv prikazuje
ikonicu sajta dok ga korisnik ne otvori.

### Meni prečica

U Podešavanjima > Prečice bira se kako se otvara poseban meni prečica: nema ga,
dok se drži **Cmd**, dok je dodat **četvrti prst**, ili oba (podrazumevano Cmd).
Prečice: Downloads, Desktop, Documents, novi Chrome tab, novi YouTube tab i
**Spusti sve prozore** (minimizuje sve prozore preko Accessibility-ja). Svaka
prečica može da se prikaže u posebnom meniju (**Meni**) i/ili stalno među
prozorima (**Stalno**).

### Aktivacija mišem

U panelu ikonice šake, pod **Aktivacija mišem**, klik na **Snimi dugme** i
pritisak na dugme miša (Esc otkazuje, **Isključi** gasi). Drži dugme, pomeri miš
ka kartici i pusti. Logi bočna dugmad (Back/Forward) rade na klik: klik otvara
meni, isto dugme ili levi klik bira. Potrebna je Accessibility dozvola.

## Podešavanja

Klik na ikonicu šake u gornjoj traci otvara prozor podešavanja (zatvara se na
Esc, Cmd+W ili klik van prozora). Podešavanja se čuvaju u
`defaults read com.milev.touchpad-switcher`.

| podešavanje | podrazumevano |
|---|---|
| Kartice: prozori i tabovi, ili samo aplikacije | prozori i tabovi |
| Naslovi na karticama, vidljiv pokazivač, zvuci | isključeno |
| Zamućenje pozadine | 20 |
| Boja pokazivača i svetla (boja sistema ili belo) | boja sistema |
| Svetlo u smeru prstiju | uključeno |
| Pozadina iza kartica (boja i jačina 0 do 90%) | skoro crna, 50% |
| Uvećanje pozadine (paralaksa, 0 do 25%) | 5% |
| Trenutni prozor ili tab u centru | isključeno |
| Finder tabovi jednog prozora kao jedna kartica | isključeno |
| Snimci prozora na karticama | uključeno |
| Ikonice sajtova na Chrome karticama | uključeno |
| Ikonice aplikacija na karticama | uključeno |
| Izabrana kartica se uveća do prozora (zum) | uključeno |
| Prečice (meni prečica, Meni / Stalno) | Cmd, stalne prečice isključene |
| Aktivacija mišem, držanje dugmeta | isključeno, držanje uključeno |
| Video u Chrome-u (vidi niže) | većina isključena |
| Sakrij ikonicu iz gornje trake | isključeno |
| Pokreni pri uključivanju računara | uključeno |

Sakrivena ikonica se vraća kad se aplikacija ponovo otvori (Spotlight ili
`/Applications`). Zum se ne radi za minimizovane i skrivene prozore, prozore na
drugom desktopu i kad je uključeno **Reduce motion**.

### Video u Chrome-u

Opciona pravila (`ring_media.m`): zaustavi video kad napustiš tab ili Chrome,
pokreni ga ponovo pri povratku, pokreni i ručno pauziran video, važi i za klik
na tab i prečice, zaustavi samo ako novi tab ima video, i posle duže pauze
vrati 2 do 5 s unazad. Za ovo u Chrome-u treba uključiti
**View > Developer > Allow JavaScript from Apple Events**.

## Instalacija

Detaljno uputstvo, korak po korak: [INSTALACIJA.md](INSTALACIJA.md).

```bash
git clone https://github.com/milev051/touchpad-switcher.git ~/Applications/touchpad-switcher
cd ~/Applications/touchpad-switcher
./Instaliraj.command          # ili: make install-ring && open -n "/Applications/Touchpad Switcher.app"
```

`Instaliraj.command` (dupli klik u Finder-u) proverava Xcode Command Line Tools,
pravi aplikaciju za procesor ovog računara, potpisuje je, stavlja u
`/Applications` i pokreće. Pokretanje nove instance zamenjuje prethodnu.

### Ažuriranje

- u aplikaciji: ikonica šake > **Ažuriraj** (preuzima ZIP poslednjeg GitHub
  izdanja, lokalni klon nije potreban),
- dupli klik na `Ažuriraj.command`, ili `make update` (git pull, ponovno
  pravljenje i pokretanje).

### Make ciljevi

| cilj | šta radi |
|---|---|
| `make touchpad_ring_test` | kompajlira aplikaciju u `Touchpad Switcher.app` i potpisuje je |
| `make ring-test` | kompajlira i pokreće iz foldera |
| `make install-ring` | instalira u `/Applications` |
| `make update` | git pull, instalacija i pokretanje nove verzije |
| `make dist` | univerzalni binarni fajl (arm64 + x86_64) u `dist/Touchpad Switcher.zip` |
| `make layout-preview` | prozor za vizuelni pregled rasporeda kartica, bez trackpada i dozvola |

## Dijagnostika

- Podešavanja > **Otvori logove** otvara `~/Library/Logs/TouchpadSwitcher/`.
  `events.jsonl` beleži gestove, izbor, dozvole i rezultat prelaska (bez naslova
  stranica i URL-ova), rotira se na 4 MB.
- Praćenje uživo: `tail -F ~/Library/Logs/TouchpadSwitcher/events.jsonl`.
- Proces se zove `touchpad_ring_test` (`pgrep -fl touchpad_ring_test`).
- Automatske provere rasporeda i unosa:
  `make /tmp/touchpad-layout-preview && /tmp/touchpad-layout-preview --verify`
  (takođe `--verify-input`, `--verify-logs`, `--verify-system-gestures`).
- Test animacija bez trackpada: `defaults write com.milev.touchpad-switcher
  TestHooks -bool YES`, pa distribuirane notifikacije
  `com.milev.touchpad-switcher.test-pick` i `.test-record`
  (`ring_test_recording.m`).

## Organizacija koda

| fajl | sadržaj |
|---|---|
| `touchpad_ring_test.m` | glavni program: čitanje dodira, gest, kružni meni, inventar prozora i Chrome tabova, sličice, prelazak na prozor (podeljen oznakama `#pragma mark`) |
| `ring_settings.m` | čuvanje podešavanja i prozor podešavanja |
| `ring_window_events.m` | događaji prozora preko AXObserver-a i NSWorkspace-a umesto čestih provera |
| `ring_zoom.m` | zum izabrane kartice do prozora |
| `ring_media.m` | pravila za video u Chrome-u |
| `ring_favicons.m` | ikonice sajtova |
| `ring_update.m` | provera i instalacija novih izdanja sa GitHub-a |
| `ring_test_recording.m` | snimanje ekrana za automatske testove |
| `ring_shared.h` | zajednički tipovi i podešavanja |
| `tools/` | pregled rasporeda (`ring_layout_preview.m`) i generator ikonice aplikacije |

Novi modul se dodaje u `RING_MODULES` u `Makefile`-u.

### Stari prototip

`touchpad_switcher.m`, `touchpad_switcher.py` i `config.json` su prva verzija
ideje (septembar 2026): aplikacije iz Dock-a mapirane na zone/tastere na gornjoj
ivici trackpada, sa zaključavanjem kursora. Taj pristup je napušten i ne ulazi u
aplikaciju; `make build` / `make run` ga i dalje kompajliraju, a
`PLAN_AND_STATUS.md` opisuje njegovo stanje.
