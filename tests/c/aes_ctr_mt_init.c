/*
 * Regression test for starting the multithreaded AES-CTR cipher the way ssh
 * does, through cipher_init() with threads enabled (cipher.c).
 *
 * The provider (cipher-ctr-mt-provider.c) is handed an EVP_CIPHER_CTX as its
 * context and keeps the real state as that context's app data. Its
 * get_ctx_params and set_ctx_params functions used to treat the pointer as the
 * state itself, so they read and wrote the wrong memory: a value 17 MB past
 * the start of a small allocation. That went unnoticed with OpenSSL 3.5, where
 * libcrypto never made the call, and crashed every aes-ctr connection with
 * OpenSSL 4.1, which does.
 *
 * Each key size is started with threads and without, for both directions, and
 * the two must produce the same bytes.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#ifdef WITH_OPENSSL3

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cipher.h"
#include "ssherr.h"

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

int
main(void)
{
	const char *names[] = { "aes128-ctr", "aes192-ctr", "aes256-ctr" };
	/* a few keystream queues' worth, in chunks the size of an ssh packet */
	const size_t total = 1024 * 1024 + 16 * 3, chunk = 32768;
	u_char key[32], iv[16];
	u_char *in, *plain, *mt;
	size_t i, off, n;
	int k, enc;

	for (i = 0; i < sizeof(key); i++)
		key[i] = (u_char)(i * 11 + 3);
	for (i = 0; i < sizeof(iv); i++)
		iv[i] = (u_char)(0xa0 + i);
	if ((in = malloc(total)) == NULL || (plain = malloc(total)) == NULL ||
	    (mt = malloc(total)) == NULL)
		return 2;
	for (i = 0; i < total; i++)
		in[i] = (u_char)((i * 2654435761u) >> 11);

	for (k = 0; k < 3; k++) {
		const struct sshcipher *c = cipher_by_name(names[k]);
		char msg[96];

		if (c == NULL) {
			printf("FAIL - no cipher %s\n", names[k]);
			return 2;
		}
		for (enc = 0; enc <= 1; enc++) {
			struct sshcipher_ctx *ref = NULL, *thr = NULL;
			int r1, r2, ok = 1;

			r1 = cipher_init(&ref, c, key, cipher_keylen(c), iv,
			    cipher_ivlen(c), 0, enc ? CIPHER_ENCRYPT : CIPHER_DECRYPT, 0);
			r2 = cipher_init(&thr, c, key, cipher_keylen(c), iv,
			    cipher_ivlen(c), 0, enc ? CIPHER_ENCRYPT : CIPHER_DECRYPT, 1);
			snprintf(msg, sizeof(msg), "%s %s starts with threads (%d, %d)",
			    names[k], enc ? "encrypt" : "decrypt", r1, r2);
			check(msg, r1 == 0 && r2 == 0);
			if (r1 != 0 || r2 != 0)
				continue;
			for (off = 0; off < total; off += n) {
				n = total - off < chunk ? total - off : chunk;
				if (cipher_crypt(ref, 0, plain + off, in + off, n, 0, 0) != 0 ||
				    cipher_crypt(thr, 0, mt + off, in + off, n, 0, 0) != 0)
					ok = 0;
			}
			snprintf(msg, sizeof(msg), "%s %s with threads matches without",
			    names[k], enc ? "encrypt" : "decrypt");
			check(msg, ok && memcmp(plain, mt, total) == 0);
			cipher_free(ref);
			cipher_free(thr);
		}
	}

	printf("%d failure(s)\n", failures);
	return failures ? 1 : 0;
}

#else
int
main(void)
{
	printf("skip - not an OpenSSL 3 build\n");
	return 0;
}
#endif
