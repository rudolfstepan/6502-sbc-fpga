# Screen-Editor Line Replay (C64-style on-screen editing)

**Status:** RESOLVED 2026-06-25 — corrected lines now tokenize cleanly on FPGA hardware.
**Component:** `sw/kernel.s` (CHRIN/CHRIN_NB, `handle_screen_key`, `build_screen_replay`, `replay_next`)

The kernel gives EhBASIC a C64-style full-screen line editor: you can move the
hardware cursor into a line you already typed, overtype characters, delete with
backspace, and press Enter anywhere on the line. This document explains how that
works and the input-buffer-desync bug that was fixed on 2026-06-25.

---

## 1. The two-editor problem

There are **two** independent things collecting the line you type:

1. **EhBASIC's input loop** (`LAB_1357`/`LAB_1359` in `basic.asm`). It calls the
   input vector `VEC_IN` → `KERNAL_CHRIN_NB`, stores each returned character in
   its own buffer `Ibuffs` ($0221), echoes it via `VEC_OUT` → `KERNAL_CHROUT`,
   and handles backspace ($08) itself by decrementing its buffer index.

2. **The kernel screen editor** (`handle_screen_key`). When the cursor keys,
   backspace, HOME, CLR, or any printable key arrive *while editing*, it edits
   the VIC screen RAM directly and returns C=0 ("consumed"), so the key is **not**
   passed up to EhBASIC.

While you just type normally, `SCREEN_EDIT_ACTIVE = 0` and every printable key is
passed through (C=1): EhBASIC stores it in `Ibuffs` and echoes it. The two stay
in sync.

The moment you press a cursor key or backspace, `SCREEN_EDIT_ACTIVE` is set and
the kernel starts editing the **screen only**. EhBASIC's `Ibuffs` is now frozen
with the originally-typed text and drifts out of sync with what's on screen.

When you finally press Enter while editing, `build_screen_replay` reads the whole
screen line back (trailing spaces trimmed, CR appended) into `SCREEN_REPLAY_BUF`
and feeds it to EhBASIC one character at a time through `replay_next` (called from
`CHRIN_NB`). `CHROUT` suppresses the echo while `SCREEN_REPLAY_POS < SCREEN_REPLAY_LEN`
so the replayed text is not duplicated on screen.

---

## 2. The bug (pre-2026-06-25)

The replay fed the corrected line to EhBASIC, but EhBASIC's `Ibuffs` still held
the **original** characters. EhBASIC stored the replayed characters *after* them
instead of replacing them:

```
type   "PRIMT"          Ibuffs = "PRIMT"   screen = "PRIMT"
edit   M -> N           Ibuffs = "PRIMT"   screen = "PRINT"   (screen only)
Enter  -> replay "PRINT\r"
                        Ibuffs = "PRIMTPRINT"  -> ?SYNTAX ERROR
```

Any on-screen edit (backspace was just the most obvious trigger) corrupted the
command. The control characters themselves were correctly swallowed by
`handle_screen_key`; the damage was the leftover prefix in `Ibuffs`.

---

## 3. The fix

Before replaying the corrected line, empty EhBASIC's input buffer by feeding it a
run of backspaces. EhBASIC processes each `$08` by decrementing its buffer index
(`LAB_134B`), and ignores a backspace once the buffer is already empty — so
sending its maximum line length ($47 = 71) backspaces always clears it exactly,
regardless of how many characters it had collected.

- `build_screen_replay` sets `SCREEN_FLUSH = $47` right before starting the replay.
- `replay_next` returns `$08` (C=1) `SCREEN_FLUSH` times before the real buffer
  contents. `SCREEN_REPLAY_POS` is left at 0 during the flush, so the existing
  `POS < LEN` echo suppression in `CHROUT` hides these backspaces (no screen or
  UART output).
- After the flush drains, the normal replay of the corrected line proceeds, now
  landing in a freshly-empty `Ibuffs`. The trailing CR ends the line and BASIC
  parses the corrected text.

`SCREEN_FLUSH` lives at $02F9 (page 2) and is cleared in the screen-state reset.

```
type   "PRIMT"          Ibuffs = "PRIMT"
edit   M -> N           screen = "PRINT"
Enter  -> 71x $08 (Ibuffs emptied), then "PRINT\r"
                        Ibuffs = "PRINT"   -> runs correctly
```

---

## 4. Related notes

- This is distinct from the 2026-06-07 syntax-error work
  ([EHBASIC_SYNTAX_ERROR_ANALYSIS.md](./EHBASIC_SYNTAX_ERROR_ANALYSIS.md)), which
  was about lost SDRAM writes and zero-page collisions. This bug is purely in the
  kernel's screen-edit/replay path.
- `VEC_IN` points at the **non-blocking** `CHRIN_NB`, which does no echo of its
  own; EhBASIC echoes via `CHROUT`. `CHRIN` (blocking, used by kernel-internal
  prompts) does echo and uses `SCREEN_REPLAY_CHAR` to skip echo on replayed bytes.
- Cursor keys arrive as PETSCII codes ($11 down, $91 up, $1D right, $9D left);
  `handle_screen_key` maps them to screen-cursor moves and never forwards them.
