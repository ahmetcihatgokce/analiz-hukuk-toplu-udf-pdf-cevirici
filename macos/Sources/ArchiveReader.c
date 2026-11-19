#include "ArchiveReader.h"

#include <archive.h>
#include <archive_entry.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define AH_MAX_ARCHIVE_BYTES (512LL * 1024 * 1024)
#define AH_MAX_ENTRY_BYTES (256LL * 1024 * 1024)
#define AH_MAX_TOTAL_BYTES (1024LL * 1024 * 1024)
#define AH_MAX_ENTRIES 4096
#define AH_MAX_PATH_BYTES 4096
#define AH_MAX_SECONDS 300

static void set_error(char *error, size_t error_size, const char *message)
{
    if (error != NULL && error_size > 0) {
        snprintf(error, error_size, "%s", message != NULL ? message : "Archive processing failed.");
    }
}

static void set_archive_error(char *error, size_t error_size, struct archive *reader)
{
    const char *detail = archive_error_string(reader);
    if (detail == NULL) {
        detail = "The archive is invalid, encrypted, or unsupported.";
    }
    if (error != NULL && error_size > 0) {
        snprintf(error, error_size, "Archive could not be read: %s", detail);
    }
}

static int directory_is_empty(int directory)
{
    int duplicate = dup(directory);
    if (duplicate < 0) {
        return 0;
    }
    DIR *entries = fdopendir(duplicate);
    if (entries == NULL) {
        close(duplicate);
        return 0;
    }
    int empty = 1;
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(entries)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            empty = 0;
            break;
        }
    }
    if (errno != 0) {
        empty = 0;
    }
    closedir(entries);
    return empty;
}

static int valid_utf8(const unsigned char *value)
{
    while (*value != 0) {
        uint32_t character;
        size_t extra;
        if (*value < 0x80) {
            value++;
            continue;
        }
        if (*value >= 0xc2 && *value <= 0xdf) {
            character = *value & 0x1f;
            extra = 1;
        } else if (*value >= 0xe0 && *value <= 0xef) {
            character = *value & 0x0f;
            extra = 2;
        } else if (*value >= 0xf0 && *value <= 0xf4) {
            character = *value & 0x07;
            extra = 3;
        } else {
            return 0;
        }
        value++;
        for (size_t index = 0; index < extra; index++) {
            if ((*value & 0xc0) != 0x80) {
                return 0;
            }
            character = (character << 6) | (*value & 0x3f);
            value++;
        }
        if ((extra == 1 && character < 0x80) ||
            (extra == 2 && character < 0x800) ||
            (extra == 3 && character < 0x10000) ||
            character > 0x10ffff ||
            (character >= 0xd800 && character <= 0xdfff)) {
            return 0;
        }
    }
    return 1;
}

static int copy_safe_relative_name(const char *name, char *relative, size_t capacity)
{
    if (name == NULL || name[0] == '\0' || name[0] == '/' || strchr(name, '\\') != NULL) {
        return 0;
    }
    while (name[0] == '.' && name[1] == '/') {
        name += 2;
    }
    size_t length = strlen(name);
    while (length > 0 && name[length - 1] == '/') {
        length--;
    }
    if (length == 0 || length >= capacity) {
        return 0;
    }
    memcpy(relative, name, length);
    relative[length] = '\0';
    if (!valid_utf8((const unsigned char *)relative)) {
        return 0;
    }
    size_t component_start = 0;
    size_t component_count = 0;
    for (size_t index = 0; index <= length; index++) {
        unsigned char byte = (unsigned char)relative[index];
        if (byte != 0 && (byte < 0x20 || byte == 0x7f || byte == ':')) {
            return 0;
        }
        if (byte == '/' || byte == 0) {
            size_t component_length = index - component_start;
            if (++component_count > 32 || component_length == 0 || component_length > NAME_MAX ||
                (component_length == 1 && relative[component_start] == '.') ||
                (component_length == 2 && relative[component_start] == '.' && relative[component_start + 1] == '.')) {
                return 0;
            }
            component_start = index + 1;
        }
    }
    return 1;
}

static int wanted_extension(const char *path, const char *extensions)
{
    const char *leaf = strrchr(path, '/');
    leaf = leaf == NULL ? path : leaf + 1;
    const char *dot = strrchr(leaf, '.');
    if (dot == NULL || dot[1] == '\0') {
        return 0;
    }
    const char *extension = dot + 1;
    size_t length = strlen(extension);
    const char *candidate = extensions;
    while (*candidate != '\0') {
        const char *separator = strchr(candidate, ',');
        size_t candidate_length = separator == NULL ? strlen(candidate) : (size_t)(separator - candidate);
        if (candidate_length == length && strncasecmp(candidate, extension, length) == 0) {
            return 1;
        }
        if (separator == NULL) {
            break;
        }
        candidate = separator + 1;
    }
    return 0;
}

