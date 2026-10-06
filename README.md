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

## Instalacija i ažuriranje

Dupli klik na `Instaliraj.command` napravi aplikaciju i stavi je u
`/Applications`. U podešavanjima aplikacija proverava poslednje GitHub izdanje;
kad postoji novija verzija, dugme **Ažuriraj** prikazuje broj stare i nove
verzije i instalira ZIP bez lokalnog Git klona. Iz izvornog foldera može i dupli
klik na `Ažuriraj.command` ili `make update`. Dozvole, trackpad i Chrome:
[INSTALACIJA.md](INSTALACIJA.md).

## Eksperimentalni troprstni kružni meni

Zaseban prototip prikazuje otvorene prozore oko centra ekrana kada detektuje tri
prsta, bez obzira na položaj kursora. Svaka kartica ima naslov prozora ili taba
preko sličice, ako je tako izabrano u meniju. Aplikacija bez otvorenih prozora
ili tabova nema karticu ni ikonicu u krugu, čak i ako je proces i dalje pokrenut.
Minimizovani prozori i prozori na drugim radnim površinama ostaju u meniju.
Izgradi i pokreni ga ovako:

```bash
make touchpad_ring_test
./touchpad_ring_test
```

Touchpad Switcher proverava sistemske gestove pri pokretanju, jednom u sekundi
i neposredno pre otvaranja menija. Ako macOS koristi tri prsta za Mission
Control, App Exposé, prelazak između ekrana, listanje stranica ili prevlačenje,
kružni meni ostaje zaključan. Obaveštenje ima dugmad koja otvaraju odgovarajuća
macOS podešavanja. „Kasnije” zatvara obaveštenje, ali ne uklanja blokadu.
Čim se konflikt ukloni, meni se automatski otključava bez restarta aplikacije.
Podešavanja se proveravaju zasebno za ugrađeni i Bluetooth trackpad.

U **System Settings → Trackpad → More Gestures** isključi konfliktne pokrete
ili izaberi četiri prsta za Mission Control, App Exposé i prelazak između ekrana,
a dva prsta za listanje stranica. U **System Settings → Accessibility → Pointer Control
→ Trackpad Options** isključi **Use trackpad for dragging** ili izaberi stil
prevlačenja koji nije **Three Finger Drag**. Apple navodi da su nazivi stavki
nešto različiti među verzijama macOS-a. Dok je meni otvoren, test dodatno
presreće scroll događaje. Sam meni preuzima događaje miša i skrola kao dodatnu
zaštitu za aplikaciju ispod kursora. Ako sistem ne dozvoli aktivni filter unosa,
meni i dalje preuzima ulaz dok je prikazan, bez ponavljajućeg upozorenja pri
pokretanju. Chrome tabovi se čitaju preko AppleScript-a; aplikacija pri startu
traži Automation dozvolu za Google Chrome. Bez te dozvole tabovi se ne vide kao
odvojene kartice. Putanja: System Settings -> Privacy & Security -> Automation
-> Touchpad Switcher -> Google Chrome. Kratka greška se ponovo pokušava, a izbor
taba koristi numerički Chrome ID prozora i taba. Ekran je blago zatamnjen iza
ikonica i thumbnailova.
### Izbor kartice

Pokret tri prsta pomera pokazivač (bela tačka) od centra ka karticama. Izabrana
je kartica najbliža pokazivaču. Pokazivač ima ubrzanje kao miš: spor pokret je
precizan i pomera ga malo, pa se lako bira između dve susedne kartice, a brz
pokret prebacuje na drugu stranu prstena. Kad se gura dalje od kartica,
pokazivač klizi po prstenu. Pokret gore-dole vredi isto koliko i levo-desno,
jer se uzima prava veličina trackpada.

