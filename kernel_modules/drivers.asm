; pic, the keyboard isr and the ata driver. the disk is polled pio, one sector at a time

; irqs moved to 0x20 and up. the timer and the slave pic stay masked, the keyboard is on
pic_init:
    mov  al, 0x11
    out  0x20, al
    out  0xA0, al
    mov  al, 0x20
    out  0x21, al
    mov  al, 0x28
    out  0xA1, al
    mov  al, 0x04
    out  0x21, al
    mov  al, 0x02
    out  0xA1, al
    mov  al, 0x01
    out  0x21, al
    out  0xA1, al
    mov  al, 0x1D
    out  0x21, al
    mov  al, 0xFF
    out  0xA1, al
    ret

isr_default:
    push eax
    mov  al, 0x20
    out  0x20, al
    pop  eax
    iretd

isr_keyboard:
    pushad
    in   al, 0x60
    test al, 0x80
    jnz  .release
    cmp  al, 0x2A
    je   .shift_down
    cmp  al, 0x36
    je   .shift_down
    mov  [scancode], al
    cmp  byte [mode], 0
    je   .shell
    cmp  byte [mode], 1
    je   .game
    cmp  byte [mode], 3
    je   .auth
    cmp  byte [mode], 5
    je   .mode_serpen
    cmp  byte [mode], 6
    je   .mode_pong
    call key_editor
    jmp  .eoi
.shell:
    call key_shell
    jmp  .eoi
.game:
    call key_game
    jmp  .eoi
.auth:
    call key_auth
    jmp  .eoi
.serpen:
    call key_serpen
    jmp  .eoi
.mode_serpen:
    call key_serpen
    jmp  .eoi
.mode_pong:
    call key_pong
    jmp  .eoi
.shift_down:
    mov  byte [shift_state], 1
    jmp  .eoi
.release:
    and  al, 0x7F
    cmp  al, 0x2A
    je   .shift_up
    cmp  al, 0x36
    je   .shift_up
    jmp  .eoi
.shift_up:
    mov  byte [shift_state], 0
.eoi:
    mov  al, 0x20
    out  0x20, al
    popad
    iretd

ata_wait_ready:
    push eax
    push edx
    mov  dx, 0x1F7
.spin:
    in   al, dx
    test al, 0x80
    jnz  .spin
    pop  edx
    pop  eax
    ret

ata_wait_drq:
    push eax
    push edx
    mov  dx, 0x1F7
.spin:
    in   al, dx
    test al, 0x08
    jz   .spin
    pop  edx
    pop  eax
    ret

; eax = lba, edi = 512 bytes. lba28, master on the primary channel
ata_read_sector:
    pusha
    call ata_wait_ready
    mov  ebx, eax
    mov  dx, 0x1F2
    mov  al, 1
    out  dx, al
    mov  dx, 0x1F3
    mov  al, bl
    out  dx, al
    mov  dx, 0x1F4
    mov  al, bh
    out  dx, al
    mov  dx, 0x1F5
    shr  ebx, 16
    mov  al, bl
    out  dx, al
    mov  dx, 0x1F6
    mov  al, bh
    and  al, 0x0F
    or   al, 0xE0
    out  dx, al
    mov  dx, 0x1F7
    mov  al, 0x20
    out  dx, al
    call ata_wait_drq
    mov  dx, 0x1F0
    mov  ecx, 256
    cld
    rep  insw
    popa
    ret

ata_write_sector:
    pusha
    call ata_wait_ready
    mov  ebx, eax
    mov  dx, 0x1F2
    mov  al, 1
    out  dx, al
    mov  dx, 0x1F3
    mov  al, bl
    out  dx, al
    mov  dx, 0x1F4
    mov  al, bh
    out  dx, al
    mov  dx, 0x1F5
    shr  ebx, 16
    mov  al, bl
    out  dx, al
    mov  dx, 0x1F6
    mov  al, bh
    and  al, 0x0F
    or   al, 0xE0
    out  dx, al
    mov  dx, 0x1F7
    mov  al, 0x30
    out  dx, al
    call ata_wait_drq
    mov  dx, 0x1F0
    mov  ecx, 256
    cld
    rep  outsw
    mov  dx, 0x1F7
    mov  al, 0xE7
    out  dx, al
    call ata_wait_ready
    popa
    ret