static int open_output(int root, const char *relative)
{
    char path[AH_MAX_PATH_BYTES];
    snprintf(path, sizeof(path), "%s", relative);
    int parent = dup(root);
    if (parent < 0) {
        return -1;
    }
    char *component = path;
    char *separator;
    while ((separator = strchr(component, '/')) != NULL) {
        *separator = '\0';
        if (mkdirat(parent, component, 0700) != 0 && errno != EEXIST) {
            close(parent);
            return -1;
        }
        int child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(parent);
        if (child < 0) {
            return -1;
        }
        parent = child;
        component = separator + 1;
    }
    int result = openat(parent, component, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(parent);
    return result;
}

static int write_all(int descriptor, const unsigned char *buffer, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(descriptor, buffer + offset, length - offset);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return 0;
        }
        offset += (size_t)written;
    }
    return 1;
}

static int allowed_format(struct archive *reader, int zip_only)
{
    int format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK;
    if (format == ARCHIVE_FORMAT_ZIP) {
        return 1;
    }
    if (zip_only) {
        return 0;
    }
    if (format == ARCHIVE_FORMAT_RAR) {
        return 1;
    }
#ifdef ARCHIVE_FORMAT_RAR_V5
    if (format == ARCHIVE_FORMAT_RAR_V5) {
        return 1;
    }
#endif
    return 0;
}

static int deadline_exceeded(const struct timespec *started)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 1;
    }
    return now.tv_sec - started->tv_sec > AH_MAX_SECONDS ||
        (now.tv_sec - started->tv_sec == AH_MAX_SECONDS && now.tv_nsec >= started->tv_nsec);
}

static int consume_entry(struct archive *reader, int output, int64_t *total_bytes,
                         const struct timespec *started, char *error, size_t error_size)
{
    int64_t file_bytes = 0;
    unsigned char buffer[64 * 1024];
    for (;;) {
        if (deadline_exceeded(started)) {
            set_error(error, error_size, "Archive processing exceeded the 300 second limit.");
            return 1;
        }
        la_ssize_t amount = archive_read_data(reader, buffer, sizeof(buffer));
        if (amount < 0) {
            set_archive_error(error, error_size, reader);
            return 1;
        }
        if (amount == 0) {
            return 0;
        }
        if ((int64_t)amount > AH_MAX_ENTRY_BYTES - file_bytes ||
            (int64_t)amount > AH_MAX_TOTAL_BYTES - *total_bytes) {
            set_error(error, error_size, "An archive entry exceeds 256 MB or total expanded data exceeds 1 GB.");
            return 1;
        }
        if (output >= 0 && !write_all(output, buffer, (size_t)amount)) {
            set_error(error, error_size, "The extracted file could not be written.");
            return 1;
        }
        file_bytes += (int64_t)amount;
        *total_bytes += (int64_t)amount;
    }
}

int ah_extract_archive(const char *source,
                       const char *destination,
                       const char *extensions,
                       char *error,
                       size_t error_size)
{
    set_error(error, error_size, "");
    if (source == NULL || destination == NULL || extensions == NULL || extensions[0] == '\0') {
        set_error(error, error_size, "Archive source, destination, and supported extensions are required.");
        return 1;
    }
    int source_fd = -1;
    int root_fd = -1;
    int result = 1;
    struct archive *reader = NULL;
    char **seen = NULL;
    size_t selected_count = 0;
    struct timespec started;
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
        set_error(error, error_size, "The archive processing timer could not be initialized.");
        goto cleanup;
    }
    source_fd = open(source, O_RDONLY | O_CLOEXEC);
    struct stat source_info;
    if (source_fd < 0 || fstat(source_fd, &source_info) != 0 || !S_ISREG(source_info.st_mode) ||
        source_info.st_size < 0 || source_info.st_size > AH_MAX_ARCHIVE_BYTES) {
        set_error(error, error_size, "The archive is unreadable or exceeds the 512 MB size limit.");
        goto cleanup;
    }
    root_fd = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root_fd < 0 || !directory_is_empty(root_fd)) {
        set_error(error, error_size, "Archive extraction requires an empty, private destination directory.");
        goto cleanup;
    }
    reader = archive_read_new();
    seen = calloc(AH_MAX_ENTRIES, sizeof(char *));
    if (reader == NULL || seen == NULL) {
        set_error(error, error_size, "Not enough memory to read the archive.");
        goto cleanup;
    }
    archive_read_support_filter_none(reader);
    archive_read_support_format_zip(reader);
    archive_read_support_format_rar(reader);
#ifdef ARCHIVE_FORMAT_RAR_V5
    archive_read_support_format_rar5(reader);
