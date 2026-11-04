#!/usr/bin/env python3
"""Summarise a results CSV written by `tools/perf/perf.sh run`.

For each tool and condition it prints, for each cipher, the median throughput of
every client and server pairing (the time to connect is subtracted), each
pairing's ratio to OpenSSH, the range over the runs, and the client's CPU
seconds per GB. A CSV from before the tool, server and threads columns existed
is read as ssh runs of OpenSSH against OpenSSH and HPN-SSH against HPN-SSH.

usage: analyze.py [results.csv]
"""
import collections
import csv
import re
import statistics
import sys

LABELS = {
    'default': "default (each side's own)",
    'chacha20-poly1305@openssh.com': 'chacha20-poly1305 (serial)',
    'aes256-gcm@openssh.com': 'aes256-gcm',
}
# client:server. "HPN client" is an HPN-SSH client against an OpenSSH server.
PAIRS = ['base:base', 'hpn:hpn', 'hpn:base', 'base:hpn']
PAIR_LABELS = {'base:base': 'OpenSSH', 'hpn:hpn': 'HPN-SSH',
               'hpn:base': 'HPN client', 'base:hpn': 'HPN server'}
TOOLS = ['ssh', 'scp', 'sftp']
COND = re.compile(r'^(lan|wan(\d+))(?:_loss(\d+(?:\.\d+)?))?(?:_jit(\d+))?$')
WIDTH = 16


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return float('nan')


def title(cond):
    m = COND.match(cond)
    if not m:
        return cond
    extra = []
    if m.group(3):
        extra.append(f'{m.group(3)}% loss each way')
    if m.group(4):
        extra.append(f'{m.group(4)} ms jitter each way')
    if m.group(1) == 'lan':
        head = 'LAN' if extra else 'LAN (no shaping)'
    else:
        head = f'{m.group(2)} ms round trip'
    return ', '.join([head] + extra)


def cond_key(cond):
    m = COND.match(cond)
    if not m:
        return (2, 0, 0.0, 0)
    return (0 if m.group(1) == 'lan' else 1, int(m.group(2) or 0),
            float(m.group(3) or 0), int(m.group(4) or 0))


def tool_key(tool):
    return (TOOLS.index(tool) if tool in TOOLS else len(TOOLS), tool)


def pair_key(pair):
    return PAIRS.index(pair) if pair in PAIRS else len(PAIRS)


def pair_label(pair):
    return PAIR_LABELS.get(pair, pair)


def thread_suffix(threads, numeric):
    if threads.isdigit():
        return f', {threads} thread' + ('' if threads == '1' else 's')
    if threads == 'default' and numeric:
        return ', default threads'
    return ''


def fmt(value, spec, unit=''):
    return '-' if value != value else f'{value:{spec}}{unit}'


def stats(data, hs):
    """(median MB/s, median CPU s/GB, (min, max) MB/s, (min, max) CPU)"""
    tp = [mb / max(e - hs, 0.05) for mb, e, u, s in data]
    cpu = [(u + s) / mb * 1024 for mb, e, u, s in data if mb]
    return (statistics.median(tp) if tp else float('nan'),
            statistics.median(cpu) if cpu else float('nan'),
            (min(tp), max(tp)) if tp else (0.0, 0.0),
            (min(cpu), max(cpu)) if cpu else (0.0, 0.0))


