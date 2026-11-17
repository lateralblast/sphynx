/*
 * Test for the huff0@hpnssh.org compression method (compress-huff0.c).
 *
 * It compresses and expands buffers of assorted sizes and contents, including
 * ones longer than one block, checks they come back unchanged, checks that
 * compressible data gets smaller and random data grows by no more than the
 * block headers, and feeds the expander malformed and corrupted input, which
 * it must refuse or expand without writing outside its buffer (run it under
 * AddressSanitizer to check that).
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sshbuf.h"
#include "ssherr.h"
#include "compress-huff0.h"

#define MAXOUT	(256 * 1024)

static int failures;

static void
check(const char *what, int ok)
{
	if (ok)
		printf("ok   - %s\n", what);
	else {
		printf("FAIL - %s\n", what);
		failures++;
	}
}

static uint64_t rng = 0x9e3779b97f4a7c15ULL;

static uint32_t
rnd(void)
{
	rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
	return (uint32_t)(rng >> 16);
}

enum kind { ZEROS, TEXT, SKEWED, RANDOM };

static void
fill(u_char *p, size_t n, enum kind k)
{
	static const char *words[] = { "sshd", "Accepted", "publickey", "for",
	    "alice", "from", "10.0.0.7", "port", "ssh2", "session", "opened" };
	size_t i, w;

	switch (k) {
	case ZEROS:
		memset(p, 0, n);
		break;
	case TEXT:
		for (i = 0; i < n;) {
			const char *word = words[rnd() % 11];

			w = strlen(word);
			if (w > n - i)
				w = n - i;
			memcpy(p + i, word, w);
			i += w;
			if (i < n)
				p[i++] = (rnd() % 7) ? ' ' : '\n';
		}
		break;
	case SKEWED:
		for (i = 0; i < n; i++)
			p[i] = (rnd() % 10) < 8 ? 'a' + rnd() % 4 : rnd();
		break;
	default:
		for (i = 0; i < n; i++)
			p[i] = rnd();
	}
}

/* compress then expand; returns the compressed size, or -1 on a failure */
static long
roundtrip(const u_char *data, size_t n)
{
	struct sshbuf *in, *comp, *out;
	long ret = -1;

	if ((in = sshbuf_new()) == NULL || (comp = sshbuf_new()) == NULL ||
	    (out = sshbuf_new()) == NULL)
		abort();
	if (sshbuf_put(in, data, n) != 0)
		abort();
	if (huff0_compress(in, comp) == 0 &&
	    huff0_uncompress(comp, out, MAXOUT) == 0 &&
	    sshbuf_len(out) == n && (n == 0 || memcmp(sshbuf_ptr(out), data, n) == 0))
		ret = (long)sshbuf_len(comp);
	sshbuf_free(in);
	sshbuf_free(comp);
	sshbuf_free(out);
	return ret;
}

/* expand raw bytes; returns the sshbuf error code */
static int
expand(const u_char *p, size_t n, size_t max)
{
	struct sshbuf *in = sshbuf_new(), *out = sshbuf_new();
	int r;

	if (in == NULL || out == NULL || sshbuf_put(in, p, n) != 0)
		abort();
	r = huff0_uncompress(in, out, max);
	sshbuf_free(in);
	sshbuf_free(out);
	return r;
}

