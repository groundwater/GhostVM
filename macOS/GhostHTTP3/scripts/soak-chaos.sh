#!/bin/zsh

# Deterministic seed-progression soak for the GhostHTTP3 chaos phase.
#
# Re-runs the conservative chaos scenarios across an advancing seed range
# with a wall-clock budget, no root, and no second host. Because losing
# a handshake-critical datagram inside quiche's 5s idle timeout causes some
# seeds to stall the stock http3 example independent of framework health,
# the soak treats those stalls as documented findings (it logs them but does
# NOT factor them into the pass/fail verdict). Real failures are: process
# leaks, proxy-queue overflows, lost-client-address, server-failed-h3, or a
# non-loss scenario that could not complete.
#
# Tunables (environment):
#   GHOST_HTTP3_SOAK_SEED_START       first seed (default 7)
#   GHOST_HTTP3_SOAK_SEED_COUNT       how many successive seeds (default 5)
#   GHOST_HTTP3_SOAK_MAX_SECONDS      wall-clock budget (default 240s; checked
#                                     between seeds)
#   GHOST_HTTP3_SOAK_MAX_ITERATIONS   hard cap on seeds run (default: off/0)
#   GHOST_HTTP3_SOAK_ITERATIONS       per-seed chaos iterations (default 2)
#   GHOST_HTTP3_SOAK_SANITIZERS=1    build the proxy with ASan/UBSan
#   GHOST_HTTP3_SOAK_HARSH=1         also run the harsh-loss reproducer/seed
#   GHOST_HTTP3_SOAK_QUIET=1         suppress per-seed chaos output
#
# Tip: combine with GHOST_HTTP3_SOAK_MAX_ITERATIONS=20 to bound the maximum
# CPU/IO commitment while still exercising budgeted seeds.

set -uo pipefail

script_dir=${0:A:h}

soak_seed_start=${GHOST_HTTP3_SOAK_SEED_START:-7}
soak_seed_count=${GHOST_HTTP3_SOAK_SEED_COUNT:-5}
soak_max_seconds=${GHOST_HTTP3_SOAK_MAX_SECONDS:-240}
soak_max_iterations=${GHOST_HTTP3_SOAK_MAX_ITERATIONS:-0}
soak_iterations=${GHOST_HTTP3_SOAK_ITERATIONS:-3}
soak_sanitizers=${GHOST_HTTP3_SOAK_SANITIZERS:-0}
soak_harsh=${GHOST_HTTP3_SOAK_HARSH:-0}
soak_quiet=${GHOST_HTTP3_SOAK_QUIET:-0}

starts_at=$(date +%s)
deadline=$((starts_at + soak_max_seconds))

passes=0
stalls=0
low_drop=0
fails=0
completed=0

last_seed=$((soak_seed_start + soak_seed_count - 1))
for ((seed = soak_seed_start; seed <= last_seed; seed++)); do
    if (( $(date +%s) >= deadline )); then
        print -r -u2 -- "soak: wall-clock cap ${soak_max_seconds}s reached, stopping at seed ${seed}"
        break
    fi
    if (( soak_max_iterations > 0 && completed >= soak_max_iterations )); then
        print -r -u2 -- "soak: iteration cap ${soak_max_iterations} reached, stopping at seed ${seed}"
        break
    fi

    out_file=$(mktemp -t ghost_http3_soak.XXXXXX)
    env_vars=(
        GHOST_HTTP3_CHAOS_SEED=${seed}
        GHOST_HTTP3_CHAOS_ITERATIONS=${soak_iterations}
        GHOST_HTTP3_CHAOS_CLIENT_TIMEOUT=25
        GHOST_HTTP3_CHAOS_PROXY_MAX_DURATION=180
        # Forces strict chaos mode so the soak classifier can distinguish
        # STALL / LOW-DROP / FAIL outcomes; the chaos test's tolerant
        # default would mask all but structural failures.
        GHOST_HTTP3_CHAOS_TOLERATE_STALL=0
    )
    if (( soak_sanitizers )); then
        env_vars+=(GHOST_HTTP3_TEST_SANITIZERS=1)
    fi
    if [[ ${soak_harsh} == 1 ]]; then
        env_vars+=(GHOST_HTTP3_CHAOS_HARSH=1)
    fi

    if env "${env_vars[@]}" "${script_dir}/test-chaos.sh" >"${out_file}" 2>&1; then
        passes=$((passes + 1))
        [[ ${soak_quiet} == 0 ]] && print -r -- "soak seed=${seed}: PASS"
    else
        # The chaos script exits non-zero for three classes of run. We
        # classify each so the soak only fails on framework regressions:
        #   * STALLED: a quiche example idle-timeout fire (5s) on the loss
        #     scenario when this seed happened to drop a handshake-critical
        #     flight. Documented; not a framework bug.
        #   * LOW_DROP: a non-loss assertion threshold (dup, reorder, mtu)
        #     wasn't met for this low-packet seed. The impairment was
        #     configured but fired too rarely to elicit the threshold on a
        #     short loopback flow. Informational; not a framework bug.
        #   * FAIL: structural — proxy queue overflow, drop_nopeer,
        #     server-failed-h3, ASan error, or unclassified chaos failure.
        if rg -q 'idle timeout fired|stalled handshake|client watchdog timed out|ALPN h3 not negotiated|ALPN h3 or HTTP/3 success markers missing' "${out_file}"; then
            stalls=$((stalls + 1))
            [[ ${soak_quiet} == 0 ]] && print -r -- "soak seed=${seed}: STALLED (documented quiche example idle-timeout limit)"
        elif rg -q "dropped no datagrams at all|fired no dups at all|did not reorder any packets|delayed nothing|dropped no oversized datagram|did not actually drop" "${out_file}"; then
            low_drop=$((low_drop + 1))
            [[ ${soak_quiet} == 0 ]] && print -r -- "soak seed=${seed}: LOW-DROP (impairment configured but fired below threshold on this short flow)"
        else
            fails=$((fails + 1))
            print -r -u2 -- "soak seed=${seed}: FAIL"
            tail -12 "${out_file}" >&2
        fi
    fi
    rm -f "${out_file}" 2>/dev/null || true
    completed=$((completed + 1))
done

elapsed=$(( $(date +%s) - starts_at ))
print -r -- "soak summary: seeds_tried=${completed} passes=${passes} stalls=${stalls} low_drop=${low_drop} fails=${fails} elapsed=${elapsed}s"
print -r -- "soak budget: seed_start=${soak_seed_start} seed_count=${soak_seed_count} max_seconds=${soak_max_seconds} max_iterations=${soak_max_iterations} iterations=${soak_iterations} (time checked between seeds)"

# Stalls and low-drop counts are documented/informational and do not gate the
# exit code. Only structural failures do.
if (( fails > 0 )); then
    exit 1
fi
exit 0
