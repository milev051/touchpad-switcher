# Touchpad Switcher (Kompaktni Tasteri & Pozicioniranje)

Prototip macOS alata koji koristi nisko-nivojski `MultitouchSupport` privatni sistemski okvir za praćenje dodira na trackpadu, mapiranje aplikacija po **tačnom redosledu u Dock-u**, sa **kompaktnom širinom tastera** (poput tastera na tastaturi), fleksibilnim **pozicioniranjem klastera** (centar, desni ugao, levi ugao, pun raspon) i **zaključavanjem kursora miša** dok se prst nalazi u gornjoj zoni trackpada.

Implementacija se nalazi u folderu:
`/Users/milev051/Desktop/Projects/Random/20260924 Touchpad Switcher/`

---

## 🎯 Ključne Mogućnosti

### 1. Kompaktna Širina Tastera (`--slot-width`)
Umesto da se zone rastežu preko celog trackpada (što je preširoko kada ima samo nekoliko aplikacija), svaka aplikacija dobija definisanu kompaktnu širinu, podrazumevano:
```
slotWidth = 0.12 (12% širine trackpada, odgovara veličini tastera na tastaturi)
```
Ukupna širina klastera tastera je:
```
W = min(N * slotWidth, 1.0)
```
Širina se može prilagoditi putem opcije `--slot-width <0.05-0.30>`.

### 2. Pozicioniranje Klastera (`--align`)
Klaster tastera se može smestiti na željeni deo gornje ivice pomoću `--align <center|right|left|full>`:

- **`center` (podrazumevano)**: Klaster je centriran na sredini gornje ivice:
  `xStart = (1.0 - W) / 2.0`
- **`right`**: Klaster je smešten u gornjem desnom uglu trackpada:
  `xStart = 1.0 - W` (idealno za brzi desni palac ili kažiprst)
- **`left`**: Klaster je smešten u gornjem levom uglu trackpada:
  `xStart = 0.0`
- **`full`**: Rasteže tastere preko celog trackpada kao u ranijim verzijama (`slotWidth = 1.0 / N`).

### 3. Vizuelni Prikaz Trackpada u Terminalu (ASCII Bar)
Prilikom pokretanja i svake promene aplikacija, program iscrtava ASCII traku koja tačno prikazuje gde se nalaze tasteri na trackpadu:

```
╔════════════════════════════════════════════════════════════════════════════════════╗
║ ADAPTIVNI KLASTER TASTERA (N = 3 , Širina tastera = 12%, Pozicija: CENTER         ) ║
╠════════════════════════════════════════════════════════════════════════════════════╣
║ Trackpad: [.........................############################.........................] ║
║ Klaster:  Od X=0.32 do X=0.68 (Ukupna širina: 36% trackpada)                       ║
╠════════════════════════════════════════════════════════════════════════════════════╣
║ Taster  0 [0.32 - 0.44]  ->  Finder                                                ║
║ Taster  1 [0.44 - 0.56]  ->  Google Chrome                                         ║
║ Taster  2 [0.56 - 0.68]  ->  AionUi                                                ║
╚════════════════════════════════════════════════════════════════════════════════════╝
```

### 4. Tačan Redosled Aplikacija kao u Dock-u
Aplikacije se sortiraju s leva na desno tačno po redosledu kako stoje u macOS Dock-u.
Redosled i položaj ikonica čitaju se direktno preko Accessibility (AX) API-ja iz
procesa `Dock`, stavke sa podulogom `AXApplicationDockItem`.

### 5. Zaključavanje Kursora Miša (Mouse Lock)
Dok korisnik dodiruje ili prevlači prst u gornjih 10% trackpada (`Y >= 0.90`):
- Pamti se trenutna pozicija kursora na ekranu pre prvog dodira.
- `CGEventTap` odbacuje sve hardverske događaje pomeranja miša, a `CGWarpMouseCursorPosition(savedPos)` drži kursor nepomičnim.
- Čim se prst podigne ili pomeri ka sredini, normalno kretanje miša se trenutno nastavlja.

### Odziv pri prebacivanju
Prebacivanje se pokreće čim se detektuje dodir u zoni. Podrazumevani vremenski
cooldown je 0 sekundi; opcija `--cooldown` može da uvede pauzu ako je potrebna.
Mala prostorna tolerancija na granici zona smanjuje slučajno prebacivanje usled
podrhtavanja prsta bez dodatnog čekanja. Konačno vreme prikaza prozora i dalje
zavisi od macOS-a i same aplikacije.

Dok je prst u gornjoj zoni, kursor se zaključava na sredini Dock ikone aplikacije
koja odgovara izabranoj zoni, pa pokazivač prati aktivnu aplikaciju. Kad prst
napusti zonu, kursor se vraća na mesto na kom je bio pre zaključavanja.

Podešavanje automatskog skrivanja Dock-a se ne menja. `CGWarpMouseCursorPosition`
pomera kursor bez događaja, pa ga Dock ne vidi i ne otkriva se. Zato se kursor
pomera pravim događajem (`CGEventPost`), isto kao kad korisnik mišem dođe do dna
ekrana:

1. Prvi dodir u zoni postavlja kursor na donju ivicu ekrana, ispod ikonice.
   Dock se otkriva svojom animacijom.
2. Kad se Dock otkrije, položaji ikonica se ponovo čitaju i kursor prelazi na
   sredinu ikonice, pa Dock pokazuje hover i naziv aplikacije.
3. Kad prst napusti zonu, kursor se vraća na staro mesto, a Dock se sam sakrije.

