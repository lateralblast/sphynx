/*
 * Regression test for forking while the multithreaded ChaCha20-Poly1305 cipher
 * has keystream threads outstanding (cipher-chachapoly-libcrypto-mt.c).
 *
 * The cipher pregenerates the keystream for the next batch of packets in a
 * manager thread and joins it when that batch is needed. ssh forks in the
 * middle of a session for "~&" and, with a control master, ControlPersist. The
 * child has only the forking thread, so a thread the parent started does not
 * exist there: joining it is undefined, and the keystream it was making is
 * never finished. The child must regenerate what it needs and carry on with the
 * same bytes as the serial cipher gives.
 *
 * The test fills a batch, forks with the next batch outstanding, and has parent
 * and child encrypt many more packets, comparing each with the serial cipher. A
 * child that hangs is killed by an alarm and counts as a failure.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#ifdef WITH_OPENSSL

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ssherr.h"
#include "cipher-chachapoly.h"
#include "cipher-chachapoly-libcrypto-mt.h"

#define PLEN 100
#define AAD 4
#define TAG 16

/* encrypt packet seqnr with both ciphers and compare; returns the number of mismatches */
static int
compare(struct chachapoly_ctx_mt *mt, struct chachapoly_ctx *serial, u_int seqnr)
{
	u_char in[AAD + PLEN + TAG], a[sizeof(in)], b[sizeof(in)];
	int ra, rb;

	memset(in, (int)(seqnr & 0xff), sizeof(in));
	ra = chachapoly_crypt_mt(mt, seqnr, a, in, PLEN, AAD, TAG, 1);
	rb = chachapoly_crypt(serial, seqnr, b, in, PLEN, AAD, TAG, 1);
	if (ra != 0 || rb != 0 || memcmp(a, b, sizeof(a)) != 0) {
		printf("  packet %u: mt returned %d, serial %d, bytes %s\n", seqnr,
		    ra, rb, memcmp(a, b, sizeof(a)) == 0 ? "match" : "differ");
		return 1;
	}
	return 0;
}

int
main(void)
{
	u_char key[64];
	struct chachapoly_ctx_mt *mt;
	struct chachapoly_ctx *serial;
	u_int seqnr, bad = 0;
	pid_t pid;
	int status;

	for (seqnr = 0; seqnr < sizeof(key); seqnr++)
		key[seqnr] = (u_char)(seqnr * 5 + 9);
	if ((mt = chachapoly_new_mt(0, key, sizeof(key))) == NULL ||
	    (serial = chachapoly_new(key, sizeof(key))) == NULL) {
		printf("FAIL - could not start the ciphers\n");
		return 2;
	}
	/* past the first batch, so a manager thread has been started for the next */
	for (seqnr = 0; seqnr < 70; seqnr++)
		bad += compare(mt, serial, seqnr);
	if (bad) {
		printf("FAIL - the ciphers differ before the fork\n");
		return 1;
	}

	fflush(stdout);
	if ((pid = fork()) == -1) {
		printf("FAIL - fork\n");
		return 2;
	}
	if (pid == 0) {
		alarm(30);
		for (seqnr = 70; seqnr < 700; seqnr++)
			bad += compare(mt, serial, seqnr);
		fflush(stdout);
		_exit(bad ? 1 : 0);
	}
	for (seqnr = 70; seqnr < 700; seqnr++)
		bad += compare(mt, serial, seqnr);
	if (waitpid(pid, &status, 0) == -1)
		status = 1;

	if (bad == 0)
		printf("ok   - the parent carries on after the fork\n");
	else
		printf("FAIL - the parent's packets differ from the serial cipher\n");
	if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
		printf("ok   - the child carries on after the fork with the serial cipher's bytes\n");
	else {
		printf("FAIL - the child %s\n", WIFSIGNALED(status) ?
		    "was killed (a crash or the 30 second alarm)" : "got different bytes");
		bad++;
	}
	return bad != 0;
}

#else
int
main(void)
{
	return 0;
}
#endif
