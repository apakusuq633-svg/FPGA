"""Bounded C9C2 capture and offline conversion; no hardware acceptance implied."""
import hashlib
import json
from pathlib import Path
import socket
import struct
import time
import zlib

MAX_PACKET = 68 + 8 * 132
MAX_DATAGRAM = 65535
BUFFER_BYTES = 256 * 1024
MAX_EVENTS = 1024


class CaptureFormatError(ValueError):
    pass


def parse_packet(data, detailed=True):
    if not 200 <= len(data) <= MAX_PACKET:
        raise ValueError('packet length outside C9C2 bounds')
    h = struct.unpack_from('<16I', data)
    if h[:3] != (0x32433943, 2, 64) or not 1 <= h[5] <= 8 or h[6:11] != (0x000a0009, 511, 156250, 1, 40000000):
        raise ValueError('unsupported profile/rate')
    if h[15] & ~3 or (not h[12] and not h[15] & 2):
        raise ValueError('unmarked calibration')
    if len(data) != 68 + h[5] * 132 or zlib.crc32(data[:-4]) != struct.unpack_from('<I', data, len(data)-4)[0]:
        raise ValueError('packet length/CRC')
    rows, prior = [], None
    for i in range(h[5]):
        offset = 64 + 132*i
        slot = memoryview(data)[offset:offset+128]
        w = struct.unpack('<32I', slot)
        output, reason = struct.unpack_from('<hH', data, offset+128)
        if w[0] != 0x47534302 or w[13] != 0x000a0009 or w[12] >> 16 or w[20:24] != (0x394d4450, 128, h[12], 0x00100009):
            raise ValueError('slot profile')
        if w[31] != (~w[18] & 0xffffffff) or any(w[24:30]) or zlib.crc32(slot[:120]) != w[30]:
            raise ValueError('slot CRC/ownership')
        if w[6] & ~0x3ff03 or reason > 9 or (reason == 0 and not h[15] & 1):
            raise ValueError('GSC state')
        das, beam = struct.unpack_from('<hh', slot, 28)
        if reason and output != beam:
            raise ValueError('invalid bypass output')
        sample, stamp = w[1], w[16] | w[17] << 32
        if prior and (not 0 < (sample-prior[0]) & 0xffffffff < 0x80000000 or stamp <= prior[1]):
            raise ValueError('nonmonotonic batch')
        prior = sample, stamp
        if detailed:
            rows.append({'sample': sample, 'direction_version': w[2], 'effective_sample': w[3], 'window': w[4],
                         'group_delay_q16': w[5], 'grid': (w[6] >> 8) & 1023, 'trusted': bool(w[6] & 1),
                         'transition': bool(w[6] & 2), 'raw': struct.unpack_from('<9h', slot, 32),
                         'das': das, 'fir': beam, 'output': output, 'reason': reason, 'epoch': w[14],
                         'tap_drops': w[15], 'timestamp': stamp, 'dma_drops': w[19]})
        else:
            rows.append((sample, stamp, w[14], w[15], w[19]))
    return {'session': h[3], 'packet': h[4], 'geometry_version': h[11], 'calibration_version': h[12],
            'dma_drops': h[13], 'software_drops': h[14], 'unverified': bool(h[15] & 2)}, rows


class PacketWriter:
    """Same legacy framing: uint32LE length, then original UDP payload."""
    def __init__(self, path):
        self.file, self.buffer = Path(path).open('wb'), bytearray()
        self.digest, self.bytes, self.batches = hashlib.sha256(), 0, 0

    def write(self, data):
        if len(data) > MAX_DATAGRAM:
            raise ValueError('UDP datagram exceeds capture limit')
        record = struct.pack('<I', len(data)) + data
        if len(self.buffer) + len(record) > BUFFER_BYTES:
            self.flush()
        self.buffer.extend(record)
        self.digest.update(record)
        self.bytes += len(record)

    def flush(self):
        if self.buffer:
            self.file.write(self.buffer)
            self.batches += 1
            self.buffer.clear()

    def close(self):
        self.flush()
        self.file.close()


