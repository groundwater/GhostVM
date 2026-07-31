// Deterministic user-space UDP impairment proxy ("chaos proxy") for the
// GhostHTTP3 HTTP/3 test phases. Requires no root privileges: it relays
// loopback UDP datagrams between one client and one server through two
// sockets and applies configurable impairments in each direction.
//
// Impairments per direction (client->server "c2s" and server->client "s2c"):
//   - random loss            (--c2s-loss / --s2c-loss, percent)
//   - random duplication     (--c2s-dup / --s2c-dup, percent)
//   - fixed delay + uniform jitter (--c2s-delay / --c2s-jitter, milliseconds)
//   - reordering             (--c2s-reorder percent, --c2s-reorder-ms range)
//   - drop above MTU         (--mtu bytes, applies to both directions)
//
// All impairment decisions are drawn from a SplitMix64 PRNG seeded with
// --seed; each direction consumes an independent stream keyed only by that
// direction's packet sequence, so a fixed seed replays the same decision
// pattern for the same offered traffic. Delayed packets sit in a bounded
// per-direction queue (--queue); overflow drops are counted, never silent.
//
// The proxy prints one machine-parseable stats line per direction on exit
// (SIGINT/SIGTERM or --max-duration) and optionally every --stats-interval
// seconds. --probe-port provides a bind probe the driver uses for
// collision-resistant port selection and server-readiness detection.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_DATAGRAM 65536
#define MAX_QUEUE_CAPACITY 4096
#define DEFAULT_QUEUE_CAPACITY 256
#define DEFAULT_MAX_DURATION_SEC 300

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: "); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        exit(1); \
    } \
} while (0)

typedef enum {
    DIR_C2S = 0,
    DIR_S2C = 1,
} direction;

typedef struct {
    double loss_pct;
    double dup_pct;
    double reorder_pct;
    uint32_t delay_ms;
    uint32_t jitter_ms;
    uint32_t reorder_ms;
} impairment_config;

typedef struct {
    uint64_t rx;
    uint64_t tx;
    uint64_t drop_loss;
    uint64_t drop_mtu;
    uint64_t drop_full;
    uint64_t drop_nopeer;
    uint64_t send_error;
    uint64_t duplicated;
    uint64_t delayed;
    uint64_t reordered;
    uint64_t max_queue;
} direction_stats;

typedef struct {
    uint64_t sequence;
    uint64_t release_at_ms;
    size_t length;
    uint8_t *data;
    bool duplicate;
} queued_packet;

typedef struct {
    impairment_config config;
    direction_stats stats;
    uint64_t prng_state;
    uint64_t next_sequence;
    uint64_t max_released_sequence;
    queued_packet *queue;
    size_t queue_length;
    size_t queue_capacity;
} direction_state;

typedef struct {
    const char *listen_host;
    uint16_t listen_port;
    const char *target_host;
    uint16_t target_port;
    uint64_t seed;
    size_t queue_capacity;
    uint16_t mtu;
    uint32_t max_duration_sec;
    uint32_t stats_interval_sec;
    bool verbose;
    direction_state directions[2];
} proxy;

static volatile sig_atomic_t stop_requested = 0;

static void handle_signal(int signal_number) {
    (void) signal_number;
    stop_requested = 1;
}

static uint64_t monotonic_ms(void) {
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0,
          "clock_gettime failed: %s", strerror(errno));
    return (uint64_t) now.tv_sec * 1000 + (uint64_t) now.tv_nsec / 1000000;
}

// SplitMix64: small, deterministic, and independent of libc rand().
static uint64_t prng_next(direction_state *state) {
    state->prng_state += 0x9e3779b97f4a7c15ULL;
    uint64_t value = state->prng_state;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
    return value ^ (value >> 31);
}

static double prng_double(direction_state *state) {
    return (double) (prng_next(state) >> 11) * (1.0 / 9007199254740992.0);
}

static uint32_t prng_range(direction_state *state, uint32_t inclusive_max) {
    return (uint32_t) (prng_double(state) * (double) (inclusive_max + 1));
}

static bool prng_roll(direction_state *state, double pct) {
    return pct > 0.0 && prng_double(state) < pct / 100.0;
}