Izabrana kartica se uveća za 20%, bez dodatnog okvira i duplirane kartice
ispod nje. Susedne kartice se blago odmaknu i vrate kada se izbor promeni.
Thumbnailovi nemaju dodatnu podlogu ni okvir. Raspored se prilagođava
odnosima stranica svih snimaka i dostupnom prostoru na ekranu. Snimak zadržava proporcije i prikazuje se ceo,
sa ikonicom centriranom preko donje ivice i nazivom bez podloge ispod nje.
Prozor bez snimka prikazuje samo veću ikonicu i naziv. Razmaci se računaju između stvarnih pravougaonih površina, uključujući
dijagonalni razmak. Dodatni korak približava susede prema razmaku njihovih
ivica, uz proveru redosleda i sudara. Horizontalni snimci sabijaju prsten po visini;
uspravni i mešoviti snimci imaju sopstvene dimenzije. Raspored ostaje
stabilan tokom izbora, uz rezervu za zoom, susede i centralnu ikonicu.
Dolazak novog thumbnaila ili promena proporcija osvežava raspored.
Veličina kartica automatski se prilagođava ekranu i njihovom broju.
Centralna ikonica se kratko smanji, uveća i vrati na svoju veličinu pri
svakom izboru kartice. Iza izabranog thumbnaila pojavi se mekan svetleći
sjaj u boji pokazivača i svetla.

Svetlo iza kartica pokazuje smer prstiju, ako je uključeno u podešavanjima. Njegov vrh se kreće pravo ka novom
smeru, ubrza pa uspori bez preletanja. Za susednu karticu to izgleda kao
okretanje. Kad se smer naglo promeni na drugu stranu, svetlo se povuče kroz
centar, gde je kratko, slabije i široko, pa se izduži na novoj strani. Kad
prsti prođu kroz centar, svetlo se ne gasi pa pali iznova, nego nastavi ka
novoj strani. Jačina svetla opada glatko od sredine ka ivicama, bez oštrih
prelaza, a širina prati širinu kartice postepeno.

Krug u sredini je zona za odustajanje: ako se prsti podignu dok je pokazivač u
njoj, ništa se ne bira. Sistemski kursor je sakriven dok je kružni meni otvoren,
bez obzira da li je aktiviran sa tri prsta ili mišem, i vraća se čim se meni zatvori.

Isti kružni meni može da se koristi i mišem. U panelu ikonice šake, pod
**Aktivacija mišem**, klikni **Snimi dugme** i pritisni željeno dugme miša
(Esc otkazuje, **Isključi** gasi aktivaciju). Drži dugme, pomeri miš u smeru kartice i pusti dugme da je aktiviraš. Ova opcija
zahteva Accessibility dozvolu; posle uključivanja dozvole ponovo pokreni
Touchpad Switcher. Sistemski kursor ostaje zaključan na mestu pritiska dok
pomeranje miša upravlja pokazivačem kružnog menija.

Snimanje pamti stvarni signal koji stiže: broj dugmeta miša, taster ili
Logi bočno dugme. Uz podrazumevano Logi Options+ podešavanje bočna dugmad su
**Back** i **Forward** i rade direktno: klik otvara meni, pomeri miš ka kartici,
pa isto dugme ili levi klik bira (Esc otkazuje). Tada se Back/Forward ne
izvršava. Za srednji klik ne treba ništa menjati u Logi Options+.

Opcija **Drži dugme i pusti ga na kartici** (podrazumevano uključena) važi za
prava dugmad miša: dugme se drži dok se miš pomera i pušta na kartici. Kad je
isključena, klik otvara meni, a drugi klik bira. Logi Back/Forward ne javlja
kad je dugme pušteno, pa uvek radi na klik; za držanje mu u Logi Options+
dodeli **Middle button**.

Podešavanja se otvaraju klikom na ikonicu u gornjoj traci, u zasebnom prozoru
na sredini ekrana. Zatvaraju se na Esc, Cmd+W, klik van prozora ili ponovni
klik na ikonicu.

### Sličice

Sličice se snimaju u smanjenoj rezoluciji ako aplikacija ima dozvolu za Screen
Recording. Čuvaju se u memoriji dok su prozori otvoreni. Novi snimak nastaje:

1. kad se napusti aplikacija, dok je njen prozor još na ekranu,
2. kad se otvori meni, za sve vidljive prozore starije od sekunde, prvo za
   prozor koji se napušta, pa se kartice osvežavaju dok je meni otvoren,