def capture_records(path, digest=None):
    """Reject corrupt framing, without guessing a resynchronization position."""
    with Path(path).open('rb') as source:
        while True:
            offset, prefix = source.tell(), source.read(4)
            if not prefix:
                return
            if len(prefix) != 4:
                raise CaptureFormatError(f'truncated length prefix at byte {offset}')
            count, = struct.unpack('<I', prefix)
            if count > MAX_DATAGRAM:
                raise CaptureFormatError(f'record length {count} exceeds UDP limit at byte {offset}')
            data = source.read(count)
            if len(data) != count:
                raise CaptureFormatError(f'truncated payload at byte {offset}: expected {count}, got {len(data)}')
            if digest is not None:
                digest.update(prefix); digest.update(data)
            yield data


class CaptureSession:
    def __init__(self, output, *, packets_only=False, online=True):
        self.output, self.packets_only = Path(output), packets_only
        self.output.mkdir(parents=True, exist_ok=False)
        self.stats = {'schema': 2, 'mode': 'packets_only' if packets_only else 'decoded_online' if online else 'decoded_offline',
                      'packets': 0, 'received_datagrams': 0, 'invalid_packets': 0, 'samples': 0, 'segments': 0,
                      'sample_rate_num': 156250, 'sample_rate_den': 1, 'raw_channels': 9, 'slot_count': 10,
                      'pcm_format': 'signed little-endian int16', 'board_acceptance': False,
                      'capture_format': 'uint32_le_length_then_original_udp_payload', 'unverified_packets': 0,
                      'missing_packets': 0, 'duplicate_packets': 0, 'reordered_packets': 0,
                      'missing_samples': 0, 'duplicate_samples': 0, 'reordered_samples': 0,
                      'session_changes': 0, 'epoch_changes': 0, 'timestamp_nonmonotonic': 0,
                      'geometry_changes': 0, 'calibration_changes': 0, 'verification_state_changes': 0,
                      'drop_counter_changes': 0, 'events_logged': 0, 'events_omitted': 0,
                      'sample_json_written': not packets_only, 'maximum_c9c2_packet_bytes': MAX_PACKET}
        self.capture = PacketWriter(self.output/'packets.c9') if online else None
        self.events = (self.output/'events.jsonl').open('w', encoding='utf-8')
        self.metadata = None if packets_only else (self.output/'frames.jsonl').open('w', encoding='utf-8')
        self.files, self.segment = [], None
        self.header = self.prior = None
        self.force_break = True

    def event(self, item):
        if self.stats['events_logged'] < MAX_EVENTS:
            self.events.write(json.dumps(item)+'\n')
            self.stats['events_logged'] += 1
        else:
            self.stats['events_omitted'] += 1

    def sequence(self, header, rows):
        reasons, old = [], self.header
        if old:
            if old['session'] != header['session']:
                reasons.append('session_change'); self.stats['session_changes'] += 1
            else:
                delta = (header['packet']-old['packet']) & 0xffffffff
                if delta == 0:
                    reasons.append('duplicate_packet'); self.stats['duplicate_packets'] += 1
                elif delta >= 0x80000000:
                    reasons.append('reordered_packet'); self.stats['reordered_packets'] += 1
                elif delta != 1:
                    reasons.append('packet_gap'); self.stats['missing_packets'] += delta-1
            for key, counter in (('geometry_version', 'geometry_changes'), ('calibration_version', 'calibration_changes'),
                                 ('unverified', 'verification_state_changes'), ('dma_drops', 'drop_counter_changes'),
                                 ('software_drops', 'drop_counter_changes')):
                if header[key] != old[key]:
                    reasons.append(key+'_change'); self.stats[counter] += 1
        self.header = header
        segments = []
        for i, row in enumerate(rows):
            sample, stamp, epoch, tap, dma = row
            why, prior = list(reasons) if i == 0 else [], self.prior
            if prior and prior[0] == header['session']:
                delta = (sample-prior[1]) & 0xffffffff
                if delta == 0:
                    why.append('duplicate_sample'); self.stats['duplicate_samples'] += 1
                elif delta >= 0x80000000:
                    why.append('reordered_sample'); self.stats['reordered_samples'] += 1
                elif delta != 1:
                    why.append('sample_gap'); self.stats['missing_samples'] += delta-1
                if stamp <= prior[2]:
                    why.append('timestamp_nonmonotonic'); self.stats['timestamp_nonmonotonic'] += 1
                if epoch != prior[3]:
                    why.append('epoch_change'); self.stats['epoch_changes'] += 1
                if (tap, dma) != prior[4:6]:
                    why.append('slot_drop_counter_change'); self.stats['drop_counter_changes'] += 1
            if self.force_break or why:
                if self.force_break:
                    why.append('start' if prior is None else 'rejected_packet_boundary')
                self.stats['segments'] += 1
                self.event({'segment': self.stats['segments']-1, 'session': header['session'], 'packet': header['packet'],
                            'sample': sample, 'timestamp': stamp, 'reasons': why})
                self.force_break = False
            segments.append(self.stats['segments']-1)
            self.prior = (header['session'], sample, stamp, epoch, tap, dma)
        return segments

    def consume(self, data):
        self.stats['received_datagrams'] += 1
        if self.capture:
            self.capture.write(data)
        try:
            header, rows = parse_packet(data, not self.packets_only)
        except (ValueError, struct.error):
            self.stats['invalid_packets'] += 1
            self.force_break = True
            return
        self.stats['packets'] += 1
        self.stats['samples'] += len(rows)
        self.stats['unverified_packets'] += int(header['unverified'])
        sequence = rows if self.packets_only else [(r['sample'], r['timestamp'], r['epoch'], r['tap_drops'], r['dma_drops']) for r in rows]
        segments = self.sequence(header, sequence)
        if self.packets_only:
            return
        buffers, lines = [bytearray(), bytearray(), bytearray()], []
        for row, segment in zip(rows, segments):
            if segment != self.segment:
                self.flush_decoded(buffers, lines)
                for f in self.files:
                    f.close()
                self.files = [(self.output/f'segment{segment:04d}_{kind}.pcm').open('wb') for kind in ('raw9', 'fir', 'gsc')]
                self.segment = segment
            buffers[0].extend(struct.pack('<9h', *row['raw']))
            buffers[1].extend(struct.pack('<h', row['fir']))
            buffers[2].extend(struct.pack('<h', row['output']))
            lines.append(json.dumps(dict(header, **{k: v for k, v in row.items() if k != 'raw'}, segment=segment))+'\n')
        self.flush_decoded(buffers, lines)

    def flush_decoded(self, buffers, lines):
        if self.files and lines:
            for f, data in zip(self.files, buffers):
                f.write(data)
            self.metadata.write(''.join(lines))
        for data in buffers:
            data.clear()
        lines.clear()

    def close(self, *, complete=True, elapsed=0.0, error=None, source=None):
        for f in self.files:
            f.close()
        if self.metadata:
            self.metadata.close()
        self.events.close()
        if self.capture:
            self.capture.close()
            self.stats.update(capture_sha256=self.capture.digest.hexdigest(), capture_bytes=self.capture.bytes,
                              capture_buffer_bytes=BUFFER_BYTES, capture_write_batches=self.capture.batches)
        self.stats.update(completed=complete, elapsed_seconds=elapsed)
        if error:
            self.stats['error'] = str(error)
        if source:
            self.stats['source_capture'] = str(Path(source).resolve())
        (self.output/'manifest.json').write_text(json.dumps(self.stats, indent=2)+'\n', encoding='utf-8')
        return self.stats


