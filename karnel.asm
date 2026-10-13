; serpentis, the 32 bit one. flat binary, boot.asm loads it at 0x10000 and jumps here
; already in protected mode. no paging, no processes, one big loop and a keyboard isr
format binary as 'img'
org 0x10000
use32
MAP_W          equ 20
MAP_H          equ 20
ISO_OX         equ 150
ISO_OY         equ 8
ISO_SH         equ 4
COLS           equ 80
ROWS           equ 25
VGA_TEXT       equ 0xB8000
VGA_GAME       equ 0xA0000
SCR_W          equ 320
SCR_H          equ 200
FAT_MAX        equ 64
; the filesystem sits after the kernel on the same disk. boot.asm reads 512 sectors of kernel
; starting at lba 1, 1024 leaves room for it to grow
FS_METADATA_START equ 1024
FS_METADATA_SECTORS equ 34
FS_DATA_START   equ FS_METADATA_START + FS_METADATA_SECTORS
FAT_SIZE       equ 4096
FAT_SECTORS    equ (FAT_SIZE/512)
ED_ROWS        equ (ROWS-3)
USERS_SECTOR    equ FS_DATA_START + FAT_MAX*FAT_SECTORS
EDIT_MAX       equ FAT_SIZE
USER_MAX       equ 4
PATH_MAX       equ 256
; fixed address inside the 256 KB the loader reads. only zeros live there now, but if the kernel
; ever gets past 128 KB this has to move
SCROLLBACK_BUF      equ 0x30000

; file contents, 64 files of 4 KB. too big to sit inside the kernel image, so it lives at 2 MB
fat_data            equ 0x200000
SCROLLBACK_LINES    equ 300
SCROLLBACK_LINE_SIZE equ 160

; only the keyboard has a real handler, the timer stays masked. the game redraws after a key
; sets game_redraw, the hlt wakes up on the next key anyway
kernel_entry:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, 0x9F000
    cld
    lidt [idt_ptr]
    call pic_init
    call fs_init
    call fs_users_init
    call vga_text_mode
    mov  byte [mode], 0
    call show_welcome
    call draw_banner
    call ai_system_init
    call shell_prompt
    sti
.main_loop:
    hlt
    cmp  byte [mode], 1
    jne  .skip_game_render
    cmp  byte [game_redraw], 0
    je   .skip_game_render
    mov  byte [game_redraw], 0
    call wait_vsync
    call world_draw
.skip_game_render:
    jmp  .main_loop

align 8

; 256 gates, all of them the default handler except 0x21, the keyboard
idt_start:
    repeat 0x21
        dw (isr_default and 0xFFFF)
        dw 0x08
        db 0x00
        db 0x8E
        dw (isr_default shr 16)
    end repeat
    dw (isr_keyboard and 0xFFFF)
    dw 0x08
    db 0x00
    db 0x8E
    dw (isr_keyboard shr 16)
    repeat 256-0x22
        dw (isr_default and 0xFFFF)
        dw 0x08
        db 0x00
        db 0x8E
        dw (isr_default shr 16)
    end repeat

idt_end:

idt_ptr:
    dw idt_end - idt_start - 1
    dd idt_start

include 'kernel_modules/drivers.asm'

; reads the table and all 64 files into memory at boot, 8 sectors a file. no magic means a
; fresh disk and it makes / /home and /home/guest
fs_init:
    pusha
    mov  eax, FS_METADATA_START
    mov  edi, fs_metadata
    mov  ecx, FS_METADATA_SECTORS
.read_meta:
    push ecx
    call ata_read_sector
    inc  eax
    add  edi, 512
    pop  ecx
    loop .read_meta
    mov  edi, fs_metadata
    cmp  dword [fs_magic], 0x53525034
    je   .load_fat
    mov  dword [fs_magic], 0x53525034
    mov  dword [fat_count], 0
    mov  ecx, FAT_MAX * PATH_MAX
    mov  edi, fat_names
    xor  eax, eax
    cld
    rep  stosb
    mov  ecx, FAT_MAX
    mov  edi, fat_sizes
    rep  stosd
    mov  ecx, FAT_MAX
    mov  edi, fat_parents
    mov  eax, 0FFFFFFFFh
    cld
    rep  stosd
    mov  ecx, 0
    mov  edx, 0
    imul eax, ecx, PATH_MAX
    lea  edi, [fat_names+eax]
    mov  byte [edi], '/'
    mov  byte [edi+1], 0
    imul eax, edx, 4
    mov  dword [fat_sizes+eax], 0FFFFFFFFh
    mov  dword [fat_parents+eax], 0FFFFFFFFh
    inc  dword [fat_count]
    mov  ecx, [fat_count]
    mov  edx, ecx
    imul eax, ecx, PATH_MAX
    lea  edi, [fat_names+eax]
    mov  esi, str_home_name_init
    mov  ecx, 4
    cld
    rep  movsb
    mov  byte [edi], 0
    imul eax, edx, 4
    mov  dword [fat_sizes+eax], 0FFFFFFFFh
    mov  dword [fat_parents+eax], 0
    inc  dword [fat_count]
    mov  ecx, [fat_count]
    mov  edx, ecx
    imul eax, ecx, PATH_MAX
    lea  edi, [fat_names+eax]
    mov  esi, str_guest_name_init
    mov  ecx, 5
    cld
    rep  movsb
    mov  byte [edi], 0
    imul eax, edx, 4
    mov  dword [fat_sizes+eax], 0FFFFFFFFh
    mov  dword [fat_parents+eax], 1
    inc  dword [fat_count]
    call fs_save_all
    popa
    ret
.load_fat:
    mov  eax, FS_METADATA_START
    mov  edi, fs_metadata
    mov  ecx, FS_METADATA_SECTORS
.load_meta:
    push ecx
    call ata_read_sector
    inc  eax
    add  edi, 512
    pop  ecx
    loop .load_meta
    mov  eax, FS_DATA_START
    mov  edi, fat_data
    mov  ecx, FAT_MAX*FAT_SECTORS
.lp:
    push ecx
    call ata_read_sector
    inc  eax
    add  edi, 512
    pop  ecx
    loop .lp
    mov  edi, current_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, str_home_guest_init
    mov  edi, current_path
    mov  ecx, 11
    cld
    rep  movsb
    mov  byte [edi], 0
    mov  edi, home_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, str_home_guest_init
    mov  edi, home_path
    mov  ecx, 11
    cld
    rep  movsb
    mov  byte [edi], 0
    popa
    ret

; writes the whole thing back, table and every file. slow, but nothing can get out of sync
fs_save_all:
    pusha
    mov  eax, FS_METADATA_START
    mov  esi, fs_metadata
    mov  ecx, FS_METADATA_SECTORS
.write_meta:
    push ecx
    call ata_write_sector
    inc  eax
    add  esi, 512
    pop  ecx
    loop .write_meta
    mov  eax, FS_DATA_START
    mov  esi, fat_data
    mov  ecx, FAT_MAX*FAT_SECTORS
.lp:
    push ecx
    call ata_write_sector
    inc  eax
    add  esi, 512
    pop  ecx
    loop .lp
    popa
    ret

fs_is_direct_child:
    push eax
    push ebx
    cmp  ecx, [fat_count]
    jge  .not_child
    mov  ebx, ecx
    imul eax, ebx, 4
    mov  eax, [fat_parents + eax]
    cmp  eax, edx
    je   .is_child
.not_child:
    pop  ebx
    pop  eax
    clc
    ret
.is_child:
    pop  ebx
    pop  eax
    stc
    ret

; old names, half the kernel still calls them
fs_resolve_path_to_index:
    jmp  fs_resolve_path_tree

fs_get_entry_name:
    jmp  fs_copy_entry_name

fs_find_child_by_name:
    push ebx
    push ecx
    push edi
    xor  ecx, ecx
.search_loop:
    cmp  ecx, [fat_count]
    jge  .not_found
    push edx
    call fs_is_direct_child
    pop  edx
    jnc  .next
    push esi
    lea  edi, [tmp_path1]
    push ecx
    call fs_get_entry_name
    pop  ecx
    mov  edi, tmp_path1
    push esi
    push edi
    call strcmp_exact
    pop  edi
    pop  esi
    jc   .found
    pop  esi
.next:
    inc  ecx
    jmp  .search_loop
.not_found:
    pop  edi
    pop  ecx
    pop  ebx
    clc
    ret
.found:
    pop  esi
    mov  eax, ecx
    pop  edi
    pop  ecx
    pop  ebx
    stc
    ret

fs_get_current_dir_index:
    push esi
    mov  esi, current_path
    call fs_resolve_path_to_index
    pop  esi
    ret

; walks a path from / one name at a time. the name gets its own buffer because
; fs_find_child_by_name uses tmp_path1 for scratch
fs_resolve_path_tree:
    push ebx
    push ecx
    push edx
    push edi
    cmp  byte [esi], '/'
    jne  .not_found
    mov  edx, 0
    inc  esi
    cmp  byte [esi], 0
    je   .found
.component:
    lea  edi, [path_component]
    mov  ecx, PATH_MAX-1
.copy:
    lodsb
    or   al, al
    jz   .end_component
    cmp  al, '/'
    je   .end_component
    stosb
    dec  ecx
    jnz  .copy
.skip:
    lodsb
    or   al, al
    jnz  .skip
    jmp  .end_component
.end_component:
    mov  byte [edi], 0
    push esi
    lea  esi, [path_component]
    call fs_find_child_by_name
    pop  esi
    jnc  .not_found
    mov  edx, eax
    cmp  byte [esi-1], 0
    je   .found
    jmp  .component
.found:
    mov  eax, edx
    stc
    jmp  .ret
.not_found:
    xor  eax, eax
    clc
.ret:
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    ret

fs_copy_entry_name:
    push eax
    push ecx
    push esi
    push edi
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names+eax]
    pop  edi
    push edi
    mov  ecx, PATH_MAX-1
.copy:
    lodsb
    stosb
    or   al, al
    jz   .done
    dec  ecx
    jnz  .copy
    mov  byte [edi], 0
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

fs_split_path:
    push ebx
    push ecx
    push edx
    push edi
    mov  edi, tmp_path2
    call str_copy_path
    mov  esi, tmp_path2
    xor  ebx, ebx
.scan:
    lodsb
    or   al, al
    jz   .scanned
    cmp  al, '/'
    jne  .scan
    mov  ebx, esi
    jmp  .scan
.scanned:
    or   ebx, ebx
    jz   .bad
    cmp  byte [ebx], 0
    je   .bad
    mov  byte [ebx-1], 0
    cmp  byte [tmp_path2], 0
    jne  .parent
    mov  byte [tmp_path2], '/'
    mov  byte [tmp_path2+1], 0
.parent:
    mov  esi, tmp_path2
    call fs_resolve_path_to_index
    jnc  .bad
    lea  esi, [ebx]
    stc
    jmp  .ret
.bad:
    xor  eax, eax
    clc
.ret:
    pop  edi
    pop  edx
    pop  ecx
    pop  ebx
    ret

fs_move_would_cycle:
    push eax
    push ecx
    mov  ecx, edx
.walk:
    cmp  ecx, ebx
    je   .cycle
    cmp  ecx, 0
    je   .safe
    imul eax, ecx, 4
    mov  ecx, [fat_parents+eax]
    cmp  ecx, 0FFFFFFFFh
    jne  .walk
.safe:
    clc
    jmp  .ret
.cycle:
    stc
.ret:
    pop  ecx
    pop  eax
    ret

fs_build_path:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov  ebx, eax
    mov  edx, edi
    lea  edi, [edi+PATH_MAX-1]
    mov  byte [edi], 0
    cmp  ebx, 0
    je   .root
.up:
    imul eax, ebx, PATH_MAX
    lea  esi, [fat_names+eax]
    xor  ecx, ecx
.len:
    cmp  byte [esi+ecx], 0
    je   .prepend
    inc  ecx
    jmp  .len
.prepend:
    dec  ecx
.chars:
    dec  edi
    mov  al, [esi+ecx]
    mov  [edi], al
    dec  ecx
    jns  .chars
    dec  edi
    mov  byte [edi], '/'
    imul eax, ebx, 4
    mov  ebx, [fat_parents+eax]
    cmp  ebx, 0
    jne  .up
    mov  esi, edi
    mov  edi, edx
.final_copy:
    lodsb
    stosb
    or   al, al
    jnz  .final_copy
    jmp  .done
.root:
    mov  byte [edx], '/'
    mov  byte [edx+1], 0
.done:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret

do_format_cmd:

include 'kernel_modules/fs_simple.asm'

include 'kernel_modules/sha256.asm'

; every mode has its own key handler, the isr picks one by [mode]
key_shell:
    push eax
    push ebx
    mov  al, [scancode]
    cmp  al, 0x1C
    je   .enter
    cmp  al, 0x0E
    je   .back
    cmp  al, 0x39
    je   .space
    cmp  al, 0x49
    je   .pageup
    cmp  al, 0x51
    je   .pagedown
    cmp  dword [scrollback_offset], 0
    je   .skip_reset
    mov  dword [scrollback_offset], 0
    call txt_clear
    call draw_banner
    call shell_prompt
    mov  esi, inbuf
    mov  ecx, [inlen]
.redraw_input:
    or   ecx, ecx
    jz   .redraw_done
    lodsb
    call txt_putc
    dec  ecx
    jmp  .redraw_input
.redraw_done:
.skip_reset:
    call sc2ascii
    or   al, al
    jz   .done
    mov  ebx, [inlen]
    cmp  ebx, 253
    jge  .done
    mov  [inbuf + ebx], al
    inc  dword [inlen]
    call txt_putc
    jmp  .done
.space:
    mov  ebx, [inlen]
    cmp  ebx, 253
    jge  .done
    mov  byte [inbuf + ebx], ' '
    inc  dword [inlen]
    mov  al, ' '
    call txt_putc
    jmp  .done
.back:
    cmp  dword [inlen], 0
    je   .done
    dec  dword [inlen]
    mov  ebx, [inlen]
    mov  byte [inbuf + ebx], 0
    call txt_backspace
    jmp  .done
.pageup:
    cmp  dword [scrollback_offset], 0
    je   .done
    dec  dword [scrollback_offset]
    call draw_from_scrollback
    jmp  .done
.pagedown:
    mov  eax, [scrollback_offset]
    cmp  eax, [scrollback_lines]
    jge  .done
    inc  dword [scrollback_offset]
    call draw_from_scrollback
    jmp  .done
.enter:
    call txt_nl
    call cmd_dispatch
.done:
    pop  ebx
    pop  eax
    ret



key_auth:
    push eax
    push ebx
    mov  al, [scancode]
    cmp  al, 0x1C
    je   .enter
    cmp  al, 0x0E
    je   .back
    cmp  byte [auth_stage], 0
    je   .stage_name
    cmp  byte [auth_stage], 1
    je   .stage_pass
    jmp  .done
.stage_name:
    call sc2ascii
    or   al, al
    jz   .done
    mov  ebx, [inlen]
    cmp  ebx, 15
    jge  .done
    mov  [inbuf + ebx], al
    inc  dword [inlen]
    call txt_putc
    jmp  .done
.stage_pass:
    call sc2ascii
    or   al, al
    jz   .done
    mov  ebx, [inlen]
    cmp  ebx, 15
    jge  .done
    mov  [inbuf + ebx], al
    inc  dword [inlen]
    call txt_putc
    jmp  .done
.back:
    cmp  dword [inlen], 0
    je   .done
    dec  dword [inlen]
    mov  ebx, [inlen]
    mov  byte [inbuf + ebx], 0
    cmp  byte [auth_stage], 0
    je   .back_name
.back_pass:
    call txt_backspace
    jmp  .done
.back_name:
    call txt_backspace
    jmp  .done
.enter:
    call txt_nl
    cmp  byte [auth_stage], 0
    je   .name_done
    cmp  byte [auth_stage], 1
    je   .pass_done
    jmp  .done
.name_done:
    mov  esi, inbuf
    mov  edi, tmp_name
    mov  ecx, 16
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_name
    mov  ecx, 15
.copy_name:
    lodsb
    or   al, al
    jz   .name_copy_done
    stosb
    dec  ecx
    jnz  .copy_name
.name_copy_done:
    mov  byte [edi], 0
    mov  dword [inlen], 0
    mov  ecx, 256
    mov  edi, inbuf
    xor  eax, eax
    cld
    rep  stosb
    mov  byte [auth_stage], 1
    mov  esi, str_password_prompt
    call txt_print
    jmp  .done
