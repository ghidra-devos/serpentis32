; snake. arrows to move, esc goes back to the shell

SERPEN_WIDTH     equ 40
SERPEN_HEIGHT    equ 20
SERPEN_MAX_LEN   equ 200
serpen_body_x: times SERPEN_MAX_LEN dw 0
serpen_body_y: times SERPEN_MAX_LEN dw 0

serpen_main:
    pusha
    mov byte [mode], 5
    mov byte [open_no_prompt], 1
    call serpen_init
    call serpen_draw_all
    popa
    ret

serpen_init:
    pusha
    mov byte [serpen_exit_flag], 0
    mov byte [serpen_last_key], 0
    mov word [serpen_x], 20
    mov word [serpen_y], 10
    mov byte [serpen_dir], 1
    mov word [serpen_len], 3
    mov word [serpen_body_x+0], 18
    mov word [serpen_body_y+0], 10
    mov word [serpen_body_x+2], 19
    mov word [serpen_body_y+2], 10
    mov word [serpen_body_x+4], 20
    mov word [serpen_body_y+4], 10
    mov word [serpen_food_x], 30
    mov word [serpen_food_y], 15
    mov edi, 0xB8000
    mov ecx, 2000
    mov ax, 0x0020
.clear:
    stosw
    loop .clear
    call serpen_draw_border
    popa
    ret

serpen_move:
    pusha
    mov ax, [serpen_x]
    cmp ax, [serpen_food_x]
    jne .no_food_before
    mov ax, [serpen_y]
    cmp ax, [serpen_food_y]
    jne .no_food_before
    inc word [serpen_len]
    mov ax, [serpen_x]
    add ax, [serpen_y]
    add ax, [serpen_len]
    xor dx, dx
    mov cx, SERPEN_WIDTH - 4
    div cx
    add dx, 2
    mov [serpen_food_x], dx
    mov ax, [serpen_y]
    add ax, [serpen_x]
    shl ax, 1
    xor dx, dx
    mov cx, SERPEN_HEIGHT - 4
    div cx
    add dx, 2
    mov [serpen_food_y], dx
    movzx ecx, word [serpen_len]
    dec ecx
    dec ecx
    test ecx, ecx
    jz .move_head
.shift_loop_grow:
    mov eax, ecx
    dec eax
    shl eax, 1
    mov bx, [serpen_body_x + eax]
    mov [serpen_body_x + ecx*2], bx
    mov bx, [serpen_body_y + eax]
    mov [serpen_body_y + ecx*2], bx
    loop .shift_loop_grow
    jmp .move_head
.no_food_before:
    movzx ecx, word [serpen_len]
    dec ecx
    test ecx, ecx
    jz .move_head
.shift_loop:
    mov eax, ecx
    dec eax
    shl eax, 1
    mov bx, [serpen_body_x + eax]
    mov [serpen_body_x + ecx*2], bx
    mov bx, [serpen_body_y + eax]
    mov [serpen_body_y + ecx*2], bx
    loop .shift_loop
.move_head:
    mov ax, [serpen_x]
    mov [serpen_body_x], ax
    mov ax, [serpen_y]
    mov [serpen_body_y], ax
    mov al, [serpen_dir]
    test al, al
    jz .move_up
    cmp al, 1
    je .move_right
    cmp al, 2
    je .move_down
    jmp .move_left
.move_up:
    dec word [serpen_y]
    jmp .check_collision
.move_down:
    inc word [serpen_y]
    jmp .check_collision
.move_left:
    dec word [serpen_x]
    jmp .check_collision
.move_right:
    inc word [serpen_x]
.check_collision:
    movzx eax, word [serpen_x]
    cmp eax, 1
    jl .game_over
    cmp eax, SERPEN_WIDTH
    jge .game_over
    movzx eax, word [serpen_y]
    cmp eax, 1
    jl .game_over
    cmp eax, SERPEN_HEIGHT
    jge .game_over
    xor ecx, ecx
.check_body:
    cmp cx, [serpen_len]
    jge .no_collision
    mov ax, [serpen_x]
    cmp ax, [serpen_body_x + ecx*2]
    jne .next_segment
    mov ax, [serpen_y]
    cmp ax, [serpen_body_y + ecx*2]
    je .game_over
.next_segment:
    inc ecx
    jmp .check_body
.no_collision:
    popa
    ret
.game_over:
    mov byte [serpen_exit_flag], 2
    popa
    ret

serpen_draw_gameover:
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
    mov esi, str_gameover_msg
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
    mov esi, str_score_msg
.p2:
    lodsb
    test al, al
    jz .num
    stosb
    mov byte [edi], 0x0E
    inc edi
    jmp .p2
.num:
    mov ax, [serpen_len]
    sub ax, 3
    call print_decimal
    mov edi, 0xB8000 + (13 * 80 + 26) * 2
    mov esi, str_choose_msg
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
    mov esi, str_play_msg
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
    mov esi, str_shell_msg
.p5:
    lodsb
    test al, al
    jz .done
    stosb
    mov byte [edi], 0x07
    inc edi
    jmp .p5