static void
put32(u_char *p, uint32_t v)
{
	p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

int
main(void)
{
	static const size_t sizes[] = { 0, 1, 2, 63, 64, 65, 255, 1000, 4096,
	    32768, 32769, 131071, 131072, 131073, 200000, 262144 };
	static const char *kinds[] = { "zeros", "text", "skewed", "random" };
	u_char *buf = malloc(MAXOUT), msg[256];
	size_t i, k, bad;
	long c;
	char what[128];
	struct sshbuf *in, *comp, *out;

	if (buf == NULL)
		abort();

	for (k = 0; k < 4; k++) {
		for (i = 0, bad = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
			fill(buf, sizes[i], (enum kind)k);
			if ((c = roundtrip(buf, sizes[i])) < 0) {
				printf("     %s, %zu bytes failed\n",
				    kinds[k], sizes[i]);
				bad++;
			}
		}
		snprintf(what, sizeof(what),
		    "%s: every size from 0 to 256 KiB round-trips", kinds[k]);
		check(what, bad == 0);
	}

	fill(buf, 32768, TEXT);
	c = roundtrip(buf, 32768);
	check("text of 32 KiB shrinks to under 70 percent", c > 0 && c < 32768 * 70 / 100);
	fill(buf, 32768, ZEROS);
	c = roundtrip(buf, 32768);
	check("a run of one byte shrinks to under 100 bytes", c > 0 && c < 100);
	fill(buf, 32768, RANDOM);
	c = roundtrip(buf, 32768);
	check("random data grows only by the 5 byte header", c == 32768 + 5);
	fill(buf, 300000 > MAXOUT ? MAXOUT : 300000, RANDOM);
	c = roundtrip(buf, 262144);
	check("random data over 2 blocks grows by 2 headers", c == 262144 + 10);

	/* malformed streams */
	memset(msg, 0, sizeof(msg));
	check("empty input expands to nothing", expand(msg, 0, MAXOUT) == 0);
	check("a header cut short is refused", expand(msg, 4, MAXOUT) != 0);
	msg[0] = 7; put32(msg + 1, 4);
	check("an unknown block type is refused", expand(msg, 9, MAXOUT) != 0);
	msg[0] = 0; put32(msg + 1, 0);
	check("a stored block of length 0 is refused", expand(msg, 5, MAXOUT) != 0);
	put32(msg + 1, 10);
	check("a stored block cut short is refused", expand(msg, 12, MAXOUT) != 0);
	put32(msg + 1, 10);
	check("a stored block of 10 bytes is accepted", expand(msg, 15, MAXOUT) == 0);
	check("a stored block over the output limit is refused", expand(msg, 15, 9) != 0);
	put32(msg + 1, 131073);
	check("a block over 128 KiB is refused", expand(msg, 5, MAXOUT) != 0);
	msg[0] = 1; put32(msg + 1, 100); put32(msg + 5, 0);
	check("a coded block with coded length 0 is refused", expand(msg, 9, MAXOUT) != 0);
	put32(msg + 5, 100);
	check("a coded length not under the raw length is refused", expand(msg, 9 + 100, MAXOUT) != 0);
	put32(msg + 5, 50);
	check("a coded block cut short is refused", expand(msg, 9 + 10, MAXOUT) != 0);
	put32(msg + 5, 0xffffffffU);
	check("a huge coded length is refused", expand(msg, 9, MAXOUT) != 0);
	msg[0] = 1; put32(msg + 1, 131072); put32(msg + 5, 1); msg[9] = 'x';
	check("a run block of 128 KiB from 1 byte is accepted", expand(msg, 10, MAXOUT) == 0);
	check("... and refused over the output limit", expand(msg, 10, 1000) != 0);

	/* corrupted streams: flip bytes of a good one, expect no crash */
	fill(buf, 20000, TEXT);
	if ((in = sshbuf_new()) == NULL || (comp = sshbuf_new()) == NULL ||
	    (out = sshbuf_new()) == NULL)
		abort();
	sshbuf_put(in, buf, 20000);
	if (huff0_compress(in, comp) != 0)
		abort();
	{
		size_t n = sshbuf_len(comp), t;
		u_char *copy = malloc(n);
		int accepted = 0;

		for (t = 0; t < 4000; t++) {
			memcpy(copy, sshbuf_ptr(comp), n);
			copy[rnd() % n] ^= 1 << (rnd() % 8);
			if (t % 4 == 0)
				copy[rnd() % n] = rnd();
			if (expand(copy, t % 5 == 0 ? rnd() % n : n, MAXOUT) == 0)
				accepted++;
		}
		printf("     %d of 4000 corrupted streams still expanded\n", accepted);
		check("4000 corrupted streams cause no crash", 1);
		free(copy);
	}
	sshbuf_free(in);
	sshbuf_free(comp);
	sshbuf_free(out);
	free(buf);

	if (failures) {
		printf("%d failures\n", failures);
		return 1;
	}
	printf("all passed\n");
	return 0;
}
