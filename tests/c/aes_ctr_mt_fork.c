/*
 * Regression test for freeing the multithreaded AES-CTR cipher in a forked child.
 *
 * sshd forks a child for each session, and the child frees the connection's
 * cipher before it execs the command. fork() keeps only the calling thread, so
 * the pregeneration threads of the multithreaded cipher are not in the child.
 * Freeing the cipher cancelled and joined them anyway, and waited for ever, so
 * the second session on a connection that had switched to the multithreaded
 * cipher never ran its command. The child must be able to free the cipher, and
 * the parent must still be able to use its own.
 *
 * A child that does not finish is killed by an alarm and counts as a failure.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#ifdef WITH_OPENSSL3

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

#include "cipher.h"
#include "ssherr.h"

int
main(void)
{
	u_char key[32], iv[16], in[4096], a[4096], b[4096];
	const struct sshcipher *c = cipher_by_name("aes256-ctr");
	struct sshcipher_ctx *serial = NULL, *mt = NULL, *ref = NULL;
	pid_t pid;
	int status, ok = 1, i;

	for (i = 0; i < (int)sizeof(key); i++)
		key[i] = (u_char)(i * 3 + 1);
	memset(iv, 0x33, sizeof(iv));
	memset(in, 0x5a, sizeof(in));

	/* a serial start first, as ssh always has one, so the library is initialised */
	if (cipher_init(&serial, c, key, cipher_keylen(c), iv, cipher_ivlen(c), 0, CIPHER_ENCRYPT, 0) != 0 ||
	    cipher_init(&ref, c, key, cipher_keylen(c), iv, cipher_ivlen(c), 0, CIPHER_ENCRYPT, 0) != 0 ||
	    cipher_init(&mt, c, key, cipher_keylen(c), iv, cipher_ivlen(c), 0, CIPHER_ENCRYPT, 1) != 0) {
		printf("FAIL - could not start the ciphers\n");
		return 2;
	}
	cipher_free(serial);
	/* use it a little, so that the threads have run */
	if (cipher_crypt(mt, 0, a, in, sizeof(in), 0, 0) != 0 ||
	    cipher_crypt(ref, 0, b, in, sizeof(in), 0, 0) != 0 || memcmp(a, b, sizeof(a)) != 0)
		ok = 0;

	fflush(stdout);
	if ((pid = fork()) == -1) {
		printf("FAIL - fork\n");
		return 2;
	}
	if (pid == 0) {
		alarm(20);
		cipher_free(mt);	/* the call that used to wait for ever */
		_exit(0);
	}
	if (waitpid(pid, &status, 0) == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		printf("FAIL - the forked child could not free the cipher (%s)\n",
		    WIFSIGNALED(status) ? "killed by the alarm: it hung" : "failed");
		ok = 0;
	} else
		printf("ok   - a forked child frees the multithreaded cipher\n");

	/* the parent's cipher still works, and still matches the serial one */
	if (cipher_crypt(mt, 0, a, in, sizeof(in), 0, 0) != 0 ||
	    cipher_crypt(ref, 0, b, in, sizeof(in), 0, 0) != 0 || memcmp(a, b, sizeof(a)) != 0) {
		printf("FAIL - the parent's cipher changed after the fork\n");
		ok = 0;
	} else
		printf("ok   - the parent's cipher still gives the serial cipher's bytes\n");
	cipher_free(mt);
	cipher_free(ref);
	return ok ? 0 : 1;
}

#else
int
main(void)
{
	return 0;
}
#endif
