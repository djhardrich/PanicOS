/* panicos-mbselect — multiboot input + menu helper for the initramfs.
 *
 * Two modes:
 *
 *   panicos-mbselect wait <seconds>
 *     Open every /dev/input/event*, poll for any EV_KEY press
 *     (value=1) for up to <seconds>. Exit 0 on press, 1 on timeout,
 *     2 on error. Used by /init to detect "user pressed a button
 *     during the boot countdown".
 *
 *   panicos-mbselect menu <default> <item1> [item2 ...]
 *     Render a menu on /dev/tty1 listing the items, highlight
 *     <default> as the initial selection. Navigate with up/down
 *     (KEY_UP/DOWN, BTN_DPAD_UP/DOWN), select with A/Start/Enter
 *     (KEY_ENTER, BTN_A=304, BTN_START=315). Print selected item on
 *     stdout, exit 0. On cancel (B/BTN_EAST) or 30-sec idle, exit 1
 *     (caller falls back to default).
 *
 * Designed to be compiled with the buildroot cross-toolchain and
 * statically linked into the initramfs. ~200 lines, no deps beyond
 * libc and <linux/input.h>.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <linux/input.h>
#include <linux/input-event-codes.h>
#include <poll.h>

#define MAX_FDS 32
#define MAX_ITEMS 16

static int open_evdevs(int *fds) {
    DIR *d = opendir("/dev/input");
    if (!d) return 0;
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d)) != NULL && n < MAX_FDS) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;
        char path[64];
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd >= 0) fds[n++] = fd;
    }
    closedir(d);
    return n;
}

static void close_fds(int *fds, int n) {
    for (int i = 0; i < n; i++) close(fds[i]);
}

/* Drain pending events, return 1 if any EV_KEY press seen. */
static int read_key_press(int fd, struct input_event *out) {
    struct input_event ev;
    int saw = 0;
    while (read(fd, &ev, sizeof ev) == (ssize_t)sizeof ev) {
        if (ev.type == EV_KEY && ev.value == 1) {
            if (out) *out = ev;
            saw = 1;
        }
    }
    return saw;
}

/* Mode: wait <sec>. Returns 0 on press, 1 on timeout. */
static int mode_wait(int seconds) {
    int fds[MAX_FDS];
    int n = open_evdevs(fds);
    if (n == 0) {
        fprintf(stderr, "mbselect: no /dev/input/event* devices\n");
        return 2;
    }
    struct pollfd pfds[MAX_FDS];
    for (int i = 0; i < n; i++) {
        pfds[i].fd = fds[i];
        pfds[i].events = POLLIN;
    }
    int r = poll(pfds, n, seconds * 1000);
    if (r < 0) { close_fds(fds, n); return 2; }
    if (r == 0) { close_fds(fds, n); return 1; }
    int got = 0;
    for (int i = 0; i < n; i++) {
        if (pfds[i].revents & POLLIN) {
            if (read_key_press(fds[i], NULL)) got = 1;
        }
    }
    close_fds(fds, n);
    return got ? 0 : 1;
}

/* ---------- menu mode ---------- */

/* Map an EV_KEY code to a navigation action. -1 = ignored. */
enum { ACT_NONE = -1, ACT_UP, ACT_DOWN, ACT_SELECT, ACT_CANCEL };

static int classify(int code) {
    switch (code) {
        case KEY_UP:        case BTN_DPAD_UP:                       return ACT_UP;
        case KEY_DOWN:      case BTN_DPAD_DOWN:                     return ACT_DOWN;
        case KEY_ENTER:     case BTN_A:        case BTN_START:      return ACT_SELECT;
        case KEY_ESC:       case KEY_BACKSPACE:case BTN_B:
        case BTN_SELECT:                                            return ACT_CANCEL;
        default: return ACT_NONE;
    }
}

static FILE *open_tty(void) {
    /* Write directly to /dev/tty1 — fbcon paints ANSI text on the panel. */
    FILE *f = fopen("/dev/tty1", "w");
    if (!f) f = stderr;
    setvbuf(f, NULL, _IONBF, 0);
    return f;
}

static void render(FILE *tty, const char *title, char **items, int n, int sel) {
    /* Clear, hide cursor, draw centered title + items. */
    fprintf(tty, "\033[?25l\033[2J\033[H");
    fprintf(tty, "\033[2;5H\033[1;37m%s\033[0m\r\n", title);
    fprintf(tty, "\033[3;5H\033[2;37m%-40s\033[0m\r\n",
                 "Up/Down: navigate   A/Enter: select   B: cancel");
    for (int i = 0; i < n; i++) {
        if (i == sel)
            fprintf(tty, "\033[%d;7H\033[1;7m> %-30s\033[0m\r\n", 5 + i, items[i]);
        else
            fprintf(tty, "\033[%d;7H  %-30s\r\n",                 5 + i, items[i]);
    }
    fflush(tty);
}

/* Find index of items[i] == target, else 0. */
static int find_default(char **items, int n, const char *target) {
    for (int i = 0; i < n; i++)
        if (strcmp(items[i], target) == 0) return i;
    return 0;
}

static int mode_menu(const char *def, char **items, int n) {
    if (n <= 0) return 1;
    int fds[MAX_FDS];
    int nfds = open_evdevs(fds);
    /* nfds == 0 is OK — we still render and let a 30s timeout fall back. */

    FILE *tty = open_tty();
    int sel = find_default(items, n, def);
    render(tty, "PanicOS Boot Menu", items, n, sel);

    struct pollfd pfds[MAX_FDS];
    for (int i = 0; i < nfds; i++) {
        pfds[i].fd = fds[i];
        pfds[i].events = POLLIN;
    }
    int rc = 1;
    int idle_ms = 0;
    const int TIMEOUT_MS = 30 * 1000;
    while (idle_ms < TIMEOUT_MS) {
        int wait = 200;
        int r = nfds > 0 ? poll(pfds, nfds, wait) : (usleep(wait * 1000), 0);
        if (r <= 0) { idle_ms += wait; continue; }
        for (int i = 0; i < nfds; i++) {
            if (!(pfds[i].revents & POLLIN)) continue;
            struct input_event ev;
            while (read(fds[i], &ev, sizeof ev) == (ssize_t)sizeof ev) {
                if (ev.type != EV_KEY || ev.value != 1) continue;
                int act = classify(ev.code);
                if (act == ACT_NONE) continue;
                idle_ms = 0;
                if      (act == ACT_UP)     sel = (sel + n - 1) % n;
                else if (act == ACT_DOWN)   sel = (sel + 1) % n;
                else if (act == ACT_SELECT) { rc = 0; goto done; }
                else if (act == ACT_CANCEL) { rc = 1; goto done; }
                render(tty, "PanicOS Boot Menu", items, n, sel);
            }
        }
    }
done:
    /* Restore cursor + clear before returning. */
    fprintf(tty, "\033[?25h\033[2J\033[H");
    fflush(tty);
    if (tty != stderr) fclose(tty);
    close_fds(fds, nfds);
    if (rc == 0) printf("%s\n", items[sel]);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 2) goto usage;
    if (strcmp(argv[1], "wait") == 0) {
        if (argc != 3) goto usage;
        return mode_wait(atoi(argv[2]));
    }
    if (strcmp(argv[1], "menu") == 0) {
        if (argc < 4) goto usage;
        return mode_menu(argv[2], &argv[3], argc - 3);
    }
usage:
    fprintf(stderr,
        "usage:\n"
        "  panicos-mbselect wait <seconds>\n"
        "  panicos-mbselect menu <default> <item1> [item2 ...]\n");
    return 2;
}
