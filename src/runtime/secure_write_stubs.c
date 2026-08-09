#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>


#if !defined(O_DIRECTORY) || !defined(O_NOFOLLOW)
#error "O_DIRECTORY and O_NOFOLLOW are required"
#endif

#ifdef O_CLOEXEC
#define PP_CLOEXEC O_CLOEXEC
#else
#define PP_CLOEXEC 0
#endif

struct traversal {
  int *fds;
  char **names;
  size_t nf;
  char *base;
};

static void close_preserve(int fd)
{
  int e = errno;

  if (fd >= 0)
    close(fd);
  errno = e;
}
static int close_checked(int fd)
{
  if (fd < 0)
    return 0;
  while (close(fd) < 0) {
    if (errno == EINTR)
      continue;
    return -1;
  }
  return 0;
}

static void traversal_free(struct traversal *t)
{
  size_t i;

  if (!t)
    return;
  for (i = 0; i < t->nf; ++i)
    close_preserve(t->fds[i]);
  for (i = 0; i + 1 < t->nf; ++i)
    free(t->names[i]);
  free(t->base);
  free(t->names);
  free(t->fds);
  t->fds = NULL;
  t->names = NULL;
  t->base = NULL;
  t->nf = 0;
}

static void check_component(const char *s)
{
  if (!*s || !strcmp(s, ".") || !strcmp(s, ".."))
    caml_invalid_argument("secure path contains an invalid component");
}

static int traversal_open(const char *path, int create, struct traversal *t)
{
  char *copy, *p, *slash;
  size_t n = strlen(path), cap = 8;
  memset(t, 0, sizeof *t);
  if (n < 2 || path[0] != '/') {
    errno = EINVAL;
    return -1;
  }
  copy = malloc(n + 1);
  t->fds = malloc(cap * sizeof *t->fds);
  t->names = calloc(cap, sizeof *t->names);
  if (!copy || !t->fds || !t->names) {
    free(copy);
    free(t->fds);
    free(t->names);
    errno = ENOMEM;
    return -1;
  }
  strcpy(copy, path + 1);
  {
    char *v = copy, *vs;

    while ((vs = strchr(v, '/')) != NULL) {
      *vs = 0;
      check_component(v);
      *vs = '/';
      v = vs + 1;
    }
    check_component(v);
  }
  t->fds[0] = open("/", O_RDONLY | O_DIRECTORY | PP_CLOEXEC);
  if (t->fds[0] < 0) {
    int e = errno;

    free(copy);
    free(t->fds);
    free(t->names);
    errno = e;
    return -1;
  }
  t->nf = 1;
  p = copy;
  while ((slash = strchr(p, '/')) != NULL) {
    int fd;

    *slash = 0;
    check_component(p);
    fd = openat(t->fds[t->nf - 1], p,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | PP_CLOEXEC);
    if (fd < 0 && errno == ENOENT && create) {
      if (mkdirat(t->fds[t->nf - 1], p, 0755) < 0 && errno != EEXIST)
        goto fail;
      fd = openat(t->fds[t->nf - 1], p,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | PP_CLOEXEC);
      if (fd >= 0 && fsync(t->fds[t->nf - 1]) < 0) {
        int e = errno;
        close_preserve(fd);
        errno = e;
        goto fail;
      }
    }
    if (fd < 0)
      goto fail;
    if (t->nf == cap) {
      int *newfds;
      char **newnames;

      cap *= 2;
      newfds = realloc(t->fds, cap * sizeof *t->fds);
      if (!newfds) {
        errno = ENOMEM;
        close(fd);
        goto fail;
      }
      t->fds = newfds;
      newnames = realloc(t->names, cap * sizeof *t->names);
      if (!newnames) {
        errno = ENOMEM;
        close(fd);
        goto fail;
      }
      t->names = newnames;
      memset(t->names + t->nf, 0, (cap - t->nf) * sizeof *t->names);
    }
    t->names[t->nf - 1] = strdup(p);
    if (!t->names[t->nf - 1]) {
      close(fd);
      errno = ENOMEM;
      goto fail;
    }
    t->fds[t->nf++] = fd;
    p = slash + 1;
  }
  check_component(p);
  t->base = strdup(p);
  if (!t->base) {
    errno = ENOMEM;
    goto fail;
  }
  free(copy);
  return 0;
fail:
  {
    int e = errno;

    free(copy);
    traversal_free(t);
    errno = e;
    return -1;
  }
}

