# Touchpad Switcher – Status, Arhitektura i Plan Zadataka

> Datum: 25. septembar 2026.  
> Projekat: `/Users/milev051/Desktop/Projects/Random/20260924 Touchpad Switcher`  
> Glavni binarni fajl: `touchpad_ring_test` (`touchpad_ring_test.m`)

---

## 1. Šta je do sada uspešno urađeno ✅

1. **Retina rezolucija i ScreenCaptureKit keširanje**:
   - Rezolucija snimanja podignuta na 800×480 (16:10 format) u `captureWindowImage` i `capturePendingThumbnails`.
   - Implementiran pametan TTL / grace period i backoff algoritam (`recordThumbnailCaptureFailure` i `recordThumbnailCaptureSuccess`).
   - Sprečeno trovanje keša (Chrome tabovi više ne preslikavaju thumbnail aktivnog taba na sve ostale tabove).

2. **Finder podrška za više tabova i pune putanje**:
   - Mapiranje pojedinačnih sistemskih `CGWindowID` za svaki Finder tab preko `matchingTabCGWindowID`.
   - Pozadinsko čitanje prave POSIX putanje foldera preko AppleScript-a (`fetchFinderPaths`) bez blokiranja glavnog threada.
   - Prikaz elegantnog staklastog bedža u donjem levom uglu Finder thumbnaila sa pametnim skraćivanjem u sredini (`~/Desktop/.../projekat`), čime se bez greške razlikuju folderi istog imena (npr. `app`).

3. **Instant sakrivanje (0ms latency)**:
   - Čim se tri prsta podignu sa tačpeda, `[g_panel orderOut:nil]` se izvršava istog trenutka na glavnom threadu.
   - Podizanje i fokusiranje prozora (`raiseWindowForEntry`) ide asinhrono u pozadini na `g_windowActivationQueue` bez odlaganja gašenja interfejsa.
   - Direktno keširanje AX referenci dugmadi tabova (`accessibilityTabObject`) omogućava trenutni `kAXPressAction` bez pretrage stabla.

4. **Uklanjanje seckanja centralne iglice**:
   - `advancePointerAnimation:` osvežava isključivo kvadrat oko iglice (90×90px preko `setNeedsDisplayInRect:`) umesto rekalkulacije i crtanja svih 6–9 Retina slika na celom ekranu na svakih 16ms.

5. **Groq AI Engine (`ai_agent.h`, `ai_agent.m`)**:
   - Samostalan i potpuno testiran modul koji koristi `openai/gpt-oss-120b` preko Groq API-ja (`~/.config/groq/api_key`).
   - Odziv u manje od 100ms.
   - Podržava akcije: otvaranje Chrome profila (`open_chrome_profile`), foldera u Finderu/Terminalu (`open_folder`), pokretanje komandi (`open_terminal_command`), sistemskih podešavanja (`open_settings`) i bezbednih shell skripti.

---

## 2. Šta je preostalo da se uradi 📋

Na osnovu najnovijih zapažanja i priloženog screenshot-a (`image-1.png`), definisana su **4 ključna zadatka**:

### Zadatak 1: Dinamičko skaliranje kartica za veći broj prozora (7–12 prozora)
- **Problem uočen na screenshot-u**:
  - Za 7 otvorenih prozora, formula u `safeCardWidthForRing` je previše agresivno smanjila sve kartice zbog jednog najužeg razmaka.
  - Na ekranu je ostala ogromna količina praznog prostora u sredini i između kartica.
- **Rešenje**:
  - Uvećati osnovni radijus prstena (`ringRadius`) tako da kartice budu pozicionirane bliže spoljnim ivicama ekrana, ostavljajući više prostora na obimu.
  - Umesto globalnog smanjivanja svih kartica na najmanju moguću meru, izračunati optimalnu širinu kartica koja maksimalno popunjava ekran uz održavanje čistog razmaka od 18–24px.
  - Povećati minimalne i prosečne dimenzije kartica za 6–9 elemenata na npr. 280–380px širine (umesto trenutnih ~180px).