#endif
    if (archive_read_open_fd(reader, source_fd, 64 * 1024) != ARCHIVE_OK) {
        set_archive_error(error, error_size, reader);
        goto cleanup;
    }
    const char *source_extension = strrchr(source, '.');
    int zip_only = source_extension != NULL && strcasecmp(source_extension, ".eyp") == 0;
    size_t entry_count = 0;
    int64_t total_bytes = 0;
    int64_t declared_total_bytes = 0;
    struct archive_entry *entry;
    int next;
    while ((next = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        if (deadline_exceeded(&started)) {
            set_error(error, error_size, "Archive processing exceeded the 300 second limit.");
            goto cleanup;
        }
        if (++entry_count > AH_MAX_ENTRIES) {
            set_error(error, error_size, "The archive contains more than 4096 entries.");
            goto cleanup;
        }
        if (!allowed_format(reader, zip_only)) {
            set_error(error, error_size, "Only ZIP, RAR, and unencrypted ZIP-based EYP archives are supported.");
            goto cleanup;
        }
#if ARCHIVE_VERSION_NUMBER >= 3002000
        if (archive_entry_is_encrypted(entry) == 1) {
            set_error(error, error_size, "Encrypted archives are not supported.");
            goto cleanup;
        }
#endif
        int64_t declared_size = archive_entry_size(entry);
        if (declared_size > AH_MAX_ENTRY_BYTES ||
            declared_size > AH_MAX_TOTAL_BYTES - declared_total_bytes) {
            set_error(error, error_size, "An archive entry exceeds 256 MB or total expanded data exceeds 1 GB.");
            goto cleanup;
        }
        if (declared_size > 0) {
            declared_total_bytes += declared_size;
        }
        const char *entry_name = archive_entry_pathname_utf8(entry);
        if (entry_name == NULL) {
            entry_name = archive_entry_pathname(entry);
        }
        int is_directory = archive_entry_filetype(entry) == AE_IFDIR;
        int is_root_directory = is_directory && entry_name != NULL &&
            (strcmp(entry_name, ".") == 0 || strcmp(entry_name, "./") == 0);
        char relative[AH_MAX_PATH_BYTES];
        if (!is_root_directory && !copy_safe_relative_name(entry_name, relative, sizeof(relative))) {
            set_error(error, error_size, "The archive contains an unsafe or invalid file path.");
            goto cleanup;
        }
        if (is_directory) {
            /* RAR readers reject archive_read_data for directory headers. A
             * directory carries no expanded payload and creates no output here.
             */
            if (declared_size > 0) {
                set_error(error, error_size, "An archive directory unexpectedly declares file data.");
                goto cleanup;
            }
            if (archive_read_data_skip(reader) < ARCHIVE_WARN) {
                set_archive_error(error, error_size, reader);
                goto cleanup;
            }
            continue;
        }
        if (archive_entry_filetype(entry) != AE_IFREG || archive_entry_hardlink(entry) != NULL ||
            archive_entry_symlink(entry) != NULL || !wanted_extension(relative, extensions)) {
            if (consume_entry(reader, -1, &total_bytes, &started, error, error_size) != 0) {
                goto cleanup;
            }
            continue;
        }
        for (size_t index = 0; index < selected_count; index++) {
            if (strcasecmp(seen[index], relative) == 0) {
                set_error(error, error_size, "The archive contains duplicate destination filenames.");
                goto cleanup;
            }
        }
        seen[selected_count] = strdup(relative);
        if (seen[selected_count] == NULL) {
            set_error(error, error_size, "Not enough memory to read the archive.");
            goto cleanup;
        }
        selected_count++;
        int output = open_output(root_fd, relative);
        if (output < 0) {
            set_error(error, error_size, "An archive destination could not be created safely or already exists.");
            goto cleanup;
        }
        if (consume_entry(reader, output, &total_bytes, &started, error, error_size) != 0) {
            close(output);
            goto cleanup;
        }
        if (close(output) != 0) {
            set_error(error, error_size, "The extracted file could not be completed.");
            goto cleanup;
        }
    }
    if (deadline_exceeded(&started)) {
        set_error(error, error_size, "Archive processing exceeded the 300 second limit.");
        goto cleanup;
    }
    if (next != ARCHIVE_EOF || !allowed_format(reader, zip_only)) {
        set_archive_error(error, error_size, reader);
        goto cleanup;
    }
    result = 0;

cleanup:
    if (reader != NULL) {
        archive_read_free(reader);
    }
    if (root_fd >= 0) {
        close(root_fd);
    }
    if (source_fd >= 0) {
        close(source_fd);
    }
    for (size_t index = 0; index < selected_count; index++) {
        free(seen[index]);
    }
    free(seen);
    return result;
}
