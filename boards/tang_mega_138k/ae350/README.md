# Tang Console 138K – AE350-Hardcore

Dieses eigenstaendige Gowin-Projekt verwendet den im GW5AST-138C
eingebetteten Andes-A25/AE350-RISC-V-Hardcore. Das bestehende
`system16`-/GoRV32-Softcore-Projekt wird weder ersetzt noch als Quelle
eingebunden.

## Direkt in der Gowin IDE bauen

In Gowin EDA 1.9.12.03 diese Datei oeffnen und `Process -> Run All` starten:

`project/tang138k_ae350.gprj`

Die fuer `GW5AST-LV138PG484AC1/I0` erzeugten AE350- und PLL-Netzlisten sind
Bestandteil des Projekts. Fuer einen normalen IDE-Build muss keine IP zuvor
regeneriert werden. Der optionale Kommandozeilen-Build fuehrt denselben
Projektlauf aus:

```powershell
make -C boards/tang_mega_138k/ae350 build
```

## Erste Bring-up-Konfiguration

- echter AE350/Andes-A25-Hardcore
- CPU 800 MHz
- AHB, APB und interner DDR-Bus 50 MHz
- AE350-UART2 auf dem bewaehrten Debug-UART (TX U15, RX V14)
- SPI-XIP am gemeinsamen 8-MiB-Konfigurations-Flash
- AE350-interner DDR3-Controller mit 200-MHz-Speichertakt
- AE350-JTAG am 8-poligen Debug-Stecker

Die drei sichtbaren Farben der FPGA-Status-LED sind die fest verdrahteten
Konfigurationssignale `READY`, `DONE` und `SYS_ACT`. Sie zeigen nicht den
AE350- oder DDR3-Zustand an. Die Pins N18, N19, M18 und L18 sind beim
Console-Board LCD-Datenleitungen und werden von diesem Projekt nicht als
Diagnose-LEDs missbraucht.

Das Projekt ist zunaechst ein Hardware-Bring-up und enthaelt noch kein
Board-spezifisches AE350-Linux-Image.

Fuer einen eindeutigen ersten CPU- und UART-Test ohne Flash- oder
DDR3-Abhaengigkeit dient das getrennte Projekt `../ae350_itcm`.

Die vier FPGA-Konfigurations-JTAG-Pins werden nach dem Laden des Bitstreams
als AE350-Debug-JTAG verwendet (`use_jtag_as_gpio=1`). Ein erneuter
SRAM-Programmiervorgang kann deshalb einen Board-Reset beziehungsweise
Power-Cycle erfordern.

## DDR3-Kapazitaet

Der eingebettete DDR3-Port der AE350-IP v1.2 ist fest 16 Bit breit und fuehrt
nur `A[13:0]` heraus. Daher wird in diesem Basisprojekt nur der untere
x16-DDR3-Baustein mit maximal 256 MiB adressiert. Die beiden Bausteine des
Boards ergeben zusammen 1 GiB, koennen aber nicht allein durch andere
Pin-Constraints an diesen festen Port angeschlossen werden.

Fuer volle 1 GiB ist als naechster eigener Ausbau noetig:

1. AE350 mit `Customized Data Memory` (64-Bit-AHB) erzeugen.
2. Den bewaehrten externen x32-DDR3-Controller fuer den 138C verwenden.
3. Eine korrekte 64-Bit-AHB-zu-256-Bit-Native-DDR-Bridge implementieren und
   mit Burst-, Byte-Lane- und Fehlerfaellen verifizieren.

Die vorhandene GoRV32-Plus-Linux-Variante bleibt waehrenddessen als
funktionierendes 1-GiB-System erhalten.

## IP-Regenerierung

`project/generate_plls.tcl` erzeugt die zwei PLLs fuer exakt den 138C neu.
Die AE350-IP selbst wird reproduzierbar aus den mit Gowin installierten
v1.2-Quellen synthetisiert; die dabei erzeugte geschuetzte `.v`-Netzliste liegt
als normale Projektquelle bei, damit auch der IDE-Lauf ohne Vorstufe klappt.