.pass_done:
    mov  esi, inbuf
    mov  edi, tmp_pass
    mov  ecx, 16
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_pass
    mov  ecx, 15
.copy_pass:
    lodsb
    or   al, al
    jz   .pass_copy_done
    stosb
    dec  ecx
    jnz  .copy_pass
.pass_copy_done:
    mov  byte [edi], 0
    mov  dword [inlen], 0
    mov  ecx, 256
    mov  edi, inbuf
    xor  eax, eax
    cld
    rep  stosb
    cmp  byte [auth_is_useradd], 1
    je   .do_useradd
.do_login:
    xor  ecx, ecx
.lp:
    cmp  ecx, [users_count]
    jge  .login_fail
    imul eax, ecx, 16
    lea  esi, [users_names+eax]
    mov  edi, tmp_name
    push ecx
    mov  ecx, 15
    call strncmp
    pop  ecx
    jne  .next
    imul eax, ecx, 16
    lea  esi, [users_pass+eax]
    call pass_check
    je   .login_ok
.next:
    inc  ecx
    jmp  .lp
.login_ok:
    mov  ecx, 16
    mov  edi, current_user
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, tmp_name
    mov  edi, current_user
    mov  ecx, 16
    cld
    rep  movsb
    mov  esi, str_login_ok
    call txt_print
    jmp  .return_shell
.login_fail:
    mov  esi, str_login_fail
    call txt_print
    jmp  .return_shell
.do_useradd:
    mov  eax, [users_count]
    cmp  eax, USER_MAX
    jge  .useradd_full
    imul ebx, eax, 16
    lea  edi, [users_names+ebx]
    mov  esi, tmp_name
    mov  ecx, 16
    cld
    rep  movsb
    lea  edi, [users_pass+ebx]
    call pass_hash
    inc  dword [users_count]
    call fs_users_save
    mov  esi, str_useradd_ok
    call txt_print
    jmp  .return_shell
.useradd_full:
    mov  esi, str_useradd_full
    call txt_print
.return_shell:
    mov  byte [mode], 0
    mov  byte [auth_stage], 0
    mov  byte [auth_is_useradd], 0
    call shell_prompt
.done:
    pop  ebx
    pop  eax
    ret

key_game:
    push eax
    mov  al, [scancode]
    cmp  al, 0x01
    je   .esc
    cmp  al, 0x48
    je   .up
    cmp  al, 0x11
    je   .up
    cmp  al, 0x50
    je   .down
    cmp  al, 0x1F
    je   .down
    cmp  al, 0x4B
    je   .left
    cmp  al, 0x1E
    je   .left
    cmp  al, 0x4D
    je   .right
    cmp  al, 0x20
    je   .right
    jmp  .done
.esc:
    pop  eax
    call return_to_shell
    ret
.up:
    cmp  dword [py], 0
    je   .done
    dec  dword [py]
    mov  byte [game_redraw], 1
    jmp  .done
.down:
    mov  eax, [py]
    cmp  eax, MAP_H-1
    je   .done
    inc  dword [py]
    mov  byte [game_redraw], 1
    jmp  .done
.left:
    cmp  dword [px], 0
    je   .done
    dec  dword [px]
    mov  byte [game_redraw], 1
    jmp  .done
.right:
    mov  eax, [px]
    cmp  eax, MAP_W-1
    je   .done
    inc  dword [px]
    mov  byte [game_redraw], 1
    jmp  .done
.done:
    pop  eax
    ret

key_serpen:
    push eax
    mov al, [scancode]
    test al, al
    jz .done_serpen
    cmp al, 0x01
    je .esc_serpen
    cmp byte [serpen_exit_flag], 2
    je .show_gameover_msg
    cmp byte [serpen_exit_flag], 3
    je .check_choice
    cmp al, 0x48
    je .up_serpen
    cmp al, 0x50
    je .down_serpen
    cmp al, 0x4B
    je .left_serpen
    cmp al, 0x4D
    je .right_serpen
    jmp .do_move
.show_gameover_msg:
    call serpen_draw_gameover
    mov byte [serpen_exit_flag], 3
    jmp .done_serpen
.check_choice:
    cmp al, 0x48
    je .menu_up
    cmp al, 0x50
    je .menu_down
    cmp al, 0x1C
    je .menu_select
    cmp al, 0x15
    je .restart_game
    cmp al, 0x31
    je .esc_serpen
    jmp .done_serpen
.menu_up:
    cmp byte [serpen_menu_choice], 0
    je .done_serpen
    dec byte [serpen_menu_choice]
    call serpen_update_menu
    jmp .done_serpen
.menu_down:
    cmp byte [serpen_menu_choice], 1
    je .done_serpen
    inc byte [serpen_menu_choice]
    call serpen_update_menu
    jmp .done_serpen
.menu_select:
    cmp byte [serpen_menu_choice], 0
    je .restart_game
    jmp .esc_serpen
.restart_game:
    call serpen_init
    call serpen_draw_all
    jmp .done_serpen
.esc_serpen:
    pop eax
    call return_to_shell
    ret
.up_serpen:
    mov al, [serpen_dir]
    cmp al, 2
    je .do_move
    mov byte [serpen_dir], 0
    jmp .do_move
.down_serpen:
    mov al, [serpen_dir]
    cmp al, 0
    je .do_move
    mov byte [serpen_dir], 2
    jmp .do_move
.left_serpen:
    mov al, [serpen_dir]
    cmp al, 1
    je .do_move
    mov byte [serpen_dir], 3
    jmp .do_move
.right_serpen:
    mov al, [serpen_dir]
    cmp al, 3
    je .do_move
    mov byte [serpen_dir], 1
.do_move:
    call serpen_move
    call serpen_draw_all
.done_serpen:
    pop eax
    ret

key_pong:
    push eax
    mov al, [scancode]
    test al, al
    jz .done_pong
    cmp al, 0x01
    je .esc_pong
    cmp byte [pong_exit_flag], 2
    je .show_gameover_pong
    cmp byte [pong_exit_flag], 3
    je .check_choice
    cmp al, 0x11
    je .move_up_pong
    cmp al, 0x48
    je .move_up_pong
    cmp al, 0x1F
    je .move_down_pong
    cmp al, 0x50
    je .move_down_pong
    jmp .do_ball_move
.show_gameover_pong:
    call pong_draw_gameover
    mov byte [pong_exit_flag], 3
    jmp .done_pong
.check_choice:
    cmp al, 0x48
    je .menu_up_pong
    cmp al, 0x50
    je .menu_down_pong
    cmp al, 0x1C
    je .menu_select_pong
    cmp al, 0x15
    je .restart_pong
    cmp al, 0x31
    je .esc_pong
    jmp .done_pong
.menu_up_pong:
    cmp byte [pong_menu_choice], 0
    je .done_pong
    dec byte [pong_menu_choice]
    call pong_update_menu
    jmp .done_pong
.menu_down_pong:
    cmp byte [pong_menu_choice], 1
    je .done_pong
    inc byte [pong_menu_choice]
    call pong_update_menu
    jmp .done_pong
.menu_select_pong:
    cmp byte [pong_menu_choice], 0
    je .restart_pong
    jmp .esc_pong
.restart_pong:
    call pong_init
    call pong_draw_all
    jmp .done_pong
.esc_pong:
    pop eax
    call return_to_shell
    ret
.move_up_pong:
    cmp word [pong_paddle_y], 2
    jle .do_ball_move
    dec word [pong_paddle_y]
    jmp .do_ball_move
.move_down_pong:
    mov ax, [pong_paddle_y]
    add ax, 4
    cmp ax, 20
    jge .do_ball_move
    inc word [pong_paddle_y]
.do_ball_move:
    call pong_move
    call pong_draw_all
.done_pong:
    pop eax
    ret

key_editor:
    push eax
    push ebx
    mov  al, [scancode]
    cmp  al, 0x01
    je   .exit
    cmp  al, 0x3C
    je   .save
    cmp  al, 0x0E
    je   .back
    cmp  al, 0x1C
    je   .newline
    cmp  al, 0x4B
    je   .cleft
    cmp  al, 0x4D
    je   .cright
    cmp  al, 0x48
    je   .cup
    cmp  al, 0x50
    je   .cdown
    call sc2ascii
    or   al, al
    jz   .done
    mov  ebx, [elen]
    cmp  ebx, EDIT_MAX-1
    jge  .done
    mov  ecx, [elen]
    sub  ecx, [ecur]
    jz   .no_shift
    push esi
    push edi
    lea  esi, [ebuf]
    add  esi, [elen]
    dec  esi
    lea  edi, [ebuf]
    add  edi, [elen]
    std
    rep  movsb
    cld
    pop  edi
    pop  esi
.no_shift:
    mov  ebx, [ecur]
    mov  [ebuf + ebx], al
    inc  dword [elen]
    inc  dword [ecur]
    call ed_redraw
    jmp  .done
.cleft:
    cmp  dword [ecur], 0
    je   .done
    dec  dword [ecur]
    call ed_redraw
    jmp  .done
.cright:
    mov  eax, [ecur]
    cmp  eax, [elen]
    jge  .done
    inc  dword [ecur]
    call ed_redraw
    jmp  .done
.cup:
    call ed_up
    call ed_redraw
    jmp  .done
.cdown:
    call ed_down
    call ed_redraw
    jmp  .done
.back:
    cmp  dword [ecur], 0
    je   .done
    dec  dword [ecur]
    push esi
    push edi
    mov  ebx, [ecur]
    lea  edi, [ebuf + ebx]
    lea  esi, [ebuf + ebx + 1]
    mov  ecx, [elen]
    sub  ecx, ebx
    dec  ecx
    jle  .bs_skip
    cld
    rep  movsb
.bs_skip:
    pop  edi
    pop  esi
    dec  dword [elen]
    call ed_redraw
    jmp  .done
.newline:
    mov  ebx, [elen]
    cmp  ebx, EDIT_MAX-1
    jge  .done
    mov  ecx, [elen]
    sub  ecx, [ecur]
    jz   .no_shift_nl
    push esi
    push edi
    lea  esi, [ebuf]
    add  esi, [elen]
    dec  esi
    lea  edi, [ebuf]
    add  edi, [elen]
    std
    rep  movsb
    cld
    pop  edi
    pop  esi
.no_shift_nl:
    mov  ebx, [ecur]
    mov  byte [ebuf + ebx], 0x0A
    inc  dword [elen]
    inc  dword [ecur]
    call ed_redraw
    jmp  .done
.save:
    call fat_save
    mov  dword [cur_y], ROWS-2
    mov  dword [cur_x], 0
    mov  esi, str_saved
    call txt_print
    jmp  .done
.exit:
    pop  ebx
    pop  eax
    call return_to_shell
    ret
.done:
    pop  ebx
    pop  eax
    ret

return_to_shell:
    mov  byte [game_redraw], 0
    mov  byte [mode], 0
    call wait_vsync
    call vga_text_mode
    call txt_clear
    call draw_banner
    call shell_prompt
    ret

resolve_path:
    push eax
    push ecx
    push edx
    push esi
    push edi
    push edi
    mov  edi, path_buf
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    pop  edi
    mov  edx, esi
    mov  edi, path_buf
    mov  ecx, PATH_MAX-1
    cmp  byte [edx], 0
    je   .cur
    cmp  byte [edx], '~'
    je   .home
    cmp  byte [edx], '/'
    je   .abs
    mov  esi, current_path
.cp1:
    lodsb
    or   al, al
    jz   .cp1d
    or   ecx, ecx
    jz   .cp1s
    stosb
    dec  ecx
.cp1s:
    jmp  .cp1
.cp1d:
    cmp  byte [current_path], '/'
    jne  .sep
    cmp  byte [current_path+1], 0
    je   .nosep
.sep:
    or   ecx, ecx
    jz   .nosep
    mov  al, '/'
    stosb
    dec  ecx
.nosep:
    mov  esi, edx
.cp2:
    lodsb
    or   al, al
    jz   .fin
    or   ecx, ecx
    jz   .cp2s
    stosb
    dec  ecx
.cp2s:
    jmp  .cp2
.cur:
    mov  esi, current_path
.curl:
    lodsb
    or   al, al
    jz   .fin
    or   ecx, ecx
    jz   .curs
    stosb
    dec  ecx
.curs:
    jmp  .curl
.home:
    mov  esi, home_path
.homel:
    lodsb
    or   al, al
    jz   .fin
    or   ecx, ecx
    jz   .homes
    stosb
    dec  ecx
.homes:
    jmp  .homel
.abs:
    mov  esi, edx
.absl:
    lodsb
    or   al, al
    jz   .fin
    or   ecx, ecx
    jz   .abss
    stosb
    dec  ecx
.abss:
    jmp  .absl
.fin:
    mov  byte [edi], 0
    cmp  byte [path_buf], '/'
    jne  .done_normalize
    cmp  byte [path_buf+1], 0
    je   .done_normalize
    mov  edi, path_buf
.find_end:
    mov  al, [edi]
    or   al, al
    jz   .check_trailing
    inc  edi
    jmp  .find_end
.check_trailing:
    dec  edi
    cmp  byte [edi], '/'
    jne  .done_normalize
    mov  byte [edi], 0
.done_normalize:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  eax
    ret

; splits on /, drops . and pops on .. . esi is where we are in the path the whole time, so the
; checks on the component go through edi
path_normalize:
    pusha
    mov  dword [path_component_count], 0
    mov  esi, path_buf
    cmp  byte [edi], '/'
    jne  .parse_loop
    inc  esi
.parse_loop:
    mov  edi, path_components_stack
    imul eax, [path_component_count], PATH_MAX
    add  edi, eax
    mov  ecx, PATH_MAX-1
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, path_components_stack
    imul eax, [path_component_count], PATH_MAX
    add  edi, eax
    push PATH_MAX-1
.copy_component:
    lodsb
    cmp  al, '/'
    je   .component_done_pop
    or   al, al
    jz   .component_done_pop
    stosb
    dec  dword [esp]
    jnz  .copy_component
.component_done_pop:
    pop  ecx
.component_done:
    mov  byte [edi], 0
    jmp  .component_done_end
.component_done_end:
    mov  edi, path_components_stack
    imul eax, [path_component_count], PATH_MAX
    add  edi, eax
    cmp  byte [edi], 0
    je   .skip_component
    cmp  byte [edi], '.'
    jne  .check_dotdot
    cmp  byte [edi+1], 0
    je   .skip_component
.check_dotdot:
    cmp  byte [edi], '.'
    jne  .push_component
    cmp  byte [edi+1], '.'
    jne  .push_component
    cmp  byte [edi+2], 0
    jne  .push_component
    cmp  dword [path_component_count], 0
    je   .skip_component
    dec  dword [path_component_count]
    jmp  .skip_component
.push_component:
    inc  dword [path_component_count]
    cmp  dword [path_component_count], 32
    jge  .rebuild
.skip_component:
    cmp  byte [esi-1], 0
    je   .rebuild
.skip_slashes:
    lodsb
    cmp  al, 0
    je   .rebuild
    cmp  al, '/'
    je   .skip_slashes
    dec  esi
    jmp  .parse_loop
.rebuild:
    mov  edi, path_buf
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, path_buf
    mov  byte [edi], '/'
    inc  edi
    cmp  dword [path_component_count], 0
    je   .done
    mov  ecx, [path_component_count]
    xor  ebx, ebx
.rebuild_loop:
    cmp  ebx, ecx
    jge  .done
    mov  esi, path_components_stack
    imul eax, ebx, PATH_MAX
    add  esi, eax
.copy_loop:
    lodsb
    or   al, al
    jz   .copy_done
    cmp  edi, path_buf + PATH_MAX - 1
    jge  .copy_done
    stosb
    jmp  .copy_loop
.copy_done:
    mov  eax, ebx
    inc  eax
    cmp  eax, ecx
    jge  .next_component
    cmp  edi, path_buf + PATH_MAX - 1
    jge  .next_component
    mov  byte [edi], '/'
    inc  edi
.next_component:
    inc  ebx
    jmp  .rebuild_loop
.done:
    mov  byte [edi], 0
    popa
    ret

rm_recursive:
    pusha
    xor  ecx, ecx
.delete_loop:
    cmp  ecx, [fat_count]
    jge  .delete_self
    call rm_is_child
    jc   .next_child
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names+eax]
    mov  edi, tmp_path1
    mov  edx, PATH_MAX
.copy_child:
    lodsb
    or   al, al
    jz   .child_copied
    stosb
    dec  edx
    jnz  .copy_child
