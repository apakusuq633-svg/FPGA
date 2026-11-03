"""Geometry gate: known topology is not a physical channel assignment."""
import itertools, math
PAIRS=tuple(itertools.combinations(range(12),2))
RING_LAGS=tuple(range(16))+tuple(range(-16,0))
def validate(config):
    assert config.get('role','PRODUCTION') in ('PRODUCTION','TEST_GEOMETRY')
    assert config['channels']==12 and config['pairs']==len(PAIRS)
    assert config.get('coordinate_unit','m')=='m'
    xyz=config.get('mic_xyz');mapping=config.get('channel_to_mic')
    if xyz is None or mapping is None or not config.get('physical_mapping_confirmed'):
        return {'geometry_enabled':False,'pairs':len(PAIRS),'reason':'missing measured XYZ or confirmed mapping',
                'ring_lags':RING_LAGS,'ring_geometry_validated':False}
    assert len(xyz)==12 and all(len(p)==3 and all(math.isfinite(v) for v in p) for p in xyz)
    assert sorted(mapping)==list(range(12)), 'mapping must be a permutation'
    xyz=[xyz[i] for i in mapping]
    fs=config['sample_rate_hz'];c=config.get('sound_speed_m_s',343.0)
    assert fs>0 and c>0
    required=[]
    for a,b in PAIRS:
        d=math.dist(xyz[a],xyz[b]);assert d>0,'coincident microphones'
        bound=math.ceil(d*fs/c)
        # Conservative support for both signs plus idx+1 interpolation sample.
        required.append({'a':a,'b':b,'distance_m':d,'max_abs_integer_lag':bound,
                         'safe':bound<=14})
    safe=all(p['safe'] for p in required)
    return {'geometry_enabled':safe and config.get('role')!='TEST_GEOMETRY',
            'ring_geometry_validated':safe,'pairs':required,'ring_lags':RING_LAGS,
            'reason':'validated' if safe else '32-point ring insufficient; do not build production LUT'}
def validate_query(integer_lag,fraction_q4):
    assert 0<=fraction_q4<16
    assert integer_lag in RING_LAGS and (not fraction_q4 or integer_lag+1 in RING_LAGS), 'query outside extracted lag support'
    return integer_lag%32