3. na svake 3 s za aktivnu aplikaciju i na 12 s za ostale vidljive prozore.

Snimaju se samo prozori sa trenutnog desktopa. Prozor sa drugog desktopa ostaje
u meniju i bez snimka, jer izbor prelazi na taj desktop. Minimizovan prozor
zadržava poslednji snimak. Ako snimka nema, kartica se ne prikazuje, jer bi
imala samo ikonicu aplikacije i obično ništa ne bi otvorila (npr. Terminalov
pomoćni prozor). Vraća se čim prozor dođe na ekran i dobije sliku.
Chrome tabovi ostaju uvek.

Za Chrome se slika čuva zasebno za svaki tab. U trenutku snimanja Touchpad
Switcher pita Chrome koji je tab aktivan, da snimak ne završi na pogrešnom
tabu. Chrome crta samo tab koji je napred, pa tab koji nikad nije bio vidljiv
nema sliku. Skriveni tabovi se ne aktiviraju radi snimanja. Ako tab još nema snimak,
prikazuje se ikonica sajta i naslov prema podešavanju. Kada ga korisnik
otvori, snimak se sačuva za sledeći pregled. Meni ne menja aktivni tab ni
redosled Chrome prozora radi thumbnaila, pa snimanje ne pokreće playback.
YouTube snimak ostaje dok je isti video, i kad se promeni vreme ili
pozicija u listi.

### Meni u gornjoj traci

Ikonica šake u gornjoj traci otvara panel sa podešavanjima:

| podešavanje | šta radi | podrazumevano |
|---|---|---|
| Kartice | prozori i tabovi, ili samo aplikacije (jedna kartica po aplikaciji, Chrome po prozoru, jer su prozori obično različiti profili) | prozori i tabovi |
| Naslovi, pokazivač, zvuci, zamućenje | izgled menija | bez naslova, nevidljiv pokazivač, bez zvuka, zamućenje 20 |
| Boja pokazivača i svetla | boja sistema (akcentna boja iz System Settings > Appearance) ili belo | boja sistema |
| Svetlo u smeru prstiju | svetlo iza kartica koje pokazuje smer prstiju | uključeno |
| Pozadina iza kartica | boja preko ekrana i njena jačina, 0 do 90% | skoro crna, 50% |
| Uvećanje pozadine | snimak ekrana iza postojećeg blura blago se uvećava i pomera suprotno pokretu | 5% |
| Trenutni prozor ili tab u centru | zamenjuje X snimkom aktivnog prozora i izdvaja ga iz kruga | isključeno |
| Finder tabovi jednog prozora kao jedna kartica | tabovi jednog Finder prozora daju jednu karticu | isključeno |
| Ikonice sajtova na Chrome karticama | ikonica sajta u donjem levom uglu (Chrome ikonica kad sajt nema svoju); preuzima se sa samog sajta, bez drugih servisa (`ring_favicons.m`) | uključeno |
| Ikonice aplikacija na karticama | ikonica aplikacije u donjem levom uglu ostalih kartica | uključeno |
| Sakrij ikonicu iz gornje trake | uklanja ikonicu | isključeno |
| Pokreni pri uključivanju računara | otvara instalirani Touchpad Switcher pri prijavi na Mac; može se isključiti u podešavanjima | uključeno |

### Video u Chrome-u

Pravila za video su u zasebnom fajlu `ring_media.m`, odvojeno od biranja
prozora. Dok je Chrome napred, tab na ekranu se proverava nekoliko puta u
sekundi jednim kratkim Apple Event-om. Kad se tab promeni (meni, klik na tab,
prečica) ili se Chrome napusti, pokreće se JavaScript u tabu:

| opcija | šta radi | podrazumevano |
|---|---|---|
| Zaustavi video kad napustiš tab ili Chrome | pauzira video i zvuk u tabu koji nije više na ekranu | isključeno |
| Pokreni ga ponovo kad se vratiš | nastavlja samo ono što je aplikacija sama zaustavila | isključeno |
| Pokreni i video koji si sam pauzirao | pri povratku na tab pokreće i video koji je korisnik ručno zaustavio | isključeno |
| Važi i za klik na tab i prečice | bez ove opcije pravila važe samo za prelazak preko menija | uključeno |
| Zaustavi samo ako novi tab ima video | stari video svira dalje dok ne pređeš na tab sa već pokrenutim videom, a izlazak iz Chrome-a ga ne zaustavlja | isključeno |
| Posle duže pauze vrati malo unazad | 2 s unazad posle pola minuta pauze, 5 s posle 5 minuta | uključeno |

Pauzirani video dobija oznaku sa vremenom pauze u samoj stranici, pa se zna
šta je zaustavila aplikacija, a šta korisnik. Sve ovo radi tek kad je u
Chrome-u uključeno **View > Developer > Allow JavaScript from Apple Events**;
do tada panel ispisuje upozorenje. Video u drugim programima (Safari, Spotify)
nije pokriven: macOS ne daje opšti način da se to uradi.

### Prelazak na prozor

Izabrani prozor se dovodi napred tačno po ID-ju, preko istog sistemskog poziva
koji koristi AltTab. Tako se prelazi i na prozor u drugom Space-u ili u full
screen-u, i bez Accessibility dozvole. Kad je prozor na drugom desktopu,
aplikacija se ne aktivira pre toga: to bi prvo otvorilo njen prozor na ovom
desktopu, a drugi prelaz bi se izgubio tokom animacije. Posle uspešnog prelaza
ne šalje se ni AX raise, jer on ostaje na starom desktopu i vraća fokus.

Sakrivena ikonica se vraća kad se aplikacija ponovo otvori dok već radi (npr.
iz Spotlight-a ili `/Applications`). Podešavanja se čuvaju pod
`com.milev.touchpad-switcher` (`defaults read com.milev.touchpad-switcher`).

### Vizuelni pregled rasporeda

`make layout-preview` otvara poseban prozor sa stvarnim karticama iz istog
koda za crtanje. Može da se bira broj kartica, odnos stranica ekrana i
selekcija klikom na karticu. Opcija „Prsten i uglovi“ pokazuje linije između centara i stvarne ugaone korake.
Dodatna kontrola bira horizontalne, uspravne ili mešovite uzorke.

Za snimak bez otvaranja prozora:

```bash
make /tmp/touchpad-layout-preview
/tmp/touchpad-layout-preview --count 5 --width 1100 --height 688 --render /tmp/raspored.png
```

`/tmp/touchpad-layout-preview --verify` proverava proporcije svakog snimka,
stvarne smerove, svaki izbor i preklapanja na pet veličina
ekrana, za 1, 2, 3, 4, 5, 6, 7, 8, 12 i 16 kartica,
u horizontalnim, uspravnim i mešovitim rasporedima. Fotografije za lokalni pregled ostaju van Git-a u
folderu `layout-previews/`.

Prelazak sa tri na jedan ili dva prsta potvrđuje izbor. Ponovno dodavanje
prstiju do tri otvara novi meni, bez potpunog podizanja ruke. Ako se treći
prst vrati dok se prethodni izbor završava, otvaranje čeka taj završetak.
Skrol i pomeranje pokazivača su blokirani tokom menija, a zaostala inercija
skrola se odbacuje. Novi skrol posle zatvaranja opet radi normalno.
Provera `--verify` pokriva 20 ponavljanja tih prelaza, brzo vraćanje,
zakašnjele zahteve i skrol pre, tokom i posle menija.

Četiri ili više prstiju poništavaju trenutni izbor. Povratak na tri prsta
odmah omogućava novi meni, bez potpunog podizanja ruke. Provera `--verify`
pokriva i taj prelaz. `--verify-input` dodatno proverava stvarno asinhrono
zatvaranje i ponovno otvaranje menija kroz 12 ciklusa sa jednim, dva i
kratkim četvrtim kontaktom, bez ručnog menjanja stanja završetka.