.child_copied:
    mov  byte [edi], 0
    imul eax, ecx, 4
    mov  eax, [fat_sizes+eax]
    cmp  eax, 0FFFFFFFFh
    jne  .delete_child_file
    mov  esi, tmp_path1
    mov  edi, ename
    call str_copy_path
    call rm_recursive
    jmp  .next_child
.delete_child_file:
    mov  esi, tmp_path1
    mov  edi, ename
    call str_copy_path
    call fat_del
.next_child:
    inc  ecx
    jmp  .delete_loop
.delete_self:
    call fat_del
    popa
    ret

rm_is_child:
    push eax
    push edx
    push esi
    push edi
    xor  edx, edx
    mov  edi, ename
.plen:
    cmp  byte [edi+edx], 0
    je   .plend
    inc  edx
    jmp  .plen
.plend:
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names+eax]
    push esi
    push edi
    push ecx
    mov  edi, ename
    mov  ecx, edx
    call strncmp
    pop  ecx
    pop  edi
    pop  esi
    jne  .no
    cmp  byte [esi+edx], '/'
    jne  .no
    clc
    jmp  .ret
.no:
    stc
.ret:
    pop  edi
    pop  esi
    pop  edx
    pop  eax
    ret

cp_recursive:
    pusha
    mov  ecx, [fat_count]
    mov  edx, ecx
    cmp  ecx, FAT_MAX
    jge  .full
    imul eax, ecx, PATH_MAX
    lea  edi, [fat_names+eax]
    push ecx
    push edi
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    pop  edi
    pop  ecx
    mov  esi, resolved_dst
    mov  ecx, PATH_MAX-1
.cp_dir:
    lodsb
    or   al, al
    jz   .cp_dir_done
    stosb
    dec  ecx
    jnz  .cp_dir
.cp_dir_done:
    mov  byte [edi], 0
    imul eax, edx, 4
    mov  dword [fat_sizes+eax], 0FFFFFFFFh
    inc  dword [fat_count]
    xor  ecx, ecx
.copy_loop:
    cmp  ecx, [fat_count]
    jge  .done
    mov  esi, resolved_src
    mov  edi, ename
    call str_copy_path
    call cp_is_child
    jc   .next_child
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names+eax]
    mov  edi, tmp_path1
    mov  edx, PATH_MAX
.copy_child:
    lodsb
    or   al, al
    jz   .child_copied
    stosb
    dec  edx
    jnz  .copy_child
.child_copied:
    mov  byte [edi], 0
    mov  esi, tmp_path1
    mov  edi, tmp_path2
    call str_copy_path
    mov  esi, resolved_src
    mov  edi, tmp_path1
    call str_copy_path
    call replace_path_prefix
    imul eax, ecx, 4
    mov  eax, [fat_sizes+eax]
    cmp  eax, 0FFFFFFFFh
    jne  .copy_child_file
    mov  esi, tmp_path1
    mov  edi, resolved_src
    call str_copy_path
    mov  esi, tmp_path2
    mov  edi, resolved_dst
    call str_copy_path
    call cp_recursive
    jmp  .next_child
.copy_child_file:
    mov  esi, tmp_path1
    mov  edi, ename
    call str_copy_path
    call fat_load
    mov  esi, tmp_path2
    mov  edi, ename
    call str_copy_path
    call fat_save
.next_child:
    inc  ecx
    jmp  .copy_loop
.full:
    mov  esi, str_fat_full
    call txt_print
.done:
    popa
    ret

cp_is_child:
    push eax
    push edx
    push esi
    push edi
    xor  edx, edx
    mov  edi, ename
.plen:
    cmp  byte [edi+edx], 0
    je   .plend
    inc  edx
    jmp  .plen
.plend:
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names+eax]
    push esi
    push edi
    push ecx
    mov  edi, ename
    mov  ecx, edx
    call strncmp
    pop  ecx
    pop  edi
    pop  esi
    jne  .no
    cmp  byte [esi+edx], '/'
    jne  .no
    clc
    jmp  .ret
.no:
    stc
.ret:
    pop  edi
    pop  esi
    pop  edx
    pop  eax
    ret

replace_path_prefix:
    pusha
    mov  esi, resolved_src
    mov  edi, tmp_path2
    mov  ecx, PATH_MAX-1
.copy_dst:
    lodsb
    or   al, al
    jz   .dst_done
    stosb
    dec  ecx
    jnz  .copy_dst
.dst_done:
    mov  esi, resolved_src
    xor  edx, edx
.src_len:
    cmp  byte [esi+edx], 0
    je   .src_len_done
    inc  edx
    jmp  .src_len
.src_len_done:
    mov  esi, tmp_path1
    add  esi, edx
.copy_rest:
    lodsb
    or   al, al
    jz   .done
    stosb
    jmp  .copy_rest
.done:
    mov  byte [edi], 0
    popa
    ret

str_copy_path:
    push eax
    push ecx
    push edi
    push esi
    push edi
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    pop  edi
    pop  esi
    mov  ecx, PATH_MAX-1
.l:
    lodsb
    or   al, al
    jz   .d
    mov  [edi], al
    inc  edi
    dec  ecx
    jnz  .l
.d:
    mov  byte [edi], 0
    pop  edi
    pop  ecx
    pop  eax
    ret

path_cd_home:
    pusha
    mov  esi, home_path
    mov  edi, path_buf
    mov  ecx, PATH_MAX
.copy_check:
    lodsb
    stosb
    or   al, al
    jz   .check_done
    dec  ecx
    jnz  .copy_check
.check_done:
    xor  ecx, ecx
.search:
    cmp  ecx, [fat_count]
    jge  .notfound
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names+eax]
    mov  edi, path_buf
    push ecx
    call strcmp_exact
    pop  ecx
    jc   .found
    inc  ecx
    jmp  .search
.found:
    imul eax, ecx, 4
    mov  eax, [fat_sizes+eax]
    cmp  eax, 0FFFFFFFFh
    jne  .notfound
    mov  esi, home_path
    mov  edi, current_path
    mov  ecx, PATH_MAX
.copy:
    lodsb
    or   al, al
    jz   .done
    stosb
    dec  ecx
    jnz  .copy
.done:
    mov  byte [edi], 0
    popa
    ret
.notfound:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    popa
    ret

; upper case the line, then try every command in order. long, but easy to follow
cmd_dispatch:
    pusha
    cmp  dword [inlen], 0
    je   .done
    call input_upper
    mov  esi, inbuf
    mov  edi, cmd_open
    mov  ecx, 4
    call strncmp
    je   .do_open
    mov  esi, inbuf
    mov  edi, cmd_game
    call strcmp_exact
    je   .done_no_prompt
    mov  esi, inbuf
    mov  edi, cmd_ai
    mov  ecx, 2
    call strncmp
    je   .do_ai
    mov  esi, inbuf
    mov  edi, cmd_train
    mov  ecx, 5
    call strncmp
    je   .do_train
    mov  esi, inbuf
    mov  edi, cmd_serpen
    mov  ecx, 6
    call strncmp
    je   .do_serpen
    mov  esi, inbuf
    mov  edi, cmd_pongi
    mov  ecx, 5
    call strncmp
    je   .do_pongi
    mov  esi, inbuf
    mov  edi, cmd_clear
    mov  ecx, 5
    call strncmp
    je   .do_clear
    mov  esi, inbuf
    mov  edi, cmd_format
    mov  ecx, 6
    call strncmp
    je   .do_format
    mov  esi, inbuf
    mov  edi, cmd_color
    mov  ecx, 5
    call strncmp
    je   .do_color
    mov  esi, inbuf
    mov  edi, cmd_help
    mov  ecx, 4
    call strncmp
    je   .do_help
    mov  esi, inbuf
    mov  edi, cmd_cd
    mov  ecx, 2
    call strncmp
    je   .do_cd
    mov  esi, inbuf
    mov  edi, cmd_pwd
    mov  ecx, 3
    call strncmp
    je   .do_pwd
    mov  esi, inbuf
    mov  edi, cmd_ls
    mov  ecx, 2
    call strncmp
    je   .do_ls
    mov  esi, inbuf
    mov  edi, cmd_mkdir
    mov  ecx, 5
    call strncmp
    je   .do_mkdir
    mov  esi, inbuf
    mov  edi, cmd_rmdir
    mov  ecx, 5
    call strncmp
    je   .do_rmdir
    mov  esi, inbuf
    mov  edi, cmd_cp
    mov  ecx, 2
    call strncmp
    je   .do_cp
    mov  esi, inbuf
    mov  edi, cmd_mv
    mov  ecx, 2
    call strncmp
    je   .do_mv
    mov  esi, inbuf
    mov  edi, cmd_rm
    mov  ecx, 2
    call strncmp
    je   .do_rm
    mov  esi, inbuf
    mov  edi, cmd_touch
    mov  ecx, 5
    call strncmp
    je   .do_touch
    mov  esi, inbuf
    mov  edi, cmd_cat
    mov  ecx, 3
    call strncmp
    je   .do_cat
    mov  esi, inbuf
    mov  edi, cmd_useradd
    mov  ecx, 7
    call strncmp
    je   .do_useradd
    mov  esi, inbuf
    mov  edi, cmd_userlist
    mov  ecx, 8
    call strncmp
    je   .do_userlist
    mov  esi, inbuf
    mov  edi, cmd_whoami
    mov  ecx, 6
    call strncmp
    je   .do_whoami
    mov  esi, inbuf
    mov  edi, cmd_who
    mov  ecx, 3
    call strncmp
    je   .do_who
    mov  esi, inbuf
    mov  edi, cmd_userdel
    mov  ecx, 7
    call strncmp
    je   .do_userdel
    mov  esi, inbuf
    mov  edi, cmd_logout
    mov  ecx, 6
    call strncmp
    je   .do_logout
    mov  esi, inbuf
    mov  edi, cmd_login
    mov  ecx, 5
    call strncmp
    je   .do_login
    mov  esi, str_notfound_cmd
    call txt_print
    jmp  .done
.do_clear:
    call txt_clear
    call draw_banner
    jmp  .done
.do_format:
    call do_format_cmd
    jmp  .done
.do_color:
    call do_color_cmd
    jmp  .done
.do_help:
    mov  esi, inbuf
    add  esi, 5
    call str_trim
    cmp  byte [esi], 0
    je   .show_general_help
    call show_detailed_help
    jmp  .done
.show_general_help:
    mov  esi, str_help
    call txt_print
    jmp  .done
.do_ai:
    call do_ai_cmd
    jmp  .done
.do_train:
    call do_train_cmd
    jmp  .done
.do_serpen:
    call serpen_main
    jmp  .done
.do_pongi:
    call pong_main
    jmp  .done
.do_cd:
    call do_cd_simple_v2
    jmp  .done
.do_pwd:
    call do_pwd_cmd
    jmp  .done
.do_ls:
    call do_ls_simple_v2
    jmp  .done
.do_mkdir:
    call do_mkdir_simple_v2
    jmp  .done
.do_rmdir:
    call do_rmdir_simple_v2
    jmp  .done
.do_cp:
    call do_cp_cmd
    jmp  .done
.do_mv:
    call do_mv_cmd
    jmp  .done
.do_rm:
    call do_rm_simple_v2
    jmp  .done
.do_touch:
    call do_touch_cmd
    jmp  .done
.do_userlist:
    call do_userlist_cmd
    jmp  .done
.do_userdel:
    call do_userdel_cmd
    jmp  .done
.do_open:
    mov  byte [open_no_prompt], 0
    call do_open_cmd
    cmp  byte [open_no_prompt], 1
    je   .done_no_prompt
    jmp  .done
.do_cat:
    mov  esi, inbuf
    add  esi, 4
    call str_trim
    cmp  byte [esi], 0
    je   .cat_noname
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, ename
    call str_copy_path
    call fat_cat
    jmp  .done
.cat_noname:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .done
.do_useradd:
    mov  esi, inbuf
    add  esi, 8
    call str_trim
    call do_useradd_cmd
    cmp  byte [mode], 3
    je   .done_no_prompt
    jmp  .done
.do_login:
    mov  esi, inbuf
    add  esi, 6
    call str_trim
    call do_login_cmd
    cmp  byte [mode], 3
    je   .done_no_prompt
    jmp  .done
.do_logout:
    call do_logout_cmd
    jmp  .done
.do_whoami:
    call do_whoami_cmd
    jmp  .done
.do_who:
    call do_who_cmd
    jmp  .done
.done:
    call shell_prompt
.done_no_prompt:
    mov  dword [inlen], 0
    mov  ecx, 256
    mov  edi, inbuf
    xor  eax, eax
    cld
    rep  stosb
    popa
    ret

show_detailed_help:
    pusha
    mov  edi, tmp_name
    mov  ecx, 16
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_name
    mov  ecx, 15
.copy_cmd:
    lodsb
    or   al, al
    jz   .find_help
    stosb
    dec  ecx
    jnz  .copy_cmd
.find_help:
    mov  byte [edi], 0
    mov  edi, tmp_name
    mov  esi, cmd_cd
    mov  ecx, 2
    call strncmp
    je   .help_cd
    mov  esi, cmd_pwd
    mov  ecx, 3
    call strncmp
    je   .help_pwd
    mov  esi, cmd_ls
    mov  ecx, 2
    call strncmp
    je   .help_ls
    mov  esi, cmd_mkdir
    mov  ecx, 5
    call strncmp
    je   .help_mkdir
    mov  esi, cmd_rmdir
    mov  ecx, 5
    call strncmp
    je   .help_rmdir
    mov  esi, cmd_cp
    mov  ecx, 2
    call strncmp
    je   .help_cp
    mov  esi, cmd_mv
    mov  ecx, 2
    call strncmp
    je   .help_mv
    mov  esi, cmd_rm
    mov  ecx, 2
    call strncmp
    je   .help_rm
    mov  esi, cmd_touch
    mov  ecx, 5
    call strncmp
    je   .help_touch
    mov  esi, cmd_cat
    mov  ecx, 3
    call strncmp
    je   .help_cat
    mov  esi, cmd_open
    mov  ecx, 4
    call strncmp
    je   .help_open
    mov  esi, cmd_useradd
    mov  ecx, 7
    call strncmp
    je   .help_useradd
    mov  esi, cmd_userlist
    mov  ecx, 8
    call strncmp
    je   .help_userlist
    mov  esi, cmd_userdel
    mov  ecx, 7
    call strncmp
    je   .help_userdel
    mov  esi, cmd_login
    mov  ecx, 5
    call strncmp
    je   .help_login
    mov  esi, cmd_logout
    mov  ecx, 6
    call strncmp
    je   .help_logout
    mov  esi, cmd_whoami
    mov  ecx, 6
    call strncmp
    je   .help_whoami
    mov  esi, str_help_unknown
    call txt_print
    jmp  .done
.help_cd:
    mov  esi, str_help_cd
    call txt_print
    jmp  .done
.help_pwd:
    mov  esi, str_help_pwd
    call txt_print
    jmp  .done
.help_ls:
    mov  esi, str_help_ls
    call txt_print
    jmp  .done
.help_mkdir:
    mov  esi, str_help_mkdir
    call txt_print
    jmp  .done
.help_rmdir:
    mov  esi, str_help_rmdir
    call txt_print
    jmp  .done
.help_cp:
    mov  esi, str_help_cp
    call txt_print
    jmp  .done
.help_mv:
    mov  esi, str_help_mv
    call txt_print
    jmp  .done
.help_rm:
    mov  esi, str_help_rm
    call txt_print
    jmp  .done
.help_touch:
    mov  esi, str_help_touch
    call txt_print
    jmp  .done
.help_cat:
    mov  esi, str_help_cat
    call txt_print
    jmp  .done
.help_open:
    mov  esi, str_help_open
    call txt_print
    jmp  .done
.help_useradd:
    mov  esi, str_help_useradd
    call txt_print
    jmp  .done
.help_userlist:
    mov  esi, str_help_userlist
    call txt_print
    jmp  .done
.help_userdel:
    mov  esi, str_help_userdel
    call txt_print
    jmp  .done
.help_login:
    mov  esi, str_help_login
    call txt_print
    jmp  .done
.help_logout:
    mov  esi, str_help_logout
    call txt_print
    jmp  .done
.help_whoami:
    mov  esi, str_help_whoami
    call txt_print
    jmp  .done
.done:
    popa
    ret

