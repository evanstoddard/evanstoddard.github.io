---
title: "TrustZone Demystified: Part 1 (Appendix)"
description: "A deeper dive into some of the technical details for TrustZone Demystified Part 1."
author: Evan Stoddard
date: 2026-04-18 12:00:00 -0600
categories: [Firmware, Security]
tags: [TrustZone, armv8, STM32, firmware, security]
pin: true
math: true
mermaid: true
---

# Overview

This post is a follow-up/appendix to [TrustZone Demystified: Part 1](/posts/trustzone-demystified_part_1/).   The aim is to provide a deeper dive into some of the topics discussed in that article. It's recommended that you either read that article first, or keep both articles open so you can bounce between the two.

# The Hardware Involved

TrustZone on Cortex-M is enforced by a layered set of hardware components.  Some of these are part of the ARM architecture specification and will be present on any Cortex-M33 with TrustZone enabled.  Others are silicon-vendor additions that sit outside the core and extend enforcement to peripherals and memory controllers.  The STM32H5 is used as the concrete example throughout this article, but other vendors (NXP, Nordic, Renesas, etc.) implement equivalent mechanisms under different names.

## SAU (Security Attribution Unit)

The SAU is part of the Cortex-M33 core itself and is defined by the ARM architecture.  It is the primary mechanism the CPU uses to decide whether a given address is Secure (S), Non-Secure (NS), or Non-Secure Callable (NSC).

The SAU works by defining a set of address regions.  Each region is configured with three registers:

- `RNR` (Region Number Register): selects which region slot you are configuring.
- `RBAR` (Region Base Address Register): sets the start address of the region.  Must be 32-byte aligned.
- `RLAR` (Region Limit Address Register): sets the end address, with two control bits.  The `NSC` bit marks the region as Non-Secure Callable rather than plain Non-Secure.  The `ENABLE` bit activates the region.

The S firmware configures the SAU at startup before handing off to the NS image.  For the firmware in this article, that configuration looks like this:

```c
SAU->RNR  = 0;           // select region 0
SAU->RBAR = 0x0C0FE000;  // base address of NSC region
SAU->RLAR = 0x0C0FFFFF | SAU_RLAR_NSC_Msk | SAU_RLAR_ENABLE_Msk;
```

Any address not covered by a configured, enabled SAU region defaults to Secure.

## IDAU (Implementation Defined Attribution Unit)

The SAU does not work alone.  The ARM architecture defines a second parallel attribution layer called the IDAU, whose implementation is left entirely to the silicon vendor.  On every memory access, both the SAU and the IDAU produce a security attribute for the address.  The CPU takes the more restrictive result.

On the STM32H5, the IDAU is what enforces the address aliasing described in the linker script section.  The `0x0C000000` range is hardwired by the IDAU as always-Secure, regardless of SAU configuration.  The `0x08000000` range is always Non-Secure.  This means S firmware cannot accidentally open up the S flash alias to NS access by misconfiguring the SAU, because the IDAU will still mark it Secure.

## Option Bytes and Flash Watermarking (STM32H5)

The SAU and IDAU determine what the CPU sees at runtime.  But before any software runs, the flash controller itself needs to know which pages are Secure.  On the STM32H5 this is handled by the SECWM (Secure Watermark) option bytes, which are programmable fields that define a start and end sector for the secure flash region in each flash bank.

The flash controller reads these at reset and marks the covered pages as Secure in hardware.  Any NS bus transaction targeting those pages is rejected at the flash controller, independent of what the SAU says.  This provides a boot-time hardware lock: even if S firmware has a bug that misconfigures the SAU, the SECWM ensures NS code still cannot read or execute from S flash pages.

Other vendors implement equivalent mechanisms.  Nordic nRF9160 and nRF5340 use a peripheral called SPU (System Protection Unit) to assign flash pages and peripherals to S or NS.  NXP's LPC55S69 uses a similar AHB security controller.  The underlying concept is the same: a vendor-defined unit that enforces security at the bus or flash-controller level before the core's SAU has a chance to be involved.

## GTZC (Global TrustZone Controller) (STM32H5)

