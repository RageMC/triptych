#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _POSIX_C_SOURCE 200809L
#endif

#include "macpkg_internal.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

void mp_set_err(char *errbuf, size_t errbuf_sz, const char *fmt, ...) {
    if (!errbuf || errbuf_sz == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(errbuf, errbuf_sz, fmt, ap);
    va_end(ap);
}

const char *macpkg_strerror(macpkg_status_t st) {
    switch (st) {
        case MACPKG_OK: return "ok";
        case MACPKG_ERR_IO: return "I/O error";
        case MACPKG_ERR_FORMAT: return "invalid or unrecognized format";
        case MACPKG_ERR_UNSUPPORTED: return "unsupported feature or compression";
        case MACPKG_ERR_NOMEM: return "out of memory";
        case MACPKG_ERR_CORRUPT: return "corrupt archive or filesystem data";
        case MACPKG_ERR_NOT_FOUND: return "no .app bundle found";
        case MACPKG_ERR_PATH: return "invalid or unsafe path";
        default: return "unknown error";
    }
}

/* ---- File-backed stream ---- */
typedef struct {
    int fd;
} mp_file_ctx_t;

static int mp_file_read_at(void *ctx, uint64_t offset, void *buf, size_t len) {
    mp_file_ctx_t *fc = (mp_file_ctx_t *)ctx;
    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fc->fd, dst + done, len - done, (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static void mp_file_close(void *ctx) {
    mp_file_ctx_t *fc = (mp_file_ctx_t *)ctx;
    if (fc) {
        if (fc->fd >= 0) close(fc->fd);
        free(fc);
    }
}

macpkg_status_t macpkg_stream_open_file(const char *path, macpkg_stream_t *out_stream,
                                        char *errbuf, size_t errbuf_sz) {
    if (!path || !out_stream) {
        mp_set_err(errbuf, errbuf_sz, "null argument");
        return MACPKG_ERR_IO;
    }
    memset(out_stream, 0, sizeof(*out_stream));
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        mp_set_err(errbuf, errbuf_sz, "cannot open '%s': %s", path, strerror(errno));
        return MACPKG_ERR_IO;
    }
    struct stat st;
    if (fstat(fd, &st) < 0) {
        mp_set_err(errbuf, errbuf_sz, "fstat '%s': %s", path, strerror(errno));
        close(fd);
        return MACPKG_ERR_IO;
    }
    mp_file_ctx_t *fc = (mp_file_ctx_t *)malloc(sizeof(*fc));
    if (!fc) {
        close(fd);
        mp_set_err(errbuf, errbuf_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    fc->fd = fd;
    out_stream->ctx = fc;
    out_stream->size = (uint64_t)st.st_size;
    out_stream->read_at = mp_file_read_at;
    out_stream->close = mp_file_close;
    return MACPKG_OK;
}

void macpkg_stream_close(macpkg_stream_t *stream) {
    if (stream && stream->close) {
        stream->close(stream->ctx);
    }
    if (stream) memset(stream, 0, sizeof(*stream));
}

macpkg_status_t mp_stream_read_exact(macpkg_stream_t *s, uint64_t off, void *buf, size_t len,
                                     char *err, size_t err_sz) {
    if (len == 0) return MACPKG_OK;
    if (!s || !s->read_at) {
        mp_set_err(err, err_sz, "invalid stream");
        return MACPKG_ERR_IO;
    }
    if (off > s->size || len > s->size - off) {
        mp_set_err(err, err_sz, "read out of bounds (off=%llu len=%zu size=%llu)",
                   (unsigned long long)off, len, (unsigned long long)s->size);
        return MACPKG_ERR_CORRUPT;
    }
    if (s->read_at(s->ctx, off, buf, len) != 0) {
        mp_set_err(err, err_sz, "stream read failed at offset %llu", (unsigned long long)off);
        return MACPKG_ERR_IO;
    }
    return MACPKG_OK;
}

/* ---- Slice stream ---- */
typedef struct {
    macpkg_stream_t *parent;
    uint64_t base;
} mp_slice_ctx_t;

static int mp_slice_read_at(void *ctx, uint64_t offset, void *buf, size_t len) {
    mp_slice_ctx_t *sc = (mp_slice_ctx_t *)ctx;
    return sc->parent->read_at(sc->parent->ctx, sc->base + offset, buf, len);
}

static void mp_slice_close(void *ctx) {
    free(ctx);
}

macpkg_status_t mp_stream_slice(macpkg_stream_t *parent, uint64_t off, uint64_t len,
                                macpkg_stream_t *out) {
    if (!parent || !out || off > parent->size || len > parent->size - off) {
        return MACPKG_ERR_CORRUPT;
    }
    mp_slice_ctx_t *sc = (mp_slice_ctx_t *)malloc(sizeof(*sc));
    if (!sc) return MACPKG_ERR_NOMEM;
    sc->parent = parent;
    sc->base = off;
    out->ctx = sc;
    out->size = len;
    out->read_at = mp_slice_read_at;
    out->close = mp_slice_close;
    return MACPKG_OK;
}

/* ---- Memory stream ---- */
typedef struct {
    const uint8_t *data;
    size_t len;
    int owned;
} mp_mem_ctx_t;

static int mp_mem_read_at(void *ctx, uint64_t offset, void *buf, size_t len) {
    mp_mem_ctx_t *mc = (mp_mem_ctx_t *)ctx;
    if (offset > mc->len || len > mc->len - offset) return -1;
    memcpy(buf, mc->data + offset, len);
    return 0;
}

static void mp_mem_close(void *ctx) {
    mp_mem_ctx_t *mc = (mp_mem_ctx_t *)ctx;
    if (mc) {
        if (mc->owned) free((void *)mc->data);
        free(mc);
    }
}

macpkg_status_t mp_stream_from_memory(const uint8_t *data, size_t len, int take_ownership,
                                      macpkg_stream_t *out) {
    mp_mem_ctx_t *mc = (mp_mem_ctx_t *)malloc(sizeof(*mc));
    if (!mc) return MACPKG_ERR_NOMEM;
    mc->data = data;
    mc->len = len;
    mc->owned = take_ownership;
    out->ctx = mc;
    out->size = len;
    out->read_at = mp_mem_read_at;
    out->close = mp_mem_close;
    return MACPKG_OK;
}

/* ---- Path helpers ---- */
static char *mp_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

int mp_sanitize_relpath(const char *raw_path, char *out, size_t out_cap) {
    if (!raw_path || !out || out_cap < 2) return -1;
    const char *p = raw_path;
    while (*p == '/') p++;
    if (p[0] == '.' && p[1] == '/') p += 2;
    while (*p == '/') p++;

    size_t len = 0;
    const char *seg = p;
    while (*seg) {
        const char *slash = strchr(seg, '/');
        size_t slen = slash ? (size_t)(slash - seg) : strlen(seg);
        if (slen == 0 || (slen == 1 && seg[0] == '.')) {
            /* skip */
        } else if (slen == 2 && seg[0] == '.' && seg[1] == '.') {
            return -1; /* reject path traversal */
        } else {
            if (len > 0) {
                if (len + 1 >= out_cap) return -1;
                out[len++] = '/';
            }
            if (len + slen >= out_cap) return -1;
            memcpy(out + len, seg, slen);
            len += slen;
        }
        if (!slash) break;
        seg = slash + 1;
    }
    out[len] = '\0';
    return (len > 0) ? 0 : -1;
}

static int ends_with_dot_app(const char *seg, size_t len) {
    if (len <= 4) return 0;
    const char *ext = seg + len - 4;
    return (ext[0] == '.' &&
            (ext[1] == 'a' || ext[1] == 'A') &&
            (ext[2] == 'p' || ext[2] == 'P') &&
            (ext[3] == 'p' || ext[3] == 'P'));
}

int mp_filter_app_relpath(const char *raw_path, const macpkg_options_t *opts,
                          char *out_rel, size_t out_cap) {
    char clean[4096];
    if (mp_sanitize_relpath(raw_path, clean, sizeof(clean)) != 0) return 0;

    /* Ignore __MACOSX resource-fork shadow tree */
    if (strncmp(clean, "__MACOSX", 8) == 0 && (clean[8] == '\0' || clean[8] == '/')) {
        return 0;
    }

    if (opts && opts->extract_all_files) {
        if (strlen(clean) >= out_cap) return 0;
        strcpy(out_rel, clean);
        return 1;
    }

    /* Find first component ending in .app */
    const char *p = clean;
    while (*p) {
        const char *slash = strchr(p, '/');
        size_t slen = slash ? (size_t)(slash - p) : strlen(p);
        if (ends_with_dot_app(p, slen)) {
            if (opts && opts->app_name && opts->app_name[0]) {
                if (strlen(opts->app_name) != slen ||
                    strncmp(p, opts->app_name, slen) != 0) {
                    return 0;
                }
            }
            if (strlen(p) >= out_cap) return 0;
            strcpy(out_rel, p);
            return 1;
        }
        if (!slash) break;
        p = slash + 1;
    }
    return 0;
}

/* ---- Output Sink ---- */
static macpkg_status_t mkdir_p(const char *path, char *err, size_t err_sz) {
    char tmp[4096];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) {
        mp_set_err(err, err_sz, "path too long");
        return MACPKG_ERR_PATH;
    }
    memcpy(tmp, path, len + 1);
    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                mp_set_err(err, err_sz, "mkdir '%s': %s", tmp, strerror(errno));
                return MACPKG_ERR_IO;
            }
            tmp[i] = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        mp_set_err(err, err_sz, "mkdir '%s': %s", tmp, strerror(errno));
        return MACPKG_ERR_IO;
    }
    return MACPKG_OK;
}

static void close_if_not_root(const mp_sink_t *sink, int fd) {
    if (fd >= 0 && fd != sink->root_fd) {
        close(fd);
    }
}

/* Walk parent components of rel_path from sink->root_fd without following symlinks. */
static macpkg_status_t open_parent_nofollow(const mp_sink_t *sink, const char *rel_path,
                                            int *out_pfd, char *out_name, size_t out_name_cap,
                                            char *err, size_t err_sz) {
    if (!sink || sink->root_fd < 0 || !rel_path || !rel_path[0] || rel_path[0] == '/') {
        mp_set_err(err, err_sz, "invalid relative path");
        return MACPKG_ERR_PATH;
    }

    int cur_fd = sink->root_fd;
    const char *seg = rel_path;
    for (;;) {
        const char *slash = strchr(seg, '/');
        size_t slen = slash ? (size_t)(slash - seg) : strlen(seg);
        if (slen == 0 || (slen == 1 && seg[0] == '.') ||
            (slen == 2 && seg[0] == '.' && seg[1] == '.')) {
            close_if_not_root(sink, cur_fd);
            mp_set_err(err, err_sz, "unsafe path component in '%s'", rel_path);
            return MACPKG_ERR_PATH;
        }
        if (!slash) {
            if (slen >= out_name_cap) {
                close_if_not_root(sink, cur_fd);
                mp_set_err(err, err_sz, "filename component too long");
                return MACPKG_ERR_PATH;
            }
            memcpy(out_name, seg, slen);
            out_name[slen] = '\0';
            *out_pfd = cur_fd;
            return MACPKG_OK;
        }

        char comp[1024];
        if (slen >= sizeof(comp)) {
            close_if_not_root(sink, cur_fd);
            mp_set_err(err, err_sz, "directory component too long");
            return MACPKG_ERR_PATH;
        }
        memcpy(comp, seg, slen);
        comp[slen] = '\0';

        int next = openat(cur_fd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(cur_fd, comp, 0755) != 0 && errno != EEXIST) {
                int saved = errno;
                close_if_not_root(sink, cur_fd);
                mp_set_err(err, err_sz, "mkdirat '%s': %s", comp, strerror(saved));
                return MACPKG_ERR_IO;
            }
            next = openat(cur_fd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        }
        if (next < 0) {
            int saved = errno;
            close_if_not_root(sink, cur_fd);
            if (saved == ELOOP || saved == ENOTDIR) {
                mp_set_err(err, err_sz, "refusing to traverse non-directory/symlink '%s'", comp);
                return MACPKG_ERR_PATH;
            }
            mp_set_err(err, err_sz, "openat '%s': %s", comp, strerror(saved));
            return MACPKG_ERR_IO;
        }
        close_if_not_root(sink, cur_fd);
        cur_fd = next;
        seg = slash + 1;
    }
}

static int validate_symlink_target(const char *rel_path, const char *target) {
    if (!target || !target[0] || target[0] == '/') return -1;
    int depth = 0;
    for (const char *p = rel_path; *p; p++) {
        if (*p == '/') depth++;
    }
    const char *seg = target;
    while (*seg) {
        const char *slash = strchr(seg, '/');
        size_t slen = slash ? (size_t)(slash - seg) : strlen(seg);
        if (slen == 0 || (slen == 1 && seg[0] == '.')) {
            /* stay at current depth */
        } else if (slen == 2 && seg[0] == '.' && seg[1] == '.') {
            depth--;
            if (depth < 0) return -1;
        } else {
            depth++;
        }
        if (!slash) break;
        seg = slash + 1;
    }
    return 0;
}

macpkg_status_t mp_sink_init(mp_sink_t *sink, const char *root_dir, int verbose,
                             char *err, size_t err_sz) {
    memset(sink, 0, sizeof(*sink));
    sink->root_fd = -1;
    if (!root_dir || !root_dir[0]) {
        mp_set_err(err, err_sz, "empty output directory");
        return MACPKG_ERR_PATH;
    }
    sink->root_dir = mp_strdup(root_dir);
    if (!sink->root_dir) {
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    size_t rlen = strlen(sink->root_dir);
    while (rlen > 1 && sink->root_dir[rlen - 1] == '/') {
        sink->root_dir[--rlen] = '\0';
    }
    sink->verbose = verbose;
    macpkg_status_t st = mkdir_p(sink->root_dir, err, err_sz);
    if (st != MACPKG_OK) {
        free(sink->root_dir);
        sink->root_dir = NULL;
        return st;
    }
    sink->root_fd = open(sink->root_dir, O_RDONLY | O_DIRECTORY);
    if (sink->root_fd < 0) {
        mp_set_err(err, err_sz, "open root '%s': %s", sink->root_dir, strerror(errno));
        free(sink->root_dir);
        sink->root_dir = NULL;
        return MACPKG_ERR_IO;
    }
    return MACPKG_OK;
}

static void record_dir_mode(mp_sink_t *sink, const char *rel_path, uint16_t mode) {
    uint16_t perm = mode & 07777;
    if (perm == 0) perm = 0755;
    if (sink->dir_count == sink->dir_cap) {
        size_t ncap = sink->dir_cap ? sink->dir_cap * 2 : 64;
        mp_dir_mode_t *nd = (mp_dir_mode_t *)realloc(sink->dirs, ncap * sizeof(*nd));
        if (!nd) return;
        sink->dirs = nd;
        sink->dir_cap = ncap;
    }
    sink->dirs[sink->dir_count].path = mp_strdup(rel_path);
    sink->dirs[sink->dir_count].mode = perm;
    if (sink->dirs[sink->dir_count].path) sink->dir_count++;
}

void mp_sink_finish(mp_sink_t *sink) {
    if (!sink) return;
    /* Apply directory permissions bottom-up without following symlinks */
    for (size_t i = sink->dir_count; i > 0; i--) {
        int pfd = -1;
        char name[1024];
        if (open_parent_nofollow(sink, sink->dirs[i - 1].path, &pfd, name, sizeof(name), NULL, 0) == MACPKG_OK) {
            int dfd = openat(pfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (dfd >= 0) {
                fchmod(dfd, sink->dirs[i - 1].mode);
                close(dfd);
            }
            close_if_not_root(sink, pfd);
        }
    }
    mp_sink_free(sink);
}

void mp_sink_free(mp_sink_t *sink) {
    if (!sink) return;
    if (sink->root_fd >= 0) {
        close(sink->root_fd);
        sink->root_fd = -1;
    }
    for (size_t i = 0; i < sink->dir_count; i++) {
        free(sink->dirs[i].path);
    }
    free(sink->dirs);
    free(sink->root_dir);
    memset(sink, 0, sizeof(*sink));
    sink->root_fd = -1;
}

macpkg_status_t mp_sink_mkdir(mp_sink_t *sink, const char *rel_path, uint16_t mode,
                              char *err, size_t err_sz) {
    int pfd = -1;
    char name[1024];
    macpkg_status_t st = open_parent_nofollow(sink, rel_path, &pfd, name, sizeof(name), err, err_sz);
    if (st != MACPKG_OK) return st;

    int dfd = openat(pfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (dfd < 0 && errno == ENOENT) {
        if (mkdirat(pfd, name, 0755) != 0 && errno != EEXIST) {
            int saved = errno;
            close_if_not_root(sink, pfd);
            mp_set_err(err, err_sz, "mkdirat '%s': %s", rel_path, strerror(saved));
            return MACPKG_ERR_IO;
        }
        dfd = openat(pfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    }
    if (dfd < 0) {
        int saved = errno;
        close_if_not_root(sink, pfd);
        if (saved == ELOOP || saved == ENOTDIR) {
            mp_set_err(err, err_sz, "refusing to overwrite non-directory/symlink '%s'", rel_path);
            return MACPKG_ERR_PATH;
        }
        mp_set_err(err, err_sz, "openat dir '%s': %s", rel_path, strerror(saved));
        return MACPKG_ERR_IO;
    }
    close(dfd);
    close_if_not_root(sink, pfd);

    record_dir_mode(sink, rel_path, mode);
    sink->dirs_created++;
    return MACPKG_OK;
}

macpkg_status_t mp_sink_begin_file(mp_sink_t *sink, const char *rel_path, uint16_t mode,
                                   FILE **out_fp, char **out_full_path,
                                   char *err, size_t err_sz) {
    int pfd = -1;
    char name[1024];
    macpkg_status_t st = open_parent_nofollow(sink, rel_path, &pfd, name, sizeof(name), err, err_sz);
    if (st != MACPKG_OK) return st;

    unlinkat(pfd, name, 0);
    int fd = openat(pfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    int saved = errno;
    close_if_not_root(sink, pfd);
    if (fd < 0) {
        mp_set_err(err, err_sz, "create '%s': %s", rel_path, strerror(saved));
        return (saved == ELOOP || saved == EISDIR) ? MACPKG_ERR_PATH : MACPKG_ERR_IO;
    }
    FILE *fp = fdopen(fd, "wb");
    if (!fp) {
        close(fd);
        mp_set_err(err, err_sz, "fdopen '%s': %s", rel_path, strerror(errno));
        return MACPKG_ERR_IO;
    }
    *out_fp = fp;
    *out_full_path = mp_strdup(rel_path);
    if (!*out_full_path) {
        fclose(fp);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    (void)mode;
    sink->files_written++;
    return MACPKG_OK;
}

macpkg_status_t mp_sink_end_file(FILE *fp, const char *full_path, uint16_t mode,
                                 char *err, size_t err_sz) {
    if (fp) {
        if (fflush(fp) != 0) {
            mp_set_err(err, err_sz, "flush '%s': %s", full_path ? full_path : "", strerror(errno));
            fclose(fp);
            free((void *)full_path);
            return MACPKG_ERR_IO;
        }
        uint16_t perm = mode & 07777;
        if (perm == 0) perm = 0644;
        if (fchmod(fileno(fp), perm) != 0) {
            mp_set_err(err, err_sz, "fchmod '%s': %s", full_path ? full_path : "", strerror(errno));
            fclose(fp);
            free((void *)full_path);
            return MACPKG_ERR_IO;
        }
        fclose(fp);
    }
    free((void *)full_path);
    return MACPKG_OK;
}

macpkg_status_t mp_sink_write_file(mp_sink_t *sink, const char *rel_path, uint16_t mode,
                                   const uint8_t *data, size_t len,
                                   char *err, size_t err_sz) {
    FILE *fp = NULL;
    char *full = NULL;
    macpkg_status_t st = mp_sink_begin_file(sink, rel_path, mode, &fp, &full, err, err_sz);
    if (st != MACPKG_OK) return st;
    if (len > 0 && fwrite(data, 1, len, fp) != len) {
        mp_set_err(err, err_sz, "write '%s': %s", full, strerror(errno));
        fclose(fp);
        free(full);
        return MACPKG_ERR_IO;
    }
    if (sink->verbose) fprintf(stderr, "  file %s (%zu bytes, mode %04o)\n", rel_path, len, mode & 07777);
    return mp_sink_end_file(fp, full, mode, err, err_sz);
}

macpkg_status_t mp_sink_symlink(mp_sink_t *sink, const char *rel_path, const char *target,
                                char *err, size_t err_sz) {
    if (validate_symlink_target(rel_path, target) != 0) {
        mp_set_err(err, err_sz, "unsafe symlink target '%s' -> '%s'", rel_path, target ? target : "");
        return MACPKG_ERR_PATH;
    }
    int pfd = -1;
    char name[1024];
    macpkg_status_t st = open_parent_nofollow(sink, rel_path, &pfd, name, sizeof(name), err, err_sz);
    if (st != MACPKG_OK) return st;

    unlinkat(pfd, name, 0);
    if (symlinkat(target, pfd, name) != 0) {
        int saved = errno;
        close_if_not_root(sink, pfd);
        mp_set_err(err, err_sz, "symlink '%s' -> '%s': %s", rel_path, target, strerror(saved));
        return MACPKG_ERR_IO;
    }
    close_if_not_root(sink, pfd);
    if (sink->verbose) fprintf(stderr, "  symlink %s -> %s\n", rel_path, target);
    sink->symlinks_written++;
    return MACPKG_OK;
}

macpkg_status_t mp_sink_hardlink(mp_sink_t *sink, const char *rel_path, const char *target_rel_path,
                                 char *err, size_t err_sz) {
    int src_pfd = -1, dst_pfd = -1;
    char src_name[1024], dst_name[1024];
    macpkg_status_t st = open_parent_nofollow(sink, target_rel_path, &src_pfd, src_name, sizeof(src_name), err, err_sz);
    if (st != MACPKG_OK) return st;
    st = open_parent_nofollow(sink, rel_path, &dst_pfd, dst_name, sizeof(dst_name), err, err_sz);
    if (st != MACPKG_OK) {
        close_if_not_root(sink, src_pfd);
        return st;
    }

    unlinkat(dst_pfd, dst_name, 0);
    if (linkat(src_pfd, src_name, dst_pfd, dst_name, 0) != 0) {
        int saved = errno;
        close_if_not_root(sink, dst_pfd);
        close_if_not_root(sink, src_pfd);
        mp_set_err(err, err_sz, "hardlink '%s' -> '%s': %s", rel_path, target_rel_path, strerror(saved));
        return MACPKG_ERR_IO;
    }
    close_if_not_root(sink, dst_pfd);
    close_if_not_root(sink, src_pfd);
    if (sink->verbose) fprintf(stderr, "  hardlink %s -> %s\n", rel_path, target_rel_path);
    sink->hardlinks_written++;
    return MACPKG_OK;
}