show_detailed_help_to_file:
    pusha
    mov  ecx, EDIT_MAX
    mov  edi, ebuf
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_name
    mov  esi, cmd_cd
    mov  ecx, 2
    call strncmp
    je   .help_cd
    mov  esi, cmd_pwd
    mov  ecx, 3
    call strncmp
    je   .help_pwd
    mov  esi, cmd_ls
    mov  ecx, 2
    call strncmp
    je   .help_ls
    mov  esi, cmd_mkdir
    mov  ecx, 5
    call strncmp
    je   .help_mkdir
    mov  esi, cmd_rmdir
    mov  ecx, 5
    call strncmp
    je   .help_rmdir
    mov  esi, cmd_cp
    mov  ecx, 2
    call strncmp
    je   .help_cp
    mov  esi, cmd_mv
    mov  ecx, 2
    call strncmp
    je   .help_mv
    mov  esi, cmd_rm
    mov  ecx, 2
    call strncmp
    je   .help_rm
    mov  esi, cmd_touch
    mov  ecx, 5
    call strncmp
    je   .help_touch
    mov  esi, cmd_cat
    mov  ecx, 3
    call strncmp
    je   .help_cat
    mov  esi, cmd_open
    mov  ecx, 4
    call strncmp
    je   .help_open
    mov  esi, cmd_useradd
    mov  ecx, 7
    call strncmp
    je   .help_useradd
    mov  esi, cmd_userlist
    mov  ecx, 8
    call strncmp
    je   .help_userlist
    mov  esi, cmd_userdel
    mov  ecx, 7
    call strncmp
    je   .help_userdel
    mov  esi, cmd_login
    mov  ecx, 5
    call strncmp
    je   .help_login
    mov  esi, cmd_logout
    mov  ecx, 6
    call strncmp
    je   .help_logout
    mov  esi, cmd_whoami
    mov  ecx, 6
    call strncmp
    je   .help_whoami
    jmp  .done
.help_cd:
    mov  esi, str_help_cd
    call copy_string_to_ebuf
    jmp  .save_file
.help_pwd:
    mov  esi, str_help_pwd
    call copy_string_to_ebuf
    jmp  .save_file
.help_ls:
    mov  esi, str_help_ls
    call copy_string_to_ebuf
    jmp  .save_file
.help_mkdir:
    mov  esi, str_help_mkdir
    call copy_string_to_ebuf
    jmp  .save_file
.help_rmdir:
    mov  esi, str_help_rmdir
    call copy_string_to_ebuf
    jmp  .save_file
.help_cp:
    mov  esi, str_help_cp
    call copy_string_to_ebuf
    jmp  .save_file
.help_mv:
    mov  esi, str_help_mv
    call copy_string_to_ebuf
    jmp  .save_file
.help_rm:
    mov  esi, str_help_rm
    call copy_string_to_ebuf
    jmp  .save_file
.help_touch:
    mov  esi, str_help_touch
    call copy_string_to_ebuf
    jmp  .save_file
.help_cat:
    mov  esi, str_help_cat
    call copy_string_to_ebuf
    jmp  .save_file
.help_open:
    mov  esi, str_help_open
    call copy_string_to_ebuf
    jmp  .save_file
.help_useradd:
    mov  esi, str_help_useradd
    call copy_string_to_ebuf
    jmp  .save_file
.help_userlist:
    mov  esi, str_help_userlist
    call copy_string_to_ebuf
    jmp  .save_file
.help_userdel:
    mov  esi, str_help_userdel
    call copy_string_to_ebuf
    jmp  .save_file
.help_login:
    mov  esi, str_help_login
    call copy_string_to_ebuf
    jmp  .save_file
.help_logout:
    mov  esi, str_help_logout
    call copy_string_to_ebuf
    jmp  .save_file
.help_whoami:
    mov  esi, str_help_whoami
    call copy_string_to_ebuf
    jmp  .save_file
.save_file:
    mov  edi, ename
    mov  esi, tmp_name
    call str_copy_path
    mov  ecx, EDIT_MAX
.find_end:
    dec  ecx
    cmp  byte [ebuf + ecx], 0
    jne  .find_end
    inc  ecx
    mov  [elen], ecx
    call fat_save
    mov  esi, str_help_saved
    call txt_print
    jmp  .done
.done:
    popa
    ret

copy_string_to_ebuf:
    pusha
    mov  edi, ebuf
    mov  ecx, EDIT_MAX
.copy_loop:
    lodsb
    or   al, al
    jz   .copy_done
    stosb
    dec  ecx
    jnz  .copy_loop
.copy_done:
    mov  byte [edi], 0
    popa
    ret

do_pwd_cmd:
    pusha
    mov  esi, current_path
    call txt_print
    call txt_nl
    popa
    ret

do_cp_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 3
    call str_trim
    mov  edi, tmp_path1
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_path2
    mov  ecx, PATH_MAX
    rep  stosb
    mov  esi, inbuf
    add  esi, 3
    call str_trim
    mov  edi, tmp_path1
    mov  ecx, PATH_MAX-1
.copy_src:
    lodsb
    or   al, al
    jz   .src_done
    cmp  al, ' '
    je   .src_done
    stosb
    dec  ecx
    jnz  .copy_src
.src_done:
    mov  byte [edi], 0
    call str_trim
    mov  edi, tmp_path2
    mov  ecx, PATH_MAX-1
.copy_dst:
    lodsb
    or   al, al
    jz   .dst_done
    stosb
    dec  ecx
    jnz  .copy_dst
.dst_done:
    mov  byte [edi], 0
    cmp  byte [tmp_path1], 0
    je   .usage
    cmp  byte [tmp_path2], 0
    je   .usage
    mov  esi, tmp_path1
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, resolved_src
    call str_copy_path
    mov  esi, tmp_path2
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, resolved_dst
    call str_copy_path
    mov  esi, resolved_src
    call fs_resolve_path_to_index
    jnc  .srcnotfound
    mov  ebx, eax
    jmp  .cp_legacy
    cmp  ebx, 0
    je   .srcnotfound
    mov  esi, resolved_dst
    call fs_resolve_path_to_index
    jc   .srcnotfound
    mov  esi, resolved_dst
    call fs_split_path
    jnc  .srcnotfound
    mov  edx, eax
    call fs_move_would_cycle
    jc   .srcnotfound
    imul eax, ebx, PATH_MAX
    lea  edi, [fat_names+eax]
    call str_copy_path
    imul eax, ebx, 4
    mov  [fat_parents+eax], edx
    jmp  .cp_legacy
.cp_legacy:
    imul eax, ebx, 4
    mov  eax, [fat_sizes + eax]
    cmp  eax, 0FFFFFFFFh
    je   .src_is_dir
    mov  esi, resolved_src
    mov  edi, ename
    call str_copy_path
    call fat_load
    mov  esi, resolved_dst
    mov  edi, ename
    call str_copy_path
    call fat_save
    mov  esi, str_cp_ok
    call txt_print
    jmp  .ret
.src_is_dir:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .ret
.srcnotfound:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .ret
.usage:
    mov  esi, str_cp_usage
    call txt_print
.ret:
    popa
    ret

do_mv_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 3
    call str_trim
    mov  edi, tmp_path1
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_path2
    mov  ecx, PATH_MAX
    rep  stosb
    mov  esi, inbuf
    add  esi, 3
    call str_trim
    mov  edi, tmp_path1
    mov  ecx, PATH_MAX-1
.copy_src:
    lodsb
    or   al, al
    jz   .src_done
    cmp  al, ' '
    je   .src_done
    stosb
    dec  ecx
    jnz  .copy_src
.src_done:
    mov  byte [edi], 0
    call str_trim
    mov  edi, tmp_path2
    mov  ecx, PATH_MAX-1
.copy_dst:
    lodsb
    or   al, al
    jz   .dst_done
    stosb
    dec  ecx
    jnz  .copy_dst
.dst_done:
    mov  byte [edi], 0
    cmp  byte [tmp_path1], 0
    je   .usage
    cmp  byte [tmp_path2], 0
    je   .usage
    mov  esi, tmp_path1
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, resolved_src
    call str_copy_path
    mov  esi, tmp_path2
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, resolved_dst
    call str_copy_path
    mov  esi, resolved_src
    call fs_resolve_path_to_index
    jnc  .srcnotfound
    mov  ebx, eax
    cmp  ebx, 0
    je   .srcnotfound
    mov  esi, resolved_dst
    call fs_resolve_path_to_index
    jc   .srcnotfound
    mov  esi, resolved_dst
    call fs_split_path
    jnc  .srcnotfound
    mov  edx, eax
    call fs_move_would_cycle
    jc   .srcnotfound
    imul eax, ebx, PATH_MAX
    lea  edi, [fat_names+eax]
    call str_copy_path
    imul eax, ebx, 4
    mov  [fat_parents+eax], edx
    jmp  .save
    imul edi, ebx, PATH_MAX
    lea  edi, [fat_names + edi]
    push edi
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    pop  edi
    mov  esi, resolved_dst
    mov  ecx, PATH_MAX-1
.cp_new_name:
    lodsb
    or   al, al
    jz   .cp_done
    stosb
    dec  ecx
    jnz  .cp_new_name
.cp_done:
    mov  byte [edi], 0
    lea  esi, [resolved_dst]
    lea  edi, [tmp_path1]
    call str_copy_path
    lea  esi, [tmp_path1]
    xor  edx, edx
.find_slash:
    lodsb
    or   al, al
    jz   .slash_found
    cmp  al, '/'
    jne  .find_slash
    mov  edx, esi
    jmp  .find_slash
.slash_found:
    or   edx, edx
    jz   .parent_root
    mov  byte [edx-1], 0
    lea  esi, [tmp_path1]
    call fs_resolve_path_to_index
    jnc  .parent_root
    imul ecx, ebx, 4
    mov  [fat_parents + ecx], eax
    jmp  .save
.parent_root:
    mov  byte [tmp_path1], '/'
    mov  byte [tmp_path1+1], 0
    lea  esi, [tmp_path1]
    call fs_resolve_path_to_index
    jnc  .save
    imul ecx, ebx, 4
    mov  [fat_parents + ecx], eax
.save:
    call fs_save_all
    mov  esi, str_mv_ok
    call txt_print
    jmp  .ret
.srcnotfound:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .ret
.usage:
    mov  esi, str_mv_usage
    call txt_print
.ret:
    popa
    ret

rm_recursive_tree:
    push eax
    push ebx
    push ecx
.delete_children:
    xor  ecx, ecx
.find_child:
    cmp  ecx, [fat_count]
    jge  .children_done
    push ecx
    imul eax, ecx, 4
    mov  eax, [fat_parents + eax]
    pop  ecx
    cmp  eax, ebx
    jne  .next_child
    push ecx
    imul eax, ecx, 4
    mov  eax, [fat_sizes + eax]
    pop  ecx
    cmp  eax, 0FFFFFFFFh
    jne  .delete_child_file
    push ebx
    mov  ebx, ecx
    call rm_recursive_tree
    pop  ebx
    jmp  .delete_children
.delete_child_file:
    push ebx
    call fat_del_by_index
    pop  ebx
    jmp  .delete_children
.next_child:
    inc  ecx
    jmp  .find_child
.children_done:
    mov  ecx, ebx
    call fat_del_by_index
    pop  ecx
    pop  ebx
    pop  eax
    ret

do_touch_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 6
    call str_trim
    cmp  byte [esi], 0
    je   .noname
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, ename
    call str_copy_path
    mov  dword [elen], 0
    mov  dword [ecur], 0
    mov  dword [ed_top], 0
    mov  ecx, EDIT_MAX
    mov  edi, ebuf
    xor  eax, eax
    cld
    rep  stosb
    call fat_save
    mov  esi, str_touch_ok
    call txt_print
    jmp  .ret
.noname:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
.ret:
    popa
    ret

do_userlist_cmd:
    pusha
    mov  esi, str_userlist_hdr
    call txt_print
    xor  ecx, ecx
.lp:
    cmp  ecx, [users_count]
    jge  .done
    imul eax, ecx, 16
    lea  esi, [users_names + eax]
    call txt_print
    call txt_nl
    inc  ecx
    jmp  .lp
.done:
    popa
    ret

do_who_cmd:
    pusha
    mov  esi, str_userlist_hdr
    call txt_print
    xor  ecx, ecx
.lp:
    cmp  ecx, [users_count]
    jge  .done
    imul eax, ecx, 16
    lea  esi, [users_names + eax]
    call txt_print
    lea  edi, [users_names + eax]
    mov  esi, current_user
    push ecx
    mov  ecx, 15
    call strncmp
    pop  ecx
    jne  .not_logged_in
    mov  esi, str_logged_in_indicator
    call txt_print
.not_logged_in:
    call txt_nl
    inc  ecx
    jmp  .lp
.done:
    popa
    ret

do_userdel_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 8
    call str_trim
    mov  edi, tmp_name
    mov  ecx, 16
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_name
    mov  ecx, 15
.copy:
    lodsb
    or   al, al
    jz   .find
    stosb
    dec  ecx
    jnz  .copy
.find:
    mov  byte [edi], 0
    xor  ecx, ecx
.search:
    cmp  ecx, [users_count]
    jge  .notfound
    imul eax, ecx, 16
    lea  esi, [users_names + eax]
    mov  edi, tmp_name
    push ecx
    mov  ecx, 15
    call strncmp
    pop  ecx
    je   .delete
    inc  ecx
    jmp  .search
.delete:
    push ecx
    mov  eax, [users_count]
    dec  eax
    sub  eax, ecx
    jz  .skip_shift
    push eax
    imul esi, ecx, 16
    lea  esi, [users_names + esi + 16]
    imul edi, ecx, 16
    lea  edi, [users_names + edi]
    pop  eax
    imul ecx, eax, 16
    cld
    rep  movsb
    pop  ecx
    push ecx
    mov  eax, [users_count]
    dec  eax
    sub  eax, ecx
    push eax
    imul esi, ecx, 16
    lea  esi, [users_pass + esi + 16]
    imul edi, ecx, 16
    lea  edi, [users_pass + edi]
    pop  eax
    imul ecx, eax, 16
    cld
    rep  movsb
    pop  ecx
.skip_shift:
    pop  ecx
    dec  dword [users_count]
    call fs_users_save
    mov  esi, str_userdel_ok
    call txt_print
    popa
    ret
.notfound:
    mov  esi, str_notfound
    call txt_print
    popa
    ret

; esi = a word, copied to open_word in upper case. the file name itself stays as typed,
; only the keywords GAME COMMAND KERNEL get compared this way
upper_word:
    push eax
    push ecx
    push esi
    push edi
    mov  edi, open_word
    mov  ecx, 63
.copy:
    lodsb
    cmp  al, 'a'
    jb   .store
    cmp  al, 'z'
    ja   .store
    sub  al, 32
.store:
    stosb
    test al, al
    jz   .done
    dec  ecx
    jnz  .copy
    mov  byte [edi], 0
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

do_open_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 5
    call str_trim
    cmp  byte [esi], 0
    je   .show_commands
    cmp  byte [esi], '-'
    jne  .check_game
    cmp  byte [esi+1], 'C'
    je   .code_upper_c
    cmp  byte [esi+1], 'c'
    je   .code_upper_c
    cmp  byte [esi+1], 'F'
    je   .file_upper_f
    cmp  byte [esi+1], 'f'
    je   .file_upper_f
    jmp  .check_game
.file_upper_f:
    cmp  byte [esi+2], 'I'
    je   .file_upper_i
    cmp  byte [esi+2], 'i'
    je   .file_upper_i
    jmp  .check_game
.file_upper_i:
    cmp  byte [esi+3], 'L'
    je   .file_upper_l
    cmp  byte [esi+3], 'l'
    je   .file_upper_l
    jmp  .check_game
.file_upper_l:
    cmp  byte [esi+4], 'E'
    je   .file_upper_e2
    cmp  byte [esi+4], 'e'
    je   .file_upper_e2
    jmp  .check_game
.file_upper_e2:
    add  esi, 5
    call str_trim
    cmp  byte [esi], 0
    je   .show_commands
    cmp  byte [esi], '-'
    jne  .show_commands
    cmp  byte [esi+1], 'N'
    je   .name_upper_n
    cmp  byte [esi+1], 'n'
    je   .name_upper_n
    jmp  .show_commands
.name_upper_n:
    cmp  byte [esi+2], 'A'
    je   .name_upper_a
    cmp  byte [esi+2], 'a'
    je   .name_upper_a
    jmp  .show_commands
.name_upper_a:
    cmp  byte [esi+3], 'M'
    je   .name_upper_m
    cmp  byte [esi+3], 'm'
    je   .name_upper_m
    jmp  .show_commands