Vreme do otkrivanja određuje macOS (`autohide-delay` i animacija Dock-a), oko
0,2 do 0,4 sekunde.

---

## 🔐 Potrebne Dozvole (macOS Permissions)

1. **Accessibility (Pristupačnost)**:
   - Putanja: `System Settings` -> `Privacy & Security` -> `Accessibility`.
   - Omogućite terminal u kom pokrećete program (`Terminal`, `iTerm`, `AionUi` itd.).
   - Potrebno za `CGEventTap` (blokiranje kursora) i očitavanje rasporeda Dock-a.

2. **Input Monitoring (Praćenje unosa)**:
   - Putanja: `System Settings` -> `Privacy & Security` -> `Input Monitoring`.
   - Dozvola za direktan pristup trackpad događajima.

---

## 📁 Struktura Fajlova

| Fajl | Opis |
|---|---|
| `touchpad_switcher.m` | Nativni Objective-C kod sa `MultitouchSupport`, klasterizacijom, pozicioniranjem, `CGEventTap` i `NSWorkspace`. |
| `touchpad_switcher.py` | Samostalna Python verzija sa punom podrškom za `--slot-width`, `--align` i zaključavanje miša. |
| `Makefile` | Prečice za bildovanje i testiranje (`make build`, `make run`, `make list-apps`, `make run-python`). |
| `config.json` | Konfiguracioni fajl. |
| `README.md` | Ova tehnička dokumentacija. |

---

## 🚀 Uputstvo za Pokretanje i Testiranje

### 1. Kompajliranje i Prikaz Tastera

```bash
cd "/Users/milev051/Desktop/Projects/Random/20260924 Touchpad Switcher"

# Kompajliranje binarne verzije
make build

# Prikaz tastera u podrazumevanom (centriranom) režimu
./touchpad_switcher --list-apps
```

### 2. Testiranje Pozicioniranja u Gornji Desni Ugao

```bash
./touchpad_switcher --align right --list-apps
```
Primer izlaza:
```
=== TRENUTNO POKRENUTE REGULARNE GUI APLIKACIJE (DOCK REDOSLED) ===
Konfiguracija klastera: Pozicija=RIGHT (Gornji desni ugao), Širina pojedinačnog tastera=12%
TASTER    RASPON X        NAZIV APLIKACIJE               BUNDLE IDENTIFIER                       
--------------------------------------------------------------------------------------------
Taster 0  [0.52 - 0.64]   Finder                         com.apple.finder                        
Taster 1  [0.64 - 0.76]   Google Chrome                  com.google.Chrome                       
Taster 2  [0.76 - 0.88]   AionUi                         com.aionui.app                          
Taster 3  [0.88 - 1.00]   WhatsApp                       net.whatsapp.WhatsApp                   
--------------------------------------------------------------------------------------------
```

### 3. Pokretanje Alata
Možete pokrenuti alat sa željenom širinom tastera i pozicijom:

```bash
# Centrirani tasteri širine 12%
./touchpad_switcher

# Tasteri u gornjem desnom uglu širine 15%
./touchpad_switcher --align right --slot-width 0.15

# Tasteri u gornjem levom uglu
./touchpad_switcher --align left

# Puni raspon preko celog trackpada
./touchpad_switcher --align full
```

### 4. Pokretanje Python Verzije
```bash
python3 touchpad_switcher.py --align right
# ili
make run-python
```

## Eksperimentalni troprstni kružni meni

Zaseban prototip prikazuje otvorene prozore oko centra ekrana kada detektuje tri
prsta, bez obzira na položaj kursora. Tokom pokreta meni samo menja označenu
stavku; podizanje prstiju aktivira izabrani prozor ili tab. Naslovi su sakriveni
po podrazumevanom podešavanju, pa ostaju samo ikonice i thumbnailovi. Izgradi i
pokreni ga ovako:

```bash
make touchpad_ring_test
./touchpad_ring_test
```

Za čist test isključi macOS troprstno prevlačenje, da sistem istovremeno ne
pokušava da vuče prozor. U **System Settings → Accessibility → Pointer Control
→ Trackpad Options** isključi **Use trackpad for dragging** ili izaberi stil
prevlačenja koji nije **Three Finger Drag**. Apple navodi da su nazivi stavki
nešto različiti među verzijama macOS-a. Dok je meni otvoren, test dodatno
presreće scroll događaje. Sam meni preuzima događaje miša i skrola kao dodatnu
zaštitu za aplikaciju ispod kursora. Ako sistem ne dozvoli aktivni filter unosa,
meni i dalje preuzima ulaz dok je prikazan, bez ponavljajućeg upozorenja pri
pokretanju. Chrome tabovi se čitaju preko AppleScript-a; kratka greška
se ponovo pokušava, a izbor taba koristi Chrome ID prozora i taba. Ekran je blago
zatamnjen iza ikonica i thumbnailova.
Thumbnailovi se snimaju u smanjenoj rezoluciji ako aplikacija koja pokreće test
ima dozvolu za Screen Recording. Čuvaju se privremeno u memoriji dok su prozori
otvoreni i uklanjaju se iz keša kada se prozori zatvore. Za Chrome se slika
čuva zasebno za svaki tab. Kada Chrome nije aktivna aplikacija i nema dodira
na trackpadu, Touchpad Switcher kratko otvori jedan tab bez slike, snimi ga i
vrati prethodni tab. Dok je Chrome aktivan, tabovi bez snimka imaju karticu sa
naslovom i domenom sajta; pozadinsko snimanje se nastavlja kada Chrome pređe
u pozadinu.