Ponovno otvaranje aplikacije vraća sakrivenu ikonicu i otvara podešavanja.
Pokretanje nove instance i dalje zamenjuje prethodnu. Chrome snimci se
proveravaju prema stvarnom ID-u taba i stranici pre i posle snimanja,
uz kratko čekanje na iscrtavanje. Promena svetle/tamne teme čuva postojeće
slike dok se nove učitavaju; vidljivi prozori se osvežavaju u pozadini.

Centralna ikonica se pozicionira u slobodnom prostoru između ivica kartica,
sa rezervom za zoom. Kada ikonica prozora dobije thumbnail tokom otvorenog
menija, raspored se osvežava i snimak odmah dobija normalnu veličinu.

Ceo raspored je centriran prema vidljivim površinama thumbnailova, ikonica
i naziva. Kartice i centralna ikonica pomeraju se zajedno, uz rezervu za
zoom i susede. Položaj grupe ostaje isti kada se promeni samo izbor.

Položaj centralne ikonice ujednačava razmake do vidljivih ivica thumbnailova
i njihovih ikonica. Računa se odstupanje tih razmaka, uz bezbedan prostor
za uvećanu karticu. Cela grupa zatim ostaje centrirana na ekranu.

Maksimalna veličina thumbnailova prati dimenzije ekrana, uz proveru prostora
za zoom i susede. Na većim ekranima kartice mogu preći prethodnih 480 pt.
Posle sabijanja rasporeda cela grupa se dodatno uvećava prema preostalim
marginama, uz očuvanje centra i proporcija thumbnailova.

Kada su nazivi skriveni, kartice čuvaju samo prostor potreban za ikonicu.
Rezerva između suseda računa jedan izabrani thumbnail, pa snimci mogu biti
veći bez preklapanja. Chrome tabovi se čitaju prema zasebnim ID-evima,
a potvrđeni otvoren tab ne uklanja se zbog promene CG površine prozora.
Dva taba sa istim linkom i naslovom zadržavaju odvojene identitete i keš.

Podešavanja imaju ujednačene razmake i odvojene redove za boju, jačinu
pozadine i zamućenje. Broj instalirane verzije stoji u dugmetu za proveru
ažuriranja; poruka da je verzija najnovija ne prikazuje se zasebno.

U sredini kružnog menija podrazumevano se prikazuje X i poruka „Otpusti za izlazak“.
Poništavanje ima širu zonu i odvojenu granicu za ponovni izbor.
Poseban meni prečica bira se u Podešavanjima > Prečice: nema ga, otvara se
dok držiš Cmd, dok je dodat četvrti prst, ili na oba načina. Podrazumevano
je Cmd. U njemu su prečice označene sa Meni (Downloads, Desktop, Documents,
novi Chrome tab i ostale uključene). Otpusti prste dok je Cmd i dalje
pritisnut, ili dok je četvrti prst još na tabli, da otvoriš izabranu prečicu.
Puštanje Cmd-a, odnosno podizanje četvrtog prsta, vraća prozore i tabove.
Dok poseban meni koristi četiri prsta, taj pokret više ne poništava izbor.
Otvorena podešavanja imaju svoju karticu i ostaju otvorena pri promeni
fokusa. Zatvaraju se preko X, Esc ili Cmd+W. Aplikacija ima zasebnu ikonicu
sa karticama i tri prsta, generisanu pomoću `tools/generate_app_icon.m`.

### Stalne prečice i novi YouTube tab

U Podešavanjima > Prečice svaka stavka ima nezavisne opcije **Meni** i
**Stalno**. Iznad njih bira se kako se poseban meni otvara: Nema, Cmd,
4 prsta ili Oba. Stalno prikazuje prečicu među aplikacijama i kad posebnog
menija nema. Meni prikazuje je u posebnom meniju dok je izabrani prekidač
aktivan. Dostupni su
Downloads, Desktop, Documents, novi Chrome tab i novi YouTube tab.
Chrome i YouTube svaki put otvaraju nov tab u Chrome-u. Izbor se pamti
posle ponovnog pokretanja aplikacije. Stalne prečice su podrazumevano
isključene, a YouTube možeš uključiti u jednoj ili obe kolone.