.done:
    mov byte [serpen_menu_choice], 0
    popa
    ret
str_gameover_msg db 'GAME OVER!', 0
str_score_msg db 'Score: ', 0
str_choose_msg db 'Choose an option:', 0
str_play_msg db 'Play Again', 0
str_shell_msg db 'Return to Shell', 0

serpen_draw_border:
    pusha
    mov ebx, 1
    mov eax, 0
.top:
    cmp eax, SERPEN_WIDTH + 2
    jge .bottom_start
    push eax
    push ebx
    call serpen_plot
    mov byte [edi], '='
    mov byte [edi+1], 0x09
    pop ebx
    pop eax
    inc eax
    jmp .top
.bottom_start:
    mov ebx, SERPEN_HEIGHT + 2
    mov eax, 0
.bottom:
    cmp eax, SERPEN_WIDTH + 2
    jge .sides_start
    push eax
    push ebx
    call serpen_plot
    mov byte [edi], '='
    mov byte [edi+1], 0x09
    pop ebx
    pop eax
    inc eax
    jmp .bottom
.sides_start:
    mov ebx, 2
.sides:
    cmp ebx, SERPEN_HEIGHT + 2
    jge .title
    push ebx
    mov eax, 0
    call serpen_plot
    mov byte [edi], '|'
    mov byte [edi+1], 0x09
    pop ebx
    push ebx
    mov eax, SERPEN_WIDTH + 1
    call serpen_plot
    mov byte [edi], '|'
    mov byte [edi+1], 0x09
    pop ebx
    inc ebx
    jmp .sides
.title:
    mov edi, 0xB8000 + 8
    mov esi, str_serpen_title
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
str_serpen_title db ' SERPEN - Arrows=Move, ESC=Exit', 0

serpen_plot:
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

serpen_draw_all:
    pusha
    mov ebx, 2
.clear_rows:
    cmp ebx, SERPEN_HEIGHT + 2
    jge .draw_snake
    mov eax, 1
.clear_cols:
    cmp eax, SERPEN_WIDTH + 1
    jge .next_row
    push eax
    push ebx
    call serpen_plot
    mov word [edi], 0x0020
    pop ebx
    pop eax
    inc eax
    jmp .clear_cols
.next_row:
    inc ebx
    jmp .clear_rows
.draw_snake:
    xor ecx, ecx
.body_loop:
    cmp cx, [serpen_len]
    jge .draw_head
    movzx eax, word [serpen_body_x + ecx*2]
    movzx ebx, word [serpen_body_y + ecx*2]
    push ecx
    call serpen_plot
    mov byte [edi], 'o'
    mov byte [edi+1], 0x0A
    pop ecx
    inc ecx
    jmp .body_loop
.draw_head:
    movzx eax, word [serpen_x]
    movzx ebx, word [serpen_y]
    call serpen_plot
    mov byte [edi], 'O'
    mov byte [edi+1], 0x0E
    movzx eax, word [serpen_food_x]
    movzx ebx, word [serpen_food_y]
    call serpen_plot
    mov byte [edi], '*'
    mov byte [edi+1], 0x0C
    mov edi, 0xB8000 + (SERPEN_HEIGHT + 3) * 80 * 2 + 4
    mov esi, str_score
.print_score:
    lodsb
    test al, al
    jz .print_len
    stosb
    mov byte [edi], 0x0F
    inc edi
    jmp .print_score
.print_len:
    mov ax, [serpen_len]
    sub ax, 3
    call print_decimal
    popa
    ret
str_score db 'Score: ', 0

print_decimal:
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

serpen_update_menu:
    pusha
    mov edi, 0xB8000 + (14 * 80 + 24) * 2
    mov word [edi], 0x0E20
    mov edi, 0xB8000 + (15 * 80 + 24) * 2
    mov word [edi], 0x0720
    mov edi, 0xB8000 + (14 * 80 + 26) * 2
    mov esi, str_play_msg
    cmp byte [serpen_menu_choice], 0
    je .draw_opt1_sel
    mov ah, 0x07
    jmp .draw_opt1
.draw_opt1_sel:
    mov ah, 0x0E
.draw_opt1:
    lodsb
    test al, al
    jz .opt2
    stosb
    mov byte [edi], ah
    inc edi
    jmp .draw_opt1
.opt2:
    mov edi, 0xB8000 + (15 * 80 + 26) * 2
    mov esi, str_shell_msg
    cmp byte [serpen_menu_choice], 1
    je .draw_opt2_sel
    mov ah, 0x07
    jmp .draw_opt2
.draw_opt2_sel:
    mov ah, 0x0E
.draw_opt2:
    lodsb
    test al, al
    jz .draw_arrow
    stosb
    mov byte [edi], ah
    inc edi
    jmp .draw_opt2
.draw_arrow:
    cmp byte [serpen_menu_choice], 0
    je .arrow1
    mov edi, 0xB8000 + (15 * 80 + 24) * 2
    mov word [edi], 0x0E3E
    jmp .done
.arrow1:
    mov edi, 0xB8000 + (14 * 80 + 24) * 2
    mov word [edi], 0x0E3E
.done:
    popa
    ret
