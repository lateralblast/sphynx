/*
 * Regression test for cipher-chachapoly-libcrypto-mt.c.
 *
 * The keystream for a packet is pregenerated at a fixed size. A packet longer
 * than that, or an additional-data length over the header stream, used to be
 * XORed anyway, reading past the keystream into neighbouring state. The
 * cipher must refuse them.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ssherr.h"
#include "cipher-chachapoly-libcrypto-mt.h"

static int failures;

static void
expect(const char *what, int got, int want)
{
	if (got == want) {
		printf("ok   - %s\n", what);
	} else {
		printf("FAIL - %s: got %d, want %d\n", what, got, want);
		failures++;
	}
}

int
main(void)
{
	/* the MT cipher needs a 64 byte key: one for the header, one for the payload */
	u_char key[64];
	size_t big = 256 * 1024;
	u_char *src, *dst;
	struct chachapoly_ctx_mt *c;

	memset(key, 0x41, sizeof(key));
	src = calloc(1, big + 64);
	dst = calloc(1, big + 64);
	if (src == NULL || dst == NULL) {
		printf("FAIL - out of memory\n");
		return 2;
	}
	if ((c = chachapoly_new_mt(0, key, sizeof(key))) == NULL) {
		printf("FAIL - chachapoly_new_mt\n");
		return 2;
	}

	/* an ordinary packet still works: 4 bytes of length, 1000 of payload, 16 of tag */
	expect("ordinary packet is accepted",
	    chachapoly_crypt_mt(c, 0, dst, src, 1000, 4, 16, 1), 0);

	/* far larger than the pregenerated keystream, but within the packet size limit */
	expect("packet larger than the keystream is refused",
	    chachapoly_crypt_mt(c, 1, dst, src, 100000, 4, 16, 1),
	    SSH_ERR_INVALID_ARGUMENT);

	/* the largest allowed by the packet size limit */
	expect("256 KiB packet is refused",
	    chachapoly_crypt_mt(c, 2, dst, src, 256 * 1024, 4, 16, 1),
	    SSH_ERR_INVALID_ARGUMENT);

	/* additional data longer than the header stream */
	expect("additional data longer than the header stream is refused",
	    chachapoly_crypt_mt(c, 3, dst, src, 100, 100, 16, 1),
	    SSH_ERR_INVALID_ARGUMENT);

	chachapoly_free_mt(c);
	free(src);
	free(dst);
	printf("%d failure(s)\n", failures);
	return failures != 0;
}