static size_t boundary_depth(const struct traversal *t, const char *boundary)
{
  char *c, *p, *s;
  size_t depth = 0;

  if (!boundary || boundary[0] != '/')
    return t->nf - 1;
  c = strdup(boundary + 1);
  if (!c)
    return t->nf - 1;
  p = c;
  while (1) {
    s = strchr(p, '/');
    if (s)
      *s = 0;
    if (*p && strcmp(p, ".") && strcmp(p, "..") &&
        depth + 1 < t->nf && !strcmp(t->names[depth], p)) {
      depth++;
    } else if (*p) {
      free(c);
      return t->nf - 1;
    }
    if (!s)
      break;
    p = s + 1;
  }
  free(c);
  return depth;
}

static int prune(struct traversal *t, const char *boundary)
{
  size_t bd = boundary_depth(t, boundary);

  while (t->nf - 1 > bd) {
    int parent = t->fds[t->nf - 2];
    char *name = t->names[t->nf - 2];

    if (unlinkat(parent, name, AT_REMOVEDIR) < 0) {
      if (errno == ENOTEMPTY || errno == EEXIST)
        return 0;
      return -1;
    }
    if (fsync(parent) < 0)
      return -1;
    close_preserve(t->fds[t->nf - 1]);
    t->fds[t->nf - 1] = -1;
    free(name);
    t->names[t->nf - 2] = NULL;
    --t->nf;
  }
  return 0;
}

static int write_all(int fd, const char *data, size_t len)
{
  while (len) {
    ssize_t n = write(fd, data, len);

    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0) {
      errno = n == 0 ? EIO : errno;
      return -1;
    }
    data += n;
    len -= (size_t)n;
  }
  return 0;
}
CAMLprim value pp_secure_write_file(value pv, value cv)
{
  CAMLparam2(pv, cv);
  struct traversal t;
  int fd = -1, e;
  const char *data = String_val(cv);

  if (traversal_open(String_val(pv), 1, &t) < 0)
    uerror("openat", pv);
  fd = openat(t.fds[t.nf - 1], t.base,
              O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | PP_CLOEXEC, 0666);
  if (fd < 0 || write_all(fd, data, caml_string_length(cv)) < 0 ||
      fsync(fd) < 0) {
    e = errno;
    close_preserve(fd);
    traversal_free(&t);
    errno = e;
    uerror("write", pv);
  }
  if (close_checked(fd) < 0) {
    e = errno;
    traversal_free(&t);
    errno = e;
    uerror("close", pv);
  }
  traversal_free(&t);
  CAMLreturn(Val_unit);
}
CAMLprim value pp_secure_read_file(value pv)
{
  CAMLparam1(pv);
  struct traversal t;
  struct stat st;
  int fd = -1, e;
  size_t len, off = 0;
  char *buf;
  value result;

  if (traversal_open(String_val(pv), 0, &t) < 0)
    uerror("openat", pv);
  fd = openat(t.fds[t.nf - 1], t.base, O_RDONLY | O_NOFOLLOW | PP_CLOEXEC);
  if (fd < 0 || fstat(fd, &st) < 0) {
    e = errno;
    close_preserve(fd);
    traversal_free(&t);
    errno = e;
    uerror("read", pv);
  }
  if (!S_ISREG(st.st_mode) || st.st_size < 0) {
    close_preserve(fd);
    traversal_free(&t);
    errno = EINVAL;
    uerror("read", pv);
  }
  len = (size_t)st.st_size;
  if ((off_t)len != st.st_size || len == (size_t)-1) {
    close_preserve(fd);
    traversal_free(&t);
    errno = EFBIG;
    uerror("read", pv);
  }
  buf = malloc(len + 1);
  if (!buf) {
    close_preserve(fd);
    traversal_free(&t);
    errno = ENOMEM;
    uerror("read", pv);
  }
  while (off < len) {
    ssize_t n = read(fd, buf + off, len - off);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0) {
      e = n == 0 ? EIO : errno;
      free(buf);
      close_preserve(fd);
      traversal_free(&t);
      errno = e;
      uerror("read", pv);
    }
    off += (size_t)n;
  }
  if (close_checked(fd) < 0) {
    e = errno;
    free(buf);
    traversal_free(&t);
    errno = e;
    uerror("close", pv);
  }
  traversal_free(&t);
  buf[len] = 0;
  result = caml_copy_string(buf);
  free(buf);
  CAMLreturn(result);
}

