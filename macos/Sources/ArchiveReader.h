#ifndef ANALIZ_ARCHIVE_READER_H
#define ANALIZ_ARCHIVE_READER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Extract supported regular files into an existing, empty private directory.
 * extensions is a comma-separated list without dots, for example "pdf,udf,png".
 * A failure may leave partial files. The caller must remove the private directory.
 */
int ah_extract_archive(const char *source,
                       const char *destination,
                       const char *extensions,
                       char *error,
                       size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
