# Stanje

- 2026-10-11: ispravljeni thumbnailovi na uspravnom (1x) monitoru. Snimak prozora
  se kopirao u gornji levi ugao većeg okvira sa crnim ostatkom. Sada
  `configureThumbnailSize` čuva proporcije prozora (visoki prozor ograničen
  visinom 960) i uključuje `scalesToFit`/`preservesAspectRatio`.
- Necommitovano: ova izmena i ranije izmene ređeg snimanja u pozadini
  (`backgroundCaptureWanted`, ređi tajmeri).
- Sledeći korak: proveriti prsten na uspravnom i na običnom monitoru, pa commit.