static const char *direction_name(direction dir) {
    return dir == DIR_C2S ? "c2s" : "s2c";
}

static void print_stats_line(const proxy *config, direction dir) {
    const direction_state *state = &config->directions[dir];
    const direction_stats *stats = &state->stats;
    printf("stats dir=%s rx=%" PRIu64 " tx=%" PRIu64
           " drop_loss=%" PRIu64 " drop_mtu=%" PRIu64
           " drop_full=%" PRIu64 " drop_nopeer=%" PRIu64
           " send_error=%" PRIu64
           " dup=%" PRIu64 " delayed=%" PRIu64
           " reordered=%" PRIu64 " queued=%zu max_queue=%" PRIu64 "\n",
           direction_name(dir), stats->rx, stats->tx,
           stats->drop_loss, stats->drop_mtu,
           stats->drop_full, stats->drop_nopeer,
           stats->send_error,
           stats->duplicated, stats->delayed,
           stats->reordered, state->queue_length, stats->max_queue);
    fflush(stdout);
}

static void print_stats(const proxy *config) {
    print_stats_line(config, DIR_C2S);
    print_stats_line(config, DIR_S2C);
}

static bool queue_enqueue(proxy *config, direction dir, uint64_t release_at_ms,
                          const uint8_t *data, size_t length,
                          bool duplicate) {
    direction_state *state = &config->directions[dir];
    if (state->queue_length == state->queue_capacity) {
        state->stats.drop_full++;
        if (config->verbose) {
            fprintf(stderr, "%s #%" PRIu64 " %zuB drop(queue full)\n",
                    direction_name(dir), state->next_sequence, length);
        }
        return false;
    }

    queued_packet *entry = &state->queue[state->queue_length++];
    entry->sequence = state->next_sequence;
    entry->release_at_ms = release_at_ms;
    entry->length = length;
    entry->duplicate = duplicate;
    entry->data = malloc(length == 0 ? 1 : length);
    CHECK(entry->data != NULL, "out of memory queueing %zu bytes", length);
    memcpy(entry->data, data, length);

    if (state->queue_length > state->stats.max_queue) {
        state->stats.max_queue = state->queue_length;
    }
    return true;
}

// Releases every due packet in (release time, arrival sequence) order.
static void queue_release_due(proxy *config, direction dir, int send_socket,
                              const struct sockaddr_storage *destination,
                              socklen_t destination_length) {
    direction_state *state = &config->directions[dir];
    uint64_t now = monotonic_ms();

    while (state->queue_length > 0) {
        size_t earliest = 0;
        for (size_t index = 1; index < state->queue_length; index++) {
            queued_packet *candidate = &state->queue[index];
            queued_packet *current = &state->queue[earliest];
            if (candidate->release_at_ms < current->release_at_ms ||
                (candidate->release_at_ms == current->release_at_ms &&
                 candidate->sequence < current->sequence)) {
                earliest = index;
            }
        }

        queued_packet *entry = &state->queue[earliest];
        if (entry->release_at_ms > now) {
            return;
        }

        if (destination == NULL) {
            state->stats.drop_nopeer++;
        } else {
            ssize_t sent = sendto(send_socket, entry->data, entry->length, 0,
                                  (const struct sockaddr *) destination,
                                  destination_length);
            if (sent < 0 || (size_t) sent != entry->length) {
                state->stats.send_error++;
                fprintf(stderr, "%s sendto failed: %s\n",
                        direction_name(dir),
                        sent < 0 ? strerror(errno) : "short datagram send");
            } else {
                state->stats.tx++;
                // Duplicates ride the original's sequence number and are
                // excluded from reorder accounting: a late copy is an
                // artifact of duplication, not of packet reordering.
                if (!entry->duplicate) {
                    if (entry->sequence < state->max_released_sequence) {
                        state->stats.reordered++;
                        if (config->verbose) {
                            fprintf(stderr, "%s #%" PRIu64
                                    " released out of order\n",
                                    direction_name(dir), entry->sequence);
                        }
                    } else {
                        state->max_released_sequence = entry->sequence;
                    }
                }
            }
        }

        free(entry->data);
        if (earliest + 1 < state->queue_length) {
            memmove(entry, entry + 1,
                    (state->queue_length - earliest - 1) *
                    sizeof(queued_packet));
        }
        state->queue_length--;
        now = monotonic_ms();
    }
}

