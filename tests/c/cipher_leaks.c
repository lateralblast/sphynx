/*
 * Starting and freeing a cipher many times must not leave anything behind.
 *
 * OpenSSL's allocations are counted, and starting and freeing ChaCha20-Poly1305
 * 200 times must not change the number that are live. The POLY1305 fetch in
 * chachapoly_new() and the AES-CTR-MT provider and cipher fetches in
 * cipher_init() used to keep a reference on every start. A reference to an
 * object OpenSSL caches is a counter and not an allocation, so this test does
 * not fail on that; it guards against a context or buffer being left behind
 * in these paths. The multithreaded AES-CTR cipher is started repeatedly as
 * well, and its bytes must still match the serial cipher's.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#ifdef WITH_OPENSSL

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/crypto.h>

#include "cipher.h"
#include "cipher-chachapoly.h"
#include "ssherr.h"

static long live;

static void *
count_malloc(size_t n, const char *file, int line)
{
	void *p = malloc(n);

	(void)file; (void)line;
	if (p != NULL)
		live++;
	return p;
}

static void *
count_realloc(void *old, size_t n, const char *file, int line)
{
	void *p = realloc(old, n);

	(void)file; (void)line;
	if (old == NULL && p != NULL)
		live++;
	return p;
}

static void
count_free(void *p, const char *file, int line)
{
	(void)file; (void)line;
	if (p != NULL)
		live--;
	free(p);
}

int
main(void)
{
	u_char key[64], iv[16], in[1024], out[1024], again[1024];
	struct chachapoly_ctx *cp;
	struct sshcipher_ctx *cc;
	long before;
	int i, failures = 0;

	if (!CRYPTO_set_mem_functions(count_malloc, count_realloc, count_free)) {
		printf("skip - could not count OpenSSL's allocations\n");
		return 0;
	}
	for (i = 0; i < (int)sizeof(key); i++)
		key[i] = (u_char)(i * 7 + 1);
	memset(iv, 0x5a, sizeof(iv));
	for (i = 0; i < (int)sizeof(in); i++)
		in[i] = (u_char)i;

	/* the first start sets up what OpenSSL keeps for good */
	for (i = 0; i < 3; i++) {
		if ((cp = chachapoly_new(key, sizeof(key))) == NULL) {
			printf("FAIL - chachapoly_new\n");
			return 1;
		}
		chachapoly_free(cp);
	}
	before = live;
	for (i = 0; i < 200; i++) {
		if ((cp = chachapoly_new(key, sizeof(key))) == NULL) {
			printf("FAIL - chachapoly_new\n");
			return 1;
		}
		chachapoly_free(cp);
	}
	if (live == before)
		printf("ok   - starting and freeing ChaCha20-Poly1305 200 times keeps %ld allocations live\n", live);
	else {
		printf("FAIL - %ld allocations were left by 200 starts of ChaCha20-Poly1305\n", live - before);
		failures++;
	}

#ifdef WITH_OPENSSL3
	/* the multithreaded AES-CTR cipher, the way ssh starts it after login */
	{
		const struct sshcipher *c = cipher_by_name("aes256-ctr");
		struct sshcipher_ctx *plain;
		int ok = 1;

		for (i = 0; i < 20 && ok; i++) {
			if (cipher_init(&cc, c, key, 32, iv, 16, 0, CIPHER_ENCRYPT, 1) != 0 ||
			    cipher_init(&plain, c, key, 32, iv, 16, 0, CIPHER_ENCRYPT, 0) != 0) {
				ok = 0;
				break;
			}
			if (cipher_crypt(cc, 0, out, in, sizeof(in), 0, 0) != 0 ||
			    cipher_crypt(plain, 0, again, in, sizeof(in), 0, 0) != 0 ||
			    memcmp(out, again, sizeof(out)) != 0)
				ok = 0;
			cipher_free(cc);
			cipher_free(plain);
		}
		if (ok)
			printf("ok   - the multithreaded AES-CTR cipher started 20 times gives the serial cipher's bytes\n");
		else {
			printf("FAIL - the multithreaded AES-CTR cipher did not match the serial one\n");
			failures++;
		}
	}
#endif
	return failures ? 1 : 0;
}

#else
int
main(void)
{
	return 0;
}
#endif