.name_upper_m:
    cmp  byte [esi+4], 'E'
    je   .name_upper_e3
    cmp  byte [esi+4], 'e'
    je   .name_upper_e3
    jmp  .show_commands
.name_upper_e3:
    cmp  byte [esi+5], '='
    jne  .show_commands
    add  esi, 6
    call str_trim
    cmp  byte [esi], 0
    je   .show_commands
    mov  edi, tmp_name
    mov  ecx, PATH_MAX
    cld
.copy_topic:
    lodsb
    cmp  al, ' '
    je   .topic_done
    cmp  al, 0
    je   .topic_done
    stosb
    loop .copy_topic
.topic_done:
    mov  byte [edi], 0
    mov  esi, inbuf
    add  esi, 5
    call str_trim
    cmp  byte [esi+5], '.'
    je   .has_extension
    call show_detailed_help
    jmp  .done
.has_extension:
    mov  esi, tmp_name
    call show_detailed_help_to_file
    jmp  .done
.code_upper_c:
    cmp  byte [esi+2], 'O'
    je   .code_upper_o
    cmp  byte [esi+2], 'o'
    je   .code_upper_o
    jmp  .check_game
.code_upper_o:
    cmp  byte [esi+3], 'D'
    je   .code_upper_d
    cmp  byte [esi+3], 'd'
    je   .code_upper_d
    jmp  .check_game
.code_upper_d:
    cmp  byte [esi+4], 'E'
    je   .code_upper_e
    cmp  byte [esi+4], 'e'
    je   .code_upper_e
    jmp  .check_game
.code_upper_e:
    add  esi, 5
    call str_trim
    cmp  byte [esi], 0
    je   .show_commands
    push esi
    call upper_word
    mov  esi, open_word
    mov  edi, cmd_kernel_word
    call strcmp_exact
    je   .kernel_word
    mov  edi, cmd_game
    call strcmp_exact
    pop  esi
    je   .open_game_src
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, ename
    call str_copy_path
    call fat_load
    mov  byte [mode], 4
    mov  byte [open_no_prompt], 1
    call vga_text_mode
    call ed_redraw
    jmp  .done
.check_game:
    push esi
    call upper_word
    mov  esi, open_word
    mov  edi, cmd_game
    call strcmp_exact
    je   .game_word
    mov  edi, cmd_command
    call strcmp_exact
    pop  esi
    je   .show_commands
    call resolve_path
    mov  esi, path_buf
    mov  edi, ename
    call str_copy_path
    call fat_load
    mov  byte [mode], 4
    mov  byte [open_no_prompt], 1
    call vga_text_mode
    call ed_redraw
    jmp  .done
.kernel_word:
    pop  esi
.open_kernel:
    mov  esi, str_kernel_src_code
    mov  edi, cmd_kernel_name
    call load_virtual_ide
    mov  byte [open_no_prompt], 1
    jmp  .done
.open_game_src:
    mov  esi, str_game_src_code
    mov  edi, cmd_game_name
    call load_virtual_ide
    mov  byte [open_no_prompt], 1
    jmp  .done
.game_word:
    pop  esi
.do_game:
    mov  dword [px], 10
    mov  dword [py], 10
    mov  byte [game_redraw], 1
    mov  byte [mode], 1
    mov  byte [open_no_prompt], 1
    call vga_game_mode
    call palette_init
    call world_draw
    jmp  .done
.show_commands:
    mov  esi, str_help
    call txt_print
.done:
    popa
    ret

fs_users_init:
    pusha
    mov  eax, USERS_SECTOR
    mov  edi, fs_users_block
    call ata_read_sector
    cmp  dword [users_magic], 0x53555334
    je   .have
    mov  dword [users_magic], 0x53555334
    mov  dword [users_count], 0
    mov  ecx, USER_MAX*16
    mov  edi, users_names
    xor  eax, eax
    cld
    rep  stosb
    mov  ecx, USER_MAX*16
    mov  edi, users_pass
    rep  stosb
    call fs_users_save
.have:
    mov  ecx, 16
    mov  edi, current_user
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, str_guest
    mov  edi, current_user
.cpg:
    lodsb
    or   al, al
    jz   .cpgd
    stosb
    jmp  .cpg
.cpgd:
    mov  edi, current_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, current_path
    mov  byte [edi],    '/'
    mov  byte [edi+1],  'h'
    mov  byte [edi+2],  'o'
    mov  byte [edi+3],  'm'
    mov  byte [edi+4],  'e'
    mov  byte [edi+5],  '/'
    mov  byte [edi+6],  'g'
    mov  byte [edi+7],  'u'
    mov  byte [edi+8],  'e'
    mov  byte [edi+9],  's'
    mov  byte [edi+10], 't'
    mov  edi, home_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, home_path
    mov  byte [edi],   '/'
    mov  byte [edi+1], 'h'
    mov  byte [edi+2], 'o'
    mov  byte [edi+3], 'm'
    mov  byte [edi+4], 'e'
    mov  byte [edi+5], '/'
    mov  byte [edi+6], 'g'
    mov  byte [edi+7], 'u'
    mov  byte [edi+8], 'e'
    mov  byte [edi+9], 's'
    mov  byte [edi+10], 't'
    popa
    ret

fs_users_save:
    pusha
    mov  eax, USERS_SECTOR
    mov  esi, fs_users_block
    call ata_write_sector
    popa
    ret

split_name_pass:
    push eax
    push ecx
    push edi
    mov  edi, tmp_name
    mov  ecx, 16
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, tmp_pass
    mov  ecx, 16
    rep  stosb
    mov  edi, tmp_name
    mov  ecx, 15
.n:
    mov  al, [esi]
    or   al, al
    jz   .fail
    cmp  al, ' '
    je   .gotsep
    mov  [edi], al
    inc  edi
    inc  esi
    dec  ecx
    jnz  .n
    jmp  .fail
.gotsep:
    inc  esi
    mov  edi, tmp_pass
    mov  ecx, 15
.p:
    mov  al, [esi]
    or   al, al
    jz   .pend
    mov  [edi], al
    inc  edi
    inc  esi
    dec  ecx
    jnz  .p
.pend:
    cmp  byte [tmp_pass], 0
    je   .fail
    pop  edi
    pop  ecx
    pop  eax
    clc
    ret
.fail:
    pop  edi
    pop  ecx
    pop  eax
    stc
    ret

do_useradd_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 8
    call str_trim
    cmp  byte [esi], 0
    je   .interactive
    call split_name_pass
    jc   .error
    mov  eax, [users_count]
    cmp  eax, USER_MAX
    jge  .full
    imul ebx, eax, 16
    lea  edi, [users_names+ebx]
    mov  esi, tmp_name
    mov  ecx, 16
    cld
    rep  movsb
    lea  edi, [users_pass+ebx]
    call pass_hash
    inc  dword [users_count]
    call fs_users_save
    mov  ecx, [fat_count]
    mov  edx, ecx
    cmp  ecx, FAT_MAX
    jge  .skip_home
    imul eax, ecx, PATH_MAX
    lea  edi, [fat_names+eax]
    push ecx
    push edi
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    pop  edi
    pop  ecx
    mov  byte [edi], '/'
    mov  byte [edi+1], 'h'
    mov  byte [edi+2], 'o'
    mov  byte [edi+3], 'm'
    mov  byte [edi+4], 'e'
    mov  byte [edi+5], '/'
    mov  esi, tmp_name
    add  edi, 6
    mov  ecx, 15
.copy_name:
    lodsb
    or   al, al
    jz   .name_done
    stosb
    dec  ecx
    jnz  .copy_name
.name_done:
    mov  byte [edi], 0
    imul eax, edx, 4
    mov  dword [fat_sizes+eax], 0FFFFFFFFh
    inc  dword [fat_count]
    call fs_save_all
.skip_home:
    mov  esi, str_useradd_ok
    call txt_print
    popa
    ret
.interactive:
    mov  byte [mode], 3
    mov  byte [auth_stage], 0
    mov  byte [auth_is_useradd], 1
    mov  dword [inlen], 0
    mov  ecx, 256
    mov  edi, inbuf
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, str_new_user_prompt
    call txt_print
    popa
    ret
.full:
    mov  esi, str_useradd_full
    call txt_print
    popa
    ret
.error:
    mov  esi, str_useradd_error
    call txt_print
    popa
    ret

do_login_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 6
    call str_trim
    cmp  byte [esi], 0
    je   .interactive
    call split_name_pass
    jc   .fail
    xor  ecx, ecx
.lp:
    cmp  ecx, [users_count]
    jge  .fail
    imul eax, ecx, 16
    lea  esi, [users_names+eax]
    mov  edi, tmp_name
    push ecx
    mov  ecx, 15
    call strncmp
    pop  ecx
    jne  .next
    imul eax, ecx, 16
    lea  esi, [users_pass+eax]
    call pass_check
    je   .ok
.next:
    inc  ecx
    jmp  .lp
.ok:
    mov  ecx, 16
    mov  edi, current_user
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, tmp_name
    mov  edi, current_user
    mov  ecx, 16
    cld
    rep  movsb
    mov  edi, home_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, home_path
    mov  byte [edi],   '/'
    mov  byte [edi+1], 'h'
    mov  byte [edi+2], 'o'
    mov  byte [edi+3], 'm'
    mov  byte [edi+4], 'e'
    mov  byte [edi+5], '/'
    mov  esi, tmp_name
    add  edi, 6
    mov  ecx, 15
.copy_home_name:
    lodsb
    or   al, al
    jz   .home_name_done
    stosb
    dec  ecx
    jnz  .copy_home_name
.home_name_done:
    mov  edi, current_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, home_path
    mov  edi, current_path
    mov  ecx, PATH_MAX
    cld
    rep  movsb
    mov  esi, str_login_ok
    call txt_print
    popa
    ret
.interactive:
    mov  byte [mode], 3
    mov  byte [auth_stage], 0
    mov  byte [auth_is_useradd], 0
    mov  dword [inlen], 0
    mov  ecx, 256
    mov  edi, inbuf
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, str_login_prompt
    call txt_print
    popa
    ret
.fail:
    mov  esi, str_login_fail
    call txt_print
    popa
    ret

do_logout_cmd:
    pusha
    mov  ecx, 16
    mov  edi, current_user
    xor  eax, eax
    cld
    rep  stosb
    mov  esi, str_guest
    mov  edi, current_user
.cp:
    lodsb
    or   al, al
    jz   .cpd
    stosb
    jmp  .cp
.cpd:
    mov  edi, home_path
    mov  ecx, PATH_MAX
    xor  eax, eax
    cld
    rep  stosb
    mov  edi, home_path
    mov  byte [edi],    '/'
    mov  byte [edi+1],  'h'
    mov  byte [edi+2],  'o'
    mov  byte [edi+3],  'm'
    mov  byte [edi+4],  'e'
    mov  byte [edi+5],  '/'
    mov  byte [edi+6],  'g'
    mov  byte [edi+7],  'u'
    mov  byte [edi+8],  'e'
    mov  byte [edi+9],  's'
    mov  byte [edi+10], 't'
    mov  esi, home_path
    mov  edi, current_path
    call str_copy_path
    mov  esi, str_logout_ok
    call txt_print
    popa
    ret

do_whoami_cmd:
    pusha
    mov  esi, current_user
    call txt_print
    call txt_nl
    popa
    ret

do_color_cmd:
    pusha
    mov  esi, inbuf
    add  esi, 6
    call str_trim
    cmp  byte [esi], 0
    je   .usage
    mov  al, [esi]
    cmp  al, '0'
    jl   .invalid
    cmp  al, '9'
    jg   .check_hex_upper
    sub  al, '0'
    jmp  .set_color
.check_hex_upper:
    cmp  al, 'A'
    jl   .invalid
    cmp  al, 'F'
    jg   .check_hex_lower
    sub  al, 'A'
    add  al, 10
    jmp  .set_color
.check_hex_lower:
    cmp  al, 'a'
    jl   .invalid
    cmp  al, 'f'
    jg   .invalid
    sub  al, 'a'
    add  al, 10
    jmp  .set_color
.set_color:
    cmp  al, 15
    jg   .invalid
    mov  [term_color], al
    mov  esi, str_color_ok
    call txt_print
    popa
    ret
.usage:
    mov  esi, str_color_usage
    call txt_print
    popa
    ret
.invalid:
    mov  esi, str_color_invalid
    call txt_print
    popa
    ret

load_virtual_ide:
    push edi
    push esi
    mov  edi, ename
    mov  ecx, PATH_MAX-1
    xor  eax, eax
    cld
    rep  stosb
    pop  esi
    pop  edi
    push esi
    mov  ecx, PATH_MAX-1
    cld
.cp_name:
    lodsb
    or   al, al
    jz   .cp_name_done
    stosb
    loop .cp_name
.cp_name_done:
    pop  esi
    mov  edi, ebuf
    mov  ecx, EDIT_MAX
    xor  eax, eax
    rep  stosb
    mov  edi, ebuf
    xor  ecx, ecx
.cp_code:
    lodsb
    or   al, al
    jz   .cp_code_done
    stosb
    inc  ecx
    cmp  ecx, EDIT_MAX-1
    jb   .cp_code
.cp_code_done:
    mov  [elen], ecx
    mov  dword [ecur], 0
    mov  dword [ed_top], 0
    mov  byte [mode], 4
    call vga_text_mode
    call ed_redraw
    ret

ed_redraw:
    pusha
    call txt_clear
    push edi
    mov  edi, VGA_TEXT
    mov  ecx, COLS
    mov  ax, 0x1720
.tb:
    mov  [edi], ax
    add  edi, 2
    loop .tb
    pop  edi
    mov  dword [cur_x], 1
    mov  dword [cur_y], 0
    mov  esi, str_etitle
    call txt_print_attr
    mov  esi, ename
    call txt_print_attr
    mov  esi, str_etitle2
    call txt_print_attr
    push edi
    mov  edi, VGA_TEXT + COLS*2
    mov  ecx, COLS
    mov  ax, 0x0B2D
.sep:
    mov  [edi], ax
    add  edi, 2
    loop .sep
    pop  edi
    call ed_locate
    call ed_fix_top
    ; only the lines that fit between the title and the help bar
    mov  esi, ebuf
    mov  ecx, [elen]
    xor  ebx, ebx
    xor  edx, edx
.lp:
    test ecx, ecx
    jz   .done
    dec  ecx
    lodsb
    cmp  al, 0x0A
    je   .newline
    mov  edi, ebx
    sub  edi, [ed_top]
    jb   .skip
    cmp  edi, ED_ROWS
    jae  .done
    add  edi, 2
    imul edi, COLS
    add  edi, edx
    shl  edi, 1
    add  edi, VGA_TEXT
    mov  ah, [term_color]
    mov  [edi], ax
.skip:
    inc  edx
    cmp  edx, COLS
    jl   .lp
.newline:
    xor  edx, edx
    inc  ebx
    jmp  .lp
.done:
    push edi
    mov  edi, VGA_TEXT + COLS*(ROWS-1)*2
    mov  ecx, COLS
    mov  ax, 0x2020
.sb:
    mov  [edi], ax
    add  edi, 2
    loop .sb
    pop  edi
    mov  dword [cur_x], 0
    mov  dword [cur_y], ROWS-1
    mov  esi, str_ehelp
    call txt_print_attr2
    call ed_place_cursor
    popa
    ret

; eax = the line the cursor is on, edx = its column. long lines wrap at 80 like on screen
ed_locate:
    push ecx
    push esi
    xor  eax, eax
    xor  edx, edx
    mov  ecx, [ecur]
    mov  esi, ebuf
.next:
    test ecx, ecx
    jz   .done
    dec  ecx
    cmp  byte [esi], 0x0A
    lea  esi, [esi+1]
    je   .newline
    inc  edx
    cmp  edx, COLS
    jl   .next
.newline:
    xor  edx, edx
    inc  eax
    jmp  .next
.done:
    pop  esi
    pop  ecx
    ret

; eax = cursor line. moves ed_top so that line is on screen, CF=1 if it had to
ed_fix_top:
    push ecx
    cmp  eax, [ed_top]
    jae  .not_above
    mov  [ed_top], eax
    pop  ecx
    stc
    ret
.not_above:
    mov  ecx, [ed_top]
    add  ecx, ED_ROWS
    cmp  eax, ecx
    jb   .fine
    lea  ecx, [eax - ED_ROWS + 1]
    mov  [ed_top], ecx
    pop  ecx
    stc
    ret
.fine:
    pop  ecx
    clc
    ret

