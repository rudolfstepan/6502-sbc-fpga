@echo off
@REM Upload the D_Y_S_P_I_D_C_E_part_2 native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_d_y_s_p_i_d_c_e_part_2.rom" --split-rom --port COM15 --baud 115200 --run --verbose
