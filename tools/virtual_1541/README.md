# C64 Virtual 1541 UART Drive

Tkinter GUI for a PC-side virtual Commodore 1541 drive. The tool talks to the
Tang C64 core over the USB UART and serves mounted `.d64` images to the C64
KERNAL load hook.

## Start

Double-click:

```bat
tools\virtual_1541\start.bat
```

Or from the repository root:

```powershell
python tools\virtual_1541\c64_1541_uart_gui.py --port COM15 --folder E:\Emulatoren\C64\Games
```

The old path still works as a compatibility launcher:

```powershell
python tools\c64_1541_uart_gui.py
```

## Settings

The GUI remembers the last folder, COM port, baud rate, mounted disk, pacing
settings, and window geometry in:

```text
%APPDATA%\c64_virtual_1541_uart\settings.json
```

Command-line arguments override saved settings for that launch.

## KERNAL LOAD Hook Benutzen

Der Hook ist ein kleines C64-PRG, das einmal geladen und mit `RUN` gestartet
wird. Danach faengt es KERNAL-Loads auf Device 8 ab und spricht ueber den
UART mit diesem virtuellen Laufwerk.

Wichtig: Der UART kann immer nur von einem PC-Programm gleichzeitig benutzt
werden. Erst den PRG-Loader beenden, dann die virtuelle 1541 verbinden.

1. Hook bauen:

   ```powershell
   make c64-v1541-hook-prg
   ```

2. Hook auf den C64 hochladen:

   ```powershell
   python tools\c64_uart_prg_loader.py roms\v1541_hook.prg --port COM15
   ```

   Bequemer geht es direkt in der GUI mit `SEND HOOK`. Die GUI trennt die
   virtuelle 1541-Verbindung, startet den UART-PRG-Loader fuer
   `roms\v1541_hook.prg` und verbindet sich nach erfolgreichem Upload wieder
   automatisch.

3. Am C64 den Hook einmal starten:

   ```basic
   RUN
   ```

   Erwartete Ausgabe:

   ```text
   V1541 KERNAL LOAD HOOK READY
   USE LOAD"*",8,1
   ```

4. Falls der Hook manuell per Kommandozeile hochgeladen wurde: Das Upload-Tool
   muss jetzt beendet sein. Danach das virtuelle Laufwerk starten:

   ```powershell
   python tools\virtual_1541\c64_1541_uart_gui.py --port COM15 --folder E:\Emulatoren\C64\Games
   ```

   Alternativ `tools\virtual_1541\start.bat` starten, Port/Ordner waehlen,
   `CONNECT` klicken und eine `.d64` mounten. Beim `SEND HOOK`-Button erledigt
   die GUI das erneute Verbinden selbst.

5. Am C64 normale KERNAL-LOAD-Befehle benutzen:

   ```basic
   LOAD"$",8
   LIST
   LOAD"*",8,1
   RUN
   ```

   Auch benannte PRGs gehen:

   ```basic
   LOAD"PROGRAMM",8,1
   RUN
   ```

### Hinweise Zum Hook

- Nach Reset oder Power-Cycle ist der RAM-Hook weg und muss erneut hochgeladen
  und mit `RUN` gestartet werden.
- Programme, die den Bereich ab `$C000` ueberschreiben, koennen den Hook
  zerstoeren. Danach ebenfalls neu hochladen/starten.
- `LOAD"name",8,1` benutzt die Ladeadresse aus dem PRG.
- `LOAD"name",8` laedt an die vom KERNAL angefragte Adresse.
- Intern nutzt der Hook Kanal 2: `OPEN 2,<name>`, wiederholtes `READ 2,128`,
  danach `CLOSE 2`.
- Das PC-Laufwerk ist aktuell eine 1541-kompatible Datei-/Kanal-Abstraktion.
  Fastloader und echte IEC-Timing-Tricks werden damit noch nicht emuliert.

## Files

- `c64_1541_uart_gui.py` - GUI and UART/D64 server
- `C64_1541_UART_PROTOCOL.md` - binary protocol and 1541-like command layer
- `start.bat` - Windows launcher from a double-click or terminal

This is a 1541-compatible command/file abstraction over UART, not a
cycle-accurate IEC/1541 emulator.
