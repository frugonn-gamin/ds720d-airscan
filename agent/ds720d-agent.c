/*
 * ds720d-agent — agent de session (LaunchAgent) du pont AirScan DS-720D.
 *
 * Sur macOS récent, piloter en USB brut un appareil de classe « stockage de masse » exige
 * l'autorisation de confidentialité « Volumes amovibles ». macOS ne peut l'accorder qu'à un
 * programme lancé depuis la session de l'utilisateur : un service système (LaunchDaemon) ne
 * peut pas l'obtenir. L'agent tourne donc dans la session et lance le démon USB (qui doit être
 * root pour soustraire le scanneur au pilote de disque) via une règle sudo limitée à cette seule
 * commande. Les accès du démon sont attribués à l'agent : macOS demande l'autorisation une fois.
 *
 * Journal : ~/Library/Logs/ds720d-usbd.log
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define USBD "/Library/PrivilegedHelperTools/local.ds720d.usbd"

extern char **environ;
static volatile pid_t child;
static volatile sig_atomic_t stopping;

static void on_term(int s) {
    (void)s;
    stopping = 1;
    if (child > 0) kill(child, SIGTERM);
}

static void logline(const char *msg) {
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s ds720d-agent: %s\n", ts, msg);
}

int main(void) {
    const char *home = getenv("HOME");
    if (home) {
        char path[1024];
        snprintf(path, sizeof path, "%s/Library/Logs/ds720d-usbd.log", home);
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    }
    setvbuf(stderr, NULL, _IOLBF, 0);
    struct sigaction sa = {0};
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    int failures = 0;
    while (!stopping) {
        char *args[] = { "/usr/bin/sudo", "-n", USBD, "-g", "staff", NULL };
        pid_t pid;
        int rc = posix_spawn(&pid, "/usr/bin/sudo", NULL, NULL, args, environ);
        if (rc != 0) {
            logline(strerror(rc));
            sleep(30);
            continue;
        }
        child = pid;
        logline("démon USB lancé");
        time_t started = time(NULL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        child = 0;
        if (stopping) break;
        /* Relance ; délai croissant si le démon s'arrête tout de suite (ex. règle sudo absente). */
        failures = time(NULL) - started < 30 ? failures + 1 : 0;
        int delay = failures ? (failures < 6 ? 10 << failures : 600) : 5;
        char msg[96];
        snprintf(msg, sizeof msg, "démon USB arrêté (statut %d), relance dans %d s", WIFEXITED(st) ? WEXITSTATUS(st) : -1, delay);
        logline(msg);
        for (int i = 0; i < delay && !stopping; i++) sleep(1);
    }
    logline("arrêt");
    return 0;
}