static uint64_t queue_next_release_ms(const direction_state *state) {
    if (state->queue_length == 0) {
        return UINT64_MAX;
    }
    uint64_t earliest = UINT64_MAX;
    for (size_t index = 0; index < state->queue_length; index++) {
        if (state->queue[index].release_at_ms < earliest) {
            earliest = state->queue[index].release_at_ms;
        }
    }
    return earliest;
}

// Applies the configured impairment pipeline to one received datagram.
static void impair_and_queue(proxy *config, direction dir,
                             const uint8_t *data, size_t length) {
    direction_state *state = &config->directions[dir];
    const impairment_config *impairment = &state->config;
    uint64_t sequence = state->next_sequence;
    uint64_t now = monotonic_ms();

    state->stats.rx++;

    if (config->mtu > 0 && length > config->mtu) {
        state->stats.drop_mtu++;
        if (config->verbose) {
            fprintf(stderr, "%s #%" PRIu64 " %zuB drop(mtu %u)\n",
                    direction_name(dir), sequence, length,
                    (unsigned) config->mtu);
        }
        state->next_sequence++;
        return;
    }

    if (prng_roll(state, impairment->loss_pct)) {
        state->stats.drop_loss++;
        if (config->verbose) {
            fprintf(stderr, "%s #%" PRIu64 " %zuB drop(loss)\n",
                    direction_name(dir), sequence, length);
        }
        state->next_sequence++;
        return;
    }

    uint64_t hold_ms = impairment->delay_ms;
    if (impairment->jitter_ms > 0) {
        hold_ms += prng_range(state, impairment->jitter_ms);
    }
    if (prng_roll(state, impairment->reorder_pct)) {
        hold_ms += 1 + prng_range(state, impairment->reorder_ms);
    }

    uint64_t release_at_ms = now + hold_ms;
    if (hold_ms > 0) {
        state->stats.delayed++;
    }
    if (config->verbose) {
        fprintf(stderr, "%s #%" PRIu64 " %zuB fwd hold=%" PRIu64 "ms\n",
                direction_name(dir), sequence, length, hold_ms);
    }
    queue_enqueue(config, dir, release_at_ms, data, length, false);

    if (prng_roll(state, impairment->dup_pct)) {
        // The duplicate rides the same impairment decision 1 ms behind the
        // original so arrival order between the two is deterministic. Count
        // only successfully-queued dups; if the queue is full queue_enqueue
        // has already accounted it as drop_full, so do not double-count.
        if (queue_enqueue(config, dir, release_at_ms + 1, data, length, true)) {
            state->stats.duplicated++;
            if (config->verbose) {
                fprintf(stderr, "%s #%" PRIu64 " %zuB dup\n",
                        direction_name(dir), sequence, length);
            }
        } else if (config->verbose) {
            fprintf(stderr, "%s #%" PRIu64 " %zuB dup dropped (queue full)\n",
                    direction_name(dir), sequence, length);
        }
    }

    state->next_sequence++;
}

static int make_udp_socket(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(fd >= 0, "socket failed: %s", strerror(errno));

    int flags = fcntl(fd, F_GETFL, 0);
    CHECK(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
          "failed to make socket non-blocking: %s", strerror(errno));
    return fd;
}

static void resolve_ipv4(const char *host, uint16_t port,
                         struct sockaddr_storage *address,
                         socklen_t *address_length) {
    char service[8];
    snprintf(service, sizeof(service), "%u", (unsigned) port);

    const struct addrinfo hints = {
        .ai_family = AF_INET,
        .ai_socktype = SOCK_DGRAM,
        .ai_protocol = IPPROTO_UDP,
    };

    struct addrinfo *result = NULL;
    int rc = getaddrinfo(host, service, &hints, &result);
    CHECK(rc == 0, "failed to resolve %s:%s: %s", host, service,
          gai_strerror(rc));
    CHECK(result->ai_addrlen <= sizeof(*address),
          "resolved address too large");
    memcpy(address, result->ai_addr, result->ai_addrlen);
    *address_length = result->ai_addrlen;
    freeaddrinfo(result);
}

