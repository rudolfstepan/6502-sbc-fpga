#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DEFAULT_KIB 2048UL
#define DEFAULT_PASSES 8UL

static volatile uint32_t benchmark_sink;

static uint64_t now_ns(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
		perror("clock_gettime");
		exit(EXIT_FAILURE);
	}
	return (uint64_t)ts.tv_sec * UINT64_C(1000000000) +
	       (uint64_t)ts.tv_nsec;
}

static unsigned long parse_number(const char *text, const char *name)
{
	char *end;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 0);
	if (errno || *text == '\0' || *end != '\0' || value == 0) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		exit(EXIT_FAILURE);
	}
	return value;
}

static void print_rate(const char *name, uint64_t bytes, uint64_t elapsed_ns)
{
	uint64_t kib_s;
	uint64_t ms;

	if (elapsed_ns == 0)
		elapsed_ns = 1;
	kib_s = (bytes * UINT64_C(1000000000)) /
	        (elapsed_ns * UINT64_C(1024));
	ms = elapsed_ns / UINT64_C(1000000);
	printf("%-8s %6" PRIu64 " ms  %8" PRIu64 " KiB/s\n",
	       name, ms, kib_s);
}

int main(int argc, char **argv)
{
	unsigned long kib = DEFAULT_KIB;
	unsigned long passes = DEFAULT_PASSES;
	size_t bytes;
	size_t words;
	uint32_t *src;
	uint32_t *dst;
	volatile uint32_t *write_dst;
	volatile uint32_t *read_src;
	uint32_t sum = 0;
	uint64_t start;
	uint64_t elapsed;
	unsigned long pass;
	size_t i;

	if (argc > 3) {
		fprintf(stderr, "usage: %s [size-KiB [passes]]\n", argv[0]);
		return EXIT_FAILURE;
	}
	if (argc >= 2)
		kib = parse_number(argv[1], "size-KiB");
	if (argc == 3)
		passes = parse_number(argv[2], "passes");
	bytes = (size_t)kib * 1024UL;
	if (bytes / 1024UL != kib) {
		fprintf(stderr, "working set is too large\n");
		return EXIT_FAILURE;
	}
	bytes &= ~(sizeof(uint32_t) - 1UL);
	words = bytes / sizeof(uint32_t);
	src = malloc(bytes);
	dst = malloc(bytes);
	if (bytes == 0 || src == NULL || dst == NULL) {
		fprintf(stderr, "cannot allocate two %lu KiB buffers\n", kib);
		free(dst);
		free(src);
		return EXIT_FAILURE;
	}

	/* Fault both buffers in before timing so page faults do not skew results. */
	memset(src, 0x5a, bytes);
	memset(dst, 0xa5, bytes);
	write_dst = dst;
	read_src = src;

	printf("System16 memory benchmark\n");
	printf("working set: %lu KiB x 2, passes: %lu\n", kib, passes);

	start = now_ns();
	for (pass = 0; pass < passes; ++pass)
		for (i = 0; i < words; ++i)
			write_dst[i] = (uint32_t)(i + pass);
	elapsed = now_ns() - start;
	print_rate("write", (uint64_t)bytes * passes, elapsed);

	start = now_ns();
	for (pass = 0; pass < passes; ++pass)
		for (i = 0; i < words; ++i)
			sum += read_src[i];
	elapsed = now_ns() - start;
	benchmark_sink = sum;
	print_rate("read", (uint64_t)bytes * passes, elapsed);

	start = now_ns();
	for (pass = 0; pass < passes; ++pass)
		memcpy(dst, src, bytes);
	elapsed = now_ns() - start;
	/* memcpy transfers each byte once from src and once to dst. */
	print_rate("memcpy", (uint64_t)bytes * passes * 2UL, elapsed);

	printf("checksum: %08" PRIx32 "\n", sum);
	free(dst);
	free(src);
	return EXIT_SUCCESS;
}