ed_place_cursor:
    push eax
    push edx
    call ed_locate
    sub  eax, [ed_top]
    add  eax, 2
    mov  [cur_y], eax
    mov  [cur_x], edx
    pop  edx
    pop  eax
    ret

; up and down keep the column if the other line is long enough
ed_line_start:
    mov  eax, [ecur]
.back:
    test eax, eax
    jz   .done
    cmp  byte [ebuf + eax - 1], 0x0A
    je   .done
    dec  eax
    jmp  .back
.done:
    ret

ed_up:
    pushad
    call ed_line_start
    test eax, eax
    jz   .done
    mov  edx, [ecur]
    sub  edx, eax
    lea  ebx, [eax - 1]
    mov  [ecur], ebx
    call ed_line_start
    sub  ebx, eax
    cmp  edx, ebx
    jbe  .col
    mov  edx, ebx
.col:
    add  eax, edx
    mov  [ecur], eax
.done:
    popad
    ret

ed_down:
    pushad
    call ed_line_start
    mov  edx, [ecur]
    sub  edx, eax
    mov  eax, [ecur]
.find_end:
    cmp  eax, [elen]
    jae  .done
    cmp  byte [ebuf + eax], 0x0A
    je   .next_line
    inc  eax
    jmp  .find_end
.next_line:
    inc  eax
    mov  ebx, eax
.walk:
    test edx, edx
    jz   .set
    cmp  eax, [elen]
    jae  .set
    cmp  byte [ebuf + eax], 0x0A
    je   .set
    inc  eax
    dec  edx
    jmp  .walk
.set:
    mov  [ecur], eax
.done:
    popad
    ret

fat_load_tree:
    cmp  byte [ename], '/'
    je   .path_ready
    mov  esi, ename
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, ename
    call str_copy_path
.path_ready:
    mov  ecx, EDIT_MAX
    mov  edi, ebuf
    xor  eax, eax
    cld
    rep  stosb
    mov  dword [elen], 0
    mov  dword [ecur], 0
    mov  dword [ed_top], 0
    mov  esi, ename
    call fs_resolve_path_to_index
    jnc  .done
    mov  ecx, eax
    imul eax, ecx, 4
    mov  eax, [fat_sizes+eax]
    cmp  eax, 0FFFFFFFFh
    je   .done
    cmp  eax, EDIT_MAX
    jb   .size_ok
    mov  eax, EDIT_MAX
.size_ok:
    mov  [elen], eax
    or   eax, eax
    jz   .done
    push eax
    imul ecx, FAT_SIZE
    lea  esi, [fat_data+ecx]
    pop  ecx
    mov  edi, ebuf
    cld
    rep  movsb
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

fat_load:
    push eax
    push ecx
    push esi
    push edi
    jmp  fat_load_tree

fat_save_tree:
    cmp  byte [ename], '/'
    je   .path_ready
    mov  esi, ename
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    mov  edi, ename
    call str_copy_path
.path_ready:
    mov  esi, ename
    call fs_resolve_path_to_index
    jc   .update
    mov  esi, ename
    call fs_split_path
    jnc  .done
    mov  ebx, eax
    push esi
    mov  edx, ebx
    call fs_find_child_by_name
    pop  esi
    jc   .done
    mov  edx, [fat_count]
    cmp  edx, FAT_MAX
    jge  .done
    imul eax, edx, PATH_MAX
    lea  edi, [fat_names+eax]
    call str_copy_path
    imul eax, edx, 4
    mov  [fat_parents+eax], ebx
    inc  dword [fat_count]
    jmp  .store
.update:
    mov  edx, eax
.store:
    imul eax, edx, 4
    mov  ecx, [elen]
    mov  [fat_sizes+eax], ecx
    or   ecx, ecx
    jz   .save
    imul eax, edx, FAT_SIZE
    lea  edi, [fat_data+eax]
    mov  esi, ebuf
    cld
    rep  movsb
.save:
    call fs_save_all
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

; pushes what fat_save_tree pops
fat_save:
    push eax
    push ecx
    push esi
    push edi
    jmp  fat_save_tree

fat_cat_lookup:
    mov  esi, ename
    call fs_resolve_path_to_index
    jnc  .nf
    imul esi, eax, FAT_SIZE
    add  esi, fat_data
    mov  ecx, [fat_sizes+eax*4]
    cmp  ecx, 0FFFFFFFFh
    je   .isdirerr
    or   ecx, ecx
    je   .empty
    call txt_nl
.print:
    or   ecx, ecx
    jz   .done
    lodsb
    call txt_putc
    dec  ecx
    jmp  .print
.empty:
    mov  esi, str_cat_empty
    call txt_print
    jmp  .done
.isdirerr:
    mov  esi, str_cat_isdir
    call txt_print
    jmp  .done
.nf:
    mov  esi, str_notfound
    call txt_print
.done:
    call txt_nl
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

fat_cat:
    push eax
    push ecx
    push esi
    push edi
    jmp  fat_cat_lookup

fat_del_by_index:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    cmp  ecx, [fat_count]
    jge  .done
    mov  eax, [fat_count]
    dec  eax
    sub  eax, ecx
    jz   .skip_shift_names
    push eax
    imul esi, ecx, PATH_MAX
    lea  esi, [fat_names + esi + PATH_MAX]
    imul edi, ecx, PATH_MAX
    lea  edi, [fat_names + edi]
    pop  eax
    imul ecx, eax, PATH_MAX
    cld
    rep  movsb
.skip_shift_names:
    pop  ecx
    push ecx
    mov  eax, [fat_count]
    dec  eax
    sub  eax, ecx
    jz   .skip_shift_sizes
    push eax
    imul esi, ecx, 4
    lea  esi, [fat_sizes + esi + 4]
    imul edi, ecx, 4
    lea  edi, [fat_sizes + edi]
    pop  eax
    mov  ecx, eax
    cld
    rep  movsd
.skip_shift_sizes:
    pop  ecx
    push ecx
    mov  eax, [fat_count]
    dec  eax
    sub  eax, ecx
    jz   .skip_shift_parents
    push eax
    imul esi, ecx, 4
    lea  esi, [fat_parents + esi + 4]
    imul edi, ecx, 4
    lea  edi, [fat_parents + edi]
    pop  eax
    mov  ecx, eax
    cld
    rep  movsd
.skip_shift_parents:
    pop  ecx
    push ecx
    mov  eax, [fat_count]
    dec  eax
    sub  eax, ecx
    jz   .skip_shift_data
    push eax
    imul esi, ecx, FAT_SIZE
    lea  esi, [fat_data + esi + FAT_SIZE]
    imul edi, ecx, FAT_SIZE
    lea  edi, [fat_data + edi]
    pop  eax
    imul ecx, eax, FAT_SIZE
    cld
    rep  movsb
.skip_shift_data:
    dec  dword [fat_count]
    call fs_save_all
.done:
    pop  edi
    pop  esi
    pop  ecx
    pop  ebx
    pop  eax
    ret

fat_del:
    push eax
    push ecx
    push esi
    push edi
    mov  edi, ename
    mov  ecx, PATH_MAX-1
    cld
.cpn:
    lodsb
    or   al, al
    jz   .cpd
    stosb
    loop .cpn
.cpd:
    mov  byte [edi], 0
    xor  ecx, ecx
.lp:
    cmp  ecx, [fat_count]
    jge  .nf
    imul eax, ecx, PATH_MAX
    lea  esi, [fat_names + eax]
    mov  edi, ename
    push ecx
    call strcmp_exact
    pop  ecx
    jc   .found
    inc  ecx
    jmp  .lp
.found:
    push ecx
    mov  eax, [fat_count]
    dec  eax
    sub  eax, ecx
    jz   .skip_shift
    push eax
    imul esi, ecx, PATH_MAX
    lea  esi, [fat_names + esi + PATH_MAX]
    imul edi, ecx, PATH_MAX
    lea  edi, [fat_names + edi]
    pop  eax
    imul ecx, eax, PATH_MAX
    cld
    rep  movsb
    pop  ecx
    push ecx
    mov  eax, [fat_count]
    dec  eax
    sub  eax, ecx
    push eax
    imul esi, ecx, 4
    lea  esi, [fat_sizes + esi + 4]
    imul edi, ecx, 4
    lea  edi, [fat_sizes + edi]
    pop  eax
    imul ecx, eax, 4
    cld
    rep  movsb
    pop  ecx
    jmp  .dec
.skip_shift:
    pop  ecx
.dec:
    dec  dword [fat_count]
    call fs_save_all
    mov  esi, str_deleted
    call txt_print
    jmp  .done
.nf:
    mov  esi, str_notfound
    call txt_print
.done:
    call txt_nl
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

draw_banner:
    push eax
    push ecx
    push edi
    mov  dword [cur_x], 0
    mov  dword [cur_y], 0
    mov  esi, str_serpentis_logo
    call txt_print
    mov  edi, VGA_TEXT
    mov  ecx, COLS
    mov  ax, 0x0D20
.l1:
    mov  [edi], ax
    add  edi, 2
    loop .l1
    mov  ecx, COLS
    mov  ax, 0x0920
.l2:
    mov  [edi], ax
    add  edi, 2
    loop .l2
    mov  ecx, COLS
    mov  ax, 0x0D2D
.l3:
    mov  [edi], ax
    add  edi, 2
    loop .l3
    pop  edi
    pop  ecx
    pop  eax
    mov  dword [cur_x], 2
    mov  dword [cur_y], 23
    mov  esi, str_title
    call txt_print_attr
    mov  dword [cur_x], 2
    mov  dword [cur_y], 24
    mov  esi, str_hint
    call txt_print_attr3
    mov  dword [cur_x], 0
    mov  dword [cur_y], 24
    ret

txt_print_attr:
    push eax
.l:
    lodsb
    or   al, al
    jz   .done
    cmp  al, 0x0A
    je   .nl
    push edi
    mov  edi, [cur_y]
    imul edi, COLS
    add  edi, [cur_x]
    shl  edi, 1
    add  edi, VGA_TEXT
    mov  ah, 0x1E
    mov  [edi], ax
    pop  edi
    inc  dword [cur_x]
    cmp  dword [cur_x], COLS
    jl   .l
    mov  dword [cur_x], 0
    inc  dword [cur_y]
    jmp  .l
.nl:
    mov  dword [cur_x], 0
    inc  dword [cur_y]
    jmp  .l
.done:
    pop  eax
    ret

txt_print_attr3:
    push eax
.l:
    lodsb
    or   al, al
    jz   .done
    push edi
    mov  edi, [cur_y]
    imul edi, COLS
    add  edi, [cur_x]
    shl  edi, 1
    add  edi, VGA_TEXT
    mov  ah, 0x1B
    mov  [edi], ax
    pop  edi
    inc  dword [cur_x]
    cmp  dword [cur_x], COLS
    jl   .l
.done:
    pop  eax
    ret

txt_print_attr2:
    push eax
.l:
    lodsb
    or   al, al
    jz   .done
    push edi
    mov  edi, [cur_y]
    imul edi, COLS
    add  edi, [cur_x]
    shl  edi, 1
    add  edi, VGA_TEXT
    mov  ah, 0x20
    mov  [edi], ax
    pop  edi
    inc  dword [cur_x]
    cmp  dword [cur_x], COLS
    jl   .l
.done:
    pop  eax
    ret

txt_clear:
    pusha
    cld
    mov  edi, VGA_TEXT
    mov  ecx, COLS*ROWS
    mov  ax, 0x0720
.l:
    mov  [edi], ax
    add  edi, 2
    loop .l
    mov  dword [cur_x], 0
    mov  dword [cur_y], 0
    popa
    ret

txt_putc:
    push eax
    push edi
    cmp  al, 0x0A
    je   .nl
    mov  edi, [cur_y]
    imul edi, COLS
    add  edi, [cur_x]
    shl  edi, 1
    add  edi, VGA_TEXT
    mov  ah, [term_color]
    mov  [edi], ax
    inc  dword [cur_x]
    cmp  dword [cur_x], COLS
    jl   .ok
.nl:
    mov  dword [cur_x], 0
    inc  dword [cur_y]
    cmp  dword [cur_y], ROWS
    jl   .ok
    call txt_scroll
    mov  dword [cur_y], ROWS-1
.ok:
    pop  edi
    pop  eax
    ret

; a line that scrolls off the top is kept in the scrollback, page up brings it back
txt_scroll:
    pusha
    cmp  dword [scrollback_lines], SCROLLBACK_LINES
    jge  .skip_save
    mov  eax, [scrollback_lines]
    imul eax, SCROLLBACK_LINE_SIZE
    lea  edi, [SCROLLBACK_BUF + eax]
    mov  esi, VGA_TEXT
    mov  ecx, COLS
.copy_line:
    mov  ax, [esi]
    mov  [edi], ax
    add  esi, 2
    add  edi, 2
    loop .copy_line
    inc  dword [scrollback_lines]
.skip_save:
    cld
    mov  esi, VGA_TEXT + COLS*2
    mov  edi, VGA_TEXT
    mov  ecx, COLS*(ROWS-1)
    rep  movsw
    mov  edi, VGA_TEXT + COLS*(ROWS-1)*2
    mov  ecx, COLS
    mov  ax, 0x0720
.l:
    mov  [edi], ax
    add  edi, 2
    loop .l
    popa
    ret

draw_from_scrollback:
    pusha
    cmp  dword [scrollback_lines], 0
    je   .done
    mov  eax, [scrollback_offset]
    cmp  eax, [scrollback_lines]
    jge  .done
    mov  edi, VGA_TEXT
    mov  ecx, ROWS
.draw_line:
    cmp  eax, [scrollback_lines]
    jge  .clear_rest
    imul ebx, eax, SCROLLBACK_LINE_SIZE
    lea  esi, [SCROLLBACK_BUF + ebx]
    mov  edx, COLS
.copy_char:
    mov  ax, [esi]
    mov  [edi], ax
    add  esi, 2
    add  edi, 2
    dec  edx
    jnz  .copy_char
    inc  eax
    loop .draw_line
    popa
    ret
.clear_rest:
    mov  ax, 0x0720
.clear_loop:
    mov  [edi], ax
    add  edi, 2
    loop .clear_loop
.done:
    popa
    ret

txt_nl:
    push eax
    mov  al, 0x0A
    call txt_putc
    pop  eax
    ret

txt_print:
    push eax
.l:
    lodsb
    or   al, al
    jz   .done
    call txt_putc
    jmp  .l
.done:
    pop  eax
    ret

txt_backspace:
    push edi
    push eax
    cmp  dword [cur_x], 0
    je   .done
    dec  dword [cur_x]
    mov  edi, [cur_y]
    imul edi, COLS
    add  edi, [cur_x]
    shl  edi, 1
    add  edi, VGA_TEXT
    mov  word [edi], 0x0720
.done:
    pop  eax
    pop  edi
    ret

shell_prompt:
    push esi
    mov  esi, current_user
    call txt_print
    mov  al, '@'
    call txt_putc
    mov  esi, str_hostname
    call txt_print
    mov  al, ':'
    call txt_putc
    push esi
    mov  esi, current_path
    mov  edi, home_path
    call strcmp_exact
    pop  esi
    jnc  .print_full_path
    mov  al, '~'
    call txt_putc
    jmp  .after_path
.print_full_path:
    mov  esi, current_path
    call txt_print
.after_path:
    mov  esi, str_prompt_suffix
    call txt_print
    pop  esi
    ret

show_welcome:
    pusha
    call txt_clear
    mov  dword [cur_x], 0
    mov  dword [cur_y], 0
    mov  esi, str_serpentis_logo
    call txt_print
    mov  dword [cur_y], 24
    mov  dword [cur_x], 30
    mov  esi, str_boot_title
    call txt_print
    mov  ecx, 0x08000000
.delay:
    loop .delay
    call txt_clear
    popa
    ret

; 320x200x256 by writing the vga registers by hand, there is no bios in protected mode
vga_game_mode:
    pusha
    mov  dx, 0x3C2
    mov  al, 0x63
    out  dx, al
    mov  dx, 0x3C4
    mov  esi, seq_game
    call out_table
    mov  dx, 0x3D4
    mov  al, 0x11
    out  dx, al
    inc  dx
    in   al, dx
    and  al, 0x7F
    out  dx, al
    dec  dx
    mov  esi, crtc_game
    call out_table
    mov  dx, 0x3CE
    mov  esi, gc_game
    call out_table
    mov  dx, 0x3DA
    in   al, dx
    mov  dx, 0x3C0
    mov  esi, attr_game
    call out_attr
    mov  dx, 0x3DA
    in   al, dx
    mov  dx, 0x3C0
    mov  al, 0x20
    out  dx, al
    call palette_init
    mov  dx, 0x3DA
    in   al, dx
    mov  edi, VGA_GAME
    mov  ecx, SCR_W*SCR_H/4
    xor  eax, eax
    cld
    rep  stosd
    popa
    ret

