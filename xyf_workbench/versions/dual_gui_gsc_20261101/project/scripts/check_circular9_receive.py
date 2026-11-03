#!/usr/bin/env python3
"""C9C2 fixture regression, bounded capture, discontinuities and offline equality."""
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'pc'))
from circular9_capture import CaptureSession, CaptureFormatError, PacketWriter, capture_records, parse_packet, decode_capture
from circular9_receive import decode


def reject(function):
    try:
        function()
    except ValueError:
        return
    raise AssertionError('malformed capture or packet accepted')


def packet(fixture, number=0, first=0, count=8, session=1, epoch=0, geometry=123, calibration=0):
    h = list(struct.unpack_from('<16I', fixture))
    h[3], h[4], h[5], h[11], h[12] = session, number & 0xffffffff, count, geometry, calibration
    result = bytearray(struct.pack('<16I', *h))
    template = fixture[64:192]
    for i in range(count):
        w = list(struct.unpack('<32I', template))
        sample = (first+i) & 0xffffffff
        w[1], w[14], w[16], w[17], w[18], w[22] = sample, epoch, 1000+1024*i+number*8192 & 0xffffffff, 1, sample, calibration
        w[31] = ~w[18] & 0xffffffff
        slot = bytearray(struct.pack('<32I', *w))
        struct.pack_into('<I', slot, 120, zlib.crc32(slot[:120]))
        result.extend(slot + fixture[192:196])
    result.extend(struct.pack('<I', zlib.crc32(result)))
    return bytes(result)


def repair_outer(data):
    struct.pack_into('<I', data, len(data)-4, zlib.crc32(data[:-4]))
    return bytes(data)


