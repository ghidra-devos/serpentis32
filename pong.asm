; pong, one paddle against the wall. w and s

PONG_WIDTH  equ 60
PONG_HEIGHT equ 20

pong_main:
    pusha
    mov byte [mode], 6
    mov byte [open_no_prompt], 1
    call pong_init
    call pong_draw_all
    popa
    ret

pong_init:
    pusha
    mov word [pong_paddle_y], 10
    mov word [pong_ball_x], 30
    mov word [pong_ball_y], 10
    mov byte [pong_ball_dx], 1
    mov byte [pong_ball_dy], 1
    mov word [pong_score], 0
    mov byte [pong_exit_flag], 0
    mov edi, 0xB8000
    mov ecx, 2000
    mov ax, 0x0020
.clear:
    stosw
    loop .clear
    call pong_draw_border
    popa
    ret

pong_draw_border:
    pusha
    mov ebx, 1
    mov eax, 0
.top:
    cmp eax, PONG_WIDTH + 2
    jge .bottom_start
    push eax
    push ebx
    call pong_plot
    mov word [edi], 0x09DF
    pop ebx
    pop eax
    inc eax
    jmp .top
.bottom_start:
    mov ebx, PONG_HEIGHT + 2
    mov eax, 0
.bottom:
    cmp eax, PONG_WIDTH + 2
    jge .sides_start
    push eax
    push ebx
    call pong_plot
    mov word [edi], 0x09DF
    pop ebx
    pop eax
    inc eax
    jmp .bottom
.sides_start:
    mov ebx, 2
.sides:
    cmp ebx, PONG_HEIGHT + 2
    jge .title
    push ebx
    mov eax, 0
    call pong_plot
    mov word [edi], 0x09BA
    pop ebx
    push ebx
    mov eax, PONG_WIDTH + 1
    call pong_plot
    mov word [edi], 0x09BA
    pop ebx
    inc ebx
    jmp .sides
.title:
    mov edi, 0xB8000 + 6
    mov esi, str_pong_title
.print:
    lodsb
    test al, al
    jz .done
    stosb
    mov byte [edi], 0x0E
    inc edi
    jmp .print
.done:
    popa
    ret
str_pong_title db ' PONG - W/S=Move, ESC=Exit', 0

pong_plot:
    push eax
    push ebx
    imul ebx, 80
    add ebx, eax
    shl ebx, 1
    mov edi, 0xB8000
    add edi, ebx
    pop ebx
    pop eax
    ret

pong_move:
    pusha
    movsx ax, byte [pong_ball_dx]
    add [pong_ball_x], ax
    movsx ax, byte [pong_ball_dy]
    add [pong_ball_y], ax
    cmp word [pong_ball_y], 1
    jle .bounce_y
    cmp word [pong_ball_y], PONG_HEIGHT
    jge .bounce_y
    jmp .check_x
.bounce_y:
    neg byte [pong_ball_dy]
.check_x:
    cmp word [pong_ball_x], PONG_WIDTH
    jge .bounce_right
    cmp word [pong_ball_x], 2
    jne .done
    mov ax, [pong_ball_y]
    mov bx, [pong_paddle_y]
    cmp ax, bx
    jl .game_over
    add bx, 4
    cmp ax, bx
    jg .game_over
    neg byte [pong_ball_dx]
    inc word [pong_score]
    jmp .done
.bounce_right:
    neg byte [pong_ball_dx]
    jmp .done
.game_over:
    mov byte [pong_exit_flag], 2
.done:
    popa
    ret

pong_draw_all:
    pusha
    mov ebx, 2
.clear_rows:
    cmp ebx, PONG_HEIGHT + 2
    jge .draw_objects
    mov eax, 1
.clear_cols:
    cmp eax, PONG_WIDTH + 1
    jge .next_row
    push eax
    push ebx
    call pong_plot
    mov word [edi], 0x0020
    pop ebx
    pop eax
    inc eax
    jmp .clear_cols
.next_row:
    inc ebx
    jmp .clear_rows
.draw_objects:
    mov ecx, 4
    movzx ebx, word [pong_paddle_y]
.draw_paddle:
    mov eax, 1
    push ecx
    push ebx
    call pong_plot
    mov word [edi], 0x0ADB
    pop ebx
    pop ecx
    inc ebx
    loop .draw_paddle
    movzx eax, word [pong_ball_x]
    movzx ebx, word [pong_ball_y]
    call pong_plot
    mov word [edi], 0x0EFE
    mov edi, 0xB8000 + (PONG_HEIGHT + 3) * 80 * 2 + 4
    mov esi, str_pong_score
.print_score:
    lodsb
    test al, al
    jz .print_num
    stosb
    mov byte [edi], 0x0F
    inc edi
    jmp .print_score
.print_num:
    mov ax, [pong_score]
    call pong_print_decimal
    popa
    ret
