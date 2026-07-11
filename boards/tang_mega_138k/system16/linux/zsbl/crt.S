/* GoRV32 Plus ZSBL startup: runs XIP at 0x80000000, stack and data in the
 * on-chip RAM at 0x40000000. Hart 0 boots, every other hart parks in wfi. */
	.section .text.start, "ax"
	.globl _start
_start:
	csrr	t0, mhartid
	bnez	t0, park
	la	sp, __stack_top
	/* Copy .data from its flash load address into on-chip RAM. */
	la	t0, __data_load
	la	t1, __data_start
	la	t2, __data_end
1:	bgeu	t1, t2, 2f
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	j	1b
2:	/* Clear .bss. */
	la	t1, __bss_start
	la	t2, __bss_end
3:	bgeu	t1, t2, 4f
	sw	zero, 0(t1)
	addi	t1, t1, 4
	j	3b
4:	call	main
park:
	wfi
	j	park
