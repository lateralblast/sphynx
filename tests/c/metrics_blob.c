/*
 * Regression test for metrics_blob_valid() in metrics.c.
 *
 * The client reads the server's metrics reply with the binn functions, which
 * are given no size. A reply that was cut short, or that lies about the size
 * of a key or a value, used to be read past the end of the packet. The client
 * now checks the blob first, and every blob that check accepts must be safe to
 * read with those functions.
 *
 * Built and run by tests/run-tests.sh against the build tree; it is also
 * meant to be run under AddressSanitizer.
 */
#include "includes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "metrics.h"

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

/* a copy of the blob in a buffer of exactly len bytes, so ASan sees a read past it */
static unsigned char *
exact(const void *p, size_t len)
{
	unsigned char *c = malloc(len ? len : 1);

	if (c == NULL)
		abort();
	if (len)
		memcpy(c, p, len);
	return c;
}

int
main(void)
{
	binn *obj;
	unsigned char *blob, *c;
	char out[1024];
	size_t len, i, n;
	int ok_truncated = 0, ok_longer = 0, accepted = 0;
	unsigned int seed = 12345;

	obj = binn_object();
	binn_object_set_uint8(obj, "tcpi_state", 1);
	binn_object_set_uint8(obj, "tcpi_ca_state", 0);
	binn_object_set_uint32(obj, "tcpi_rto", 204000);
	binn_object_set_uint32(obj, "kernel_version", 6);
	binn_object_set_str(obj, "name", "a string value");
	len = (size_t)binn_size(obj);
	blob = exact(binn_ptr(obj), len);
	binn_free(obj);

	expect("a whole object is valid", metrics_blob_valid(blob, len), 1);
	expect("NULL is not valid", metrics_blob_valid(NULL, 10), 0);
	expect("length 0 is not valid", metrics_blob_valid(blob, 0), 0);

	/* every shorter length, read from a buffer that ends there */
	for (n = 0; n < len; n++) {
		c = exact(blob, n);
		if (metrics_blob_valid(c, n))
			ok_truncated++;
		free(c);
	}
	expect("no truncated object is valid", ok_truncated, 0);

	/* the same bytes with extra after them: the size no longer matches */
	c = malloc(len + 8);
	if (c == NULL)
		abort();
	memcpy(c, blob, len);
	memset(c + len, 0, 8);
	for (n = 1; n <= 8; n++)
		if (metrics_blob_valid(c, len + n))
			ok_longer++;
	free(c);
	expect("an object with trailing bytes is not valid", ok_longer, 0);

	/* corrupt one to three bytes, then read every value from what is accepted */
	for (i = 0; i < 40000; i++) {
		c = exact(blob, len);
		for (n = 1 + rand_r(&seed) % 3; n > 0; n--)
			c[rand_r(&seed) % len] = (unsigned char)rand_r(&seed);
		if (metrics_blob_valid(c, len)) {
			accepted++;
			(void)binn_object_int32(c, "kernel_version");
			(void)binn_object_uint8(c, "tcpi_state");
			(void)binn_object_uint32(c, "tcpi_rto");
			metrics_read_binn_object(c, out);
		}
		free(c);
	}
	printf("ok   - %d of 40000 corrupted objects were accepted and read safely\n", accepted);

	free(blob);
	if (failures) {
		printf("%d failure(s)\n", failures);
		return 1;
	}
	return 0;
}
