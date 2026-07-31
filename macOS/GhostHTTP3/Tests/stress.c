// Exercises the packaged GhostHTTP3/quiche library without a TCP or HTTP/1.x
// fallback. Two HTTP/3 endpoints exchange QUIC datagrams in memory so the
// test is deterministic while still traversing TLS, QUIC, QPACK, and RFC 9114.

#include <GhostHTTP3/GhostHTTP3.h>

#include <arpa/inet.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CID_LEN 16
#define DATAGRAM_CAPACITY 65535
#define WIRE_DATAGRAM_CAPACITY 2048
#define REORDER_BATCH_SIZE 4
#define MAX_REQUESTS 256
#define BODY_CHUNK 16384
#define FAST_REQUEST_COUNT 96
#define LARGE_REQUEST_COUNT 16
#define LARGE_BODY_LENGTH (512 * 1024)
#define CANCEL_BODY_LENGTH (32 * 1024 * 1024)
// RFC 9114 §4.2 error codes for the wire-level application close that quiche
// raises when a peer exceeds SETTINGS_MAX_FIELD_SECTION_SIZE: the QPACK
// decoder reports HeaderListTooLarge and the h3 layer converts that to
// Error::ExcessiveLoad, surfaced as a CONNECTION_CLOSE error code on the
// wire. Used to verify rejection rather than "no crash" only.
#define H3_EXCESSIVE_LOAD_ERROR 0x107
#define H3_REQUEST_CANCELLED_ERROR 0x10c
#define SERVER_RESET_ERROR 0x201
#define CONNECTION_CLOSE_ERROR 0x102
#define STREAM_LIMIT_TEST_COUNT 4
#define MAX_FIELD_SECTION_SIZE_LIMIT 128

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: "); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        exit(1); \
    } \
} while (0)

typedef struct {
    quiche_conn *quic;
    quiche_h3_conn *h3;
    struct sockaddr_storage local;
    socklen_t local_len;
    struct sockaddr_storage peer;
    socklen_t peer_len;
} endpoint;

typedef struct {
    endpoint client;
    endpoint server;
    quiche_config *client_config;
    quiche_config *server_config;
    quiche_h3_config *client_h3_config;
    quiche_h3_config *server_h3_config;
    size_t datagrams;
    bool reorder_datagrams;
    size_t reordered_batches;
} test_pair;

typedef struct {
    uint8_t bytes[WIRE_DATAGRAM_CAPACITY];
    size_t length;
    quiche_send_info send_info;
} queued_packet;

typedef struct {
    uint64_t stream_id;
    char path[16384];
    bool headers_sent;
    bool finished;
    bool abandoned;
    bool server_reset_after_partial;
    bool server_reset_sent;
    size_t body_length;
    size_t body_sent;
    uint8_t seed;
} server_response;

typedef struct {
    server_response responses[MAX_REQUESTS];
    size_t response_count;
    int64_t paused_stream;
    bool paused_released;
    bool goaway_sent;
    size_t reset_count;
} server_state;

typedef struct {
    uint64_t stream_id;
    char path[128];
    size_t expected_length;
    size_t body_received;
    uint8_t seed;
    int status;
    bool saw_headers;
    bool finished;
    bool cancel_on_headers;
    bool cancellation_sent;
    bool expect_server_reset;
    bool saw_reset;
} client_request;

typedef struct {
    client_request requests[MAX_REQUESTS];
    size_t request_count;
    bool saw_goaway;
} client_state;

typedef struct {
    char path[16384];
    int status;
    size_t content_length;
    bool saw_path;
    bool saw_status;
    bool saw_content_length;
} parsed_headers;

static void make_address(struct sockaddr_storage *storage, socklen_t *length,
                         uint16_t port) {
    struct sockaddr_in *address = (struct sockaddr_in *) storage;
    memset(storage, 0, sizeof(*storage));
    address->sin_family = AF_INET;
    address->sin_port = htons(port);
    address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    *length = sizeof(*address);
}

static quiche_config *make_config_with_stream_limit(bool server,
                                                     const char *cert_path,
                                                     const char *key_path,
                                                     uint64_t max_streams_bidi) {
    quiche_config *config = quiche_config_new(QUICHE_PROTOCOL_VERSION);
    CHECK(config != NULL, "could not create QUIC config");
    CHECK(quiche_config_set_application_protos(
              config, (const uint8_t *) QUICHE_H3_APPLICATION_PROTOCOL,
              sizeof(QUICHE_H3_APPLICATION_PROTOCOL) - 1) == 0,
          "could not configure h3 ALPN");

    if (server) {
        CHECK(quiche_config_load_cert_chain_from_pem_file(config, cert_path) == 0,
              "could not load test certificate at %s", cert_path);
        CHECK(quiche_config_load_priv_key_from_pem_file(config, key_path) == 0,
              "could not load test private key at %s", key_path);
    } else {
        quiche_config_verify_peer(config, false);
    }

    quiche_config_set_max_idle_timeout(config, 30000);
    quiche_config_set_max_recv_udp_payload_size(config, 1350);
    quiche_config_set_max_send_udp_payload_size(config, 1350);
    quiche_config_set_initial_max_data(config, 64 * 1024 * 1024);
    quiche_config_set_initial_max_stream_data_bidi_local(config, 2 * 1024 * 1024);
    quiche_config_set_initial_max_stream_data_bidi_remote(config, 2 * 1024 * 1024);
    quiche_config_set_initial_max_stream_data_uni(config, 2 * 1024 * 1024);
    quiche_config_set_initial_max_streams_bidi(config, max_streams_bidi);
    quiche_config_set_initial_max_streams_uni(config, 16);
    quiche_config_set_disable_active_migration(config, true);
    return config;
}