def decode_capture(source, output):
    session, start = CaptureSession(output, online=False), time.monotonic()
    digest = hashlib.sha256()
    try:
        for data in capture_records(source, digest):
            session.consume(data)
    except (OSError, CaptureFormatError) as error:
        session.close(complete=False, elapsed=time.monotonic()-start, error=error, source=source)
        raise
    session.stats['source_capture_sha256'] = digest.hexdigest()
    return session.close(elapsed=time.monotonic()-start, source=source)


def receive(args):
    if not args.seconds > 0 or not 0 <= args.port <= 65535:
        raise ValueError('seconds positive and port0..65535 required')
    session, start = CaptureSession(args.output, packets_only=args.packets_only), time.monotonic()
    error = None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4*1024*1024)
            sock.bind((args.bind, args.port)); sock.settimeout(.25)
            session.stats['socket_receive_buffer_bytes'] = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
            print(f'Listening {args.bind}:{sock.getsockname()[1]}, mode={session.stats["mode"]}, output={args.output}', flush=True)
            while time.monotonic()-start < args.seconds:
                try:
                    data, _ = sock.recvfrom(MAX_DATAGRAM)
                except socket.timeout:
                    continue
                session.consume(data)
    except KeyboardInterrupt:
        session.stats['operator_interrupted'] = True
    except OSError as caught:
        error = caught
        raise
    finally:
        stats = session.close(complete=error is None, elapsed=time.monotonic()-start, error=error)
        print(json.dumps(stats, indent=2))
    return stats
