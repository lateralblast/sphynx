/*
 * Regression test for patch_list() in kex.c.
 *
 * patch_list() makes sure that a cipher list naming the multithreaded
 * ChaCha20-Poly1305 cipher also names the serial one, directly after it.
 * It used to take the insertion point from the wrong string, which is only
 * right when the multithreaded cipher is the first entry.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sshkey.h"
#include "ssherr.h"
#include "ssh-pkcs11.h"
#include "ssh-sk.h"

extern char *patch_list(char *);

/*
 * kex.o refers to key signing code that lives in other programs' objects.
 * patch_list() never reaches it, so these only have to satisfy the linker.
 */
int
pkcs11_sign(struct sshkey *k, u_char **sp, size_t *lp, const u_char *d,
    size_t dl, const char *a, const char *p, const char *pin, u_int f)
{
	return SSH_ERR_FEATURE_UNSUPPORTED;
}

void
pkcs11_key_free(struct sshkey *k)
{
}

int
sshsk_sign(const char *provider_path, struct sshkey *key, u_char **sigp,
    size_t *lenp, const u_char *data, size_t datalen, u_int compat,
    const char *pin)
{
	return SSH_ERR_FEATURE_UNSUPPORTED;
}

static int failures;

static void
check(const char *in, const char *want)
{
	char *copy = strdup(in), *got = patch_list(copy);

	if (got != NULL && strcmp(got, want) == 0) {
		printf("ok   - %s\n", in);
	} else {
		printf("FAIL - %s\n       got:  %s\n       want: %s\n", in,
		    got ? got : "(null)", want);
		failures++;
	}
	free(got);
	free(copy);
}

int
main(void)
{
	const char *mt = "chacha20-poly1305-mt@hpnssh.org";
	const char *cc = "chacha20-poly1305@openssh.com";
	char in[256], want[256];

	/* first entry: the case that always worked */
	snprintf(in, sizeof in, "%s,aes128-ctr", mt);
	snprintf(want, sizeof want, "%s,%s,aes128-ctr", mt, cc);
	check(in, want);

	/* last entry */
	snprintf(in, sizeof in, "aes128-ctr,%s", mt);
	snprintf(want, sizeof want, "aes128-ctr,%s,%s", mt, cc);
	check(in, want);

	/* middle entry */
	snprintf(in, sizeof in, "aes128-ctr,%s,aes256-ctr", mt);
	snprintf(want, sizeof want, "aes128-ctr,%s,%s,aes256-ctr", mt, cc);
	check(in, want);

	/* only entry */
	snprintf(want, sizeof want, "%s,%s", mt, cc);
	check(mt, want);

	/* serial cipher already present: unchanged */
	snprintf(in, sizeof in, "aes128-ctr,%s,%s", mt, cc);
	check(in, in);

	/* no MT cipher: unchanged */
	check("aes128-ctr,aes256-ctr", "aes128-ctr,aes256-ctr");

	/* a name that only contains the MT name is not the MT cipher */
	snprintf(in, sizeof in, "x%s,aes128-ctr", mt);
	check(in, in);

	printf("%d failure(s)\n", failures);
	return failures != 0;
}