### Zadatak 2: Vidljivost thumbnailova – Borderi i senke (Dark / Light Mode)
- **Problem**:
  - Na tamnoj ili svetloj pozadini, thumbnailovi sa tamnim sadržajem (tamne teme, terminal, tamni Finder) se stapaju sa pozadinom ekrana i gube konture.
- **Rešenje u `drawRect:`**:
  - Dodati diskretan, prefinjen dvostruki obod ili beli poluprovidni okvir (`border`):
    - Za neselektovane: `[NSColor colorWithCalibratedWhite:1.0 alpha:0.22]` debljine 1.5px.
    - Za selektovanu karticu: svetleći akcentovani okvir (`[NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.95]`) debljine 2.5px.
  - Dodati bogatiji drop shadow iza svake kartice (`shadowBlurRadius: 14`, `shadowColor: alpha 0.40`), tako da se svaka kartica jasno izdvaja i „lebdi” iznad bilo koje pozadine.
  - Dodati blago zaobljene ivice thumbnaila (`cornerRadius: 8px`) preko `NSBezierPath` clipping-a radi modernog izgleda.

### Zadatak 3: Trenutno osvežavanje stanja pri startu gesta (Uklanjanje zatvorenih prozora)
- **Problem**:
  - Kada se prozor ili tab zatvori, on ostaje vidljiv u switcher-u još nekoliko sekundi jer se osvežavanje oslanja samo na periodični tajmer od 1s i TTL keša.
- **Rešenje**:
  - U trenutku kada korisnik spusti 3 prsta na tačped (`[touch] three-finger gesture started`):
    - Odmah izvršiti brzu proveru živih prozora (`CGWindowListCopyWindowInfo`) i filtrirati ugašene `windowID`-jeve pre prikazivanja overlay-a.
    - Čim se proces ugasi ili tab zatvori, ukloniti ga iz `g_windowEntries` bez čekanja grejs perioda od 15 sekundi.

### Zadatak 4: Integracija Groq AI kartice u radijalni meni
- **Koncept**:
  - U meni se dodaje specijalna kartica (npr. *⚡ AI Asistent* ili *Brza Komanda*).
  - Dizajn kartice: tamni gradijent sa ljubičasto-plavim sjajem i ikonicom varnice / terminala.
  - Kada korisnik usmeri 3 prsta ka njoj i pusti:
    - Ring se istog trena zatvara.
    - Na sredini ekrana se otvara lebdeći Spotlight bar (`ai_input_panel`) gde korisnik unosi komandu (ili bira predložene brze akcije).
    - `AIAgent` (Groq `openai/gpt-oss-120b`) obrađuje komandu i izvršava akciju za ~100ms.

---

## 3. Plan Raspodele Posla za Agente 👥

| Agent | Uloga | Zaduženje | Fajlovi |
|---|---|---|---|
| **Agent 1** | *UI & Visual Polish Developer* | Implementacija belo/svetlećih bordera, zaobljenih ivica (8px) i drop shadow-a oko thumbnailova; proširenje radijusa prstena i povećanje kartica za 7–12 elemenata | `touchpad_ring_test.m` (`drawRect:`, `safeCardWidthForRing`, `fittedRingRadius`) |
| **Agent 2** | *Responsiveness & Lifecycle Engineer* | Instant sinhronizacija na početku 3-finger gesta; momentalno izbacivanje zatvorenih tabova/prozora bez kašnjenja | `touchpad_ring_test.m` (`ringTouchCallback`, `collectOpenWindows`, `pruneThumbnailCaches`) |
| **Agent 3** | *AI Launcher Integration Engineer* | Spajanje `ai_agent.m` i `ai_input_panel.m` u `touchpad_ring_test.m`; dodavanje AI kartice u radijalni meni | `touchpad_ring_test.m`, `Makefile` |
| **Agent 4** | *Build & QA Reviewer* | Kompajliranje celog projekta, provera preklapanja na svim rezolucijama i verifikacija stabilnosti procesa | `Makefile`, test skripte |

---

## 4. Komanda za Kompajliranje i Pokretanje

```bash
make touchpad_ring_test
pkill -9 touchpad_ring_test 2>/dev/null || true
nohup ./touchpad_ring_test > /tmp/touchpad_ring_test.log 2>&1 &
```
