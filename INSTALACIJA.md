# Instalacija i ažuriranje

Uputstvo za korisnika ili za agenta koji instalira aplikaciju umesto njega.
Agent piše korisniku na srpskom, kratko, korak po korak. Dozvole u System
Settings uključuje samo korisnik, klikom; agent otvara pravo mesto i čeka potvrdu.

## 1. Preuzimanje

Potreban je macOS 14 ili noviji (`sw_vers`). Repozitorijum je privatan, pa je
potrebna GitHub prijava sa nalogom koji je pozvan u repozitorijum.

```bash
gh auth status || gh auth login        # jednom; bez gh: git sa GitHub tokenom
gh auth setup-git                      # da git i dugme Ažuriraj koriste tu prijavu
git clone https://github.com/milev051/touchpad-switcher.git ~/Applications/touchpad-switcher
```

## 2. Instalacija

Dupli klik na `Instaliraj.command` u tom folderu, ili:

```bash
cd ~/Applications/touchpad-switcher && ./Instaliraj.command
```

Ako nedostaju Xcode Command Line Tools, otvoriće se njihova instalacija. Kad se
završi, isti korak se ponavlja. Aplikacija se pravi na ovom računaru, za njegov
procesor, i stavlja u `/Applications`. Ikonica šake se pojavi u gornjoj traci.

## 3. Dozvole

| dozvola | čemu služi | gde |
|---|---|---|
| Screen Recording | sličice prozora | `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"` |
| Accessibility | preciznije prebacivanje prozora, Finder i Terminal tabovi | `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"` |
| Automation → Google Chrome | Chrome tabovi i video | pitanje stiže samo pri prvom korišćenju; kasnije `?Privacy_Automation` |

Posle Screen Recording dozvole aplikaciju treba ponovo pokrenuti:

```bash
pkill -x touchpad_ring_test; open "/Applications/Touchpad Switcher.app"
```

Dozvole ostaju i posle ažuriranja, jer se aplikacija uvek potpisuje istim
identifikatorom.

## 4. Trackpad

Meni se otvara sa tri prsta, pa macOS ne sme da koristi tri prsta za nešto drugo.
Stanje se samo čita:

```bash
defaults read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag
defaults read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture
defaults read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerVertSwipeGesture
```

- `TrackpadThreeFingerDrag = 1`: korisnik isključuje prevlačenje sa tri prsta u
  System Settings > Accessibility > Pointer Control > Trackpad Options.
- Bilo koja od druge dve vrednosti `= 2`: korisnik u System Settings > Trackpad >
  More Gestures prebacuje „Swipe between full-screen applications“ i „Mission
  Control“ na četiri prsta.

Panel aplikacije ispisuje isto upozorenje dok je nešto od ovoga uključeno.

Ako se koristi miš, u panelu ikonice šake pod **Aktivacija mišem** klikne se
**Snimi dugme**, pa pritisne željeno dugme miša (Esc otkazuje); aplikacija sama
pamti signal koji stiže. **Isključi** gasi aktivaciju mišem. Dugme se drži dok
se miš pomera ka kartici, a puštanje je aktivira. Za ovu opciju je potrebna
Accessibility dozvola i ponovno pokretanje aplikacije posle njenog uključivanja.
Logi bočna dugmad sa podešavanjem **Back/Forward** rade direktno: klik otvara
meni, pomeri se miš, pa isto dugme ili levi klik bira. U Logi Options+ ne treba
im dodeljivati Middle button.
Sistemski kursor je sakriven dok je kružni meni otvoren i ponovo se prikazuje
čim se izbor završi ili otkaže.

## 5. Chrome

Za automatsko zaustavljanje i pokretanje videa u svakom Chrome profilu treba
uključiti View > Developer > Allow JavaScript from Apple Events.

## 6. Provera

```bash
pgrep -fl touchpad_ring_test
```

Tri prsta na trackpad, pomeranje ka kartici, podizanje. Ako nešto ne radi:

```bash
pkill -x touchpad_ring_test
open -n --stdout /tmp/ts.log --stderr /tmp/ts.log "/Applications/Touchpad Switcher.app"
sleep 5; tail -30 /tmp/ts.log
```

## Ažuriranje

Tri jednaka načina:

- u aplikaciji: ikonica šake > **Ažuriraj sa GitHub-a**
- dupli klik na `Ažuriraj.command`
- `make update` u folderu repozitorijuma

Svaki preuzme izmene, napravi aplikaciju ponovo i pokrene novu verziju, koja
zameni staru.

## Uklanjanje

Ikonica šake > Ugasi Touchpad Switcher, zatim:

```bash
rm -rf "/Applications/Touchpad Switcher.app" ~/Applications/touchpad-switcher
defaults delete com.milev.touchpad-switcher
```

Na kraju ukloniti aplikaciju iz Privacy & Security (Screen Recording,
Accessibility, Automation).
