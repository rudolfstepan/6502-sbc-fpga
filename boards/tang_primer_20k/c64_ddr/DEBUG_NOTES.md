# C64 Debug-Stand 2026-06-28

## Aktueller stabiler Stand

Der aktuelle Stand laeuft nach Hardwaretest stabil genug, um ihn erstmal
einzufrieren. Ein BASIC-Programm, das eine Variable hochzaehlt und ausgibt,
laeuft sichtbar weiter. Damit sind mindestens BASIC-Ausfuehrung, Screen Editor,
CIA1 Timer-A IRQ, Stack-Pfad, Tastatur/IRQ-Polling und RAM/VIC-Zugriffe im
laufenden Betrieb aktiv.

Aktueller Bitstream:

- `boards/tang_primer_20k/c64/bitstream/tang_c64.fs`
- SHA256: `D8DB1F8F3B5FAC84508F561CF2A9CD8557B82BFA270ECB82718E478344DA3644`
- Gowin-Build: 0 Setup- und 0 Hold-Verletzungen

Wichtig: An diesem Stand erstmal nichts ohne Not aendern.

## Was geaendert wurde

- Die CIA wurde testweise auf die MiST/MiSTer-Implementierung `mos6526_mist.v`
  umgestellt.
- Gowin-kompatible Anpassungen an `mos6526_mist.v` wurden gemacht, unter anderem
  Block-lokale Verilog-Regs auf Modulebene gezogen.
- CIA1/CIA2 werden in `c64_core.vhd` jetzt ueber den MiST-CIA-Bus angebunden.
- `cia_bus_en` wurde als Pre-Strobe vor dem CPU-`phi2_en` gesetzt, damit CIA
  Reads/Writes rechtzeitig fuer den T65-Daten-Sample liegen.
- Die Tastaturmatrix wurde bidirektional modelliert: CIA Port A und Port B
  koennen beide treiben/lesen.
- CIA2-Portausgaenge werden als eigene Pin-Level zurueckgefuehrt, passend zum
  erwarteten CIA-Pinmodell.
- Main-RAM- und Color-RAM-Write-FIFOs puffern CPU-Schreibbursts waehrend
  VIC-BA-Steals.
- `ram_settle` haelt RDY nach VIC-Steal/FIFO-Drain noch einige Takte low, damit
  der Single-Port-BSRAM wieder gueltige CPU-Lesedaten liefert.
- Der Host-Disk-UART im C64-Core existiert weiter, ist im aktuellen Diagnose-Top
  aber zugunsten des Debug-UARTs vom CH340 getrennt.

## Debug-UART

Der CH340 gibt aktuell ungefaehr einmal pro Sekunde einen Snapshot aus:

```text
PC=xxxx ST=xxxx A=xxxx DI=xx DO=xx C1=xxxxxxxx R=xxxxxxxxxxxxxxxx IC=xxxx IK=xxxx SW=aa:dd SR=aa:dd
```

Felder:

- `PC`: letzter Opcode-Fetch
- `ST`: gepackter Core-Status
- `A`: aktuelle CPU-Busadresse, nicht Akkumulator
- `DI`: CPU-Dateneingang
- `DO`: CPU-Datenausgang
- `C1`: CIA1-Debugstatus
- `R`: T65-Registerpackung `PC,S,P,Y,X,A`
- `IC`: 16-bit Opcode-Fetch-Zaehler
- `IK`: 16-bit Zaehler fuer KERNAL IRQ/BRK-Vektoreinstieg `$FF48`
- `SW`: letzter Stack-Write, Low-Adresse und Daten
- `SR`: letzter Stack-Read, Low-Adresse und Daten

`ST`-Bitbelegung:

```text
15 phi2_en
14 cs_vic
13 cs_cia1
12 cwq_full
11 wq_full
10 cwq_nonempty
 9 wq_nonempty
 8 cpu_we
 7 cpu_sync
 6 restore_n
 5 cia2_irq_n
 4 vic_irq_n
 3 cia1_irq_n
 2 cpu_irq_n
 1 vic_ba
 0 cpu_rdy
```

`C1`-Bitbelegung:

```text
31     irq_n
30     int_reset
29     rd
28     wr
27..23 IMR[4:0]
22..18 ICR[4:0]
17..16 CRA[1:0]
15..0  Timer A
```

## Wichtige Erkenntnisse

- Der 6510 hat keine gepagete Zero Page und keinen gepageten Stack.
  Zero Page ist fest `$0000-$00FF`, Stack fest `$0100-$01FF`.
- `$0000/$0001` sind der 6510-Prozessorport fuer Banking.
- Fruehere Haenger nach `SYNTAX ERROR` zeigten teils CIA1-IRQ low oder Aktivitaet
  im KERNAL-IRQ-Prolog.
- Der echte KERNAL IRQ/BRK-Vektor ist `$FFFE -> $FF48`, nicht `$FF43`.
- `IK` wurde deshalb auf `$FF48` korrigiert.
- Ein spaeter stabiler Snapshot waehrend BASIC-Ausgabe war plausibel:
  `ST=807F`, CIA1 IRQ inaktiv, IRQ-Zaehler aktiv, Stackwerte unauffaellig.

## Letzter stabiler Beobachtungspunkt

Snapshot waehrend laufendem BASIC-Zaehlerprogramm:

```text
PC=E9DD ST=807F A=E9DE DI=F5 DO=0A C1=80811A97 R=E9DEFFE5300A130E IC=332C IK=4913 SW=E2:E2 SR=E5:E9
```

Interpretation:

- CPU laeuft in KERNAL-Ausgabe/Screen-Routine.
- `ST=807F`: RDY/BA ok, keine IRQ-Leitung aktiv im Snapshot.
- `C1=80811A97`: CIA1 IRQ nicht pending, Timer A laeuft.
- `IC` und `IK` zaehlen, also CPU und IRQ-Service leben.
- `SW`/`SR` zeigen keinen offensichtlichen Stack-Fehler.

## UART-PRG-Loader

Stand 2026-06-28:

- Der CH340-UART streamt im Idle weiter den C64-Debug-UART.
- Sobald der PC ein Byte sendet, wird der vorhandene `uart_debug_monitor`
  aktiviert und uebernimmt den UART bis zum Monitor-Befehl `G`.
- `uart_debug_monitor` hat dafuer einen generischen `FLAT_64K`-Modus bekommen.
  Im C64 sieht der Monitor die kompletten 64K als RAM unter ROM/I/O.
- `c64_core` parkt die CPU bei aktivem Monitor ueber RDY und laesst
  Monitor-RAM-Zugriffe nur zu, wenn VIC-BA, RAM-Settle und beide Write-FIFOs
  ruhig sind.
- PC-Helfer:

```text
python tools/c64_uart_prg_loader.py demo.prg --port COM15
```

Fuer BASIC-PRGs mit Ladeadresse `$0801` setzt das Tool automatisch die BASIC-
Pointer `$2B-$32` auf den Programmstart und das Programmende. Danach sendet es
`G` ohne Adresse; am C64 dann `RUN` tippen.

Das ist noch kein echter KERNAL-`LOAD"*",8,1`-Hook und keine 1541-Emulation,
sondern ein pragmatischer RAM-Loader fuer den aktuellen stabilen Core.