static uint16_t bound_port(int socket_fd) {
    struct sockaddr_storage address;
    socklen_t address_length = sizeof(address);
    CHECK(getsockname(socket_fd, (struct sockaddr *) &address,
                      &address_length) == 0,
          "getsockname failed: %s", strerror(errno));
    return ntohs(((struct sockaddr_in *) &address)->sin_port);
}

static void drain_socket(proxy *config, direction dir, int socket_fd) {
    uint8_t buffer[MAX_DATAGRAM];
    for (;;) {
        ssize_t length = recvfrom(socket_fd, buffer, sizeof(buffer), 0,
                                  NULL, NULL);
        if (length < 0) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
                return;
            }
            if (errno == EINTR) {
                return;
            }
            fprintf(stderr, "%s recvfrom failed: %s\n",
                    direction_name(dir), strerror(errno));
            return;
        }
        impair_and_queue(config, dir, buffer, (size_t) length);
    }
}

static void run_proxy(proxy *config) {
    struct sockaddr_storage listen_address;
    socklen_t listen_address_length;
    resolve_ipv4(config->listen_host, config->listen_port,
                 &listen_address, &listen_address_length);

    struct sockaddr_storage target_address;
    socklen_t target_address_length;
    resolve_ipv4(config->target_host, config->target_port,
                 &target_address, &target_address_length);

    // client_sock faces the HTTP/3 client; server_sock faces the quiche
    // server. Replies are sent from client_sock so the client sees a
    // consistent peer address (the proxy), hiding the real server.
    int client_sock = make_udp_socket();
    CHECK(bind(client_sock, (struct sockaddr *) &listen_address,
               listen_address_length) == 0,
          "failed to bind %s:%u: %s", config->listen_host,
          (unsigned) config->listen_port, strerror(errno));

    int server_sock = make_udp_socket();

    struct sockaddr_storage client_address;
    socklen_t client_address_length = sizeof(client_address);
    bool client_known = false;

    printf("config listen=%s:%u target=%s:%u seed=%" PRIu64
           " queue=%zu mtu=%u"
           " c2s(loss=%.2f%% dup=%.2f%% delay=%ums jitter=%ums"
           " reorder=%.2f%% reorder_ms=%ums)"
           " s2c(loss=%.2f%% dup=%.2f%% delay=%ums jitter=%ums"
           " reorder=%.2f%% reorder_ms=%ums)\n",
           config->listen_host, (unsigned) config->listen_port,
           config->target_host, (unsigned) config->target_port, config->seed,
           config->queue_capacity, (unsigned) config->mtu,
           config->directions[DIR_C2S].config.loss_pct,
           config->directions[DIR_C2S].config.dup_pct,
           config->directions[DIR_C2S].config.delay_ms,
           config->directions[DIR_C2S].config.jitter_ms,
           config->directions[DIR_C2S].config.reorder_pct,
           config->directions[DIR_C2S].config.reorder_ms,
           config->directions[DIR_S2C].config.loss_pct,
           config->directions[DIR_S2C].config.dup_pct,
           config->directions[DIR_S2C].config.delay_ms,
           config->directions[DIR_S2C].config.jitter_ms,
           config->directions[DIR_S2C].config.reorder_pct,
           config->directions[DIR_S2C].config.reorder_ms);
    printf("listening on %s:%u\n", config->listen_host,
           (unsigned) bound_port(client_sock));
    fflush(stdout);

    uint64_t start_ms = monotonic_ms();
    uint64_t deadline_ms = config->max_duration_sec > 0
        ? start_ms + (uint64_t) config->max_duration_sec * 1000
        : UINT64_MAX;
    uint64_t next_stats_ms = config->stats_interval_sec > 0
        ? start_ms + (uint64_t) config->stats_interval_sec * 1000
        : UINT64_MAX;

    while (!stop_requested) {
        uint64_t now = monotonic_ms();
        if (now >= deadline_ms) {
            break;
        }

        queue_release_due(config, DIR_C2S, server_sock,
                          &target_address, target_address_length);
        queue_release_due(config, DIR_S2C, client_sock,
                          client_known ? &client_address : NULL,
                          client_address_length);

        if (now >= next_stats_ms) {
            print_stats(config);
            next_stats_ms = now + (uint64_t) config->stats_interval_sec * 1000;
        }

        uint64_t wake_ms = deadline_ms;
        uint64_t release_ms;
        release_ms = queue_next_release_ms(&config->directions[DIR_C2S]);
        if (release_ms < wake_ms) {
            wake_ms = release_ms;
        }
        release_ms = queue_next_release_ms(&config->directions[DIR_S2C]);
        if (release_ms < wake_ms) {
            wake_ms = release_ms;
        }
        if (next_stats_ms < wake_ms) {
            wake_ms = next_stats_ms;
        }

        int timeout_ms = -1;
        if (wake_ms != UINT64_MAX) {
            now = monotonic_ms();
            timeout_ms = wake_ms <= now ? 0
                : (wake_ms - now > INT32_MAX ? INT32_MAX
                                             : (int) (wake_ms - now));
        }

        struct pollfd fds[2] = {
            { .fd = client_sock, .events = POLLIN },
            { .fd = server_sock, .events = POLLIN },
        };

        int ready = poll(fds, 2, timeout_ms);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "poll failed: %s\n", strerror(errno));
            break;
        }
        if (ready == 0) {
            continue;
        }

        if (fds[0].revents & POLLIN) {
            // Track the most recent client address so replies find the
            // current client even across successive client processes.
            uint8_t peek[MAX_DATAGRAM];
            struct sockaddr_storage source;
            socklen_t source_length = sizeof(source);
            ssize_t length = recvfrom(client_sock, peek, sizeof(peek),
                                      MSG_PEEK,
                                      (struct sockaddr *) &source,
                                      &source_length);
            if (length >= 0) {
                memcpy(&client_address, &source, source_length);
                client_address_length = source_length;
                client_known = true;
            }
            drain_socket(config, DIR_C2S, client_sock);
        }
        if (fds[1].revents & POLLIN) {
            drain_socket(config, DIR_S2C, server_sock);
        }
    }

    close(client_sock);
    close(server_sock);

    // Print before freeing so `queued` truthfully reports any datagrams that
    // were still pending when the proxy stopped. The driver asserts zero for
    // gated scenarios instead of mistaking cleanup for successful delivery.
    print_stats(config);

    for (direction dir = DIR_C2S; dir <= DIR_S2C; dir++) {
        direction_state *state = &config->directions[dir];
        for (size_t index = 0; index < state->queue_length; index++) {
            free(state->queue[index].data);
        }
        state->queue_length = 0;
    }

}

