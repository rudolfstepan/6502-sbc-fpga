# Tang Mega 138K USB-CDC-Loopback

Dieses eigenstaendige FPGA-Projekt prueft zuerst die USB-Verbindung zwischen
Tang Console und PC. Es veraendert weder System16 noch DDR3 oder Linux:

- USB 1.1 Full Speed (12 Mbit/s) am dedizierten USB-C-Anschluss
- Gowin USB Device Controller v3.3 mit UTMI-Schnittstelle
- Gowin USB 1.1 SoftPHY v1.3 bei 60 MHz
- CDC-ACM-Enumeration als `CDC Loopback` (Hersteller `System16`)
- pakettreues Echo von Endpoint 2 OUT nach Endpoint 2 IN

Endpoint 1 IN ist als CDC-Interrupt-Endpoint konfiguriert. Der Loopback-Test
sendet dort noch keine `SERIAL_STATE`-Benachrichtigungen; der Host darf den
leeren Endpoint pollen.

Der USB-2.0-High-Speed-SoftPHY wird absichtlich nicht verwendet. Seine fuer
GW5AST erzeugte v3.5-Netzliste fordert fuer Bank 3 eine 2,5-V-I/O-Variante,
waehrend Board und dokumentierter Full-Speed-Pfad mit 3,3 V arbeiten.

## Direkt in der Gowin IDE bauen

In der Gowin IDE diese Datei oeffnen und normal mit `Process -> Run All`
bauen:

`project/tang138k_usb_cdc_loopback.gprj`

Die fuer GW5AST-138C erzeugten Controller- und SoftPHY-Netzlisten liegen als
Projektquellen unter `project/src`. Eine IP-Regenerierung und ein anderes
Board-Projekt sind fuer den IDE-Build nicht erforderlich. `project/build.tcl`
enthaelt denselben Build fuer eine optionale Kommandozeilen-Gegenprobe.

## Anschliessen und testen

1. Den erzeugten Bitstream programmieren.
2. Den dedizierten USB-C-Anschluss der Tang Console mit dem PC verbinden,
   nicht den Programmer-UART-Anschluss.
3. Im Windows-Geraetemanager unter `Anschluesse (COM & LPT)` den neuen
   `USB Serial Device (COM...)` beziehungsweise `CDC Loopback`-Port ablesen.
4. Den Echo-Test aus dem Repository-Wurzelverzeichnis mit dem neu angelegten
   COM-Port starten, zum Beispiel:

```powershell
& .\boards\tang_mega_138k\usb_cdc_loopback\tools\test_cdc_echo.ps1 -Port COM15
```

Der Test sendet standardmaessig 4096 Zufallsbytes in begrenzten Fenstern,
liest jedes Fenster zurueck und vergleicht alle Bytes. Ein laengerer Test ist
beispielsweise mit `-ByteCount 1048576 -TimeoutSeconds 120` moeglich.

Der FPGA begrenzt Bulk-IN-Pakete bewusst auf 63 Byte, obwohl der Descriptor
64 Byte MaxPacketSize erlaubt. Damit beendet jedes Paket einen Windows-
`usbser`-Lesetransfer sofort; auch Datenmengen von exakt 64 x N Byte bleiben
nicht bis zu einem spaeteren Short Packet oder ZLP gepuffert.

LED-Belegung:

- LED0: 60-MHz-PLL eingerastet
- LED1: USB-Controller online
- LED2: wechselt bei gueltigen OUT- und abgeschlossenen IN-Paketen
- LED3: Bus-Reset plus Diagnose der neutral gehaltenen USB-2-Pads

## Elektrische Pinbehandlung

J19/H19 sind das Full-Speed-Datenpaar. R129 verbindet M17 ueber 1,5 kOhm mit
D+. M17 ist waehrend FPGA-/PLL-Reset hochohmig und wird erst danach auf High
getrieben; auch ein USB-Bus-Reset trennt den Pull-up nicht. Die nur fuer den
USB-2.0-Pfad benoetigten Empfaenger H17/H18/H20/G20 sind pull-up-freie
LVCMOS33-Eingaenge. J16 und AB16 bleiben ueber explizite I/O-Puffer hochohmig.

## VID/PID

Der Test verwendet intern `33aa:0121`. Gowins VCP-Referenzkennung `33aa:0120`
wird auf dem Entwicklungs-PC bereits durch einen libwdi/WinUSB-Treiber
beansprucht und erzeugt deshalb keinen CDC-COM-Port. Auch `33aa:0121` ist nur
fuer diesen internen Boardtest vorgesehen und darf nicht als eigene
Produktkennung ausgeliefert werden. Fuer ein Produkt ist eine eigene
USB-VID/PID-Zuteilung erforderlich.
