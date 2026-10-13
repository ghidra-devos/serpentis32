; boot sector. reads the kernel in four 64 KB pieces with the int 13h extensions, one read
; can not cross a segment. then a20, the gdt and the far jump to 32 bit
format binary as 'img'
org 0x7C00
use16

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [boot_drv], dl
    mov ax, 0x0003
    int 0x10
    mov  word [dap_count], 128
    mov  word [dap_seg], 0x1000
    mov  dword [dap_lba_lo], 1
    mov  dword [dap_lba_hi], 0
    mov  ah, 0x42
    mov  dl, [boot_drv]
    mov  si, dap
    int  0x13
    jc   .disk_err
    mov  word [dap_count], 128
    mov  word [dap_seg], 0x2000
    mov  dword [dap_lba_lo], 129
    mov  dword [dap_lba_hi], 0
    mov  ah, 0x42
    mov  dl, [boot_drv]
    mov  si, dap
    int  0x13
    jc   .disk_err
    mov  word [dap_count], 128
    mov  word [dap_seg], 0x3000
    mov  dword [dap_lba_lo], 257
    mov  dword [dap_lba_hi], 0
    mov  ah, 0x42
    mov  dl, [boot_drv]
    mov  si, dap
    int  0x13
    jc   .disk_err
    mov  word [dap_count], 128
    mov  word [dap_seg], 0x4000
    mov  dword [dap_lba_lo], 385
    mov  dword [dap_lba_hi], 0
    mov  ah, 0x42
    mov  dl, [boot_drv]
    mov  si, dap
    int  0x13
    jc   .disk_err
    in al, 0x92
    or al, 2
    out 0x92, al
    cli
    lgdt [gdt_desc]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    db 0x66, 0xEA
    dd 0x00010000
    dw 0x08
.disk_err:
    mov ax, 0x0003
    int 0x10
    mov si, err_msg
.ep:
    lodsb
    or al, al
    jz $
    mov ah, 0x0E
    int 0x10
    jmp .ep

align 4

; disk address packet for int 13h ah=42h, the fields get filled in before every read
dap:
    db 0x10
    db 0

dap_count:
    dw 0
    dw 0x0000

dap_seg:
    dw 0

dap_lba_lo:
    dd 0

dap_lba_hi:
    dd 0
boot_drv db 0
err_msg db 'BOOT ERROR',0

align 8

gdt_start:
    dq 0
    dw 0xFFFF, 0x0000, 0x9A00, 0x00CF
    dw 0xFFFF, 0x0000, 0x9200, 0x00CF

gdt_end:

gdt_desc:
    dw gdt_end - gdt_start - 1
    dd gdt_start
rb 510-($ - $$)
dw 0xAA55