static double parse_percent(const char *option, const char *value) {
    char *end = NULL;
    double parsed = strtod(value, &end);
    CHECK(end != value && *end == '\0' && parsed >= 0.0 && parsed <= 100.0,
          "%s expects a percentage in [0, 100], got '%s'", option, value);
    return parsed;
}

static uint64_t parse_u64(const char *option, const char *value,
                          uint64_t maximum) {
    char *end = NULL;
    errno = 0;
    uint64_t parsed = strtoull(value, &end, 10);
    CHECK(errno == 0 && end != value && *end == '\0' && parsed <= maximum,
          "%s expects an integer in [0, %" PRIu64 "], got '%s'",
          option, maximum, value);
    return parsed;
}

static void usage(const char *program) {
    fprintf(stderr,
        "usage: %s --listen-port PORT --target-port PORT [options]\n"
        "       %s --probe-port PORT\n"
        "\n"
        "Relays UDP between a client and a target server, applying\n"
        "deterministic seeded impairments in both directions.\n"
        "\n"
        "required:\n"
        "  --listen-port PORT    UDP port the client connects to\n"
        "  --target-port PORT    UDP port of the real server\n"
        "\n"
        "addressing:\n"
        "  --listen-host ADDR    listen address (default 127.0.0.1)\n"
        "  --target-host ADDR    server address (default 127.0.0.1)\n"
        "\n"
        "determinism and bounds:\n"
        "  --seed N              impairment PRNG seed (default 1)\n"
        "  --queue N             per-direction delayed-packet queue capacity\n"
        "                        (default %d, max %d; overflow drops counted)\n"
        "  --max-duration SEC    graceful self-termination deadline\n"
        "                        (default %d, 0 disables)\n"
        "\n"
        "impairments (DIR is c2s or s2c):\n"
        "  --DIR-loss PCT        random packet loss, 0-100\n"
        "  --DIR-dup PCT         random duplication, 0-100\n"
        "  --DIR-delay MS        fixed delay added to every packet\n"
        "  --DIR-jitter MS       uniform extra delay in [0, MS]\n"
        "  --DIR-reorder PCT     probability of holding a packet back\n"
        "  --DIR-reorder-ms MS   reorder hold range in [1, MS] (default 30)\n"
        "  --mtu BYTES           drop datagrams larger than this (0 disables)\n"
        "\n"
        "diagnostics:\n"
        "  --stats-interval SEC  also print stats periodically (default off)\n"
        "  -v, --verbose         log every packet decision to stderr\n"
        "  --probe-port PORT     exit 0 if ADDR:PORT is bindable, 1 if busy\n"
        "  --probe-host ADDR     probe address (default 127.0.0.1)\n",
        program, program, DEFAULT_QUEUE_CAPACITY, MAX_QUEUE_CAPACITY,
        DEFAULT_MAX_DURATION_SEC);
}

