/* Native replacement for the default unpack.py, registered through
 * py_unpack_toolchain (docs/interpreter.md, "Custom wheel-unpack tool").
 *
 * Installs a simple pure wheel without Python: stored or deflated zip entries,
 * no `.data/` tree, no entry points, no patching or exclusion. Python runs
 * only for --compile-pyc, via compileall under --python-bin. It writes a
 * distinctive dist-info INSTALLER so the test can prove this tool ran (the
 * reference unpack.py writes `aspect_rules_py` there instead).
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <zlib.h>

#define EOCD_SIG 0x06054b50u
#define CENTRAL_SIG 0x02014b50u
#define LOCAL_SIG 0x04034b50u

#define INSTALLER_MARKER "rules_py-e2e-c-unpack-tool\n"

static void die(const char *msg, const char *detail) {
    fprintf(stderr, "unpack_tool: %s%s%s\n", msg, detail ? ": " : "", detail ? detail : "");
    exit(1);
}

static uint16_t read_u16(const unsigned char *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void mkdir_p(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') {
            continue;
        }
        *p = '\0';
        if (mkdir(path, 0755) != 0 && errno != EEXIST) {
            die("mkdir failed", path);
        }
        *p = '/';
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        die("mkdir failed", path);
    }
}

static void write_file(const char *dir, const char *name, const unsigned char *data, size_t size) {
    char path[4096];
    if ((size_t)snprintf(path, sizeof(path), "%s/%s", dir, name) >= sizeof(path)) {
        die("path too long", name);
    }
    char *slash = strrchr(path, '/');
    *slash = '\0';
    mkdir_p(path);
    *slash = '/';
    FILE *out = fopen(path, "wb");
    if (!out) {
        die("cannot create", path);
    }
    if (size > 0 && fwrite(data, 1, size, out) != size) {
        die("short write", path);
    }
    fclose(out);
}

int main(int argc, char **argv) {
    const char *into = NULL, *wheel = NULL, *python_version = NULL;
    const char *python_bin = NULL, *pyc_invalidation_mode = "unchecked-hash";
    int compile_pyc = 0;
    for (int i = 1; i < argc; i++) {
        const char *flag = argv[i];
        if (strcmp(flag, "--compile-pyc") == 0) {
            compile_pyc = 1;
            continue;
        }
        if (i + 1 >= argc) {
            die("missing value for flag", flag);
        }
        const char *value = argv[++i];
        if (strcmp(flag, "--into") == 0) {
            into = value;
        } else if (strcmp(flag, "--wheel") == 0) {
            wheel = value;
        } else if (strcmp(flag, "--python-version") == 0) {
            python_version = value;
        } else if (strcmp(flag, "--python-bin") == 0) {
            python_bin = value;
        } else if (strcmp(flag, "--pyc-invalidation-mode") == 0) {
            pyc_invalidation_mode = value;
        } else {
            die("unknown flag", flag);
        }
    }
    if (!into || !wheel || !python_version) {
        die("--into, --wheel and --python-version are required", NULL);
    }
    if (compile_pyc && !python_bin) {
        die("--compile-pyc requires --python-bin", NULL);
    }

    FILE *in = fopen(wheel, "rb");
    if (!in) {
        die("cannot open wheel", wheel);
    }
    if (fseek(in, 0, SEEK_END) != 0) {
        die("seek failed", wheel);
    }
    long file_size = ftell(in);
    if (file_size <= 0) {
        die("empty wheel", wheel);
    }
    unsigned char *buf = malloc((size_t)file_size);
    if (!buf) {
        die("out of memory", NULL);
    }
    rewind(in);
    if (fread(buf, 1, (size_t)file_size, in) != (size_t)file_size) {
        die("short read", wheel);
    }
    fclose(in);

    /* End-of-central-directory record: scan backwards over the trailing
     * comment space for its signature. */
    long eocd = -1;
    long scan_floor = file_size - 22 - 65535;
    if (scan_floor < 0) {
        scan_floor = 0;
    }
    for (long i = file_size - 22; i >= scan_floor; i--) {
        if (read_u32(buf + i) == EOCD_SIG) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        die("no zip end-of-central-directory in", wheel);
    }
    uint16_t entries = read_u16(buf + eocd + 10);
    uint32_t central_offset = read_u32(buf + eocd + 16);

    char site_packages[4096];
    if ((size_t)snprintf(site_packages, sizeof(site_packages), "%s/lib/python%s/site-packages",
                         into, python_version) >= sizeof(site_packages)) {
        die("path too long", into);
    }
    mkdir_p(site_packages);

    char dist_info[512] = "";
    long offset = central_offset;
    for (uint16_t e = 0; e < entries; e++) {
        if (offset + 46 > file_size || read_u32(buf + offset) != CENTRAL_SIG) {
            die("bad central directory entry in", wheel);
        }
        uint16_t method = read_u16(buf + offset + 10);
        uint32_t comp_size = read_u32(buf + offset + 20);
        uint32_t uncomp_size = read_u32(buf + offset + 24);
        uint16_t name_len = read_u16(buf + offset + 28);
        uint16_t extra_len = read_u16(buf + offset + 30);
        uint16_t comment_len = read_u16(buf + offset + 32);
        uint32_t local_offset = read_u32(buf + offset + 42);

        char name[2048];
        if (name_len >= sizeof(name)) {
            die("entry name too long in", wheel);
        }
        memcpy(name, buf + offset + 46, name_len);
        name[name_len] = '\0';
        offset += 46 + name_len + extra_len + comment_len;

        if (name[0] == '/' || strstr(name, "..")) {
            die("unsafe entry path", name);
        }
        if (method != 0 && method != 8) {
            die("unsupported compression method", name);
        }

        /* Remember the dist-info directory for the INSTALLER marker. */
        const char *slash = strchr(name, '/');
        if (slash) {
            size_t top_len = (size_t)(slash - name);
            if (top_len > 10 && top_len < sizeof(dist_info) &&
                strncmp(name + top_len - 10, ".dist-info", 10) == 0) {
                memcpy(dist_info, name, top_len);
                dist_info[top_len] = '\0';
            }
        }

        if (name_len > 0 && name[name_len - 1] == '/') {
            char dir[4096];
            if ((size_t)snprintf(dir, sizeof(dir), "%s/%s", site_packages, name) >= sizeof(dir)) {
                die("path too long", name);
            }
            dir[strlen(dir) - 1] = '\0';
            mkdir_p(dir);
            continue;
        }

        if (local_offset + 30 > (uint32_t)file_size || read_u32(buf + local_offset) != LOCAL_SIG) {
            die("bad local header for", name);
        }
        uint16_t local_name_len = read_u16(buf + local_offset + 26);
        uint16_t local_extra_len = read_u16(buf + local_offset + 28);
        uint32_t data_offset = local_offset + 30 + local_name_len + local_extra_len;
        if (data_offset + comp_size > (uint32_t)file_size) {
            die("truncated entry", name);
        }
        if (method == 0) {
            if (comp_size != uncomp_size) {
                die("stored entry size mismatch", name);
            }
            write_file(site_packages, name, buf + data_offset, comp_size);
        } else {
            unsigned char *plain = malloc(uncomp_size ? uncomp_size : 1);
            if (!plain) {
                die("out of memory", name);
            }
            z_stream zs;
            memset(&zs, 0, sizeof(zs));
            /* Negative windowBits: raw deflate, as stored in zip entries. */
            if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
                die("inflateInit2 failed", name);
            }
            zs.next_in = (Bytef *)(buf + data_offset);
            zs.avail_in = comp_size;
            zs.next_out = plain;
            zs.avail_out = uncomp_size;
            int zr = inflate(&zs, Z_FINISH);
            if (zr != Z_STREAM_END || zs.total_out != uncomp_size) {
                die("inflate failed", name);
            }
            inflateEnd(&zs);
            write_file(site_packages, name, plain, uncomp_size);
            free(plain);
        }
    }

    if (dist_info[0] != '\0') {
        char meta[2048];
        if ((size_t)snprintf(meta, sizeof(meta), "%s/INSTALLER", dist_info) >= sizeof(meta)) {
            die("path too long", dist_info);
        }
        write_file(site_packages, meta, (const unsigned char *)INSTALLER_MARKER,
                   strlen(INSTALLER_MARKER));
        snprintf(meta, sizeof(meta), "%s/REQUESTED", dist_info);
        write_file(site_packages, meta, NULL, 0);
    }

    if (compile_pyc) {
        pid_t pid = fork();
        if (pid < 0) {
            die("fork failed", NULL);
        }
        if (pid == 0) {
            /* Match the reference tool's compileall invocation. */
            execl(python_bin, python_bin, "-c", "import compileall; compileall.main()",
                  "-q", "--invalidation-mode", pyc_invalidation_mode, "--", site_packages,
                  (char *)NULL);
            die("exec failed", python_bin);
        }
        int status = 0;
        if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            die("pyc compilation failed under", python_bin);
        }
    }

    free(buf);
    return 0;
}