CAMLprim value pp_secure_materialize_file(value pv, value cv, value ev)
{
  CAMLparam3(pv, cv, ev);
  struct traversal t;
  int fd = -1, e;
  char tmp[512];
  unsigned i;
  const char *path = String_val(pv), *data = String_val(cv);

  if (traversal_open(path, 1, &t) < 0)
    uerror("openat", pv);
  for (i = 0; ; ++i) {
    snprintf(tmp, sizeof tmp, ".%s.pp-tmp.%ld.%u", t.base,
             (long)getpid(), i);
    fd = openat(t.fds[t.nf - 1], tmp,
                O_WRONLY | O_CREAT | O_EXCL | PP_CLOEXEC, 0600);
    if (fd >= 0)
      break;
    if (errno != EEXIST)
      goto fail;
  }
  if (write_all(fd, data, caml_string_length(cv)) < 0 ||
      fchmod(fd, Bool_val(ev) ? 0755 : 0644) < 0 ||
      fsync(fd) < 0)
    goto fail;
  if (close_checked(fd) < 0)
    goto fail;
  fd = -1;
  if (renameat(t.fds[t.nf - 1], tmp, t.fds[t.nf - 1], t.base) < 0 ||
      fsync(t.fds[t.nf - 1]) < 0)
    goto fail;
  traversal_free(&t);
  CAMLreturn(Val_unit);
fail:
  e = errno;
  close_preserve(fd);
  unlinkat(t.fds[t.nf - 1], tmp, 0);
  traversal_free(&t);
  errno = e;
  uerror("materialize", pv);
}

CAMLprim value pp_secure_remove_file(value pv, value bv)
{
  CAMLparam2(pv, bv);
  struct traversal t;
  int e;

  if (traversal_open(String_val(pv), 0, &t) < 0) {
    if (errno == ENOENT)
      CAMLreturn(Val_unit);
    uerror("openat", pv);
  }
  if (unlinkat(t.fds[t.nf - 1], t.base, 0) < 0 && errno != ENOENT) {
    e = errno;
    traversal_free(&t);
    errno = e;
    uerror("unlinkat", pv);
  }
  if (fsync(t.fds[t.nf - 1]) < 0) {
    e = errno;
    traversal_free(&t);
    errno = e;
    uerror("fsync", pv);
  }
  if (prune(&t, String_val(bv)) < 0) {
    e = errno;
    traversal_free(&t);
    errno = e;
    uerror("fsync", pv);
  }
  traversal_free(&t);
  CAMLreturn(Val_unit);
}
CAMLprim value pp_store_ensure_dir_one(value pv)
{
  CAMLparam1(pv);
  struct traversal t;
  int fd, e;
  if (traversal_open(String_val(pv), 0, &t) < 0) uerror("openat", pv);
  fd = openat(t.fds[t.nf - 1], t.base,
              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | PP_CLOEXEC);
  if (fd < 0 && errno == ENOENT) {
    if (mkdirat(t.fds[t.nf - 1], t.base, 0700) < 0) {
      e = errno; traversal_free(&t); errno = e; uerror("mkdirat", pv);
    }
    fd = openat(t.fds[t.nf - 1], t.base,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | PP_CLOEXEC);
  }
  if (fd < 0 || fchmod(fd, 0700) < 0 || fsync(fd) < 0 ||
      fsync(t.fds[t.nf - 1]) < 0) {
    e = errno; close_preserve(fd); traversal_free(&t); errno = e;
    uerror("ensure_dir", pv);
  }
  close_preserve(fd); traversal_free(&t); CAMLreturn(Val_unit);
}

CAMLprim value pp_store_atomic_replace(value pv, value cv)
{
  CAMLparam2(pv, cv);
  struct traversal t;
  int fd = -1, e;
  char tmp[512];
  unsigned i;
  if (traversal_open(String_val(pv), 0, &t) < 0) uerror("openat", pv);
  for (i = 0; ; ++i) {
    snprintf(tmp, sizeof tmp, ".%s.pp-tmp.%ld.%u", t.base, (long)getpid(), i);
    fd = openat(t.fds[t.nf - 1], tmp, O_WRONLY | O_CREAT | O_EXCL |
                O_NOFOLLOW | PP_CLOEXEC, 0600);
    if (fd >= 0) break;
    if (errno != EEXIST) goto fail;
  }
  if (write_all(fd, String_val(cv), caml_string_length(cv)) < 0 ||
      fchmod(fd, 0600) < 0 || fsync(fd) < 0)
    goto fail;
  if (close_checked(fd) < 0)
    goto fail;
  fd = -1;
  if (renameat(t.fds[t.nf - 1], tmp, t.fds[t.nf - 1], t.base) < 0 ||
      fsync(t.fds[t.nf - 1]) < 0) goto fail;
  traversal_free(&t); CAMLreturn(Val_unit);
fail:
  e = errno; close_preserve(fd); unlinkat(t.fds[t.nf - 1], tmp, 0);
  traversal_free(&t); errno = e; uerror("atomic_replace", pv);
}
static value store_open(value pv, int flags)
{
  CAMLparam1(pv);
  struct traversal t;
  struct stat st;
  int fd, e;
  if (traversal_open(String_val(pv), 0, &t) < 0) uerror("openat", pv);
  fd = openat(t.fds[t.nf - 1], t.base, flags | O_NOFOLLOW | PP_CLOEXEC, 0600);
  if (fd < 0) {
    e = errno;
    traversal_free(&t);
    errno = e;
    uerror("open", pv);
  }
  if (fstat(fd, &st) < 0) {
    e = errno;
    close_preserve(fd);
    traversal_free(&t);
    errno = e;
    uerror("fstat", pv);
  }
  if (!S_ISREG(st.st_mode) || fchmod(fd, 0600) < 0 ||
      fsync(t.fds[t.nf - 1]) < 0) {
    e = !S_ISREG(st.st_mode) ? EISDIR : errno;
    close_preserve(fd);
    traversal_free(&t);
    errno = e;
    uerror("open", pv);
  }
  traversal_free(&t);
  CAMLreturn(Val_int(fd));
}