def summarise(rows):
    connect = collections.defaultdict(list)
    runs = collections.defaultdict(list)
    seen = collections.defaultdict(list)   # (tool, cond) -> [(cipher, threads)]
    pairs, tools = set(), set()
    numeric_threads = set()
    for row in rows:
        cond, cipher, impl = row['cond'], row['cipher'], row['impl']
        tool = row.get('tool') or 'ssh'
        server = row.get('server') or impl
        threads = row.get('threads') or '-'
        pair = f'{impl}:{server}'
        pairs.add(pair)
        tools.add(tool)
        elapsed = number(row['elapsed'])
        if cipher != 'handshake':
            if (cipher, threads) not in seen[(tool, cond)]:
                seen[(tool, cond)].append((cipher, threads))
            if threads.isdigit():
                numeric_threads.add((tool, cond, cipher))
        elif (tool, cond) not in seen:
            seen[(tool, cond)] = []
        if elapsed != elapsed:  # a failed run
            continue
        if cipher == 'handshake':
            connect[(pair, tool, cond)].append(elapsed)
        else:
            runs[(pair, tool, cond, cipher, threads)].append(
                (number(row['mb']), elapsed, number(row['user']), number(row['sys'])))

    order = sorted(pairs, key=pair_key)
    mixed = any(p not in ('base:base', 'hpn:hpn') for p in order)
    lines = []
    if mixed:
        lines.append('HPN client = HPN-SSH client against an OpenSSH server; '
                     'HPN server = OpenSSH client against an HPN-SSH server.')
    for tool, cond in sorted(seen, key=lambda k: (tool_key(k[0]), cond_key(k[1]))):
        hs = {p: statistics.median(connect[(p, tool, cond)])
              if connect[(p, tool, cond)] else 0.0 for p in order}
        heading = title(cond) if tools == {'ssh'} else f'{title(cond)}, {tool}'
        lines.append('')
        lines.append(heading)
        lines.append('  connect time (median): ' + ', '.join(
            f'{pair_label(p)} {hs[p] * 1000:.0f} ms' for p in order))
        ref = 'base:base' in order
        others = [p for p in order if p != 'base:base'] if ref else []
        head = f"  {'cipher':34s}" + ''.join(f'{pair_label(p):>{WIDTH}s}' for p in order)
        head += ''.join(f"{'x ' + pair_label(p):>13s}" for p in others)
        head += f"   {'CPU s/GB:':>10s}" + ''.join(f'{pair_label(p):>{WIDTH}s}' for p in order)
        lines.append(head)
        has_digits = {c for t, k, c in numeric_threads if (t, k) == (tool, cond)}
        rows_here = []
        for cipher, threads in seen[(tool, cond)]:
            # a case that does not depend on the thread count is recorded once, as
            # "-", and stands in for every thread count of the same cipher
            if threads == '-' and any(c == cipher and t != '-' for c, t in seen[(tool, cond)]):
                continue
            rows_here.append((cipher, threads))
        for cipher, threads in rows_here:
            out = {}
            for p in order:
                data = runs.get((p, tool, cond, cipher, threads))
                if data is None:
                    data = runs.get((p, tool, cond, cipher, '-'), [])
                out[p] = stats(data, hs[p])
            label = LABELS.get(cipher, cipher) + thread_suffix(threads, cipher in has_digits)
            row1 = f'  {label:34s}' + ''.join(
                f"{fmt(out[p][0], '.0f', 'MB/s'):>{WIDTH}s}" for p in order)
            for p in others:
                base = out['base:base'][0]
                ratio = out[p][0] / base if base == base and base else float('nan')
                row1 += f"{fmt(ratio, '.2f', 'x'):>13s}"
            row1 += f"   {'':10s}" + ''.join(
                f"{fmt(out[p][1], '.2f'):>{WIDTH}s}" for p in order)
            lines.append(row1)
            row2 = f"  {'':34s}" + ''.join(
                (f"{'(runs %.0f-%.0f)' % out[p][2]:>{WIDTH}s}" if out[p][0] == out[p][0]
                 else ' ' * WIDTH) for p in order)
            row2 += ' ' * (13 * len(others)) + f"   {'CPU range:':>10s}" + ''.join(
                (f"{'%.1f-%.1f' % out[p][3]:>{WIDTH}s}" if out[p][1] == out[p][1]
                 else ' ' * WIDTH) for p in order)
            lines.append(row2)
    return '\n'.join(lines)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'results.csv'
    with open(path, newline='') as handle:
        print(summarise(list(csv.DictReader(handle))))


if __name__ == '__main__':
    main()