static quiche_config *make_config(bool server, const char *cert_path,
                                  const char *key_path) {
    return make_config_with_stream_limit(server, cert_path, key_path, MAX_REQUESTS);
}

static ssize_t deliver_first_client_packet(test_pair *pair, uint8_t *packet,
                                           quiche_send_info *send_info) {
    ssize_t length = quiche_conn_send(pair->client.quic, packet,
                                      DATAGRAM_CAPACITY, send_info);
    CHECK(length > 0, "client did not produce an Initial packet: %zd", length);

    uint32_t version = 0;
    uint8_t type = 0;
    uint8_t scid[QUICHE_MAX_CONN_ID_LEN];
    uint8_t dcid[QUICHE_MAX_CONN_ID_LEN];
    uint8_t token[256];
    size_t scid_len = sizeof(scid);
    size_t dcid_len = sizeof(dcid);
    size_t token_len = sizeof(token);
    CHECK(quiche_header_info(packet, (size_t) length, CID_LEN, &version, &type,
                             scid, &scid_len, dcid, &dcid_len,
                             token, &token_len) == 0,
          "could not parse client Initial packet");

    uint8_t server_scid[CID_LEN];
    for (size_t i = 0; i < sizeof(server_scid); i++) {
        server_scid[i] = (uint8_t) (0xa0 + i);
    }
    pair->server.quic = quiche_accept(
        server_scid, sizeof(server_scid), dcid, dcid_len,
        (const struct sockaddr *) &pair->server.local, pair->server.local_len,
        (const struct sockaddr *) &pair->server.peer, pair->server.peer_len,
        pair->server_config);
    CHECK(pair->server.quic != NULL, "could not create server QUIC connection");

    quiche_recv_info receive_info = {
        .from = (struct sockaddr *) &send_info->from,
        .from_len = send_info->from_len,
        .to = (struct sockaddr *) &send_info->to,
        .to_len = send_info->to_len,
    };
    CHECK(quiche_conn_recv(pair->server.quic, packet, (size_t) length,
                           &receive_info) == length,
          "server rejected client Initial packet");
    pair->datagrams++;
    return length;
}

static void deliver_packet(endpoint *to, queued_packet *packet) {
    quiche_recv_info receive_info = {
        .from = (struct sockaddr *) &packet->send_info.from,
        .from_len = packet->send_info.from_len,
        .to = (struct sockaddr *) &packet->send_info.to,
        .to_len = packet->send_info.to_len,
    };
    ssize_t accepted = quiche_conn_recv(to->quic, packet->bytes,
                                        packet->length, &receive_info);
    CHECK(accepted == (ssize_t) packet->length,
          "peer rejected QUIC packet: %zd", accepted);
}

static size_t transfer(endpoint *from, endpoint *to, bool reorder,
                       size_t *reordered_batches) {
    size_t transferred = 0;
    for (;;) {
        queued_packet batch[REORDER_BATCH_SIZE];
        size_t batch_count = 0;
        while (batch_count < REORDER_BATCH_SIZE) {
            queued_packet *packet = &batch[batch_count];
            ssize_t length = quiche_conn_send(
                from->quic, packet->bytes, sizeof(packet->bytes),
                &packet->send_info);
            if (length == QUICHE_ERR_DONE) {
                break;
            }
            CHECK(length > 0, "QUIC packet generation failed: %zd", length);
            packet->length = (size_t) length;
            batch_count++;
        }
        if (batch_count == 0) {
            break;
        }
        if (reorder && batch_count > 1) {
            for (size_t i = batch_count; i > 0; i--) {
                deliver_packet(to, &batch[i - 1]);
            }
            (*reordered_batches)++;
        } else {
            for (size_t i = 0; i < batch_count; i++) {
                deliver_packet(to, &batch[i]);
            }
        }
        transferred += batch_count;
        CHECK(transferred < 100000, "QUIC transfer loop did not quiesce");
    }
    return transferred;
}

static size_t pump_transport(test_pair *pair) {
    size_t total = 0;
    for (size_t round = 0; round < 10000; round++) {
        size_t moved = transfer(&pair->client, &pair->server,
                                pair->reorder_datagrams,
                                &pair->reordered_batches);
        moved += transfer(&pair->server, &pair->client,
                          pair->reorder_datagrams,
                          &pair->reordered_batches);
        total += moved;
        if (moved == 0) {
            pair->datagrams += total;
            return total;
        }
    }
    CHECK(false, "QUIC transport did not quiesce");
    return 0;
}

static void assert_h3_alpn(endpoint *value, const char *side) {
    const uint8_t *protocol = NULL;
    size_t protocol_length = 0;
    quiche_conn_application_proto(value->quic, &protocol, &protocol_length);
    CHECK(protocol_length == 2 && memcmp(protocol, "h3", 2) == 0,
          "%s negotiated unexpected ALPN", side);
}