int main(int argc, char *argv[]) {
    static const struct option options[] = {
        { "listen-host",     required_argument, NULL, 'H' },
        { "listen-port",     required_argument, NULL, 'p' },
        { "target-host",     required_argument, NULL, 'T' },
        { "target-port",     required_argument, NULL, 't' },
        { "seed",            required_argument, NULL, 's' },
        { "queue",           required_argument, NULL, 'q' },
        { "mtu",             required_argument, NULL, 'm' },
        { "max-duration",    required_argument, NULL, 'd' },
        { "stats-interval",  required_argument, NULL, 'i' },
        { "verbose",         no_argument,       NULL, 'v' },
        { "probe-port",      required_argument, NULL, 'P' },
        { "probe-host",      required_argument, NULL, 'B' },
        { "help",            no_argument,       NULL, 'h' },
        { "c2s-loss",        required_argument, NULL, 1000 },
        { "c2s-dup",         required_argument, NULL, 1001 },
        { "c2s-delay",       required_argument, NULL, 1002 },
        { "c2s-jitter",      required_argument, NULL, 1003 },
        { "c2s-reorder",     required_argument, NULL, 1004 },
        { "c2s-reorder-ms",  required_argument, NULL, 1005 },
        { "s2c-loss",        required_argument, NULL, 1006 },
        { "s2c-dup",         required_argument, NULL, 1007 },
        { "s2c-delay",       required_argument, NULL, 1008 },
        { "s2c-jitter",      required_argument, NULL, 1009 },
        { "s2c-reorder",     required_argument, NULL, 1010 },
        { "s2c-reorder-ms",  required_argument, NULL, 1011 },
        { NULL, 0, NULL, 0 },
    };

    proxy config = {
        .listen_host = "127.0.0.1",
        .listen_port = 0,
        .target_host = "127.0.0.1",
        .target_port = 0,
        .seed = 1,
        .queue_capacity = DEFAULT_QUEUE_CAPACITY,
        .mtu = 0,
        .max_duration_sec = DEFAULT_MAX_DURATION_SEC,
        .stats_interval_sec = 0,
        .verbose = false,
    };

    const char *probe_host = "127.0.0.1";
    uint64_t probe_port = 0;

    int option;
    while ((option = getopt_long(argc, argv, "hvp:H:t:T:s:q:m:d:i:P:B:",
                                 options, NULL)) != -1) {
        impairment_config *c2s = &config.directions[DIR_C2S].config;
        impairment_config *s2c = &config.directions[DIR_S2C].config;
        switch (option) {
            case 'H': config.listen_host = optarg; break;
            case 'p': config.listen_port = (uint16_t) parse_u64("--listen-port", optarg, 65535); break;
            case 'T': config.target_host = optarg; break;
            case 't': config.target_port = (uint16_t) parse_u64("--target-port", optarg, 65535); break;
            case 's': config.seed = parse_u64("--seed", optarg, UINT64_MAX); break;
            case 'q': config.queue_capacity = (size_t) parse_u64("--queue", optarg, MAX_QUEUE_CAPACITY); break;
            case 'm': config.mtu = (uint16_t) parse_u64("--mtu", optarg, 65535); break;
            case 'd': config.max_duration_sec = (uint32_t) parse_u64("--max-duration", optarg, 86400); break;
            case 'i': config.stats_interval_sec = (uint32_t) parse_u64("--stats-interval", optarg, 86400); break;
            case 'v': config.verbose = true; break;
            case 'P': probe_port = parse_u64("--probe-port", optarg, 65535); break;
            case 'B': probe_host = optarg; break;
            case 'h': usage(argv[0]); return 0;
            case 1000: c2s->loss_pct = parse_percent("--c2s-loss", optarg); break;
            case 1001: c2s->dup_pct = parse_percent("--c2s-dup", optarg); break;
            case 1002: c2s->delay_ms = (uint32_t) parse_u64("--c2s-delay", optarg, 60000); break;
            case 1003: c2s->jitter_ms = (uint32_t) parse_u64("--c2s-jitter", optarg, 60000); break;
            case 1004: c2s->reorder_pct = parse_percent("--c2s-reorder", optarg); break;
            case 1005: c2s->reorder_ms = (uint32_t) parse_u64("--c2s-reorder-ms", optarg, 60000); break;
            case 1006: s2c->loss_pct = parse_percent("--s2c-loss", optarg); break;
            case 1007: s2c->dup_pct = parse_percent("--s2c-dup", optarg); break;
            case 1008: s2c->delay_ms = (uint32_t) parse_u64("--s2c-delay", optarg, 60000); break;
            case 1009: s2c->jitter_ms = (uint32_t) parse_u64("--s2c-jitter", optarg, 60000); break;
            case 1010: s2c->reorder_pct = parse_percent("--s2c-reorder", optarg); break;
            case 1011: s2c->reorder_ms = (uint32_t) parse_u64("--s2c-reorder-ms", optarg, 60000); break;
            default: usage(argv[0]); return 2;
        }
    }

    if (probe_port > 0) {
        struct sockaddr_storage address;
        socklen_t address_length;
        resolve_ipv4(probe_host, (uint16_t) probe_port, &address,
                     &address_length);
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        CHECK(fd >= 0, "socket failed: %s", strerror(errno));
        if (bind(fd, (struct sockaddr *) &address, address_length) == 0) {
            close(fd);
            printf("%s:%" PRIu64 " free\n", probe_host, probe_port);
            return 0;
        }
        int bind_errno = errno;
        close(fd);
        if (bind_errno == EADDRINUSE) {
            printf("%s:%" PRIu64 " busy\n", probe_host, probe_port);
            return 1;
        }
        fprintf(stderr, "probe bind failed: %s\n", strerror(bind_errno));
        return 2;
    }

    if (config.listen_port == 0 || config.target_port == 0) {
        usage(argv[0]);
        return 2;
    }
    CHECK(config.queue_capacity >= 1, "--queue must be at least 1");

    // Distinct PRNG streams per direction so impairment decisions depend
    // only on the seed and that direction's packet sequence, not on how
    // the two directions happen to interleave in real time.
    config.directions[DIR_C2S].prng_state = config.seed;
    config.directions[DIR_S2C].prng_state =
        config.seed ^ 0x9e3779b97f4a7c15ULL;

    for (direction dir = DIR_C2S; dir <= DIR_S2C; dir++) {
        config.directions[dir].queue_capacity = config.queue_capacity;
        config.directions[dir].queue =
            calloc(config.queue_capacity, sizeof(queued_packet));
        CHECK(config.directions[dir].queue != NULL,
              "out of memory allocating packet queue");
    }

    struct sigaction action = { .sa_handler = handle_signal };
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    run_proxy(&config);

    free(config.directions[DIR_C2S].queue);
    free(config.directions[DIR_S2C].queue);
    return 0;
}