vga_text_mode:
    pusha
    mov  dx, 0x3C2
    mov  al, 0x67
    out  dx, al
    mov  dx, 0x3C4
    mov  ax, 0x0100
    out  dx, ax
    mov  esi, seq_text
    call out_table
    mov  dx, 0x3C4
    mov  ax, 0x0300
    out  dx, ax
    mov  dx, 0x3D4
    mov  al, 0x11
    out  dx, al
    inc  dx
    in   al, dx
    and  al, 0x7F
    out  dx, al
    dec  dx
    mov  esi, crtc_text
    call out_table
    mov  dx, 0x3CE
    mov  esi, gc_text
    call out_table
    mov  dx, 0x3DA
    in   al, dx
    mov  dx, 0x3C0
    mov  esi, attr_text
    call out_attr
    mov  dx, 0x3DA
    in   al, dx
    mov  dx, 0x3C0
    mov  al, 0x20
    out  dx, al
    call palette_init_text
    mov  dx, 0x3DA
    in   al, dx
    mov  edi, VGA_TEXT
    mov  ecx, COLS*ROWS
    mov  ax, 0x0720
    cld
    rep  stosw
    popa
    ret

out_table:
    push eax
    cld
.l:
    lodsb
    cmp  al, 0xFF
    je   .done
    out  dx, al
    inc  dx
    lodsb
    out  dx, al
    dec  dx
    jmp  .l
.done:
    pop  eax
    ret

out_attr:
    push eax
    cld
.l:
    lodsb
    cmp  al, 0xFF
    je   .done
    out  dx, al
    lodsb
    out  dx, al
    jmp  .l
.done:
    pop  eax
    ret

seq_game:   db 0x00,0x03,0x01,0x01,0x02,0x0F,0x03,0x00,0x04,0x0E,0xFF

crtc_game:  db 0x00,0x5F,0x01,0x4F,0x02,0x50,0x03,0x82,0x04,0x54,0x05,0x80
            db 0x06,0xBF,0x07,0x1F,0x08,0x00,0x09,0x41,0x0A,0x00,0x0B,0x00
            db 0x0C,0x00,0x0D,0x00,0x0E,0x00,0x0F,0x00,0x10,0x9C,0x11,0x0E
            db 0x12,0x8F,0x13,0x28,0x14,0x40,0x15,0x96,0x16,0xB9,0x17,0xA3
            db 0x18,0xFF,0xFF

gc_game:    db 0x00,0x00,0x01,0x00,0x02,0x00,0x03,0x00,0x04,0x00,0x05,0x40
            db 0x06,0x05,0x07,0x0F,0x08,0xFF,0xFF

attr_game:  db 0x00,0x00,0x01,0x01,0x02,0x02,0x03,0x03,0x04,0x04,0x05,0x05
            db 0x06,0x06,0x07,0x07,0x08,0x08,0x09,0x09,0x0A,0x0A,0x0B,0x0B
            db 0x0C,0x0C,0x0D,0x0D,0x0E,0x0E,0x0F,0x0F,0x10,0x41,0x11,0x00
            db 0x12,0x0F,0x13,0x00,0x14,0x00,0xFF

seq_text:   db 0x01,0x00,0x02,0x03,0x03,0x00,0x04,0x02,0xFF

crtc_text:  db 0x00,0x5F,0x01,0x4F,0x02,0x50,0x03,0x82,0x04,0x55,0x05,0x81
            db 0x06,0xBF,0x07,0x1F,0x08,0x00,0x09,0x4F,0x0A,0x0D,0x0B,0x0E
            db 0x0C,0x00,0x0D,0x00,0x0E,0x00,0x0F,0x00,0x10,0x9C,0x11,0x8E
            db 0x12,0x8F,0x13,0x28,0x14,0x1F,0x15,0x96,0x16,0xB9,0x17,0xA3
            db 0x18,0xFF,0xFF

gc_text:    db 0x00,0x00,0x01,0x00,0x02,0x00,0x03,0x00,0x04,0x00,0x05,0x10
            db 0x06,0x0E,0x07,0x00,0x08,0xFF,0xFF

attr_text:  db 0x00,0x00,0x01,0x01,0x02,0x02,0x03,0x03,0x04,0x04,0x05,0x05
            db 0x06,0x14,0x07,0x07,0x08,0x38,0x09,0x39,0x0A,0x3A,0x0B,0x3B
            db 0x0C,0x3C,0x0D,0x3D,0x0E,0x3E,0x0F,0x3F,0x10,0x0C,0x11,0x00
            db 0x12,0x0F,0x13,0x08,0x14,0x00,0xFF

palette_init_text:
    pusha
    mov  dx, 0x3C8
    xor  al, al
    out  dx, al
    mov  dx, 0x3C9
    mov  esi, pal_data_text
    mov  ecx, 16*3
.l:
    lodsb
    out  dx, al
    loop .l
    popa
    ret

pal_data_text:
    db  0, 0, 0
    db  0, 0,42
    db  0,42, 0
    db  0,42,42
    db 42, 0, 0
    db 42, 0,42
    db 42,21, 0
    db 42,42,42
    db 21,21,21
    db 21,21,63
    db 21,63,21
    db 21,63,63
    db 63,21,21
    db 63,21,63
    db 63,63,21
    db 63,63,63

palette_init:
    pusha
    mov  dx, 0x3C8
    xor  al, al
    out  dx, al
    mov  dx, 0x3C9
    mov  esi, pal_data
    mov  ecx, 32*3
.l:
    lodsb
    out  dx, al
    loop .l
    popa
    ret

pal_data:
    db  0,0,0,    5,5,8,   12,10,12,  24,22,24
    db 10,32,10, 16,44,12, 22,52,14,  30,58,20
    db 28,14,4,  42,22,6,  52,32,8,   58,40,14
    db  0,6,32,   0,14,48,  4,22,58,  14,36,63
    db 14,12,16, 24,22,26, 36,34,38,  46,44,48
    db 28,16,4,  40,24,8,   8,30,8,   12,46,10
    db 20,54,14,  0,0,0,   58,48,30,  48,22,8
    db 24,14,4,  63,63,63, 63,60,0,   63,20,10

world_map:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,3,3,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,3,3,3,0,0,0,0,1,1,1,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,2,2,2,2,2,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,2,2,2,2,2,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,2,2,0,0,0,0,0,3,3,0,0
    db 0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0,3,3,0,0
    db 0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,3,3,3,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,3,3,3,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,3,3,3,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,1,1,0,0,0,0,0,0,0,2,2,2,0,0,0
    db 0,0,0,0,0,1,1,0,0,0,0,0,0,0,2,2,2,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,2,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,3,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,3,3,0,0,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

trees:
    db  1,0,  5,0, 14,0,  0,2,  9,2, 17,1
    db  4,4, 13,3, 19,3,  2,6, 15,5,  0,7
    db  6,8, 18,7, 12,6,  3,10,16,10, 7,11
    db  1,12,10,13,19,12, 4,15,14,16, 8,15
    db  0,17,18,17, 5,18, 9,19,13,19, 2,19, 0xFF
px dd 10
py dd 10

; map x and y to the pixel where that tile is drawn in the isometric view
iso_to_screen:
    push ecx
    push edx
    mov  ecx, eax
    sub  ecx, ebx
    imul ecx, 10
    add  ecx, ISO_OX
    add  eax, ebx
    imul eax, 5
    add  eax, ISO_OY
    mov  ebx, eax
    mov  eax, ecx
    pop  edx
    pop  ecx
    ret

hline:
    push eax
    push ecx
    push edi
    or   ecx, ecx
    jle  .done
    cmp  ebx, SCR_H
    jae  .done
    cmp  eax, SCR_W
    jae  .done
    or   eax, eax
    jge  .nclip
    add  ecx, eax
    xor  eax, eax
    or   ecx, ecx
    jle  .done
.nclip:
    push eax
    add  eax, ecx
    cmp  eax, SCR_W
    jle  .nrclip
    mov  ecx, SCR_W
    sub  ecx, [esp]
.nrclip:
    pop  eax
    imul edi, ebx, SCR_W
    add  edi, eax
    add  edi, VGA_GAME
    mov  al, dl
    cld
    rep  stosb
.done:
    pop  edi
    pop  ecx
    pop  eax
    ret

draw_tile:
    pusha
    movzx esi, cl
    call  iso_to_screen
    mov   [tsx], eax
    mov   [tsy], ebx
    cmp   esi, 1
    je    .dirt
    cmp   esi, 2
    je    .water
    cmp   esi, 3
    je    .stone
    mov   byte [ctop0], 7
    mov   byte [ctop1], 6
    mov   byte [ctop2], 5
    mov   byte [cside0], 4
    jmp   .draw
.dirt:
    mov   byte [ctop0], 11
    mov   byte [ctop1], 10
    mov   byte [ctop2], 9
    mov   byte [cside0], 8
    jmp   .draw
.water:
    mov   byte [ctop0], 15
    mov   byte [ctop1], 14
    mov   byte [ctop2], 13
    mov   byte [cside0], 12
    jmp   .draw
.stone:
    mov   byte [ctop0], 19
    mov   byte [ctop1], 18
    mov   byte [ctop2], 17
    mov   byte [cside0], 16
.draw:
    xor   edi, edi
.tloop:
    cmp   edi, 10
    jge   .sides
    mov   ebx, [tsy]
    add   ebx, edi
    cmp   edi, 5
    jl    .upper
    mov   ecx, edi
    sub   ecx, 5
    mov   eax, [tsx]
    add   eax, ecx
    mov   ecx, 10
    sub   ecx, edi
    imul  ecx, 2
    jmp   .pc
.upper:
    mov   eax, [tsx]
    mov   ecx, edi
    sub   eax, ecx
    add   eax, 4
    mov   ecx, edi
    imul  ecx, 2
    add   ecx, 2
.pc:
    cmp   edi, 2
    jl    .c0
    cmp   edi, 7
    jl    .c1
    movzx edx, byte [ctop2]
    jmp   .dr
.c0:
    movzx edx, byte [ctop0]
    jmp   .dr
.c1:
    movzx edx, byte [ctop1]
.dr:
    call  hline
    inc   edi
    jmp   .tloop
.sides:
    xor   edi, edi
.ls:
    cmp   edi, ISO_SH
    jge   .rs
    mov   eax, [tsx]
    dec   eax
    mov   ecx, 11
    mov   ebx, [tsy]
    add   ebx, 10
    add   ebx, edi
    movzx edx, byte [cside0]
    call  hline
    inc   edi
    jmp   .ls
.rs:
    xor   edi, edi
.rs2:
    cmp   edi, ISO_SH
    jge   .td
    mov   eax, [tsx]
    add   eax, 10
    mov   ecx, 11
    mov   ebx, [tsy]
    add   ebx, 10
    add   ebx, edi
    movzx edx, byte [cside0]
    call  hline
    inc   edi
    jmp   .rs2
.td:
    popa
    ret

draw_tree:
    pusha
    call  iso_to_screen
    push  eax
    push  ebx
    add   eax, 8
    sub   ebx, 1
    mov   ecx, 4
    mov   dl, 21
    call  hline
    add   ebx, 1
    mov   ecx, 3
    call  hline
    add   ebx, 1
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    sub   ebx, 12
    push  eax
    push  ebx
    add   eax, 7
    mov   ecx, 6
    mov   dl, 24
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 4
    add   ebx, 1
    mov   ecx, 12
    mov   dl, 23
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 2
    add   ebx, 2
    mov   ecx, 16
    mov   dl, 23
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 1
    add   ebx, 3
    mov   ecx, 18
    mov   dl, 22
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 2
    add   ebx, 4
    mov   ecx, 16
    mov   dl, 22
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 4
    add   ebx, 5
    mov   ecx, 12
    mov   dl, 23
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 6
    add   ebx, 6
    mov   ecx, 8
    mov   dl, 22
    call  hline
    pop   ebx
    pop   eax
    pop   ebx
    pop   eax
    popa
    ret

draw_player:
    pusha
    push  eax
    push  ebx
    add   eax, 6
    add   ebx, 2
    mov   ecx, 8
    mov   dl, 1
    call  hline
    add   ebx, 1
    add   eax, 1
    mov   ecx, 6
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 7
    sub   ebx, 4
    mov   ecx, 2
    mov   dl, 28
    call  hline
    add   eax, 4
    call  hline
    add   ebx, 1
    sub   eax, 3
    mov   ecx, 2
    call  hline
    add   eax, 2
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 6
    sub   ebx, 8
    mov   ecx, 8
    mov   dl, 27
    call  hline
    add   ebx, 1
    call  hline
    add   ebx, 1
    call  hline
    pop   ebx
    pop   eax
    push  eax
    push  ebx
    add   eax, 7
    sub   ebx, 12
    mov   ecx, 6
    mov   dl, 26
    call  hline
    add   ebx, 1
    call  hline
    add   ebx, 1
    call  hline
    add   ebx, 1
    call  hline
    pop   ebx
    pop   eax
    popa
    ret

draw_minimap:
    pusha
    xor   esi, esi
.mr:
    cmp   esi, MAP_H
    jge   .mpl
    xor   edi, edi
.mc:
    cmp   edi, MAP_W
    jge   .mn
    mov   eax, esi
    imul  eax, MAP_W
    add   eax, edi
    movzx ecx, byte [world_map + eax]
    cmp   ecx, 1
    je    .d
    cmp   ecx, 2
    je    .w
    cmp   ecx, 3
    je    .s
    mov   dl, 5
    jmp   .md
.d: mov   dl, 9
    jmp   .md
.w: mov   dl, 14
    jmp   .md
.s: mov   dl, 17
.md:
    mov   eax, edi
    imul  eax, 2
    add   eax, SCR_W-MAP_W*2-2
    mov   ebx, esi
    imul  ebx, 2
    add   ebx, 2
    mov   ecx, 2
    call  hline
    add   ebx, 1
    call  hline
    inc   edi
    jmp   .mc
.mn:
    inc   esi
    jmp   .mr
.mpl:
    mov   eax, [px]
    imul  eax, 2
    add   eax, SCR_W-MAP_W*2-2
    mov   ebx, [py]
    imul  ebx, 2
    add   ebx, 2
    mov   ecx, 2
    mov   dl, 30
    call  hline
    add   ebx, 1
    call  hline
    popa
    ret

wait_vsync:
    push eax
    push edx
    mov  dx, 0x3DA
.l1:
    in   al, dx
    test al, 8
    jnz  .l1
.l2:
    in   al, dx
    test al, 8
    jz   .l2
    pop  edx
    pop  eax
    ret

world_draw:
    pusha
    mov   edi, VGA_GAME
    mov   ecx, SCR_W*SCR_H/4
    xor   eax, eax
    cld
    rep   stosd
    xor   esi, esi
.row:
    cmp   esi, MAP_H
    jge   .dt
    xor   edi, edi
.col:
    cmp   edi, MAP_W
    jge   .nr
    imul  eax, esi, MAP_W
    add   eax, edi
    movzx ecx, byte [world_map + eax]
    mov   eax, edi
    mov   ebx, esi
    call  draw_tile
    inc   edi
    jmp   .col
.nr:
    inc   esi
    jmp   .row
.dt:
    mov   esi, trees
.tl:
    movzx eax, byte [esi]
    cmp   al, 0xFF
    je    .dp
    movzx ebx, byte [esi+1]
    push  esi
    call  draw_tree
    pop   esi
    add   esi, 2
    jmp   .tl
.dp:
    mov   eax, [px]
    mov   ebx, [py]
    call  iso_to_screen
    call  draw_player
    call  draw_minimap
    popa
    ret

strncmp:
    push esi
    push edi
    push ecx
    push eax
    push ebx
    cld
.l:
    or   ecx, ecx
    jz   .eq
    mov  al, [esi]
    mov  bl, [edi]
    cmp  al, bl
    jne  .ne
    inc  esi
    inc  edi
    dec  ecx
    jmp  .l
.eq:
    pop  ebx
    pop  eax
    pop  ecx
    pop  edi
    pop  esi
    xor  eax, eax
    cmp  eax, eax
    ret