static value store_open_read(value pv)
{
  CAMLparam1(pv);
  struct traversal t;
  struct stat st;
  int fd, e;
  if (traversal_open(String_val(pv), 0, &t) < 0) uerror("openat", pv);
  fd = openat(t.fds[t.nf - 1], t.base, O_RDONLY | O_NOFOLLOW | PP_CLOEXEC);
  if (fd < 0) {
    e = errno;
    traversal_free(&t);
    errno = e;
    uerror("open", pv);
  }
  if (fstat(fd, &st) < 0) {
    e = errno;
    close_preserve(fd);
    traversal_free(&t);
    errno = e;
    uerror("fstat", pv);
  }
  if (!S_ISREG(st.st_mode)) {
    close_preserve(fd);
    traversal_free(&t);
    errno = EISDIR;
    uerror("open", pv);
  }
  traversal_free(&t);
  CAMLreturn(Val_int(fd));
}

CAMLprim value pp_store_open_read(value pv) { return store_open_read(pv); }
CAMLprim value pp_store_open_append(value pv) { return store_open(pv, O_WRONLY | O_CREAT | O_APPEND); }
CAMLprim value pp_store_open_rw(value pv) { return store_open(pv, O_RDWR | O_CREAT); }
CAMLprim value pp_store_open_trunc(value pv) { return store_open(pv, O_WRONLY | O_CREAT | O_TRUNC); }

CAMLprim value pp_store_unlink(value pv)
{
  CAMLparam1(pv);
  struct traversal t; int e;
  if (traversal_open(String_val(pv), 0, &t) < 0) {
    if (errno == ENOENT) CAMLreturn(Val_unit);
    uerror("openat", pv);
  }
  if (unlinkat(t.fds[t.nf - 1], t.base, 0) < 0 && errno != ENOENT) {
    e = errno; traversal_free(&t); errno = e; uerror("unlinkat", pv);
  }
  if (fsync(t.fds[t.nf - 1]) < 0) {
    e = errno; traversal_free(&t); errno = e; uerror("fsync", pv);
  }
  traversal_free(&t); CAMLreturn(Val_unit);
}

static int clear_fd(int dirfd)
{
  DIR *d = fdopendir(dup(dirfd));
  struct dirent *de;
  if (!d) return -1;
  while ((de = readdir(d)) != NULL) {
    struct stat st;
    int child;
    if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
    if (fstatat(dirfd, de->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) goto fail;
    if (S_ISDIR(st.st_mode)) {
      child = openat(dirfd, de->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | PP_CLOEXEC);
      if (child < 0) goto fail;
      if (clear_fd(child) < 0) {
        int e = errno;
        close_preserve(child);
        errno = e;
        goto fail;
      }
      if (close(child) < 0) goto fail;
      if (unlinkat(dirfd, de->d_name, AT_REMOVEDIR) < 0) goto fail;
    } else if (unlinkat(dirfd, de->d_name, 0) < 0) goto fail;
  }
  if (closedir(d) < 0) return -1;
  return fsync(dirfd);
fail:
  { int e = errno; closedir(d); errno = e; return -1; }
}

CAMLprim value pp_store_clear_dir(value pv)
{
  CAMLparam1(pv);
  struct traversal t; int fd, e;
  if (traversal_open(String_val(pv), 0, &t) < 0) uerror("openat", pv);
  fd = openat(t.fds[t.nf - 1], t.base,
              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | PP_CLOEXEC);
  if (fd < 0 || clear_fd(fd) < 0) {
    e = errno; close_preserve(fd); traversal_free(&t); errno = e; uerror("clear_dir", pv);
  }
  close_preserve(fd); traversal_free(&t); CAMLreturn(Val_unit);
}
