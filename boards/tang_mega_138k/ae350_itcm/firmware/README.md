# ITCM test firmware

`itcm_initial/itcm0` through `itcm3` are Gowin's AE350 v1.2 default ITCM
bring-up program, copied from the locally installed IP package. The four files
are byte lanes for a 64-KiB ITCM image.

The program expects a 100-MHz APB/UART clock and sends its UART2 output at
38400 baud, 8N1. It is embedded in the protected AE350 netlist by
`tools/regenerate_ae350_itcm_core.ps1`.
