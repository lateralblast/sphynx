/*
 * Known-answer test for the multithreaded AES-CTR cipher
 * (cipher-ctr-mt-functions.c, the OpenSSL 3 build).
 *
 * aes_mt_do_cipher XORs the keystream queues into the data. It does so over
 * whatever is left of the current queue in one pass, and switches queues at
 * the end of each. This encrypts data in chunks of assorted sizes, across
 * several queue switches, and checks the result against OpenSSL's own
 * AES-256-CTR with the same key and counter.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#ifdef WITH_OPENSSL3

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>
#include <openssl/provider.h>

extern OSSL_provider_init_fn OSSL_provider_init;

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

/* encrypt in with the given chunk sizes (cycled), return the result */
static u_char *
crypt_chunks(EVP_CIPHER_CTX *ctx, const u_char *in, size_t total,
    const size_t *sizes, int nsizes)
{
	u_char *out = malloc(total);
	size_t off = 0;
	int i = 0;

	if (out == NULL)
		return NULL;
	while (off < total) {
		size_t n = sizes[i++ % nsizes];
		if (n > total - off)
			n = total - off;
		/* EVP_Cipher is what cipher.c calls for every packet */
		if (EVP_Cipher(ctx, out + off, in + off, (unsigned int)n) < 0) {
			free(out);
			return NULL;
		}
		off += n;
	}
	return out;
}

int
main(void)
{
	/* a queue is 32768 blocks, 512 KiB, so 3 MiB crosses five of them */
	const size_t total = 3 * 1024 * 1024 + 16 * 5;
	u_char key[32], iv[16];
	u_char *in, *want, *got;
	size_t i, outl;
	int olen;
	EVP_CIPHER *mt;
	EVP_CIPHER_CTX *ref, *ctx;
	size_t chunks_a[] = { 16, 32, 48, 64, 1008, 32768, 16 * 5 };
	size_t chunks_b[] = { 524288, 16, 524272, 524288 + 32 };
	size_t chunks_c[] = { 1 << 20 };

	for (i = 0; i < sizeof(key); i++)
		key[i] = (u_char)(i * 7 + 1);
	for (i = 0; i < sizeof(iv); i++)
		iv[i] = (u_char)(0xf0 + i);
	/* a counter that carries out of its low byte early on */
	iv[15] = 0xfd;

	if ((in = malloc(total)) == NULL || (want = malloc(total)) == NULL)
		return 2;
	for (i = 0; i < total; i++)
		in[i] = (u_char)((i * 2654435761u) >> 13);

	if ((ref = EVP_CIPHER_CTX_new()) == NULL ||
	    EVP_EncryptInit_ex(ref, EVP_aes_256_ctr(), NULL, key, iv) != 1 ||
	    EVP_EncryptUpdate(ref, want, &olen, in, (int)total) != 1) {
		printf("FAIL - reference AES-256-CTR\n");
		return 2;
	}
	outl = olen;
	check("the reference encrypted everything", outl == total);

	if (OSSL_PROVIDER_add_builtin(NULL, "hpnssh", OSSL_provider_init) != 1 ||
	    OSSL_PROVIDER_load(NULL, "hpnssh") == NULL) {
		printf("FAIL - could not load the hpnssh provider\n");
		return 2;
	}
	if ((mt = EVP_CIPHER_fetch(NULL, "aes_ctr_mt_256", NULL)) == NULL) {
		printf("FAIL - could not fetch aes_ctr_mt_256\n");
		return 2;
	}

	struct { const char *what; size_t *sizes; int n; } cases[] = {
		{ "small and odd-sized chunks", chunks_a, 7 },
		{ "chunks that start and end on a queue boundary", chunks_b, 4 },
		{ "one 1 MiB chunk at a time", chunks_c, 1 },
	};
	for (i = 0; i < 3; i++) {
		if ((ctx = EVP_CIPHER_CTX_new()) == NULL ||
		    EVP_CipherInit_ex(ctx, mt, NULL, key, iv, 1) != 1) {
			printf("FAIL - could not start aes_ctr_mt_256\n");
			return 2;
		}
		got = crypt_chunks(ctx, in, total, cases[i].sizes, cases[i].n);
		{
			char msg[128];
			snprintf(msg, sizeof(msg),
			    "AES-CTR-MT matches AES-CTR: %s", cases[i].what);
			check(msg, got != NULL && memcmp(got, want, total) == 0);
			if (got != NULL && memcmp(got, want, total) != 0) {
				size_t d = 0;
				while (got[d] == want[d])
					d++;
				printf("     first difference at byte %zu\n", d);
			}
		}
		free(got);
		EVP_CIPHER_CTX_free(ctx);
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
