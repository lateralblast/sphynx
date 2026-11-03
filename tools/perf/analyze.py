#!/usr/bin/env python3
"""Summarise a results CSV written by `tools/perf/perf.sh run`.

For each condition and cipher it prints the median throughput of OpenSSH and
HPN-SSH (the time to connect is subtracted), their ratio, the range over the
runs, and the client's CPU seconds per GB.

usage: analyze.py [results.csv]
"""
import collections
import csv
import statistics
import sys

TITLES = {'lan': 'LAN (no shaping)'}
LABELS = {
    'default': "default (each side's own)",
    'chacha20-poly1305@openssh.com': 'chacha20-poly1305 (serial)',
    'aes256-gcm@openssh.com': 'aes256-gcm',
}
ORDER = ['lan']


def number(text):
    try:
        return float(text)
    except ValueError:
        return float('nan')


def title(cond):
    if cond in TITLES:
        return TITLES[cond]
    if cond.startswith('wan') and cond[3:].isdigit():
        return f'{cond[3:]} ms round trip'
    return cond


def sort_key(cond):
    if cond == 'lan':
        return (0, 0)
    if cond.startswith('wan') and cond[3:].isdigit():
        return (1, int(cond[3:]))
    return (2, 0)


def summarise(rows):
    connect = collections.defaultdict(list)
    runs = collections.defaultdict(list)
    conds, ciphers = set(), []
    for row in rows:
        cond, cipher, impl = row['cond'], row['cipher'], row['impl']
        conds.add(cond)
        elapsed = number(row['elapsed'])
        if elapsed != elapsed:  # a failed run
            continue
        if cipher == 'handshake':
            connect[(impl, cond)].append(elapsed)
            continue
        if cipher not in ciphers:
            ciphers.append(cipher)
        runs[(impl, cipher, cond)].append(
            (number(row['mb']), elapsed, number(row['user']), number(row['sys'])))

    lines = []
    for cond in sorted(conds, key=sort_key):
        hs = {i: statistics.median(connect[(i, cond)]) if connect[(i, cond)] else 0.0
              for i in ('base', 'hpn')}
        lines.append('')
        lines.append(title(cond))
        lines.append(f"  connect time (median): OpenSSH {hs['base'] * 1000:.0f} ms, "
                     f"HPN-SSH {hs['hpn'] * 1000:.0f} ms")
        lines.append(f"  {'cipher':28s} {'OpenSSH':>10s} {'HPN-SSH':>10s} {'ratio':>7s}"
                     f"   {'CPU s/GB: OpenSSH':>18s} {'HPN-SSH':>8s}")
        for cipher in ciphers:
            out = {}
            for impl in ('base', 'hpn'):
                data = runs.get((impl, cipher, cond), [])
                tp = [mb / max(e - hs[impl], 0.05) for mb, e, u, s in data]
                cpu = [(u + s) / mb * 1024 for mb, e, u, s in data if mb]
                out[impl] = (statistics.median(tp) if tp else float('nan'),
                             statistics.median(cpu) if cpu else float('nan'),
                             (min(tp), max(tp)) if tp else (0.0, 0.0),
                             (min(cpu), max(cpu)) if cpu else (0.0, 0.0))
            b, h = out['base'], out['hpn']
            ratio = h[0] / b[0] if b[0] == b[0] and b[0] else float('nan')
            lines.append(f"  {LABELS.get(cipher, cipher):28s} {b[0]:8.0f}MB/s {h[0]:8.0f}MB/s "
                         f"{ratio:6.2f}x   {b[1]:18.2f} {h[1]:8.2f}")
            lines.append(f"  {'':28s} (runs {b[2][0]:.0f}-{b[2][1]:.0f})   "
                         f"(runs {h[2][0]:.0f}-{h[2][1]:.0f})"
                         f"   CPU range: {b[3][0]:.1f}-{b[3][1]:.1f}  {h[3][0]:.1f}-{h[3][1]:.1f}")
    return '\n'.join(lines)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'results.csv'
    with open(path, newline='') as handle:
        print(summarise(list(csv.DictReader(handle))))


if __name__ == '__main__':
    main()
