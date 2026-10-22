"""Run the XDC generator in Tcl, then check both profiles and reject control flow."""
from pathlib import Path
import ctypes,ctypes.util,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/pdm_constraints_check';OUT.mkdir(parents=True,exist_ok=True)
def main():
    name=ctypes.util.find_library('tcl8.6')
    if not name:raise RuntimeError('Run this check in WSL with libtcl8.6 installed')
    lib=ctypes.CDLL(name)
    lib.Tcl_CreateInterp.restype=ctypes.c_void_p
    lib.Tcl_Eval.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
    lib.Tcl_GetStringResult.argtypes=[ctypes.c_void_p];lib.Tcl_GetStringResult.restype=ctypes.c_char_p
    lib.Tcl_DeleteInterp.argtypes=[ctypes.c_void_p]
    interp=lib.Tcl_CreateInterp()
    def evaluate(command):
        status=lib.Tcl_Eval(interp,command.encode())
        message=lib.Tcl_GetStringResult(interp).decode()
        if status:raise RuntimeError(message)
    try:
        evaluate('source {'+str(ROOT/'scripts/apply_pdm_constraints.tcl')+'}')
        template=ROOT/'constrs/ps_pl_wrapper.xdc'
        pins=['Y16','Y17','T15','T14','W16','T17','V18','V17']
        for channels,lines in ((12,6),(16,8)):
            target=OUT/f'pdm{channels}.xdc'
            evaluate(f'write_pdm_constraints {{{template}}} {{{target}}} {lines}')
            text=target.read_text()
            assert not re.search(r'^\s*(if|foreach|for|while|puts|source)\b',text,re.M)
            actual=re.findall(r'PACKAGE_PIN (\w+).*get_ports \{pdm_din_i\[(\d+)\]\}',text)
            assert actual==[(pin,str(i)) for i,pin in enumerate(pins[:lines])]
            assert 'tacho_s1_q_reg' not in text
            print(f'PDM_XDC_PROFILE_PASS channels={channels} DATA={lines} control_flow=0')
        corrupt=OUT/'unsupported.xdc';corrupt.write_text(template.read_text()+'\nif {1} {puts bad}\n')
        try:evaluate(f'write_pdm_constraints {{{corrupt}}} {{{OUT/"bad.xdc"}}} 6')
        except RuntimeError as error:assert 'Unsupported control flow' in str(error)
        else:raise AssertionError('Unsupported XDC was accepted')
        print('PDM_XDC_NEGATIVE_PASS unsupported_control_flow_rejected=1')
    finally:lib.Tcl_DeleteInterp(interp)
if __name__=='__main__':main()
