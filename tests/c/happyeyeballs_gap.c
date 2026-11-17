/*
 * Regression test for happyeyeballs.c.
 *
 * happy_eyeballs_process() read fd_ai[sock] for every descriptor below the
 * highest one in use before it asked whether the descriptor was a socket it had
 * opened. fd_ai holds an entry only for those sockets, so when another
 * descriptor sat between two of them the read went through a pointer that was
 * never set (a null pointer in a build that zeroes automatic variables).
 *
 * Two loopback addresses are tried, both with a full accept queue so that the
 * connections stay pending. A descriptor is left open between the two sockets.
 * After half a second the first queue is drained, so its connect completes while
 * the second is still pending, and the scan passes over the gap on the way down.
 * The test runs in a child process so that a crash is a failure and not the end
 * of the run. Linux only: it relies on how Linux holds back a full accept queue.
 *
 * Built and run by tests/run-tests.sh against the build tree.
 */
#include "includes.h"

#ifdef __linux__

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#include "happyeyeballs.h"
#include "sshconnect.h"
#include "ssh.h"
#include "misc.h"
#include "log.h"
#include "readconf.h"

/* what happyeyeballs.c needs from ssh.c and sshconnect.c */
Options options;

int
ssh_create_socket(struct addrinfo *ai)
{
	return socket(ai->ai_family, SOCK_STREAM, 0);
}

/* a listening socket whose accept queue is full, so that a new connect stays pending */
static int
full_listener(struct sockaddr_in *sin)
{
	int l, i, fillers[8];
	socklen_t len = sizeof(*sin);

	memset(sin, 0, sizeof(*sin));
	sin->sin_family = AF_INET;
	sin->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if ((l = socket(AF_INET, SOCK_STREAM, 0)) < 0 ||
	    bind(l, (struct sockaddr *)sin, sizeof(*sin)) < 0 ||
	    listen(l, 0) < 0 ||
	    getsockname(l, (struct sockaddr *)sin, &len) < 0)
		return -1;
	for (i = 0; i < 8; i++) {
		fillers[i] = socket(AF_INET, SOCK_STREAM, 0);
		fcntl(fillers[i], F_SETFL, O_NONBLOCK);
		connect(fillers[i], (struct sockaddr *)sin, sizeof(*sin));
	}
	usleep(100000);
	return l;
}

static int drain_fd;

static void *
drain(void *arg)
{
	int i;

	(void)arg;
	usleep(500000);
	for (i = 0; i < 40; i++) {	/* keep emptying it, so the retried connect gets in */
		while (accept(drain_fd, NULL, NULL) >= 0)
			;
		usleep(100000);
	}
	return NULL;
}

static int
child(void)
{
	struct sockaddr_in a, b;
	struct sockaddr_storage hostaddr;
	struct addrinfo ai_a, ai_b;
	int la, lb, d[4], i, timeout_ms = 15000, sock;
	pthread_t t;

	alarm(30);
	if ((la = full_listener(&a)) < 0 || (lb = full_listener(&b)) < 0)
		return 2;

	/* four consecutive descriptors; keep the second as the gap, free the other three */
	for (i = 0; i < 4; i++)
		d[i] = open("/dev/null", O_RDONLY);
	close(d[0]);
	close(d[2]);
	close(d[3]);

	memset(&ai_a, 0, sizeof(ai_a));
	memset(&ai_b, 0, sizeof(ai_b));
	ai_a.ai_family = ai_b.ai_family = AF_INET;
	ai_a.ai_socktype = ai_b.ai_socktype = SOCK_STREAM;
	ai_a.ai_addr = (struct sockaddr *)&a;
	ai_b.ai_addr = (struct sockaddr *)&b;
	ai_a.ai_addrlen = ai_b.ai_addrlen = sizeof(a);
	ai_a.ai_next = &ai_b;

	options.happy_delay = 100;
	drain_fd = la;
	pthread_create(&t, NULL, drain, NULL);

	sock = happy_eyeballs("test", &ai_a, &hostaddr, &timeout_ms);
	if (sock < 0)
		return 3;
	if (memcmp(&hostaddr, &a, sizeof(a)) != 0)
		return 4;	/* connected to the wrong one */
	return 0;
}

int
main(void)
{
	pid_t pid;
	int status;

	fflush(stdout);
	if ((pid = fork()) == 0)
		_exit(child());
	if (pid < 0 || waitpid(pid, &status, 0) < 0) {
		printf("FAIL - could not run the test\n");
		return 2;
	}
	if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
		printf("ok   - happy_eyeballs passes over a descriptor that is not its own\n");
		return 0;
	}
	if (WIFSIGNALED(status))
		printf("FAIL - happy_eyeballs was killed by signal %d\n", WTERMSIG(status));
	else
		printf("FAIL - the test child exited with %d\n", WEXITSTATUS(status));
	return 1;
}

#else
#include <stdio.h>
int
main(void)
{
	printf("skip - Linux only\n");
	return 0;
}
#endif
