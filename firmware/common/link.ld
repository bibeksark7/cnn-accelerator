/* SoC RAM layout (spec 13.5, docs/decisions.md D-042), one 64 KB RAM from address 0:
 *
 *   .text, .rodata            code and constants (never written)
 *   .data                     initialized variables (run address)
 *   .bss                      zero-initialized variables
 *   .data load image          the initial .data contents, copied to .data by crt0.S at every
 *                             reset, so a reset restarts the firmware from its initial state
 *   ... free ...
 *   stack                     grows down from the top of RAM (sp = RAM_BYTES, spec 13.2)
 *
 * The size here must equal soc_top's RAM_BYTES.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K }

__stack_size = 4K;

SECTIONS
{
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(4) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > RAM

  .data : AT(__data_load) ALIGN(4) {
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __data_load = ALIGN(4);
  __image_end = __data_load + (__data_end - __data_start);
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);

  ASSERT(__image_end <= __stack_top - __stack_size, "firmware image leaves less than the stack size")

  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