static void pair_create_internal(test_pair *pair, const char *cert_path,
                                  const char *key_path,
                                  uint64_t server_max_streams_bidi,
                                  uint64_t max_field_section_size,
                                  uint16_t client_port) {
    memset(pair, 0, sizeof(*pair));
    make_address(&pair->client.local, &pair->client.local_len, client_port);
    make_address(&pair->client.peer, &pair->client.peer_len, client_port + 1);
    pair->server.local = pair->client.peer;
    pair->server.local_len = pair->client.peer_len;
    pair->server.peer = pair->client.local;
    pair->server.peer_len = pair->client.local_len;

    pair->client_config = make_config(false, cert_path, key_path);
    pair->server_config = make_config_with_stream_limit(
        true, cert_path, key_path, server_max_streams_bidi);

    uint8_t client_scid[CID_LEN];
    for (size_t i = 0; i < sizeof(client_scid); i++) {
        client_scid[i] = (uint8_t) (0x10 + i);
    }
    pair->client.quic = quiche_connect(
        "localhost", client_scid, sizeof(client_scid),
        (const struct sockaddr *) &pair->client.local, pair->client.local_len,
        (const struct sockaddr *) &pair->client.peer, pair->client.peer_len,
        pair->client_config);
    CHECK(pair->client.quic != NULL, "could not create client QUIC connection");

    uint8_t first_packet[DATAGRAM_CAPACITY];
    quiche_send_info first_send_info;
    deliver_first_client_packet(pair, first_packet, &first_send_info);

    for (size_t round = 0; round < 1000; round++) {
        pump_transport(pair);
        if (quiche_conn_is_established(pair->client.quic) &&
            quiche_conn_is_established(pair->server.quic)) {
            break;
        }
    }
    CHECK(quiche_conn_is_established(pair->client.quic),
          "client QUIC handshake did not complete");
    CHECK(quiche_conn_is_established(pair->server.quic),
          "server QUIC handshake did not complete");
    assert_h3_alpn(&pair->client, "client");
    assert_h3_alpn(&pair->server, "server");

    pair->client_h3_config = quiche_h3_config_new();
    pair->server_h3_config = quiche_h3_config_new();
    CHECK(pair->client_h3_config != NULL && pair->server_h3_config != NULL,
          "could not create HTTP/3 configs");
    quiche_h3_config_set_qpack_max_table_capacity(pair->client_h3_config, 4096);
    quiche_h3_config_set_qpack_blocked_streams(pair->client_h3_config, 100);
    quiche_h3_config_set_qpack_max_table_capacity(pair->server_h3_config, 4096);
    quiche_h3_config_set_qpack_blocked_streams(pair->server_h3_config, 100);
    if (max_field_section_size > 0) {
        quiche_h3_config_set_max_field_section_size(
            pair->server_h3_config, max_field_section_size);
    }

    pair->client.h3 = quiche_h3_conn_new_with_transport(
        pair->client.quic, pair->client_h3_config);
    pair->server.h3 = quiche_h3_conn_new_with_transport(
        pair->server.quic, pair->server_h3_config);
    CHECK(pair->client.h3 != NULL && pair->server.h3 != NULL,
          "could not create HTTP/3 connections");
    pump_transport(pair);
}

static void pair_create(test_pair *pair, const char *cert_path,
                        const char *key_path) {
    pair_create_internal(pair, cert_path, key_path, MAX_REQUESTS, 0, 41000);
}

static void pair_free(test_pair *pair) {
    quiche_h3_conn_free(pair->client.h3);
    quiche_h3_conn_free(pair->server.h3);
    quiche_conn_free(pair->client.quic);
    quiche_conn_free(pair->server.quic);
    quiche_h3_config_free(pair->client_h3_config);
    quiche_h3_config_free(pair->server_h3_config);
    quiche_config_free(pair->client_config);
    quiche_config_free(pair->server_config);
}

static int parse_header(uint8_t *name, size_t name_length, uint8_t *value,
                        size_t value_length, void *context) {
    parsed_headers *headers = context;
    if (name_length == 5 && memcmp(name, ":path", 5) == 0) {
        CHECK(value_length < sizeof(headers->path), "request path is too large");
        memcpy(headers->path, value, value_length);
        headers->path[value_length] = '\0';
        headers->saw_path = true;
    } else if (name_length == 7 && memcmp(name, ":status", 7) == 0) {
        char status[4] = {0};
        CHECK(value_length == 3, "malformed :status value");
        memcpy(status, value, value_length);
        headers->status = atoi(status);
        headers->saw_status = true;
    } else if (name_length == 14 &&
               memcmp(name, "content-length", 14) == 0) {
        char length[32] = {0};
        CHECK(value_length < sizeof(length), "content-length is too large");
        memcpy(length, value, value_length);
        headers->content_length = (size_t) strtoull(length, NULL, 10);
        headers->saw_content_length = true;
    }
    return 0;
}

static uint8_t body_byte(uint8_t seed, size_t offset) {
    return (uint8_t) (seed + (offset * 31u) + (offset >> 8));
}

static server_response *server_find(server_state *state, uint64_t stream_id) {
    for (size_t i = 0; i < state->response_count; i++) {
        if (state->responses[i].stream_id == stream_id) {
            return &state->responses[i];
        }
    }
    return NULL;
}

static server_response *server_add(server_state *state, uint64_t stream_id,
                                   const char *path) {
    CHECK(state->response_count < MAX_REQUESTS, "too many server requests");
    server_response *response = &state->responses[state->response_count++];
    memset(response, 0, sizeof(*response));
    response->stream_id = stream_id;
    CHECK(strlen(path) < sizeof(response->path), "server path overflow");
    strcpy(response->path, path);
    return response;
}

static void configure_server_response(server_state *state,
                                      server_response *response) {
    unsigned index = 0;
    if (strcmp(response->path, "/paused") == 0) {
        state->paused_stream = (int64_t) response->stream_id;
        response->body_length = 11;
        response->seed = 0x71;
        return;
    }
    if (strcmp(response->path, "/empty") == 0) {
        response->body_length = 0;
        response->seed = 0;
        return;
    }
    if (strcmp(response->path, "/cancel") == 0) {
        response->body_length = CANCEL_BODY_LENGTH;
        response->seed = 0xc1;
        return;
    }
    if (strcmp(response->path, "/server-reset") == 0) {
        response->body_length = LARGE_BODY_LENGTH;
        response->seed = 0xd1;
        response->server_reset_after_partial = true;
        return;
    }
    if (sscanf(response->path, "/fast/%u", &index) == 1) {
        response->body_length = 257 + (index % 127);
        response->seed = (uint8_t) index;
        return;
    }
    if (sscanf(response->path, "/large/%u", &index) == 1) {
        response->body_length = LARGE_BODY_LENGTH;
        response->seed = (uint8_t) (0x40 + index);
        return;
    }
    CHECK(false, "server received unknown path: %s", response->path);
}

