# Tang Console 138K - AE350 ITCM/UART bring-up

Dieses eigenstaendige Gowin-Projekt prueft den echten AE350/Andes-A25-
Hardcore ohne externen Flash und ohne DDR3-Abhaengigkeit. Programm und Daten
liegen in internem 64-KiB-ITCM beziehungsweise 64-KiB-DTCM.

Das SPI-XIP+DDR3-Hauptprojekt unter `../ae350` bleibt als getrennte Variante
erhalten.

## Direkt in der Gowin IDE bauen

In Gowin EDA 1.9.12.03 diese Datei oeffnen und `Process -> Run All` starten:

`project/tang138k_ae350_itcm.gprj`

Das Projekt enthaelt die fuer `GW5AST-LV138PG484AC1/I0` erzeugten AE350- und
PLL-Netzlisten. Vor einem normalen IDE-Build ist deshalb kein Generatorlauf
noetig. Der optionale Kommandozeilen-Build fuehrt denselben Projektlauf aus:

```powershell
make -C boards/tang_mega_138k/ae350_itcm build
```

## Hardwaretest

1. `project/impl/pnr/tang138k_ae350_itcm.fs` programmieren.
2. Das Board einmal resetten.
3. Den FTDI-Kanal B beziehungsweise den ihm zugewiesenen COM-Port (am
   Test-PC COM14) mit `38400 Baud, 8 Datenbits, keine Paritaet, 1 Stoppbit`
   oeffnen.

Zuerst erscheint eine vom AE350 unabhaengige FPGA-Diagnosemeldung. `PLL=1`
zeigt, dass die System-PLL fertig kalibriert ist:

```text
FPGA AE350 ITCM PLL=1
```

Danach wird der AE350 aus dem Reset freigegeben und es folgt seine
wiederholte UART2-Ausgabe:

```text
It's a Waterfall Led demo.

led[1] is on ...
led[2] is on ...
led[3] is on ...
```

Die LED-Texte stammen aus Gowins vorinstallierter ITCM-Testfirmware. Die
Firmware schreibt zwar den internen GPIO-Block, diese GPIOs werden auf dem
Console-Board absichtlich nicht herausgefuehrt. Entscheidend ist die Ausgabe
auf UART2 (TX U15, RX V14).

Die drei sichtbaren Farben der FPGA-Status-LED sind `READY`, `DONE` und
`SYS_ACT`. Sie werden von diesem Test nicht als Diagnose-LEDs verwendet.
N18, N19, M18 und L18 sind LCD-Datenleitungen und bleiben unbenutzt.

Ein schwarzer Monitor ist bei diesem Test normal; das Projekt enthaelt keine
Videoausgabe. Ebenso testet diese Variante noch nicht den externen DDR3-RAM.

## IP-Regenerierung

`tools/regenerate_ae350_itcm_core.ps1` erzeugt die geschuetzte AE350-Netzliste
fuer den 138C neu. Dabei werden die Dateien unter `firmware/itcm_initial` in
die Netzliste eingebettet. Nach einer Aenderung dieser vier Dateien sind
Core-Regenerierung und ein kompletter Gowin-Build zwingend.

`project/generate_pll.tcl` erzeugt die System-PLL neu. Wie in Gowins
`Emb_TCM`-Referenz laufen DDR-, AHB- und APB-Takt mit 100 MHz, der Core mit
800 MHz und RTC mit 10 MHz. Der AE350 wird erst nach der Diagnosemeldung und
einem stabilen PLL-Lock aus dem Reset freigegeben. Der 100-MHz-APB-Takt passt
zum UART-Teiler der eingebetteten Testfirmware.