str_pong_score db 'Score: ', 0

pong_print_decimal:
    pusha
    xor ecx, ecx
    mov bx, 10
.div_loop:
    xor dx, dx
    div bx
    add dl, '0'
    push dx
    inc ecx
    test ax, ax
    jnz .div_loop
.print_loop:
    pop ax
    stosb
    mov byte [edi], 0x0F
    inc edi
    loop .print_loop
    popa
    ret

pong_draw_gameover:
    pusha
    mov ebx, 8
.clear_loop:
    mov edi, 0xB8000
    mov eax, ebx
    imul eax, 80
    shl eax, 1
    add edi, eax
    add edi, 30
    mov ecx, 25
    mov ax, 0x0020
.clear_col:
    stosw
    loop .clear_col
    inc ebx
    cmp ebx, 17
    jl .clear_loop
    mov edi, 0xB8000 + (8 * 80 + 18) * 2
    mov ecx, 30
    mov ax, 0x0FCD
.top:
    stosw
    loop .top
    mov edi, 0xB8000 + (16 * 80 + 18) * 2
    mov ecx, 30
.bottom:
    stosw
    loop .bottom
    mov ebx, 9
.sides:
    cmp ebx, 16
    jge .text
    mov edi, 0xB8000
    mov eax, ebx
    imul eax, 80
    add eax, 18
    shl eax, 1
    add edi, eax
    mov word [edi], 0x0FBA
    add edi, 60
    mov word [edi], 0x0FBA
    inc ebx
    jmp .sides
.text:
    mov edi, 0xB8000 + (9 * 80 + 28) * 2
    mov esi, str_pong_go
.p1:
    lodsb
    test al, al
    jz .score
    stosb
    mov byte [edi], 0x0C
    inc edi
    jmp .p1
.score:
    mov edi, 0xB8000 + (11 * 80 + 28) * 2
    mov esi, str_pong_sc
.p2:
    lodsb
    test al, al
    jz .num
    stosb
    mov byte [edi], 0x0E
    inc edi
    jmp .p2
.num:
    mov ax, [pong_score]
    call pong_print_decimal
    mov edi, 0xB8000 + (13 * 80 + 26) * 2
    mov esi, str_pong_choose
.p3:
    lodsb
    test al, al
    jz .opt1
    stosb
    mov byte [edi], 0x0F
    inc edi
    jmp .p3
.opt1:
    mov edi, 0xB8000 + (14 * 80 + 24) * 2
    mov word [edi], 0x0E3E
    mov edi, 0xB8000 + (14 * 80 + 26) * 2
    mov esi, str_pong_play
.p4:
    lodsb
    test al, al
    jz .opt2
    stosb
    mov byte [edi], 0x0E
    inc edi
    jmp .p4
.opt2:
    mov edi, 0xB8000 + (15 * 80 + 26) * 2
    mov esi, str_pong_shell
.p5:
    lodsb
    test al, al
    jz .done
    stosb
    mov byte [edi], 0x07
    inc edi
    jmp .p5
.done:
    mov byte [pong_menu_choice], 0
    popa
    ret
str_pong_go db 'GAME OVER!', 0
str_pong_sc db 'Score: ', 0
str_pong_choose db 'Choose an option:', 0
str_pong_play db 'Play Again', 0
str_pong_shell db 'Return to Shell', 0

pong_update_menu:
    pusha
    mov edi, 0xB8000 + (14 * 80 + 24) * 2
    mov word [edi], 0x0E20
    mov edi, 0xB8000 + (15 * 80 + 24) * 2
    mov word [edi], 0x0720
    mov edi, 0xB8000 + (14 * 80 + 26) * 2
    mov esi, str_pong_play
    cmp byte [pong_menu_choice], 0
    je .sel1
    mov ah, 0x07
    jmp .dr1
.sel1:
    mov ah, 0x0E
.dr1:
    lodsb
    test al, al
    jz .opt2
    stosb
    mov byte [edi], ah
    inc edi
    jmp .dr1
.opt2:
    mov edi, 0xB8000 + (15 * 80 + 26) * 2
    mov esi, str_pong_shell
    cmp byte [pong_menu_choice], 1
    je .sel2
    mov ah, 0x07
    jmp .dr2
.sel2:
    mov ah, 0x0E
.dr2:
    lodsb
    test al, al
    jz .arrow
    stosb
    mov byte [edi], ah
    inc edi
    jmp .dr2
.arrow:
    cmp byte [pong_menu_choice], 0
    je .ar1
    mov edi, 0xB8000 + (15 * 80 + 24) * 2
    mov word [edi], 0x0E3E
    jmp .done
.ar1:
    mov edi, 0xB8000 + (14 * 80 + 24) * 2
    mov word [edi], 0x0E3E
.done:
    popa
    ret
