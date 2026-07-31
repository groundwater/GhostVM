#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int parse_u16(const char *text, uint16_t *value) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed > UINT16_MAX) {
        return -1;
    }
    *value = (uint16_t) parsed;
    return 0;
}

static int parse_size(const char *text, size_t *value) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed == 0 ||
        parsed > 65507UL) {
        return -1;
    }
    *value = (size_t) parsed;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s IPV4 PORT BYTES\n", argv[0]);
        return 2;
    }

    uint16_t port = 0;
    size_t payload_size = 0;
    if (parse_u16(argv[2], &port) != 0 || port == 0 ||
        parse_size(argv[3], &payload_size) != 0) {
        fprintf(stderr, "invalid port or datagram size\n");
        return 2;
    }

    struct sockaddr_in destination = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
    };
    if (inet_pton(AF_INET, argv[1], &destination.sin_addr) != 1) {
        fprintf(stderr, "invalid IPv4 address: %s\n", argv[1]);
        return 2;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    uint8_t *payload = calloc(payload_size, 1);
    if (payload == NULL) {
        perror("calloc");
        close(fd);
        return 1;
    }

    ssize_t sent = sendto(fd, payload, payload_size, 0,
        (const struct sockaddr *) &destination, sizeof(destination));
    if (sent < 0 || (size_t) sent != payload_size) {
        if (sent < 0) {
            perror("sendto");
        } else {
            fprintf(stderr, "short UDP send: %zd of %zu bytes\n", sent,
                payload_size);
        }
        free(payload);
        close(fd);
        return 1;
    }

    free(payload);
    close(fd);
    return 0;
}