### Dijagnostika i praćenje problema

Podešavanja > **Otvori logove** otvara `~/Library/Logs/TouchpadSwitcher/`.
`events.jsonl` sadrži vreme, PID, generaciju geste, broj prstiju, stanje
menija, izbor, ID prozora/taba, rezultat skripte i naknadnu proveru aktivnog
Chrome taba. Naslovi stranica i URL-ovi ne beleže se u ovom dnevniku.
Dnevnik se rotira na 4 MB; prethodni je `events.jsonl.previous`.

Praćenje uživo u Terminalu:

```bash
tail -F ~/Library/Logs/TouchpadSwitcher/events.jsonl
```

`permissions` beleži Accessibility, Input Monitoring i Screen Recording;
`input_filter` govori da li radi sistemski filter skrola. `touch_count` i
`gesture_start` pokazuju da li je trackpad prepoznat. `menu_open`,
`touch_release` i `menu_close` prate izbor. `chrome_switch_requested`,
`chrome_script_result` i `chrome_verify` razlikuju zahtev od potvrde da je
stvarno aktivan očekivani tab. `activation_skipped` objašnjava zastareli
zahtev, a `chrome_background_switch` prati promene radi snimanja thumbnaila.

Za pregled sistemskih zapisa pokreni macOS **Console** i filtriraj proces
`touchpad_ring_test`. **Activity Monitor** pokazuje da li proces radi, CPU
i memoriju; opcija Sample Process pomaže pri zastoju. Izveštaji o rušenju
nalaze se u `~/Library/Logs/DiagnosticReports/`.

Provera pisanja dnevnika, paralelnih zapisa i rotacije:

```bash
make /tmp/touchpad-layout-preview
/tmp/touchpad-layout-preview --verify-logs
```

Kada ponoviš problem, zabeleži približno vreme i koji izbor nije uspeo.
Tako možemo povezati gestu, izbor i rezultat aktivacije u istom dnevniku.

### Spusti sve prozore (1.0.5)

Drži Cmd u otvorenom meniju i izaberi **Spusti sve prozore**. Akcija
minimizuje svaki prozor preko Accessibility interfejsa i proverava njegovo
stvarno stanje. Ako direktan zahtev ne uspe, pokušava preko dugmeta za
minimizovanje tog prozora. Zahtevi različitim aplikacijama šalju se paralelno.
Prozori koji su već spušteni ostaju takvi. Full-screen prozor prvo dobija
zahtev za izlazak iz full-screen režima, pa za minimizovanje.

Potrebna je dozvola System Settings > Privacy & Security > Accessibility
za instalirani Touchpad Switcher. Na macOS-u 27 dozvola se zove
**Device Control and Data Access**. Ako provera statusa vrati da dozvola
nije aktivna, aplikacija prvo proverava stvarni pristup prozorima Finder-a
ili aktivne aplikacije. Uspešan pristup omogućava nastavak akcije; ako i
sistemski zahtev bude odbijen, prikazuje se objašnjenje i dugme za
otvaranje podešavanja. Uključen prekidač uz odbijen pristup može zahtevati
osvežavanje unosa dozvole i ponovno pokretanje aplikacije. U Dock podešavanjima uključi
**Minimize windows into application icon** da prozori budu u svojim
aplikacijama. Aplikacija ne menja tu sistemsku opciju.

`accessibility_probe` beleži odgovor stvarnog AX zahteva kada status
dozvole nije potvrđen. `minimize_window` beleži rezultat svakog prozora, `minimize_enumeration`
broj pronađenih prozora i grešku čitanja aplikacije, a `minimize_all_done` ukupan rezultat. Neke
pomoćne prozore aplikacije ne dozvoljavaju minimizovanje; greška se beleži
umesto prijavljivanja uspeha.

U Podešavanjima > Prečice možeš izabrati Meni i/ili Stalno. Podešavanje
prethodne akcije ostaje sačuvano. **Desktop** i dalje otvara folder.

Ažuriranje se preuzima iz GitHub Releases preko dugmeta u podešavanjima;
klon repozitorijuma nije potreban za instaliranje novog izdanja.

