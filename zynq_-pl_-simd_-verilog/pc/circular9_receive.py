"""Receive C9C2, preserving original PCM/provenance with optional deferred decode.

python pc/circular9_receive.py --seconds 30 --output recordings/run01
python pc/circular9_receive.py --packets-only --seconds 30 --output recordings/run01
python pc/circular9_receive.py --decode-capture recordings/run01/packets.c9 --output recordings/run01_decoded
Use a new directory. Discontinuities start new PCM files; no silent concatenation.
"""
import argparse
import json
from pathlib import Path
from circular9_capture import parse_packet, decode_capture, receive

def decode(data):
    """Keep the original public decoder API for protocol fixtures and callers."""
    return parse_packet(data, detailed=True)

def main(argv=None):
    p=argparse.ArgumentParser();p.add_argument('--bind',default='0.0.0.0');p.add_argument('--port',type=int,default=1234)
    p.add_argument('--seconds',type=float,default=30);p.add_argument('--output',type=Path,required=True)
    mode=p.add_mutually_exclusive_group()
    mode.add_argument('--packets-only',action='store_true',help='Batch original packets and CRC/sequence statistics; defer sample PCM/JSON work.')
    mode.add_argument('--decode-capture',type=Path,help='Decode a saved packets.c9 offline; opens no UDP socket.')
    a=p.parse_args(argv)
    if a.decode_capture:
        stats=decode_capture(a.decode_capture,a.output)
        print(json.dumps(stats,indent=2));return stats
    return receive(a)

if __name__=='__main__':main()