static bool send_response_headers(test_pair *pair, server_response *response) {
    char length[32];
    snprintf(length, sizeof(length), "%zu", response->body_length);
    const char *status = response->body_length == 0 ? "204" : "200";
    quiche_h3_header headers[] = {
        {(const uint8_t *) ":status", 7,
         (const uint8_t *) status, strlen(status)},
        {(const uint8_t *) "content-length", 14,
         (const uint8_t *) length, strlen(length)},
        {(const uint8_t *) "server", 6,
         (const uint8_t *) "ghost-http3-stress", 18},
    };
    int result = quiche_h3_send_response(
        pair->server.h3, pair->server.quic, response->stream_id,
        headers, sizeof(headers) / sizeof(headers[0]),
        response->body_length == 0);
    if (result == QUICHE_H3_ERR_DONE ||
        result == QUICHE_H3_ERR_STREAM_BLOCKED) {
        return false;
    }
    CHECK(result == 0, "could not send response headers on stream %" PRIu64
          ": %d", response->stream_id, result);
    response->headers_sent = true;
    response->finished = response->body_length == 0;
    return true;
}

static void server_poll(test_pair *pair, server_state *state) {
    for (size_t count = 0; count < 10000; count++) {
        quiche_h3_event *event = NULL;
        int64_t stream_id = quiche_h3_conn_poll(
            pair->server.h3, pair->server.quic, &event);
        if (stream_id < 0) {
            return;
        }

        switch (quiche_h3_event_type(event)) {
        case QUICHE_H3_EVENT_HEADERS: {
            parsed_headers headers = {0};
            CHECK(quiche_h3_event_for_each_header(event, parse_header,
                                                   &headers) == 0,
                  "could not parse request headers");
            CHECK(headers.saw_path, "request omitted :path");
            if (server_find(state, (uint64_t) stream_id) == NULL) {
                server_response *response = server_add(
                    state, (uint64_t) stream_id, headers.path);
                configure_server_response(state, response);
            }
            break;
        }
        case QUICHE_H3_EVENT_DATA: {
            uint8_t discard[4096];
            while (quiche_h3_recv_body(pair->server.h3, pair->server.quic,
                                       (uint64_t) stream_id, discard,
                                       sizeof(discard)) > 0) {}
            break;
        }
        case QUICHE_H3_EVENT_RESET:
            state->reset_count++;
            break;
        case QUICHE_H3_EVENT_FINISHED:
        case QUICHE_H3_EVENT_GOAWAY:
        case QUICHE_H3_EVENT_PRIORITY_UPDATE:
            break;
        }
        quiche_h3_event_free(event);
    }
    CHECK(false, "server HTTP/3 event loop did not quiesce");
}

static void server_flush(test_pair *pair, server_state *state) {
    uint8_t body[BODY_CHUNK];
    for (size_t i = 0; i < state->response_count; i++) {
        server_response *response = &state->responses[i];
        if (response->finished || response->abandoned) {
            continue;
        }
        if (!response->headers_sent) {
            if ((int64_t) response->stream_id == state->paused_stream &&
                !state->paused_released) {
                continue;
            }
            if (!send_response_headers(pair, response)) {
                continue;
            }
            if (response->finished) {
                continue;
            }
        }

        if (response->server_reset_after_partial && !response->server_reset_sent) {
            if (response->body_sent >= BODY_CHUNK) {
                int result = quiche_conn_stream_shutdown(
                    pair->server.quic, response->stream_id,
                    QUICHE_SHUTDOWN_WRITE, SERVER_RESET_ERROR);
                CHECK(result == 0, "server stream reset failed on %" PRIu64
                      ": %d", response->stream_id, result);
                response->server_reset_sent = true;
                response->abandoned = true;
                state->reset_count++;
                continue;
            }
        }

        size_t remaining = response->body_length - response->body_sent;
        size_t length = remaining < sizeof(body) ? remaining : sizeof(body);
        for (size_t j = 0; j < length; j++) {
            body[j] = body_byte(response->seed, response->body_sent + j);
        }
        bool final = length == remaining;
        ssize_t sent = quiche_h3_send_body(
            pair->server.h3, pair->server.quic, response->stream_id,
            body, length, final);
        if (sent == QUICHE_H3_ERR_DONE || sent == QUICHE_H3_ERR_STREAM_BLOCKED) {
            continue;
        }
        if (sent == QUICHE_H3_TRANSPORT_ERR_STREAM_STOPPED ||
            sent == QUICHE_H3_TRANSPORT_ERR_STREAM_RESET) {
            response->abandoned = true;
            state->reset_count++;
            continue;
        }
        CHECK(sent > 0, "body send failed on stream %" PRIu64 ": %zd",
              response->stream_id, sent);
        response->body_sent += (size_t) sent;
        if (response->body_sent == response->body_length) {
            response->finished = true;
        }
    }
}

static client_request *client_find(client_state *state, uint64_t stream_id) {
    for (size_t i = 0; i < state->request_count; i++) {
        if (state->requests[i].stream_id == stream_id) {
            return &state->requests[i];
        }
    }
    return NULL;
}

