# Stanje

- 2026-10-11: ispravljeni thumbnailovi na uspravnom (1x) monitoru. Snimak prozora
  se kopirao u gornji levi ugao većeg okvira sa crnim ostatkom. Sada
  `configureThumbnailSize` čuva proporcije prozora (visoki prozor ograničen
  visinom 960) i uključuje `scalesToFit`/`preservesAspectRatio`.
- 2026-10-11: commit 84b3a17 (ređe snimanje u pozadini, ređi tajmeri, proporcije).
  Nije pushovano na GitHub.
- Sledeći korak: pratiti da li su sličice dovoljno sveže i da li CPU u mirovanju
  ostaje nizak (bilo je 8% u jednom merenju).
