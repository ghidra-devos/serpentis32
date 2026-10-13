; mkdir cd ls rm rmdir. the first versions only knew the current directory, these take paths
do_mkdir_simple_v2:
    pusha
    mov  esi, inbuf
    add  esi, 6
    call str_trim
    cmp  byte [esi], 0
    je   .error_noname
    mov  edi, tmp_filename
    mov  ecx, 64
.copy_name:
    lodsb
    stosb
    or   al, al
    jz   .name_done
    dec  ecx
    jnz  .copy_name
    jmp  .error_toolong
.name_done:
    mov  ecx, [fat_count]
    cmp  ecx, 0
    je   .create
    xor  ebx, ebx
    call fs_get_current_dir_index
    mov  edx, eax
.check_loop:
    cmp  ebx, ecx
    jge  .create
    push ebx
    push ecx
    push edx
    mov  eax, ebx
    shl  eax, 2
    mov  eax, [fat_parents + eax]
    cmp  eax, edx
    jne  .check_next
    imul eax, ebx, PATH_MAX
    lea  esi, [fat_names + eax]
    mov  edi, tmp_filename
    call strcmp_exact
    jc   .found_existing
.check_next:
    pop  edx
    pop  ecx
    pop  ebx
    inc  ebx
    jmp  .check_loop
.found_existing:
    pop  edx
    pop  ecx
    pop  ebx
    mov  esi, str_mkdir_exists
    call txt_print
    jmp  .done
.create:
    mov  ecx, [fat_count]
    cmp  ecx, FAT_MAX
    jge  .error_full
    imul eax, ecx, PATH_MAX
    lea  edi, [fat_names + eax]
    mov  esi, tmp_filename
.copy_to_fat:
    lodsb
    stosb
    or   al, al
    jnz  .copy_to_fat
    mov  eax, ecx
    shl  eax, 2
    mov  dword [fat_sizes + eax], 0FFFFFFFFh
    push ecx
    call fs_get_current_dir_index
    pop  ecx
    mov  ebx, ecx
    shl  ebx, 2
    mov  [fat_parents + ebx], eax
    inc  dword [fat_count]
    call fs_save_all
    mov  esi, str_mkdir_ok
    call txt_print
    jmp  .done
.error_noname:
    mov  esi, str_mkdir_error
    call txt_print
    jmp  .done
.error_toolong:
    mov  esi, str_mkdir_error
    call txt_print
    jmp  .done
.error_full:
    mov  esi, str_fat_full
    call txt_print
.done:
    popa
    ret

do_cd_simple_v2:
    pusha
    mov  esi, inbuf
    add  esi, 3
    call str_trim
    cmp  byte [esi], 0
    je   .go_home
    cmp  word [esi], '..'
    jne  .not_parent
    cmp  byte [esi+2], 0
    je   .go_parent
.not_parent:
    cmp  byte [esi], '/'
    jne  .relative
    cmp  byte [esi+1], 0
    je   .go_root
.relative:
    mov  edi, tmp_filename
.copy_name:
    lodsb
    stosb
    or   al, al
    jnz  .copy_name
    call fs_get_current_dir_index
    mov  edx, eax
    xor  ebx, ebx
    mov  ecx, [fat_count]
.search_loop:
    cmp  ebx, ecx
    jge  .not_found
    push ebx
    push ecx
    push edx
    mov  eax, ebx
    shl  eax, 2
    mov  eax, [fat_parents + eax]
    cmp  eax, edx
    jne  .search_next
    imul eax, ebx, PATH_MAX
    lea  esi, [fat_names + eax]
    mov  edi, tmp_filename
    call strcmp_exact
    jc   .found_it
.search_next:
    pop  edx
    pop  ecx
    pop  ebx
    inc  ebx
    jmp  .search_loop
.found_it:
    pop  edx
    pop  ecx
    pop  ebx
    mov  eax, ebx
    shl  eax, 2
    cmp  dword [fat_sizes + eax], 0FFFFFFFFh
    jne  .not_dir
    mov  eax, ebx
    mov  edi, current_path
    call fs_build_path
    jmp  .done
.go_home:
    call path_cd_home
    jmp  .done
.go_root:
    mov  byte [current_path], '/'
    mov  byte [current_path+1], 0
    jmp  .done
.go_parent:
    call fs_get_current_dir_index
    cmp  eax, 0
    je   .done
    shl  eax, 2
    mov  eax, [fat_parents + eax]
    cmp  eax, 0FFFFFFFFh
    je   .go_root
    mov  edi, current_path
    call fs_build_path
    jmp  .done
.not_found:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .done
.not_dir:
    mov  esi, str_cd_notdir
    call txt_print
    jmp  .done
.done:
    popa
    ret

do_ls_simple_v2:
    pusha
    mov  esi, inbuf
    add  esi, 2
    call str_trim
    cmp  byte [esi], 0
    je   .here
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    call fs_resolve_path_to_index
    jnc  .missing
    imul ebx, eax, 4
    cmp  dword [fat_sizes + ebx], 0FFFFFFFFh
    jne  .not_dir
    mov  edx, eax
    jmp  .listed
.missing:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    popa
    ret
.not_dir:
    mov  esi, str_cd_notdir
    call txt_print
    popa
    ret
.here:
    call fs_get_current_dir_index
    mov  edx, eax
.listed:
    xor  ebx, ebx
    mov  ecx, [fat_count]
    xor  edi, edi