### Glatkiji pokazivač (1.0.5)

Strelica i kružić imaju kratak prelaz od 65 ms koji nastavlja od trenutno
prikazanog položaja. Strelica se okreće kraćim putem preko granice uglova,
a sitno podrhtavanje u centru ne menja pravac. Izbor kartice koristi
neizmenjene koordinate prstiju, pa zaglađivanje ne usporava aktivaciju.
Otvaranje menija i prelazak na Cmd prečice odmah resetuju pokazivač.

### Brzo prebacivanje sa tri prsta

Tap sa tri prsta kraći od 0,5 sekundi vraća prethodno korišćeni prozor.
Uzastopni tapovi prebacuju između poslednja dva prozora. Prati se prozor,
uključujući više prozora iste aplikacije. Zatvoreni prozori i prečice se
ne biraju. Dok istorija još nije zabeležena, koristi se redosled vidljivih
prozora od napred ka nazad.

Povlačenje ka kartici zadržava običan izbor čak i kada traje kraće od
0,5 sekundi. Poseban meni prečica i poništavanje sa četiri prsta ne pokreću
brzo prebacivanje. Ako nema prethodnog prozora, tap samo zatvara meni.

### Više tabova i brže osvežavanje (1.0.6)

Meni prikazuje najviše 10 kartica na jednoj stranici. Leva i desna
strelica na tastaturi menjaju stranicu dok je meni otvoren. Dole se vidi
broj trenutne i ukupan broj stranica. Cmd prečice imaju zaseban pregled,
a brzi tap i dalje vraća prethodni prozor i kada je na drugoj stranici.

Inventar se proverava na 0,5 sekundi, uz dodatnu proveru promene naslova
prozora. Chrome vraća ID-eve, naslove i adrese tabova u grupama. Snimci
vidljivih tabova osvežavaju se najranije posle 0,6 sekundi, a pri otvaranju
menija posle 0,15 sekundi od prethodnog snimka. Ovo su intervali zahteva,
bez garancije vremena odgovora macOS-a i Chrome-a. U režimu „Samo
aplikacije” Chrome zadržava po jednu karticu za svaki prozor i njen aktivni
tab. Zatvoreni i novootvoreni tabovi ažuriraju se posle uspešnog čitanja
inventara; tokom izbora stranica ostaje stabilna.

Chrome inventar, izbor taba i provera snimka vezani su za PID konkretne
instance, pa Chrome bez prozora pokrenut za snimanje ne dodaje svoje tabove
u meni. ID, naslov i URL čitaju se zajedno. Pri otvaranju menija dodatno
se proveravaju živi ID-evi: zatvorene i ponovljene kartice uklanjaju se dok
je pokazivač u sredini; započeti izbor ostaje stabilan. Dva stvarna taba
istog linka ostaju odvojena. Događaji `chrome_inventory` i
`chrome_menu_inventory` beleže ID-eve i broj uklonjenih kartica, bez adresa.

### Uvećana pozadina i centar menija (1.0.6)

Kad je uvećanje uključeno i aplikacija ima dozvolu za snimanje ekrana, meni
se odmah otvara sa sistemskim zamućenjem. Snimak ekrana se učitava u
zasebnom prozoru iza menija, gde ga zamućenje obrađuje jednom. Snimak se
postepeno pojavljuje tokom jedne sekunde već u podešenom uvećanju, bez animacije zuma. Pomeranje
prstiju ili miša pomera pozadinu u suprotnom smeru. Malo uvećanje čuva
ivice ekrana tokom paralakse, uz rezervu na ivicama i pri naglom pokretu.
Klizač za uvećanje ide od 0 do 25%; na nuli
ostaje samo sistemsko zamućenje.

Opcija „Trenutni prozor ili tab u centru” prikazuje njegov thumbnail umesto
X-a, a tu karticu uklanja iz kruga. Puštanje prstiju u sredini ostaje na
istom prozoru. Kada je opcija isključena, u centru je X. Ako trenutni
prozor ne može da se prepozna, X ostaje dostupan.
