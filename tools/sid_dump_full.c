/* Dump all 25 SID registers once per 50 Hz frame from a PSID file.
 * This is intentionally independent of the reduced five-byte-per-voice dump
 * used by the old converter, because pulse width and filter state matter.
 */
#include "cpu6502.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t mem[65536];
static uint8_t rd(void *ctx, uint16_t a) { (void)ctx; return mem[a]; }
static void wr(void *ctx, uint16_t a, uint8_t v) { (void)ctx; mem[a] = v; }

static void call_sub(CPU6502 *cpu, uint16_t addr, uint8_t a)
{
    long guard = 0;
    cpu->A = a; cpu->X = 0; cpu->Y = 0; cpu->SP = 0xff;
    mem[0x0100 + cpu->SP--] = 0;
    mem[0x0100 + cpu->SP--] = 0;
    cpu->PC = addr; cpu->P |= FLAG_I;
    while (cpu->SP != 0xff && guard++ < 20000000)
        cpu6502_step(cpu);
}

int main(int argc, char **argv)
{
    uint8_t hdr[0x7e], body[65536];
    int data_off, load, init, play, songs, start, n, off = 0, frames;
    FILE *in, *out;
    CPU6502 cpu;

    if (argc != 4) {
        fprintf(stderr, "usage: %s input.sid seconds output.raw\n", argv[0]);
        return 2;
    }
    in = fopen(argv[1], "rb");
    if (!in) { perror("input"); return 1; }
    if (fread(hdr, 1, sizeof hdr, in) != sizeof hdr) return 1;
    data_off = (hdr[6] << 8) | hdr[7];
    load = (hdr[8] << 8) | hdr[9];
    init = (hdr[10] << 8) | hdr[11];
    play = (hdr[12] << 8) | hdr[13];
    songs = (hdr[14] << 8) | hdr[15];
    start = (hdr[16] << 8) | hdr[17];
    (void)songs;
    fseek(in, data_off, SEEK_SET);
    n = (int)fread(body, 1, sizeof body, in);
    fclose(in);
    if (load == 0) { load = body[0] | (body[1] << 8); off = 2; }
    memcpy(&mem[load], &body[off], (size_t)(n - off));

    cpu6502_init(&cpu, rd, wr, NULL);
    cpu6502_reset(&cpu);
    call_sub(&cpu, (uint16_t)init, (uint8_t)(start - 1));

    out = fopen(argv[3], "wb");
    if (!out) { perror("output"); return 1; }
    frames = (int)(atof(argv[2]) * 50.0 + 0.5);
    for (int f = 0; f < frames; ++f) {
        call_sub(&cpu, (uint16_t)play, 0);
        fwrite(&mem[0xd400], 1, 25, out);
    }
    fclose(out);
    printf("%d frames, 25 SID registers/frame -> %s\n", frames, argv[3]);
    return 0;
}
