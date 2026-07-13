/* demo/src/greeter.c — M6 devops-complete demo service.
 *
 * A tiny, socket-free "greeter" daemon: every tick it re-reads a config
 * file and rewrites a status file with a heartbeat + the current
 * greeting. No network dependency at all (keeps the exit tests free of
 * curl/python3/open ports) — the whole point of this program is to be a
 * believable stand-in for "a deployed service that reads its config and
 * proves it's alive," nothing more.
 *
 * usage: greeter <config-file> <status-file>
 *
 * Every loop:
 *   - reads the ENTIRE config file fresh (so a config edit is visible on
 *     the very next tick, without a restart — though this demo restarts
 *     it anyway, because CONFIG_HASH is baked into the process's own env
 *     by the proc-domain spec, so a content change is also an identity
 *     change from the supervisor's point of view: LAW-restart-on-drift);
 *   - writes pid + tick counter + the config bytes to the status file.
 *
 * SIGTERM/SIGINT stop the loop cleanly (the proc domain's stop path sends
 * SIGTERM first, then escalates to SIGKILL after a grace period).
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t g_running = 1;

static void on_term(int sig) {
    (void)sig;
    g_running = 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <config-file> <status-file>\n", argv[0]);
        return 2;
    }
    const char *conf_path = argv[1];
    const char *status_path = argv[2];

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    long tick = 0;
    while (g_running) {
        char conf_buf[8192];
        size_t conf_len = 0;
        FILE *cf = fopen(conf_path, "rb");
        if (cf) {
            conf_len = fread(conf_buf, 1, sizeof(conf_buf) - 1, cf);
            fclose(cf);
        }
        conf_buf[conf_len] = '\0';

        FILE *sf = fopen(status_path, "wb");
        if (sf) {
            fprintf(sf, "pid=%d tick=%ld\n--- config ---\n%s",
                    (int)getpid(), tick, conf_buf);
            fclose(sf);
        }

        tick++;
        /* Sleep in short slices so SIGTERM is noticed promptly rather
         * than after a whole-second nap. */
        for (int slice = 0; slice < 10 && g_running; slice++) {
            usleep(100 * 1000);
        }
    }
    return 0;
}