.loop:
    cmp  ebx, ecx
    jge  .done
    push ebx
    push ecx
    push edx
    mov  eax, ebx
    shl  eax, 2
    mov  eax, [fat_parents + eax]
    cmp  eax, edx
    jne  .next
    imul eax, ebx, PATH_MAX
    lea  esi, [fat_names + eax]
    call txt_print
    mov  eax, ebx
    shl  eax, 2
    cmp  dword [fat_sizes + eax], 0FFFFFFFFh
    jne  .is_file
    mov  al, '/'
    call txt_putc
.is_file:
    call txt_nl
    inc  edi
.next:
    pop  edx
    pop  ecx
    pop  ebx
    inc  ebx
    jmp  .loop
.done:
    or   edi, edi
    jnz  .has_items
    mov  esi, str_ls_empty
    call txt_print
.has_items:
    popa
    ret

tmp_filename: times 65 db 0

str_cd_notdir: db '  Error: not a directory.',10,0

str_ls_empty: db '  (empty)',10,0

do_rmdir_simple_v2:
    pusha
    mov  esi, inbuf
    add  esi, 6
    call str_trim
    cmp  byte [esi], 0
    je   .error_noname
    call lookup_arg
    jnc  .not_found
    mov  eax, ebx
    shl  eax, 2
    cmp  dword [fat_sizes + eax], 0FFFFFFFFh
    jne  .not_dir
    push ebx
    call is_directory_empty
    pop  ebx
    jnc  .not_empty
    call delete_fat_entry
    call fs_save_all
    mov  esi, str_rmdir_ok
    call txt_print
    jmp  .done
.not_found:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .done
.not_dir:
    mov  esi, str_rmdir_notdir
    call txt_print
    jmp  .done
.not_empty:
    mov  esi, str_rmdir_notempty
    call txt_print
    jmp  .done
.error_noname:
    mov  esi, str_rmdir_error
    call txt_print
    jmp  .done
.error_toolong:
    mov  esi, str_rmdir_error
    call txt_print
.done:
    popa
    ret

is_directory_empty:
    push eax
    push ecx
    push edx
    xor  ecx, ecx
    mov  edx, [fat_count]
.check_loop:
    cmp  ecx, edx
    jge  .empty
    mov  eax, ecx
    shl  eax, 2
    mov  eax, [fat_parents + eax]
    cmp  eax, ebx
    je   .has_children
    inc  ecx
    jmp  .check_loop
.empty:
    stc
    jmp  .ret
.has_children:
    clc
.ret:
    pop  edx
    pop  ecx
    pop  eax
    ret

delete_fat_entry:
    push eax
    push ecx
    push esi
    push edi
    mov  ecx, [fat_count]
    dec  ecx
    cmp  ebx, ecx
    jge  .skip_move
    imul esi, ebx, PATH_MAX
    lea  esi, [fat_names + esi + PATH_MAX]
    imul edi, ebx, PATH_MAX
    lea  edi, [fat_names + edi]
    mov  eax, [fat_count]
    sub  eax, ebx
    dec  eax
    imul ecx, eax, PATH_MAX
    cld
    rep  movsb
    mov  eax, ebx
    shl  eax, 2
    lea  esi, [fat_sizes + eax + 4]
    lea  edi, [fat_sizes + eax]
    mov  eax, [fat_count]
    sub  eax, ebx
    dec  eax
    shl  eax, 2
    mov  ecx, eax
    cld
    rep  movsb
    mov  eax, ebx
    shl  eax, 2
    lea  esi, [fat_parents + eax + 4]
    lea  edi, [fat_parents + eax]
    mov  eax, [fat_count]
    sub  eax, ebx
    dec  eax
    shl  eax, 2
    mov  ecx, eax
    cld
    rep  movsb
.skip_move:
    push ebx
    push edx
    xor  ecx, ecx
    mov  edx, [fat_count]
.update_parents:
    cmp  ecx, edx
    jge  .parents_done
    push eax
    mov  eax, ecx
    shl  eax, 2
    mov  eax, [fat_parents + eax]
    cmp  eax, ebx
    jle  .skip_parent
    dec  eax
    push ebx
    mov  ebx, ecx
    shl  ebx, 2
    mov  [fat_parents + ebx], eax
    pop  ebx
.skip_parent:
    pop  eax
    inc  ecx
    jmp  .update_parents
.parents_done:
    pop  edx
    pop  ebx
    dec  dword [fat_count]
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    ret

lookup_arg:
    push eax
    push esi
    call resolve_path
    call path_normalize
    mov  esi, path_buf
    call fs_resolve_path_to_index
    mov  ebx, eax
    pop  esi
    pop  eax
    ret

do_rm_simple_v2:
    pusha
    mov  esi, inbuf
    add  esi, 3
    call str_trim
    cmp  byte [esi], 0
    je   .error_noname
    call lookup_arg
    jnc  .not_found
    mov  eax, ebx
    shl  eax, 2
    cmp  dword [fat_sizes + eax], 0FFFFFFFFh
    je   .is_dir
    call delete_fat_entry
    call fs_save_all
    mov  esi, str_rm_ok
    call txt_print
    jmp  .done
.not_found:
    mov  esi, str_notfound
    call txt_print
    call txt_nl
    jmp  .done
.is_dir:
    mov  esi, str_rm_isdir
    call txt_print
    jmp  .done
.error_noname:
    mov  esi, str_rm_error
    call txt_print
.done:
    popa
    ret

str_rmdir_ok: db '  Directory removed successfully.',10,0

str_rmdir_error: db '  Error: invalid directory name.',10,0

str_rmdir_notdir: db '  Error: not a directory.',10,0

str_rmdir_notempty: db '  Error: directory not empty.',10,0

str_rm_ok: db '  File deleted successfully.',10,0

str_rm_error: db '  Error: invalid file name.',10,0

str_rm_isdir: db '  Error: is a directory (use rmdir).',10,0
