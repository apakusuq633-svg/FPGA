"""Fail-closed scheme-A acceptance for structured, per-window RTL events.

Module runs can prove numerical/throughput properties but never SoC acceptance.
Input is JSONL: one run, ordered window records, one coverage record.
"""
import argparse
import json
import math
from pathlib import Path

BUDGET = 524288


def evaluate(events):
    runs = [e for e in events if e.get('type') == 'run']
    coverage = [e for e in events if e.get('type') == 'coverage']
    windows = [e for e in events if e.get('type') == 'window']
    if len(runs) != 1 or len(coverage) != 1:
        raise ValueError('Exactly one run and coverage record required')
    run, source = runs[0], coverage[0]
    if events[0] is not run or events[-1] is not source:
        raise ValueError('Run/coverage must bound all window events')
    if any(e.get('type') not in ('run', 'window', 'coverage') for e in events):
        raise ValueError('Unknown event type')

    def integer(record, key, minimum=0):
        value = record.get(key)
        if type(value) is not int or value < minimum:
            raise ValueError(f'Invalid integer {key}: {value!r}')
        return value

    failures = []
    for key, value in dict(window_length=1024, hop=512, channels=12,
                           clock_hz=40000000, sample_period_cycles=1024).items():
        if integer(run, key, 1) != value:
            failures.append('CONFIG_' + key.upper())
    first_sample = integer(source, 'first_sample')
    count = integer(source, 'sample_count')
    expected = max(0, (count - 1024) // 512 + 1)
    ids = [integer(w, 'window_id', 1) for w in windows]
    expected_ids = list(range(1, expected + 1))
    if ids != expected_ids:
        failures.append('MISSING_DUPLICATE_OR_REORDERED_WINDOWS')
    if not expected:
        failures.append('NO_COMPLETE_WINDOWS')
    for key in ('raw_block_loss', 'window_skip', 'audio_drops'):
        value = source.get(key)
        if value is None:
            failures.append('UNMEASURED_' + key.upper())
        elif integer(source, key) != 0:
            failures.append(key.upper())
    latencies, gaps, totals = [], [], dict(fft_fwd=0, gcc_pairs=0, ifft=0, srp=0, srp_grid=0)
    previous = None
    for w in windows:
        wid = integer(w, 'window_id', 1)
        first = integer(w, 'first_sample')
        ready = integer(w, 'ready_cycle')
        result = integer(w, 'result_cycle')
        if first != first_sample + (wid - 1) * 512:
            failures.append('WINDOW_SAMPLE_RANGE')
        if result < ready:
            raise ValueError('Negative latency; timestamps must be extended, not wrapped')
        if previous:
            if ready - previous['ready_cycle'] != BUDGET:
                failures.append('READY_CADENCE')
            if result <= previous['result_cycle']:
                failures.append('RESULT_ORDER')
            gaps.append(result - previous['result_cycle'])
        latencies.append(result - ready)
        previous = w
        for key, required in dict(fft_fwd=12, gcc_pairs=66, ifft=66, srp=1, srp_grid=1024).items():
            value = integer(w, key)
            totals[key] += value
            if value != required:
                failures.append('FULL_CHAIN_NOT_EXECUTED')
        if w.get('geometry_mode') not in ('TEST_GEOMETRY_ONLY', 'CONFIRMED_PRODUCTION'):
            failures.append('FULL_CHAIN_NOT_EXECUTED')
        if w.get('geometry_mode') == 'CONFIRMED_PRODUCTION' and run.get('physical_geometry_confirmed') is not True:
            failures.append('UNCONFIRMED_PRODUCTION_GEOMETRY')
        for key in ('window_golden_match', 'pair_computation_verified', 'srp_golden_match'):
            if w.get(key) is not True:
                failures.append('NUMERIC_' + key.upper())
    max_gap = max(gaps, default=None)
    max_latency = max(latencies, default=None)
    if max_gap is not None and max_gap > BUDGET:
        failures.append('THROUGHPUT_FAIL')
    if max_latency is not None and max_latency > BUDGET:
        failures.append('LATENCY_FAIL')
    backlog = []
    # Include arrivals between results, so a fast consumer still has peak backlog 1.
    origin = windows[0]['ready_cycle'] - (windows[0]['window_id'] - 1) * BUDGET if windows else 0
    timeline = ([(origin + i * BUDGET, 0, 1) for i in range(expected)]
                + [(w['result_cycle'], 1, -1) for w in windows]) if windows else []
    outstanding = peak = 0
    for _, kind, delta in sorted(timeline):
        outstanding += delta
        peak = max(peak, outstanding)
        if kind == 1:
            backlog.append(max(0, outstanding))
    def stats(values):
        return dict(mean=sum(values)/len(values), p99=sorted(values)[math.ceil(.99*len(values))-1],
                    maximum=max(values)) if values else None
    if len(windows) < 256:
        failures.append('INSUFFICIENT_STRESS_COVERAGE')
    if run.get('scope') != 'SOC':
        failures.append('SOC_NOT_EXECUTED')
    if run.get('audio_verified') is not True:
        failures.append('AUDIO_NOT_VERIFIED')
    timing = run.get('timing', {})
    valid_timing = (timing.get('source_hash_match') is True and timing.get('clock_hz') == 40000000
                    and bool(timing.get('report')))
    for key in ('wns_ns', 'whs_ns'):
        value = timing.get(key)
        valid_timing = valid_timing and type(value) in (int, float) and math.isfinite(value) and value >= 0
    if not valid_timing:
        failures.append('CURRENT_40MHZ_IMPLEMENTATION_NOT_VERIFIED')
    failures = sorted(set(failures))
    return dict(status='PASS' if not failures else 'FAIL', failures=failures,
                scope=run.get('scope'), expected_windows=expected, processed_windows=len(windows),
                missing_windows=len(set(expected_ids) - set(ids)),
                max_result_gap_cycles=max_gap, max_window_latency_cycles=max_latency,
                throughput_pass_latency_fail=(max_gap is not None and max_gap <= BUDGET
                                              and max_latency is not None and max_latency > BUDGET),
                max_backlog=peak,
                backlog_at_results=backlog, algorithm_counts=totals,
                result_gap_cycles=stats(gaps), window_latency_cycles=stats(latencies),
                raw_block_loss=source.get('raw_block_loss'), window_skip=source.get('window_skip'),
                audio_drops=source.get('audio_drops'),
                timing_met=bool(valid_timing), physical_accuracy_validated=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('events', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = evaluate([json.loads(line) for line in args.events.read_text().splitlines() if line.strip()])
    except (ValueError, KeyError, TypeError) as exc:
        result = dict(status='FAIL', failures=['INVALID_EVIDENCE'], error=str(exc))
    encoded = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end='')
    raise SystemExit(0 if result['status'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