def main():
    # Existing C writer plus all332 single-byte corruptions remain authoritative.
    subprocess.run([sys.executable, 'scripts/check_circular9_stream.py'], cwd=ROOT, check=True)
    fixture = (ROOT/'build/circular9_stream_checks/packet.bin').read_bytes()
    for index in range(len(fixture)):
        bad = bytearray(fixture); bad[index] ^= 1
        reject(lambda: parse_packet(bad, False))
    header, original = decode(fixture)
    assert original[0]['raw'] == (123,)*9 and original[1]['output'] == 122
    # Recomputed outer CRC cannot hide bad inner CRC/ownership or invalid state.
    for offset in (64+32, 64+124, 64+96):
        bad = bytearray(fixture); bad[offset] ^= 1
        if offset != 96:
            struct.pack_into('<I', bad, 64+120, zlib.crc32(bad[64:64+120]))
        reject(lambda: parse_packet(repair_outer(bad), False))
    for data in (b'', b'\x00'*199, b'\x00'*1125):
        reject(lambda: parse_packet(data, False))
    normal = [packet(fixture, i, 8*i) for i in range(3)]
    with tempfile.TemporaryDirectory() as name:
        base = Path(name)
        fast = CaptureSession(base/'fast', packets_only=True)
        full = CaptureSession(base/'full')
        for data in normal:
            fast.consume(data); full.consume(data)
        fs, ds = fast.close(), full.close()
        assert fs['samples'] == ds['samples'] == 24 and fs['segments'] == ds['segments'] == 1
        assert not (base/'fast/frames.jsonl').exists() and not list((base/'fast').glob('*.pcm'))
        assert fs['capture_write_batches'] == 1
        assert (base/'fast/packets.c9').read_bytes() == (base/'full/packets.c9').read_bytes()
        assert list(capture_records(base/'fast/packets.c9')) == normal
        offline = decode_capture(base/'fast/packets.c9', base/'offline')
        assert offline['samples'] == 24 and offline['source_capture_sha256'] == fs['capture_sha256']
        for suffix in ('raw9.pcm', 'fir.pcm', 'gsc.pcm'):
            assert (base/'full'/('segment0000_'+suffix)).read_bytes() == (base/'offline'/('segment0000_'+suffix)).read_bytes()
        assert (base/'offline/segment0000_raw9.pcm').read_bytes() == struct.pack('<9h', *([123]*9))*24
        assert (base/'full/frames.jsonl').read_bytes() == (base/'offline/frames.jsonl').read_bytes()
        # A skipped packet starts a new segment even with seemingly contiguous samples.
        for label, data, expected_counter in (
                ('packet_gap', packet(fixture, 2, 8), 'missing_packets'),
                ('sample_gap', packet(fixture, 1, 9), 'missing_samples'),
                ('duplicate', normal[0], 'duplicate_packets'),
                ('session', packet(fixture, 1, 0, session=2), 'session_changes'),
                ('epoch', packet(fixture, 1, 8, epoch=1), 'epoch_changes'),
                ('geometry', packet(fixture, 1, 8, geometry=124), 'geometry_changes'),
                ('calibration', packet(fixture, 1, 8, calibration=1), 'calibration_changes')):
            run = CaptureSession(base/label, packets_only=True)
            run.consume(normal[0]); run.consume(data); stats = run.close()
            assert stats['segments'] == 2 and stats[expected_counter] >= 1, (label, stats)
        # Invalid CRC has explicit provenance: it cannot be silently skipped and joined.
        run = CaptureSession(base/'crc_break', packets_only=True)
        damaged = bytearray(normal[0]); damaged[88] ^= 1
        for data in (normal[0], damaged, normal[1]):
            run.consume(data)
        broken = run.close()
        assert broken['invalid_packets'] == 1 and broken['segments'] == 2
        decoded = decode_capture(base/'crc_break/packets.c9', base/'crc_offline')
        assert decoded['segments'] == 2 and decoded['invalid_packets'] == 1
        assert len(list((base/'crc_offline').glob('*_raw9.pcm'))) == 2
        # Header/slot counter wrap is valid when sample/timestamp continuity holds.
        wrap = CaptureSession(base/'wrap', packets_only=True)
        a = bytearray(packet(fixture, 0, 0xfffffff8))
        struct.pack_into('<I', a, 16, 0xffffffff); a = repair_outer(a)
        b = packet(fixture, 0, 0)
        # Keep timestamps increasing across the artificial packet-number wrap.
        a = bytearray(a)
        for i in range(8):
            off = 64+132*i
            struct.pack_into('<I', a, off+68, 0)
            struct.pack_into('<I', a, off+120, zlib.crc32(a[off:off+120]))
        a = repair_outer(a)
        wrap.consume(a); wrap.consume(b); stats = wrap.close()
        assert stats['segments'] == 1 and not stats['missing_packets'] and not stats['missing_samples']
        # Truncated or excessive framing never allocates unbounded input or yields mixed PCM.
        for label, data in (('prefix', b'\x01\x00'), ('huge', struct.pack('<I', 0xffffffff)),
                            ('tail', struct.pack('<I', len(normal[0]))+normal[0][:-1])):
            source = base/(label+'.c9'); source.write_bytes(data)
            reject(lambda: list(capture_records(source)))
            reject(lambda: decode_capture(source, base/(label+'_decoded')))
            assert not json.loads((base/(label+'_decoded')/'manifest.json').read_text())['completed']
        # Bounded event reporting avoids a sample-rate JSON fallback in packets-only mode.
        events = CaptureSession(base/'events', packets_only=True)
        for i in range(1100):
            events.consume(packet(fixture, i, 8*i, epoch=i))
        e = events.close()
        assert e['events_logged'] == 1024 and e['events_omitted'] == 76
        # Actual loopback exercises the public CLI, without touching FPGA hardware.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
        process = subprocess.Popen([sys.executable, 'pc/circular9_receive.py', '--packets-only', '--bind', '127.0.0.1',
                                    '--port', str(port), '--seconds', '.2', '--output', str(base/'udp')],
                                   cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = process.stdout.readline()
        assert 'Listening' in line
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            for data in normal:
                client.sendto(data, ('127.0.0.1', port))
        output, error = process.communicate(timeout=3)
        assert process.returncode == 0, (output, error)
        assert json.loads((base/'udp/manifest.json').read_text())['samples'] == 24
        subprocess.run([sys.executable, 'pc/circular9_receive.py', '--decode-capture', str(base/'udp/packets.c9'),
                        '--output', str(base/'udp_decoded')], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        assert (base/'udp_decoded/segment0000_raw9.pcm').stat().st_size == 24*18
        # Local sink benchmark includes validation, framing and real writes, no network guarantee.
        payloads = [packet(fixture, i, 8*i) for i in range(4000)]
        measured = {}
        for label, only in (('packets_only', True), ('full_decode', False)):
            start = time.perf_counter(); run = CaptureSession(base/('benchmark_'+label), packets_only=only)
            for data in payloads:
                run.consume(data)
            stats = run.close(elapsed=time.perf_counter()-start)
            measured[label] = {'samples_per_second': stats['samples']/stats['elapsed_seconds'],
                               'seconds': stats['elapsed_seconds'], 'capture_write_batches': stats['capture_write_batches']}
    result = {'passed': True, 'hardware_tested': False, 'udp_loopback_tested': True,
              'fixture': 'C_writer_C9C2_two_slot_and_synthetic_reframed_eight_slot',
              'checks': ['legacy_protocol_corruption_regression', 'fast_full_offline_bit_exact_PCM',
                         'CRC_inner_ownership', 'packet_sample_session_epoch_version_segmentation',
                         'invalid_packet_forces_break', 'counter_wrap', 'truncated_and_unbounded_records_rejected',
                         'bounded_events', 'public_CLI_UDP_loopback'],
              'host_sink_benchmark': measured, 'network_reliability_proved': False,
              'source_sha256': {path: hashlib.sha256((ROOT/path).read_bytes()).hexdigest() for path in
                                ('pc/circular9_receive.py', 'pc/circular9_capture.py', 'scripts/check_circular9_receive.py',
                                 'scripts/check_circular9_stream.py', 'sw/circular9_stream_test.c', 'sw/circular9_stream.c',
                                 'sw/circular9_audio.c', 'sw/pdm_stream.c', 'sw/gsc9.c', 'sw/circular9_stream.h',
                                 'sw/circular9_audio.h', 'sw/pdm_stream.h', 'sw/gsc9.h', 'sw/circular9_decimator.h')}}
    out = ROOT/'build/circular9_receive_checks'; out.mkdir(parents=True, exist_ok=True)
    (out/'results.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print('CIRCULAR9_RECEIVE_PASS fast_full_offline_PCM_identical hardware=UNVERIFIED')


if __name__ == '__main__':
    main()