static size_t client_send(test_pair *pair, client_state *state,
                          const char *path, size_t expected_length,
                          uint8_t seed, bool cancel_on_headers,
                          bool padded_headers, bool expect_server_reset) {
    CHECK(state->request_count < MAX_REQUESTS, "too many client requests");
    static uint8_t padding[12 * 1024];
    static bool padding_ready = false;
    if (!padding_ready) {
        memset(padding, 'p', sizeof(padding));
        padding_ready = true;
    }
    quiche_h3_header headers[] = {
        {(const uint8_t *) ":method", 7, (const uint8_t *) "GET", 3},
        {(const uint8_t *) ":scheme", 7, (const uint8_t *) "https", 5},
        {(const uint8_t *) ":authority", 10,
         (const uint8_t *) "ghostfile.test", 14},
        {(const uint8_t *) ":path", 5,
         (const uint8_t *) path, strlen(path)},
        {(const uint8_t *) "user-agent", 10,
         (const uint8_t *) "ghost-http3-stress", 18},
        {(const uint8_t *) "x-ghost-padding", 15,
         padding, padded_headers ? sizeof(padding) : 0},
    };
    size_t header_count = padded_headers ? 6 : 5;
    int64_t stream_id = quiche_h3_send_request(
        pair->client.h3, pair->client.quic, headers, header_count, true);
    CHECK(stream_id >= 0, "could not send %s: %" PRId64, path, stream_id);

    size_t index = state->request_count++;
    client_request *request = &state->requests[index];
    memset(request, 0, sizeof(*request));
    request->stream_id = (uint64_t) stream_id;
    snprintf(request->path, sizeof(request->path), "%s", path);
    request->expected_length = expected_length;
    request->seed = seed;
    request->cancel_on_headers = cancel_on_headers;
    request->expect_server_reset = expect_server_reset;
    return index;
}

static void client_poll(test_pair *pair, client_state *state) {
    for (size_t count = 0; count < 10000; count++) {
        quiche_h3_event *event = NULL;
        int64_t stream_id = quiche_h3_conn_poll(
            pair->client.h3, pair->client.quic, &event);
        if (stream_id < 0) {
            return;
        }

        if (quiche_h3_event_type(event) == QUICHE_H3_EVENT_GOAWAY) {
            state->saw_goaway = true;
            quiche_h3_event_free(event);
            continue;
        }

        client_request *request = client_find(state, (uint64_t) stream_id);
        CHECK(request != NULL, "event for unknown client stream %" PRId64,
              stream_id);

        switch (quiche_h3_event_type(event)) {
        case QUICHE_H3_EVENT_HEADERS: {
            parsed_headers headers = {0};
            CHECK(quiche_h3_event_for_each_header(event, parse_header,
                                                   &headers) == 0,
                  "could not parse response headers");
            CHECK(headers.saw_status && headers.saw_content_length,
                  "response omitted required headers on %s", request->path);
            if (!request->expect_server_reset) {
                CHECK(headers.content_length == request->expected_length,
                      "content-length mismatch on %s: %zu != %zu",
                      request->path, headers.content_length,
                      request->expected_length);
            }
            request->status = headers.status;
            request->saw_headers = true;
            if (request->cancel_on_headers && !request->cancellation_sent) {
                int result = quiche_conn_stream_shutdown(
                    pair->client.quic, request->stream_id,
                    QUICHE_SHUTDOWN_READ, H3_REQUEST_CANCELLED_ERROR);
                CHECK(result == 0, "could not cancel stream %" PRIu64 ": %d",
                      request->stream_id, result);
                request->cancellation_sent = true;
            }
            break;
        }
        case QUICHE_H3_EVENT_DATA: {
            if (request->cancellation_sent) {
                break;
            }
            uint8_t body[32768];
            for (;;) {
                ssize_t received = quiche_h3_recv_body(
                    pair->client.h3, pair->client.quic, request->stream_id,
                    body, sizeof(body));
                if (received <= 0) {
                    break;
                }
                if (!request->expect_server_reset) {
                    for (ssize_t i = 0; i < received; i++) {
                        uint8_t expected = body_byte(
                            request->seed, request->body_received + (size_t) i);
                        CHECK(body[i] == expected,
                              "body corruption on %s at offset %zu",
                              request->path,
                              request->body_received + (size_t) i);
                    }
                }
                request->body_received += (size_t) received;
                CHECK(request->body_received <= request->expected_length,
                      "body overflow on %s", request->path);
            }
            break;
        }
        case QUICHE_H3_EVENT_FINISHED:
            CHECK(request->saw_headers, "stream finished before headers: %s",
                  request->path);
            CHECK(request->body_received == request->expected_length,
                  "short body on %s: %zu != %zu", request->path,
                  request->body_received, request->expected_length);
            request->finished = true;
            break;
        case QUICHE_H3_EVENT_RESET:
            CHECK(request->cancellation_sent || request->expect_server_reset,
                  "unexpected reset on %s", request->path);
            request->saw_reset = true;
            break;
        case QUICHE_H3_EVENT_GOAWAY:
        case QUICHE_H3_EVENT_PRIORITY_UPDATE:
            break;
        }
        quiche_h3_event_free(event);
    }
    CHECK(false, "client HTTP/3 event loop did not quiesce");
}

static void drive_round(test_pair *pair, server_state *server,
                        client_state *client) {
    pump_transport(pair);
    server_poll(pair, server);
    server_flush(pair, server);
    pump_transport(pair);
    client_poll(pair, client);
}

static bool requests_finished(client_state *state, size_t first, size_t count) {
    for (size_t i = first; i < first + count; i++) {
        if (!state->requests[i].finished) {
            return false;
        }
    }
    return true;
}

static void drive_until_finished(test_pair *pair, server_state *server,
                                 client_state *client, size_t first,
                                 size_t count, const char *label) {
    for (size_t round = 0; round < 200000; round++) {
        drive_round(pair, server, client);
        if (requests_finished(client, first, count)) {
            return;
        }
        CHECK(!quiche_conn_is_closed(pair->client.quic) &&
              !quiche_conn_is_closed(pair->server.quic),
              "connection closed during %s", label);
    }
    CHECK(false, "%s timed out", label);
}

