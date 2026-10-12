# Stanje

- 2026-10-12: README.md prepisan od nule prema stvarnom kodu: kružni meni sa
  tri prsta kao glavna aplikacija, podešavanja, instalacija, zahtevi i dozvole.
  Stari prototip sa zonama na ivici trackpada opisan je samo kao napušten.
- 2026-10-12: sve izmene (ring_settings, ring_window_events, ring_shared, README
  sa engleskim uvodom) commitovane kao 92bdaf0, main spojen fast-forward, obe grane na origin.
- 2026-10-11: thumbnailovi na uspravnom (1x) monitoru čuvaju proporcije prozora
  (`configureThumbnailSize`, `scalesToFit`). Promena veličine prozora pravi nov
  snimak 0,7 s posle poslednje promene (`recaptureResizedWindow`).
- 2026-10-11 optimizacija: događaji prozora (`ring_window_events.m`, AXObserver
  i NSWorkspace) zamenjuju česte provere; tajmeri su rezerva (5 s, 10 s, 2 s).
  Procesor u mirovanju je pao sa oko 1,4% na 0,3 do 0,4%. Velike slike za zum
  se čuvaju samo za poslednjih 16 snimaka (`ring_zoom.m`). Prozor podešavanja
  i čuvanje podešavanja su izdvojeni u `ring_settings.m`, a zajednički tipovi
  u `ring_shared.h`.
- 2026-10-11: X (sredina prstena) stoji u sredini kartica (`balancedHubPoint`);
  ranije ga je izjednačavanje razmaka pomeralo i do 100 pt.
- 2026-10-11: opcija „Snimci prozora na karticama” (ShowThumbnails); isključena
  kartice su samo ikonice i ništa se ne snima.
- Provereno: `make`, `layout-preview` sa --verify, --verify-input,
  --verify-logs i --verify-system-gestures, događaji za otvaranje, resize i
  zatvaranje Finder prozora, otvaranje podešavanja.
- Necommitovano: sve gore navedeno i ranije izmene ređeg snimanja u pozadini.
- Sledeći korak: korisnik proverava prsten i resize, pa commit. Dalja podela
  glavnog fajla (snimanje thumbnailova, Chrome) je moguća istim putem.
