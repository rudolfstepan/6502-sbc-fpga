# SDRAM-Phasensweep-Tester (Tang Console 138K)

Kleines Testdesign, um die richtige Phase des SDRAM-Clock-Pins für den
NanoMig-Port zu finden, ohne jedes Mal das komplette Amiga-Projekt bauen zu
müssen. Es verwendet denselben SDRAM-Controller (NanoMig `sdram.sv`) mit
denselben Parametern (85 MHz, CL2, `RASCAS_DELAY=2` für die
W9825G6KH-6-Chips) und dieselben Pins wie der NanoMig-Port.

Der Trick: die GW5A-PLL kann die Phase eines Ausgangs zur Laufzeit
verstellen. Das Design fährt damit alle 80 Positionen (je 4,5°) selbst
durch. Pro Position schreibt es 8192 Wörter ab Adresse 0x3C0000 (dasselbe
Segment, in dem NanoMig den Kickstart ablegt), liest sie zurück, wiederholt
das mit invertiertem Muster und zählt die Fehler. Refresh läuft dabei
weiter, damit auch Retention stimmt.

## Bauen und starten

`project/tang138k_ramtest.gprj` in Gowin EDA öffnen, bauen, per SRAM
Program laden. Baut in etwa einer Minute. Kein Kickstart, kein Flash nötig.

## Ausgabe lesen

UART auf Pin **U15** (derselbe wie beim System16-Monitor), 115200 8N1.
Pro Sweep (~1 s) kommt eine Zeile mit 80 Zeichen, ein Zeichen pro
Phasenposition, beginnend bei 0° ab dem Einschalten:

```
.......334#####..............
```

- `.` = 0 Fehler
- `1`–`9`, `A`–`F` = so viele Fehlerwörter
- `#` = 16 oder mehr Fehler

LEDs verdrahtet das Design keine: Die LED-Pins der Console (G11/U12) sind
Dual-Purpose-Pins (DONE/READY) und bräuchten die passenden Prozessoptionen
im Gowin-Projekt — den Aufwand spart sich der Tester, die UART-Zeile sagt
alles.

## Ergebnis übernehmen

Die Mitte des breitesten `.`-Bereichs nehmen. Zeichenposition (ab 0)
zählen, dann in NanoMigs
`third_party/NanoMig/src/tang/console138k/gowin_pll/pll_142m_mod.v`:

```
CLKOUT2_PE_COARSE = Position / 8
CLKOUT2_PE_FINE   = Position % 8
```

Position 48 wäre also 6/0 (216°), Position 60 wäre 7/4 (270°).

## Hinweise

- Für absolute Positionsangaben zählt die Ausrichtung ab dem Einschalten;
  nach einem Power-Cycle stimmt Zeichen 0 wieder mit 0° überein. Einen
  Reset-Taster verdrahtet das Design bewusst nicht.
- Zeigt die ganze Zeile denselben Wert auf allen 80 Positionen, greift die
  dynamische Phasenverstellung nicht auf CLKOUT2 — dann `PS_SEL` in
  `rtl/ramtest_top.sv` anpassen (Kandidat: `3'b001`).
- Das Fenster kann je Build des großen Projekts um ein, zwei Feinschritte
  wandern (Routing). Deshalb die Fenstermitte wählen, nicht den Rand.
