/* The one libc header libzstd includes (lib/common/zstd_deps.h), declared by
 * hand so the library compiles with no libc beside it (ADR 295). Zig's
 * compiler_rt defines all four for a program that links no libc; with a libc
 * linked, the libc's definitions are the ones taken. */
#ifndef NILO_ZSTD_STRING_H
#define NILO_ZSTD_STRING_H
#include <stddef.h>
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
#endif