.ne:
    pop  ebx
    pop  eax
    pop  ecx
    pop  edi
    pop  esi
    xor  eax, eax
    inc  eax
    cmp  eax, 0
    ret

strcmp_exact:
    pusha
.l:
    mov  al, [esi]
    mov  bl, [edi]
    cmp  al, bl
    jne  .neq
    or   al, al
    jz   .eq
    inc  esi
    inc  edi
    jmp  .l
.neq:
    popa
    clc
    ret
.eq:
    popa
    stc
    ret

input_upper:
    push eax
    push esi
    mov  esi, inbuf
.l:
    mov  al, [esi]
    or   al, al
    jz   .done
    cmp  al, ' '
    je   .done
    cmp  al, 'a'
    jl   .n
    cmp  al, 'z'
    jg   .n
    sub  byte [esi], 32
.n:
    inc  esi
    jmp  .l
.done:
    pop  esi
    pop  eax
    ret

str_trim:
    push eax
    push ebx
.l:
    mov  al, [esi]
    cmp  al, ' '
    jne  .lead_done
    inc  esi
    jmp  .l
.lead_done:
    mov  ebx, esi
.find_end:
    cmp  byte [ebx], 0
    je   .found_end
    inc  ebx
    jmp  .find_end
.found_end:
    dec  ebx
    cmp  ebx, esi
    jb   .done
.rloop:
    cmp  byte [ebx], ' '
    jne  .done
    mov  byte [ebx], 0
    dec  ebx
    cmp  ebx, esi
    jae  .rloop
.done:
    pop  ebx
    pop  eax
    ret

sc2ascii:
    push ebx
    movzx eax, al
    cmp  eax, 58
    jge  .none
    mov  ebx, keymap
    cmp  byte [shift_state], 0
    je   .use
    mov  ebx, keymap_shift
.use:
    mov  al, [ebx + eax]
    pop  ebx
    ret
.none:
    xor  al, al
    pop  ebx
    ret

; scan code set 1 to ascii, us layout. no other layouts
keymap:
    db 0,0,'1','2','3','4','5','6','7','8','9','0','-','=',0,0
    db 'q','w','e','r','t','y','u','i','o','p','[',']',0,0
    db 'a','s','d','f','g','h','j','k','l',';',"'",'`',0,'\'
    db 'z','x','c','v','b','n','m',',','.','/',0,0,0,' ',0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0

keymap_shift:
    db 0,0,'!','@','#','$','%','^','&','*','(',')','_','+',0,0
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}',0,0
    db 'A','S','D','F','G','H','J','K','L',':','"','~',0,'|'
    db 'Z','X','C','V','B','N','M','<','>','?',0,0,0,' ',0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0

str_title:       db 'SERPENTIS-OS v1.0  ',0

str_hint:        db '',0

str_boot_title:  db 'SERPENTIS-OS',0

str_serpentis_logo:
    db '                        __..._              ',10
    db '                       ..-                  ',10
    db '                    .-            :           ',10
    db '                _..             .__..--<     ',10
    db '         ...--""                 -.           ',10
    db '     ..-"                       __           ',10
    db '   .                  ___...--               ',10
    db '  :        ____....---                        ',10
    db ' :       .                                     ',10
    db ':       :           _____                      ',10
    db ':      :    _..--"""     """--..__             ',10
    db ':       :  .                      ""i--.       ',10
    db ':       .:                         :    .     ',10
    db ':         --...___i---""""--..___.      :     ',10
    db ' :                 ""---...---""          :     ',10
    db '  .                                     :      ',10
    db '    -.                                 :       ',10
    db '       --...                         .        ',10
    db '         :   ""---....._____.....---""          ',10
    db '         .    .                               ',10
    db '           -..  .                             ',10
    db '               .  :                            ',10
    db '                : .                            ',10
    db '               /  :                             ',10
    db '             .   :                             ',10
    db '           . .--                              ',10
    db '          --',0

; kept in sync with cmd_dispatch by hand
str_help:
    db '  CD <path>             - Change directory (supports .., /, ~, relative, absolute)',10
    db '  PWD                   - Print working directory',10
    db '  LS                    - List directory contents',10
    db '  LS -LA                - List directory with details',10
    db '  MKDIR <name>          - Create directory',10
    db '  RMDIR <name>          - Remove empty directory',10
    db '  CP <src> <dst>        - Copy file',10
    db '  MV <src> <dst>        - Move/rename file',10
    db '  RM <file>             - Remove file',10
    db '  TOUCH <file>          - Create empty file',10
    db '  CAT <file>            - Display file content',10
    db '  AI                    - Run AI system test',10
    db '  TRAIN                 - Train the AI model',10
    db '  SERPEN                - Play the SERPEN game (arrow keys to move)',10
    db '  PONGI                 - Play the PONGI game (W/S to move paddle)',10
    db '  OPEN GAME             - Start isometric graphical world',10
    db '  OPEN -CODE KERNEL     - Kernel entry code in the Editor        ',10
    db '  OPEN -CODE GAME       - How the world gets drawn, in the Editor',10
    db '  OPEN -CODE <file>     - Open (or create) a file inside the Editor',10
    db '  OPEN <file>           - Open (or create) a file inside the Editor',10
    db '  OPEN COMMAND          - Show this command list',10
    db '  CLEAR                 - Clear screen',10
    db '  COLOR <0-15>          - Set terminal text color',10
    db '  USERADD <name> <pass> - Create user account',10
    db '  USERLIST / WHO        - List all users',10
    db '  USERDEL <name>        - Delete user account',10
    db '  LOGIN <name> <pass>   - Log in as a user',10
    db '  LOGOUT                - Return to guest session',10
    db '  WHOAMI                - Show current logged-in user',10
    db '  HELP <command>        - Show detailed help for a command',10,0

str_etitle:      db ' SERPENTIS-IDE SOURCE EDITOR: ',0

str_etitle2:     db '  |  F2=Save to ATA  ESC=Exit to Shell',0

str_ehelp:       db ' F2:Write-to-Disk  ESC:Return-to-Prompt  Arrows:Navigate  Enter:NL',0

str_saved:       db ' [ATA Write Sector OK - Saved Permanent]',0

str_notfound:    db '  Target object not found.',0

str_notfound_cmd: db '  Unknown command. Type HELP.',10,0

str_deleted:     db '  File cleared from sector tracking.',0

str_cat_empty:   db '  (empty file)',0

str_cat_isdir:   db '  Error: that is a directory.',0

str_mkdir_ok:    db '  Directory created successfully.',10,0

str_mkdir_exists: db '  Error: already exists.',10,0

str_mkdir_error: db '  Error: invalid directory name.',10,0

str_cp_ok:       db '  File copied successfully.',10,0

str_cp_usage:    db '  Usage: CP <source> <destination>',10,0

str_mv_ok:       db '  File moved successfully.',10,0

str_mv_usage:    db '  Usage: MV <source> <destination>',10,0

str_touch_ok:    db '  File created successfully.',10,0

str_fat_full:    db '  Error: storage table full (max 64 entries).',10,0

str_userlist_hdr: db '  Registered users:',10,0

str_userdel_ok:  db '  User deleted successfully.',10,0

str_useradd_ok:  db '  User created successfully.',10,0

str_useradd_error: db '  Error: Usage: USERADD <name> <password>',10,0

str_useradd_full: db '  Error: User table full (max 4 accounts).',10,0

str_login_ok:    db '  Login successful. Welcome back.',10,0

str_login_fail:  db '  Login failed: invalid name or password.',10,0

str_logout_ok:   db '  Logged out. Back to guest session.',10,0

str_guest:       db 'guest',0

str_hostname:      db 'serpentis',0

str_prompt_suffix: db '$ ',0

str_login_prompt: db 'login: ',0

str_password_prompt: db 'password: ',0

str_new_user_prompt: db 'new user: ',0

str_logged_in_indicator: db ' [logged in]',0

str_color_ok: db '  Color set successfully.',10,0

str_color_usage: db '  Usage: COLOR <0-15>',10,0

str_color_invalid: db '  Error: Invalid color value (must be 0-15).',10,0

str_help_unknown: db '  Unknown command. Type HELP for a list of commands.',10,0

str_help_cd:     db '  CD - Change directory',10
                 db '  Usage: CD <path>',10
                 db '  Examples:',10
                 db '    CD /home/guest   - Absolute path',10
                 db '    CD ..            - Parent directory',10
                 db '    CD ~             - Home directory',10
                 db '    CD documents     - Relative path',10,0

str_help_pwd:    db '  PWD - Print working directory',10
                 db '  Usage: PWD',10
                 db '  Displays the current directory path.',10,0

str_help_ls:     db '  LS - List directory contents',10
                 db '  Usage: LS [options]',10
                 db '  Options:',10
                 db '    -la              - Detailed listing with sizes',10
                 db '  Examples:',10
                 db '    LS               - Simple listing',10
                 db '    LS -LA           - Detailed listing',10,0

str_help_mkdir:  db '  MKDIR - Create directory',10
                 db '  Usage: MKDIR <name>',10
                 db '  Creates a new directory in the current path.',10,0

str_help_rmdir:  db '  RMDIR - Remove empty directory',10
                 db '  Usage: RMDIR <name>',10
                 db '  Removes an empty directory.',10,0

str_help_cp:     db '  CP - Copy file',10
                 db '  Usage: CP <source> <destination>',10
                 db '  Copies a file to a new location.',10,0

str_help_mv:     db '  MV - Move/rename file',10
                 db '  Usage: MV <source> <destination>',10
                 db '  Moves or renames a file.',10,0

str_help_rm:     db '  RM - Remove file',10
                 db '  Usage: RM <file>',10
                 db '  Deletes a file permanently.',10,0

str_help_touch:  db '  TOUCH - Create empty file',10
                 db '  Usage: TOUCH <filename>',10
                 db '  Creates a new empty file.',10,0

str_help_cat:    db '  CAT - Display file content',10
                 db '  Usage: CAT <file>',10
                 db '  Shows the contents of a file.',10,0

str_help_open:   db '  OPEN - Open files or applications',10
                 db '  Usage: OPEN <option> [argument]',10
                 db '  Options:',10
                 db '    OPEN -CODE KERNEL  - Kernel entry code in editor ',10
                 db '    OPEN -CODE GAME    - World drawing code in editor',10
                 db '    OPEN -CODE <file>  - Open/create file in editor',10
                 db '    OPEN <filename>    - Open/create file in editor',10
                 db '    OPEN GAME          - Launch game world',10
                 db '    OPEN COMMAND       - Show command list',10,0

str_help_useradd: db '  USERADD - Create user account',10
                 db '  Usage: USERADD <name> <password>',10
                 db '  Creates a new user account.',10,0

str_help_userlist: db '  USERLIST/WHO - List users',10
                 db '  Usage: USERLIST or WHO',10
                 db '  Shows all registered users.',10,0

str_help_userdel: db '  USERDEL - Delete user account',10
                 db '  Usage: USERDEL <name>',10
                 db '  Deletes a user account.',10,0

str_help_login:  db '  LOGIN - Log in as user',10
                 db '  Usage: LOGIN <name> <password>',10
                 db '  Authenticates and logs in a user.',10,0

str_help_logout: db '  LOGOUT - Log out',10
                 db '  Usage: LOGOUT',10
                 db '  Returns to guest session.',10,0

str_help_whoami: db '  WHOAMI - Show current user',10
                 db '  Usage: WHOAMI',10
                 db '  Displays the currently logged-in user.',10,0

str_help_saved:  db '  Help content saved to file.',10,0

; OPEN -CODE shows a short piece of the real code, the kernel is way bigger than one 4 KB file
str_kernel_src_code:
    db 'org 0x10000',10
    db 'use32',10
    db 'kernel_entry:',10
    db '  mov ax, 0x10',10
    db '  mov ds, ax',10
    db '  mov es, ax',10
    db '  mov ss, ax',10
    db '  mov esp, 0x9F000',10
    db '  lidt [idt_ptr]',10
    db '  call pic_init',10
    db '  call fs_init',10
    db '  call fs_users_init',10
    db '  call vga_text_mode',10
    db '  call show_welcome',10
    db '  call ai_system_init',10
    db '  call shell_prompt',10
    db '  sti',10
    db '.main_loop:',10
    db '  hlt',10
    db '  jmp .main_loop',0

str_game_src_code:
    db 'world_draw:',10
    db '  clear the 320x200 screen',10
    db '  for every tile on the 20x20 map',10
    db '    call draw_tile',10
    db '  for every tree in the list',10
    db '    call draw_tree',10
    db '  mov eax, [px]',10
    db '  mov ebx, [py]',10
    db '  call iso_to_screen',10
    db '  call draw_player',10
    db '  call draw_minimap',10
    db '  ret',0

cmd_clear:             db 'CLEAR',0

cmd_format:            db 'FORMAT',0

cmd_color:             db 'COLOR',0

cmd_help:              db 'HELP',0

cmd_open:              db 'OPEN',0

cmd_command:           db 'COMMAND',0

cmd_cd:                db 'CD',0

cmd_pwd:               db 'PWD',0

cmd_ls:                db 'LS',0

cmd_mkdir:             db 'MKDIR',0

cmd_rmdir:             db 'RMDIR',0

cmd_cp:                db 'CP',0

cmd_mv:                db 'MV',0

cmd_rm:                db 'RM',0

cmd_touch:             db 'TOUCH',0

cmd_cat:               db 'CAT',0

cmd_game:              db 'GAME',0

cmd_ai:                db 'AI',0

cmd_train:             db 'TRAIN',0

cmd_serpen:            db 'SERPEN',0

cmd_kernel_word:       db 'KERNEL',0

cmd_kernel_name:       db 'KERNEL.ASM',0

cmd_game_name:         db 'GAME.ASM',0

cmd_useradd:           db 'USERADD',0

cmd_userlist:          db 'USERLIST',0

cmd_who:               db 'WHO',0

cmd_userdel:           db 'USERDEL',0

cmd_login:             db 'LOGIN',0

cmd_logout:            db 'LOGOUT',0

cmd_whoami:            db 'WHOAMI',0

cmd_pongi:             db 'PONGI',0

str_home_name_init:   db 'home',0

str_home_guest_init:  db '/home/guest',0

str_guest_name_init:  db 'guest',0
mode        db 0
game_redraw db 0
serpen_last_key db 0
serpen_exit_flag db 0
serpen_menu_choice db 0
serpen_dir db 1
serpen_x dw 20
serpen_y dw 10
serpen_len dw 3
serpen_food_x dw 30
serpen_food_y dw 15
pong_paddle_y dw 10
pong_ball_x dw 30
pong_ball_y dw 10
pong_ball_dx db 1
pong_ball_dy db 1
pong_score dw 0
pong_exit_flag db 0
pong_menu_choice db 0
scancode    db 0
shift_state db 0
open_no_prompt db 0
auth_stage  db 0
auth_is_useradd db 0
scrollback_offset dd 0
scrollback_lines dd 0
cur_x       dd 0
cur_y       dd 0
inlen       dd 0
term_color  db 0x09
elen        dd 0
open_word   rb 64
ed_top      dd 0
ecur        dd 0
tsx         dd 0
tsy         dd 0
ctop0       db 0
ctop1       db 0
ctop2       db 0
cside0      db 0
inbuf       rb 256
ename       rb PATH_MAX
ebuf        rb EDIT_MAX
current_user rb 16
tmp_name    rb 16
tmp_pass    rb 16
current_path rb PATH_MAX
home_path    rb PATH_MAX
tmp_path1    rb PATH_MAX
path_component rb PATH_MAX
tmp_path2    rb PATH_MAX
path_buf     rb PATH_MAX
resolved_src rb PATH_MAX
resolved_dst rb PATH_MAX
path_components_stack rb PATH_MAX * 32
path_component_count dd 0

; read and written as one block of 34 sectors, the rb pads it to exactly that
fs_metadata:
fs_magic     dd 0
fat_count    dd 0
fat_names    rb FAT_MAX*PATH_MAX
fat_sizes    rd FAT_MAX
fat_parents  rd FAT_MAX
            rb 17408-(8+FAT_MAX*PATH_MAX+FAT_MAX*4+FAT_MAX*4)

; one sector with the users. passwords are kept as half a sha-256, see sha256.asm
fs_users_block:
users_magic  dd 0
users_count  dd 0
users_names  rb USER_MAX*16
users_pass   rb USER_MAX*16
            rb 512-(8+USER_MAX*16+USER_MAX*16)

include 'ai/ai.asm'

include 'serpen.asm'

include 'pong.asm'

times 262144-($ - $$) db 0