The SAU is a core-level unit: it interprets addresses on instructions the CPU executes.  It does not see DMA transfers or transactions from other bus masters.  The GTZC fills that gap on the STM32H5.  It sits in the AHB bus fabric and inspects the security attribute on every bus transaction, regardless of which bus master initiated it.

The GTZC has two main subcomponents relevant here:

**MPCBB (Memory Protection Controller, Block-Based):** Divides each internal SRAM bank into configurable blocks and assigns each block a security attribute.  This is what ensures that a DMA controller operating in NS context cannot read Secure SRAM, even if the CPU's SAU would otherwise be out of the picture.

**TZIC (TrustZone Interrupt Controller):** Filters which interrupts can be seen by NS firmware.  Secure interrupts are hidden from the NS NVIC entirely.

The practical distinction is: the SAU protects against CPU-driven accesses, the GTZC protects against bus-driven accesses.  Both are needed for a complete security boundary.  Other vendors provide equivalent bus-fabric security controllers under different names (Nordic's SPU also covers this, NXP uses its AHB secure controller for the same purpose).

# Exploring the Assembly of `CMSE_NS_ENTRY` Calls

In the article, the UART peripheral is initialized as a secure peripheral.  As a result, an entry point for a secure function that puts characters out over UART is implemented so the NS image can write to the UART console.

There are a couple parts here.  The entry point is declared in `secure_nsc.h` as `int SECURE_put_char_uart(int ch)`.

This is callable by the NS firmware, and this is called in `int __io_putchar(int ch)`, to bind `printf` to UART.

The definition of this secure function is defined in the S firmware as:

```c
CMSE_NS_ENTRY int SECURE_put_char_uart(int ch) {
  ...
}
```

When the NS firmware calls `SECURE_put_char_uart`, it doesn't directly call the function defined in the S firmware, however.  There are actually two stubs involved.

The first is an NS-side import stub in `secure_nsclib.o`, which is automatically generated by the toolchain and linked with the NS firmware.  This stub is a simple trampoline: it loads the address of the NSC entry point into the PC and jumps there.

The second is the actual CMSE veneer, which lives in the `FLASH_NSC` region of the S image.  This is the stub that begins with the `SG` (Secure Gateway) instruction, which performs the NS-to-S state transition and validates that the call originated from a legitimate NS caller.  After `SG`, the veneer branches to the real `SECURE_put_char_uart` implementation in S flash.

Additionally, some cleanup instructions are added to the epilogue of `SECURE_put_char_uart` in the S image to scrub registers before returning to NS.

At a high level: NS code calls the import stub, the stub jumps to the NSC region, `SG` transitions the processor to S mode, and then execution continues in the actual function.

## Exploring the Linker Scripts

Before we look at some of the disassembly, I think it's important to talk about how all of this links together.

Let's take a look at a portion of the S firmware linker script:

```c
MEMORY
{
  RAM    (xrw)    : ORIGIN = 0x30000000,    LENGTH = 320K    /* Memory is divided. Actual start is 0x20000000 and actual length is 640K */
  FLASH    (rx)    : ORIGIN = 0xc000000,    LENGTH = 1016K    /* Memory is divided. Actual start is 0x8000000 and actual length is 2048K */
  FLASH_NSC    (rx)    : ORIGIN = 0xc0fe000,    LENGTH = 8K    /* Non-Secure Call-able region */
}
```

The STM32H563 used in this article has 2 MB of total flash, and 640K of total RAM.  In this project, the first half of flash and first half of RAM are allocated for the S firmware.  Note the use of the secure alias of the addresses.  

In most (if not all?) STM32s, RAM address space physically starts at 0x20000000.  However, there is an alias to that same address space which starts at `0x30000000`.  Physically, they're the same chunks of memory, but the alias is used to differentiate between S and NS access.  

Similar story with flash.  Physically, flash address space starts `0x08000000`, which is also the address space used by NS firmware.  It is aliased to `0x0C000000` for S firmware.

Peripheral addresses also have the same aliasing.

What you'll notice here is that there's another section that lives in S flash, called `FLASH_NSC`.  In this case, it lives in the last 8K of S flash, and this is where the CMSE veneers (the stubs with the `SG` instruction) go.  The NS-side import stubs in `secure_nsclib.o` point into this region; the actual NS-to-S transition happens here.

## Disassembly of NS `__io_putchar`

Let's take a quick look at the disassembly of `__io_putchar` in the NS firmware:

```armasm
08100d9a <__io_putchar>:
 8100d9a:  b580        push  {r7, lr}
 8100d9c:  b082        sub   sp, #8
 8100d9e:  af00        add   r7, sp, #0
 8100da0:  6078        str   r0, [r7, #4]      ; save char arg to stack
 8100da2:  6878        ldr   r0, [r7, #4]      ; reload into r0
 8100da4:  f000 fcc4   bl    8101730 <__SECURE_put_char_uart_veneer>
 8100da8:  2300        movs  r3, #0
 8100daa:  4618        mov   r0, r3             ; return 0
 8100dac:  3708        adds  r7, #8
 8100dae:  46bd        mov   sp, r7
 8100db0:  bd80        pop   {r7, pc}
```

The point of interest is the `bl` instruction which branches into the NS-side import stub.

That stub is pretty small:

```armasm
 8101730:  f85f f000   ldr.w  pc, [pc]         ; load address from literal pool into PC
 8101734:  0c0fe001    .word  0x0c0fe001        ; literal: 0x0c0fe000 | 1 (Thumb bit)
```

There's a bit to unpack from these two lines.

The first line is loading a value into the program counter register.  

A quick note about the program counter (PC) in ARM MCUs.  Say there's an instruction at address 0x08000000, by the time that instruction is being executed, the PC has already incremented to 0x08000004.  To drive the point home, if the instruction at 0x08000000 was `mov r0, pc`, which moves the current value of the PC to register 0, register 0 would contain 0x08000004, not 0x08000000.

A second note: when you load an address into the PC register, the CPU immediately executes the instruction at that address.

The second argument to `ldr.w` is `[pc]`, which means "read the word stored at the address currently in the PC."  Concretely: the `ldr.w` instruction is at `0x08101730`, so by the time it executes the PC has already advanced to `0x08101734`.  The instruction therefore reads the 32-bit word stored at `0x08101734`, which is the `.word` on the very next line: `0x0c0fe001`.  That value gets written into the PC, which causes the processor to jump there immediately.

In C-like pseudocode:

```c
uint32_t target = *(uint32_t *)pc;  // pc == 0x08101734 at execution time
pc = target;                         // jump to 0x0c0fe001
```

ARM Cortex-M cores run in Thumb mode, which uses a compact 16/32-bit instruction encoding rather than the original 32-bit ARM encoding.  You'll notice bit 0 of `0x0c0fe001` is set: in ARM, bit 0 of an address loaded into the PC is not part of the instruction address itself; it signals that the target is Thumb code.  The processor strips bit 0 before fetching, so execution actually begins at `0x0c0fe000`.

## Disassembly of Veneer

The address `0x0c0fe000` should look familiar.  It is the start address of the `FLASH_NSC` section called out in the S firmware linker script.  This section contains the CMSE veneers that trampoline into the S functions.  The veneer for `SECURE_put_char_uart` is the first entry in this section.

Let's take a look at the disassembly of this veneer.

```armasm
0c0fe000 <SECURE_put_char_uart>:
 c0fe000:  e97f e97f   sg
 c0fe004:  f70a bc4a   b.w    c00889c <__acle_se_SECURE_put_char_uart>
```

The first instruction is `sg` (Secure Gateway).  When NS code branches to an NSC address, the processor checks that `SG` is the instruction it lands on.  If it isn't, a SecureFault fires immediately.  When `SG` does execute, it performs the NS-to-S state transition: it flips the processor's security state to S and rewrites LR to a special sentinel value (`FNC_RETURN`) that the processor will recognize later when returning to NS.

This is followed by a branch to `__acle_se_SECURE_put_char_uart`, which is the actual `SECURE_put_char_uart` implementation in the S firmware.  The `__acle_se_` prefix is a toolchain convention used to differentiate the real implementation symbol from the veneer entry point symbol.

### Trying to Bypass the NSC Region

After reading the veneer, a natural question is: "Could I just branch directly from NS code to any S function, bypassing the NSC region entirely?"  The `sg` instruction is what performs the NS-to-S state transition, and you can see it in the veneer.  So the follow-up question is: "What if I just executed `sg` myself and then called whatever S function I wanted?"

I tried exactly that.

In the S firmware linker script, I placed a function at a fixed address inside the S flash region, but outside the NSC region:

```
  /* Secure target function at a known fixed address for TrustZone experiments.
     Branch to 0x0c010001 (Thumb) from NS to test sg / INVEP behavior. */
  .secure_target 0x0c010000 :
  {
    KEEP(*(.secure_target_func))
  } >FLASH
```

I then defined the function to go into that section which will print "secure_target reached!" if executed:

```c
__attribute__((section(".secure_target_func"), noinline))
void secure_target(void) {
  LOG_INF("secure_target reached!");
}
```

In the NS firmware, I added the following code to execute once the user button is pressed.  The `sg` inline asm runs first (in NS context), and then the function pointer call branches directly to the S address:

```c
      void (*super_secret_function)(void) = (void (*)(void))0x0c010000;
      __asm volatile("sg");
      super_secret_function();
```

Running this, we're rewarded with a SecureFault:

```
[SECURE] ERR: **** Secure Fault ****
[SECURE] ERR:   r0:   0x0c0002a1  r1:   0x00100000
[SECURE] ERR:   r2:   0x00000000  r3:   0x00000000
[SECURE] ERR:   r12:  0x00000000  lr:   0x00000000
[SECURE] ERR:   pc:   0x00000000  xpsr: 0x00000000
[SECURE] ERR:   sp:   0x3004ff98
[SECURE] ERR:   EXC_RETURN: 0xffffffa9  mode=Thread   stack=MSP  security=NS
[SECURE] ERR:   HFSR: 0x00000000
[SECURE] ERR:   CFSR: 0x00000000
[SECURE] ERR:   SFSR: 0x00000001  INVEP
[SECURE] ERR:   SHCSR: 0x000f0010
[SECURE] ERR:     ena:  SFAULTENA  BFAULTENA  UFAULTENA  MFAULTENA
[SECURE] ERR:     act:  SFAULT
[SECURE] ERR:   [NS] HFSR: 0x00000000
[SECURE] ERR:   [NS] CFSR: 0x00000000
[SECURE] ERR:   SFSR: 0x00000001  INVEP
```

There are two things to note here.

First, executing `sg` while already in NS state (from NS flash) does nothing useful.  `sg` only performs the NS-to-S transition when the CPU is in NS state and the instruction is fetched from an NSC-attributed address.  Executed from plain NS flash, it is effectively a no-op, so the CPU is still in NS state when the function pointer call fires.

Second, and more importantly, the SFSR shows `INVEP` (Invalid Entry Point).  This fires because the CPU branched from NS execution to an S address that is not in the NSC region.  The NSC region is the only legal entry point into S from NS code.  Branching directly to any S address outside of it, regardless of what instructions are there, results in an immediate SecureFault.

The bottom line: you cannot bypass the NSC region.  The trampoline into the S function **must** live in the NSC section of flash.

In our case, that is the `FLASH_NSC` section defined in the S firmware linker script starting at address `0x0c0fe000`.  The SAU configuration shown in the [SAU section above](#sau-security-attribution-unit) is what marks that region as NSC, which is what the processor checks before allowing the transition.

## Disassembly of `SECURE_put_char_uart`

After the secure function performs its task, the processor needs to be put back into an NS state.  This involves cleaning up the registers to avoid any data leaks from S to NS, and branching back to the return site of the calling function.

Here's the disassembly of the `SECURE_put_char_uart` function implemented in the S firmware:

```armasm
; --- prologue ---
 c00889c:  b580        push  {r7, lr}
 c00889e:  b082        sub   sp, #8
 c0088a0:  af00        add   r7, sp, #0
 c0088a2:  6078        str   r0, [r7, #4]
 c0088a4:  6878        ldr   r0, [r7, #4]
 c0088a6:  f000 f90d   bl    c008ac4 <__io_putchar>   ; Secure-side UART transmit

 ; --- return value ---
 c0088aa:  2300        movs  r3, #0
 c0088ac:  4618        mov   r0, r3
 c0088ae:  3708        adds  r7, #8
 c0088b0:  46bd        mov   sp, r7
 c0088b2:  e8bd 4080   ldmia.w  sp!, {r7, lr}         ; restore frame, keep lr for scrubbing

 ; --- register scrubbing ---
 c0088b6:  4671        mov   r1, lr            ; poison r1-r3 with lr value
 c0088b8:  4672        mov   r2, lr
 c0088ba:  4673        mov   r3, lr
 c0088bc:  eeb7 0a00   vmov.f32  s0,  #1.0    ; scrub s0-s15
 c0088c0:  eef7 0a00   vmov.f32  s1,  #1.0
 c0088c4:  eeb7 1a00   vmov.f32  s2,  #1.0
 c0088c8:  eef7 1a00   vmov.f32  s3,  #1.0
 c0088cc:  eeb7 2a00   vmov.f32  s4,  #1.0
 c0088d0:  eef7 2a00   vmov.f32  s5,  #1.0
 c0088d4:  eeb7 3a00   vmov.f32  s6,  #1.0
 c0088d8:  eef7 3a00   vmov.f32  s7,  #1.0
 c0088dc:  eeb7 4a00   vmov.f32  s8,  #1.0
 c0088e0:  eef7 4a00   vmov.f32  s9,  #1.0
 c0088e4:  eeb7 5a00   vmov.f32  s10, #1.0
 c0088e8:  eef7 5a00   vmov.f32  s11, #1.0
 c0088ec:  eeb7 6a00   vmov.f32  s12, #1.0
 c0088f0:  eef7 6a00   vmov.f32  s13, #1.0
 c0088f4:  eeb7 7a00   vmov.f32  s14, #1.0
 c0088f8:  eef7 7a00   vmov.f32  s15, #1.0
 c0088fc:  f38e 8c00   msr   CPSR_fs, lr       
 c008900:  b410        push  {r4}
 c008902:  eef1 ca10   vmrs  ip, fpscr
 c008906:  f64f 7460   movw  r4, #0xff60
 c00890a:  f6c0 74ff   movt  r4, #0xfff
 c00890e:  ea0c 0c04   and.w ip, ip, r4        
 c008912:  eee1 ca10   vmsr  fpscr, ip
 c008916:  bc10        pop   {r4}
 c008918:  46f4        mov   ip, lr
 c00891a:  4774        bxns  lr                ; Branch eXchange Non-Secure — return to NS
```

The prologue and return value sections of this block are a standard function prologue.  The unique part added automatically by the compiler is the chunk of code in the register scrubbing section.

The first three `mov` instructions are used to "poison" the general purpose registers, `r1`-`r3`.  This is important because any data that the secure firmware operated on could still be in those registers by the time we're ready to return to the NS state.  That secure data would ultimately leak and be accessible to the NS firmware.  

Next, we write `1.0` to all the floating point registers for the same exact reason as filling the general purpose registers with garbage.

Finally, `bxns` is executed, which branches back to the return address of the call site, causing the MCU to return to an NS state.

# Exploring the Assembly of `CMSE_NS_CALL` Calls

## Why the Direct Call Faulted

In the main article, calling `prv_gpio_irq_cb(GPIO_Pin)` directly from the S GPIO IRQ handler without `CMSE_NS_CALL` triggered a HardFault.

Without the attribute, the compiler treats the NS function pointer like any other and emits a standard `blx r3`, a plain branch from S execution state to NS memory.  The processor prohibits this: transitioning from S to NS requires the dedicated `blxns` instruction.  A regular `blx` to an NS address from S state raises a SecureFault with the INVTRAN (Invalid Transition) bit set in the SFSR.  Because the fault fired inside an interrupt handler with a SecureFault already active, it escalated to a HardFault.

## What `CMSE_NS_CALL` Generates

Applying the `CMSE_NS_CALL` cast changes what the compiler emits.  Rather than a plain branch, it routes the call through a compiler runtime helper called `__gnu_cmse_nonsecure_call`, which handles register scrubbing and performs the actual `blxns`.

### Call Site: `HAL_GPIO_EXTI_Falling_Callback`

```armasm
 ; load callback, set up argument, scrub registers
 c0094a2:  4b1e        ldr   r3, [pc, #120]  @ address of prv_gpio_irq_cb
 c0094a4:  681b        ldr   r3, [r3, #0]    @ r3 = callback function pointer
 c0094a6:  2b00        cmp   r3, #0
 c0094a8:  d02b        beq.n c009502         @ skip if NULL
 c0094aa:  4b1c        ldr   r3, [pc, #112]
 c0094ac:  681b        ldr   r3, [r3, #0]    @ r3 = callback function pointer
 c0094ae:  88fa        ldrh  r2, [r7, #6]    @ r2 = GPIO_Pin
 c0094b0:  4610        mov   r0, r2          @ r0 = argument to callback
 c0094b2:  461c        mov   r4, r3          @ r4 = callback address
 c0094b4:  0864        lsrs  r4, r4, #1
 c0094b6:  0064        lsls  r4, r4, #1      @ strip bit 0 (required by blxns)
 c0094b8:  4621        mov   r1, r4          @ scrub r1-r3
 c0094ba:  4622        mov   r2, r4
 c0094bc:  4623        mov   r3, r4
 c0094be:  eeb7 0a00   vmov.f32  s0, #1.0   @ scrub s0-s15
 ...
 c0094fa:  eef7 7a00   vmov.f32  s15, #1.0
 c0094fe:  f7f6 fea5   bl    c00024c <__gnu_cmse_nonsecure_call>
```

### Runtime Helper: `__gnu_cmse_nonsecure_call`

```armasm
0c00024c <__gnu_cmse_nonsecure_call>:
 c00024c:  e92d 4fe0   stmdb sp!, {r5, r6, r7, r8, r9, sl, fp, lr}  @ save callee-saved regs
 c000250:  4627        mov   r7, r4          @ scrub callee-saved integer regs with r4
 c000252:  46a0        mov   r8, r4
 c000254:  46a1        mov   r9, r4
 c000256:  46a2        mov   sl, r4
 c000258:  46a3        mov   fp, r4
 c00025a:  46a4        mov   ip, r4
 c00025c:  ed2d 8b10   vpush {d8-d15}                                 @ save callee-saved FP regs
 c000260:  f04f 0500   mov.w r5, #0
 c000264:  ec45 5b18   vmov  d8, r5, r5     @ zero-scrub d8-d15 (s16-s31)
 ...
 c000284:  eef1 5a10   vmrs  r5, fpscr      @ mask sensitive FPSCR bits
 c000288:  f64f 7660   movw  r6, #0xff60
 c00028c:  f6c0 76ff   movt  r6, #0xfff
 c000290:  4035        ands  r5, r6
 c000292:  eee1 5a10   vmsr  fpscr, r5
 c000296:  f384 8800   msr   CPSR_f, r4     @ scrub APSR condition flags
 c00029a:  4625        mov   r5, r4
 c00029c:  4626        mov   r6, r4
 c00029e:  47a4        blxns r4             @ transition to NS and call the callback
 c0002a0:  ecbd 8b10   vpop  {d8-d15}       @ restore callee-saved FP regs
 c0002a4:  e8bd 8fe0   ldmia.w sp!, {r5, r6, r7, r8, r9, sl, fp, pc}  @ restore and return
```

`blxns r4` is the instruction that performs the S-to-NS transition.  It branches to the callback address in r4, transitions the processor to NS state, and stores the return address in LR pointing back into S memory.  When the NS callback finishes and executes `bx lr`, the processor sees the return address is in S memory and transitions back to S automatically.

# Conclusion 

Hopefully, this scratches the itch for those who were interested in some of the inner workings of TrustZone.  If you haven't read the main article yet, head over to [TrustZone Demystified: Part 1](/posts/trustzone-demystified_part_1/) to see these mechanisms in action with actual firmware.

I do recommend taking a look at ARM and vendor documentation regarding TrustZone if you're struggling to sleep.  There is a lot more to explore and learn.  I've linked some sources below.

All that I've written is based on my experimentation and reading of documentation.  So, if something seems incorrect, definitely let me know! 

- [ARMv8-M Architecture Reference Manual](https://developer.arm.com/documentation/ddi0553/latest)
- [Cortex-M33 Technical Reference Manual](https://developer.arm.com/documentation/100230/latest)
- STM32H563 Reference Manual (RM0481), available on st.com