int main(int argc, char **argv) {
    CHECK(argc == 3, "usage: %s cert.crt cert.key", argv[0]);
    CHECK(ghost_http3_backend_is_ready(), "GhostHTTP3 backend is not ready");

    test_pair pair;
    server_state server = {.paused_stream = -1};
    client_state client = {0};
    pair_create(&pair, argv[1], argv[2]);
    printf("PASS handshake: TLS over QUIC negotiated ALPN h3\n");
    pair.reorder_datagrams = true;

    size_t empty = client_send(&pair, &client, "/empty", 0, 0,
                               false, true, false);
    drive_until_finished(&pair, &server, &client, empty, 1,
                         "empty response and oversized request headers");
    CHECK(client.requests[empty].status == 204,
          "empty response had status %d", client.requests[empty].status);
    printf("PASS edge headers: 12 KiB header block and zero-byte 204 response\n");

    size_t paused = client_send(&pair, &client, "/paused", 11, 0x71,
                                false, false, false);
    size_t fast_first = client.request_count;
    for (unsigned i = 0; i < FAST_REQUEST_COUNT; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/fast/%u", i);
        client_send(&pair, &client, path, 257 + (i % 127), (uint8_t) i,
                    false, (i % 19) == 0, false);
        if ((i % 8) == 7) {
            drive_round(&pair, &server, &client);
        }
    }
    drive_until_finished(&pair, &server, &client, fast_first,
                         FAST_REQUEST_COUNT, "multiplexed fast requests");
    CHECK(server.paused_stream == (int64_t) client.requests[paused].stream_id,
          "server did not observe the paused stream");
    CHECK(!client.requests[paused].saw_headers &&
          !client.requests[paused].finished,
          "paused request unexpectedly completed before fast requests");
    printf("PASS multiplexing: %d requests completed while an earlier stream was paused\n",
           FAST_REQUEST_COUNT);

    server.paused_released = true;
    drive_until_finished(&pair, &server, &client, paused, 1,
                         "released paused request");
    printf("PASS stream resumption: paused request completed after release\n");

    size_t large_first = client.request_count;
    for (unsigned i = 0; i < LARGE_REQUEST_COUNT; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/large/%u", i);
        client_send(&pair, &client, path, LARGE_BODY_LENGTH,
                    (uint8_t) (0x40 + i), false, false, false);
        if ((i % 8) == 7) {
            drive_round(&pair, &server, &client);
        }
    }
    drive_until_finished(&pair, &server, &client, large_first,
                         LARGE_REQUEST_COUNT, "parallel large bodies");
    printf("PASS parallel bodies: %d x %d KiB verified byte-for-byte\n",
           LARGE_REQUEST_COUNT, LARGE_BODY_LENGTH / 1024);

    size_t cancelled = client_send(&pair, &client, "/cancel",
                                    CANCEL_BODY_LENGTH, 0xc1, true, false,
                                    false);
    size_t post_cancel_first = client.request_count;
    for (unsigned i = 1000; i < 1016; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/fast/%u", i);
        client_send(&pair, &client, path, 257 + (i % 127), (uint8_t) i,
                    false, false, false);
        if ((i % 8) == 7) {
            drive_round(&pair, &server, &client);
        }
    }
    drive_until_finished(&pair, &server, &client, post_cancel_first, 16,
                         "requests after cancellation");
    CHECK(client.requests[cancelled].cancellation_sent,
          "large response was not cancelled");
    CHECK(!quiche_conn_is_closed(pair.client.quic),
          "cancelling one stream closed the connection");
    printf("PASS cancellation: reset a 32 MiB stream; 16 sibling requests survived\n");

    size_t reuse = client_send(&pair, &client, "/fast/4242",
                               257 + (4242 % 127), (uint8_t) 4242,
                               false, true, false);
    drive_until_finished(&pair, &server, &client, reuse, 1,
                         "connection reuse");
    CHECK(pair.reordered_batches > 0,
          "test traffic never produced a reorderable packet batch");

    quiche_stats stats;
    quiche_conn_stats(pair.client.quic, &stats);
    printf("PASS connection reuse: %zu request streams on one h3 connection\n",
           client.request_count);
    printf("PASS packet reordering: %zu datagram batches delivered in reverse order\n",
           pair.reordered_batches);
    printf("PASS GhostHTTP3 stress: datagrams=%zu sent=%zu recv=%zu lost=%zu\n",
           pair.datagrams, stats.sent, stats.recv, stats.lost);

    size_t reset_idx = client_send(&pair, &client, "/server-reset",
                                    LARGE_BODY_LENGTH, 0xd1, false, false,
                                    true);
    for (size_t round = 0; round < 200000; round++) {
        drive_round(&pair, &server, &client);
        if (client.requests[reset_idx].saw_reset) {
            break;
        }
        CHECK(!quiche_conn_is_closed(pair.client.quic) &&
              !quiche_conn_is_closed(pair.server.quic),
              "connection closed during server-initiated reset");
    }
    CHECK(client.requests[reset_idx].saw_reset,
          "client did not observe server reset");
    CHECK(client.requests[reset_idx].saw_headers,
          "client did not see headers before server reset");
    CHECK(client.requests[reset_idx].body_received > 0,
          "client received no body before server reset");
    CHECK(client.requests[reset_idx].body_received < LARGE_BODY_LENGTH,
          "client received full body despite expecting server reset");
    printf("PASS server reset: stream reset mid-response after %" PRId64 " bytes\n",
           (int64_t) client.requests[reset_idx].body_received);

    size_t normal_after_reset = client_send(&pair, &client, "/fast/9999",
                                             257 + (9999 % 127),
                                             (uint8_t) 9999, false, false,
                                             false);
    drive_until_finished(&pair, &server, &client, normal_after_reset, 1,
                         "request after server-initiated reset");
    printf("PASS post-reset recovery: new request completed on same connection\n");

    size_t pre_goaway = client_send(&pair, &client, "/fast/7777",
                                     257 + (7777 % 127),
                                     (uint8_t) 7777, false, false, false);
    int goaway_result = quiche_h3_send_goaway(pair.server.h3, pair.server.quic,
                                               0);
    CHECK(goaway_result == 0, "could not send GOAWAY: %d", goaway_result);
    server.goaway_sent = true;
    drive_until_finished(&pair, &server, &client, pre_goaway, 1,
                         "in-flight request after GOAWAY");
    CHECK(client.requests[pre_goaway].finished,
          "in-flight request did not complete after GOAWAY");
    for (size_t round = 0; round < 1000; round++) {
        drive_round(&pair, &server, &client);
        if (client.saw_goaway) {
            break;
        }
    }
    CHECK(client.saw_goaway, "client did not receive GOAWAY event");
    printf("PASS GOAWAY: in-flight request completed; client received GOAWAY\n");

    quiche_h3_header goaway_reject_headers[] = {
        {(const uint8_t *) ":method", 7, (const uint8_t *) "GET", 3},
        {(const uint8_t *) ":scheme", 7, (const uint8_t *) "https", 5},
        {(const uint8_t *) ":authority", 10,
         (const uint8_t *) "ghostfile.test", 14},
        {(const uint8_t *) ":path", 5,
         (const uint8_t *) "/fast/8888", 10},
    };
    int64_t post_goaway_stream = quiche_h3_send_request(
        pair.client.h3, pair.client.quic, goaway_reject_headers, 4, true);
    CHECK(post_goaway_stream == QUICHE_H3_ERR_FRAME_UNEXPECTED,
          "post-GOAWAY request should be rejected with FRAME_UNEXPECTED, got %"
          PRId64, post_goaway_stream);
    printf("PASS GOAWAY rejection: new request rejected after GOAWAY (err=%"
           PRId64 ")\n", post_goaway_stream);

    pair_free(&pair);

    /* ---- Stream limit / backpressure ---- */
    static test_pair limit_pair;
    static server_state limit_server;
    static client_state limit_client;
    memset(&limit_pair, 0, sizeof(limit_pair));
    memset(&limit_server, 0, sizeof(limit_server));
    memset(&limit_client, 0, sizeof(limit_client));
    limit_server.paused_stream = -1;
    pair_create_internal(&limit_pair, argv[1], argv[2],
                          STREAM_LIMIT_TEST_COUNT, 0, 41200);
    CHECK(quiche_conn_peer_streams_left_bidi(limit_pair.client.quic)
            == STREAM_LIMIT_TEST_COUNT,
          "client should see %u peer bidi streams, got %" PRIu64,
          STREAM_LIMIT_TEST_COUNT,
          quiche_conn_peer_streams_left_bidi(limit_pair.client.quic));

    for (unsigned i = 0; i < STREAM_LIMIT_TEST_COUNT; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/fast/%u", 10000 + i);
        client_send(&limit_pair, &limit_client, path,
                    257 + ((10000 + i) % 127),
                    (uint8_t) (10000 + i), false, false, false);
        CHECK(quiche_conn_peer_streams_left_bidi(limit_pair.client.quic)
                == STREAM_LIMIT_TEST_COUNT - (uint64_t)(i + 1),
              "stream budget mismatch after %u opens: got %" PRIu64,
              i + 1,
              quiche_conn_peer_streams_left_bidi(limit_pair.client.quic));
    }

    quiche_h3_header over_limit_headers[] = {
        {(const uint8_t *) ":method", 7, (const uint8_t *) "GET", 3},
        {(const uint8_t *) ":scheme", 7, (const uint8_t *) "https", 5},
        {(const uint8_t *) ":authority", 10,
         (const uint8_t *) "ghostfile.test", 14},
        {(const uint8_t *) ":path", 5, (const uint8_t *) "/fast/99999", 11},
    };
    int64_t over_limit_stream = quiche_h3_send_request(
        limit_pair.client.h3, limit_pair.client.quic, over_limit_headers, 4,
        true);
    CHECK(over_limit_stream == QUICHE_H3_TRANSPORT_ERR_STREAM_LIMIT,
          "over-limit request should return STREAM_LIMIT, got %" PRId64,
          over_limit_stream);

    drive_until_finished(&limit_pair, &limit_server, &limit_client, 0,
                          STREAM_LIMIT_TEST_COUNT, "stream-limit requests");
    printf("PASS stream limit: %d streams allowed, over-limit rejected (err=%"
           PRId64 ")\n", STREAM_LIMIT_TEST_COUNT, over_limit_stream);
    pair_free(&limit_pair);

    /* ---- Connection close with peer error ---- */
    static test_pair close_pair;
    pair_create(&close_pair, argv[1], argv[2]);
    const char *close_reason = "ga-shutdown";
    int close_result = quiche_conn_close(
        close_pair.server.quic, true, (uint64_t) CONNECTION_CLOSE_ERROR,
        (const uint8_t *) close_reason, strlen(close_reason));
    CHECK(close_result == 0, "quiche_conn_close failed: %d", close_result);
    bool client_saw_close = false;
    for (size_t round = 0; round < 5000; round++) {
        pump_transport(&close_pair);
        if (quiche_conn_is_closed(close_pair.client.quic) ||
            quiche_conn_is_draining(close_pair.client.quic)) {
            client_saw_close = true;
            break;
        }
    }
    CHECK(client_saw_close, "client did not detect connection close");
    CHECK(quiche_conn_is_closed(close_pair.server.quic) ||
          quiche_conn_is_draining(close_pair.server.quic),
          "server should be closed or draining after close");

    bool peer_is_app = false;
    uint64_t peer_error_code = 0;
    const uint8_t *peer_reason = NULL;
    size_t peer_reason_len = 0;
    CHECK(quiche_conn_peer_error(close_pair.client.quic, &peer_is_app,
                                  &peer_error_code, &peer_reason,
                                  &peer_reason_len),
          "client should have peer error after close");
    CHECK(peer_is_app, "peer error should be app-level");
    CHECK(peer_error_code == CONNECTION_CLOSE_ERROR,
          "peer error code mismatch: %" PRIu64, peer_error_code);
    CHECK(peer_reason_len == strlen(close_reason),
          "peer reason length mismatch: %zu", peer_reason_len);
    CHECK(memcmp(peer_reason, close_reason, peer_reason_len) == 0,
          "peer reason text mismatch");

    bool local_is_app = false;
    uint64_t local_error_code = 0;
    const uint8_t *local_reason = NULL;
    size_t local_reason_len = 0;
    CHECK(quiche_conn_local_error(close_pair.server.quic, &local_is_app,
                                   &local_error_code, &local_reason,
                                   &local_reason_len),
          "server should have local error after initiating close");
    CHECK(local_is_app, "local error should be app-level");
    CHECK(local_error_code == CONNECTION_CLOSE_ERROR,
          "local error code mismatch: %" PRIu64, local_error_code);
    CHECK(local_reason_len == strlen(close_reason),
          "local reason length mismatch: %zu", local_reason_len);
    CHECK(memcmp(local_reason, close_reason, local_reason_len) == 0,
          "local reason text mismatch");
    printf("PASS connection close: app=%d code=%" PRIu64 " reason=%.*s "
           "(client draining=%d server draining=%d)\n",
           peer_is_app, peer_error_code, (int) peer_reason_len,
           (const char *) peer_reason,
           quiche_conn_is_draining(close_pair.client.quic),
           quiche_conn_is_draining(close_pair.server.quic));
    pair_free(&close_pair);

    /* ---- Oversized headers / max_field_section_size ---- */
    static test_pair field_pair;
    static server_state field_server;
    static client_state field_client;
    memset(&field_pair, 0, sizeof(field_pair));
    memset(&field_server, 0, sizeof(field_server));
    memset(&field_client, 0, sizeof(field_client));
    field_server.paused_stream = -1;
    pair_create_internal(&field_pair, argv[1], argv[2], MAX_REQUESTS,
                          MAX_FIELD_SECTION_SIZE_LIMIT, 41300);
    static uint8_t oversized_value[4 * 1024];
    memset(oversized_value, 'x', sizeof(oversized_value));
    quiche_h3_header oversized_headers[] = {
        {(const uint8_t *) ":method", 7, (const uint8_t *) "GET", 3},
        {(const uint8_t *) ":scheme", 7, (const uint8_t *) "https", 5},
        {(const uint8_t *) ":authority", 10,
         (const uint8_t *) "ghostfile.test", 14},
        {(const uint8_t *) ":path", 5, (const uint8_t *) "/oversized", 10},
        {(const uint8_t *) "x-oversized", 11,
         oversized_value, sizeof(oversized_value)},
    };
    int64_t oversized_stream = quiche_h3_send_request(
        field_pair.client.h3, field_pair.client.quic, oversized_headers, 5,
        true);
    CHECK(oversized_stream >= 0,
          "oversized header request should be accepted for sending: %" PRId64,
          oversized_stream);
    // RFC 9114 §4.2.2: client-side header enforcement is not done at encode
    // time, so quiche accepts the 4 KiB request. The receiver (server) is
    // the one bound by SETTINGS_MAX_FIELD_SECTION_SIZE; on decode quiche
    // raises HeaderListTooLarge → Error::ExcessiveLoad and tears down the
    // h3 connection with code 0x107. The loop drives until both endpoints
    // reach a terminal transport state (closed or draining).
    bool client_terminal = false;
    bool server_terminal = false;
    for (size_t round = 0; round < 5000; round++) {
        drive_round(&field_pair, &field_server, &field_client);
        if (quiche_conn_is_closed(field_pair.client.quic) ||
            quiche_conn_is_draining(field_pair.client.quic)) {
            client_terminal = true;
        }
        if (quiche_conn_is_closed(field_pair.server.quic) ||
            quiche_conn_is_draining(field_pair.server.quic)) {
            server_terminal = true;
        }
        if (client_terminal && server_terminal) {
            break;
        }
    }
    CHECK(client_terminal,
          "client should reach terminal state after the server rejected the "
          "oversized header");
    CHECK(server_terminal,
          "server should reach terminal state after rejecting the oversized "
          "header");
    bool oversize_peer_is_app = false;
    uint64_t peer_code = 0;
    const uint8_t *peer_close_reason = NULL;
    size_t peer_close_reason_len = 0;
    CHECK(quiche_conn_peer_error(field_pair.client.quic, &oversize_peer_is_app,
                                  &peer_code, &peer_close_reason,
                                  &peer_close_reason_len),
          "client should observe the server's CONNECTION_CLOSE error");
    CHECK(oversize_peer_is_app,
          "rejection close should be application-level (HTTP/3)");
    CHECK(peer_code == H3_EXCESSIVE_LOAD_ERROR,
          "peer error code should be HTTP_EXCESSIVE_LOAD (0x107), got 0x%"
          PRIx64, peer_code);
    printf("PASS oversized headers: 4 KiB field rejected by "
           "max_field_section_size=%d via HTTP_EXCESSIVE_LOAD=0x%" PRIx64
           " (app=%d); transport drained cleanly without framework crash\n",
           MAX_FIELD_SECTION_SIZE_LIMIT, peer_code, oversize_peer_is_app);
    pair_free(&field_pair);

    return 0;
}
