; sha-256 for short messages, one block, so up to 55 bytes. that is all the passwords need.
; the users file keeps 16 bytes per password, the first half of sha256(name:password), so two
; users with the same password still get different hashes

; esi = message, ecx = length. digest in sha_out
sha256_short:
    pushad
    push ecx
    push esi
    mov  edi, sha_block
    mov  ecx, 16
    xor  eax, eax
    rep  stosd
    pop  esi
    pop  ecx
    mov  edi, sha_block
    push ecx
    rep  movsb
    pop  ecx
    mov  byte [sha_block + ecx], 0x80
    mov  eax, ecx
    shl  eax, 3
    bswap eax
    mov  dword [sha_block + 60], eax
    xor  ebx, ebx
.load:
    mov  eax, dword [sha_block + ebx*4]
    bswap eax
    mov  [sha_w + ebx*4], eax
    inc  ebx
    cmp  ebx, 16
    jb   .load
.expand:
    mov  eax, [sha_w + ebx*4 - 8]
    mov  edx, eax
    mov  ecx, eax
    ror  eax, 17
    ror  ecx, 19
    xor  eax, ecx
    shr  edx, 10
    xor  eax, edx
    add  eax, [sha_w + ebx*4 - 28]
    mov  edx, [sha_w + ebx*4 - 60]
    mov  ecx, edx
    mov  esi, edx
    ror  ecx, 7
    ror  esi, 18
    xor  ecx, esi
    shr  edx, 3
    xor  ecx, edx
    add  eax, ecx
    add  eax, [sha_w + ebx*4 - 64]
    mov  [sha_w + ebx*4], eax
    inc  ebx
    cmp  ebx, 64
    jb   .expand
    mov  esi, sha_init
    mov  edi, sha_v
    mov  ecx, 8
    rep  movsd
    xor  ebx, ebx
.round:
    mov  eax, [sha_v + 16]
    mov  ecx, eax
    mov  edx, eax
    ror  ecx, 6
    ror  edx, 11
    xor  ecx, edx
    ror  eax, 25
    xor  ecx, eax
    mov  eax, [sha_v + 16]
    mov  edx, eax
    and  eax, [sha_v + 20]
    not  edx
    and  edx, [sha_v + 24]
    xor  eax, edx
    add  ecx, eax
    add  ecx, [sha_v + 28]
    add  ecx, [sha_k + ebx*4]
    add  ecx, [sha_w + ebx*4]
    mov  eax, [sha_v]
    mov  edx, eax
    mov  esi, eax
    ror  edx, 2
    ror  esi, 13
    xor  edx, esi
    ror  eax, 22
    xor  edx, eax
    mov  eax, [sha_v]
    mov  esi, eax
    and  eax, [sha_v + 4]
    and  esi, [sha_v + 8]
    xor  eax, esi
    mov  esi, [sha_v + 4]
    and  esi, [sha_v + 8]
    xor  eax, esi
    add  edx, eax
    mov  eax, [sha_v + 24]
    mov  [sha_v + 28], eax
    mov  eax, [sha_v + 20]
    mov  [sha_v + 24], eax
    mov  eax, [sha_v + 16]
    mov  [sha_v + 20], eax
    mov  eax, [sha_v + 12]
    add  eax, ecx
    mov  [sha_v + 16], eax
    mov  eax, [sha_v + 8]
    mov  [sha_v + 12], eax
    mov  eax, [sha_v + 4]
    mov  [sha_v + 8], eax
    mov  eax, [sha_v]
    mov  [sha_v + 4], eax
    add  ecx, edx
    mov  [sha_v], ecx
    inc  ebx
    cmp  ebx, 64
    jb   .round
    xor  ebx, ebx
.out:
    mov  eax, [sha_init + ebx*4]
    add  eax, [sha_v + ebx*4]
    bswap eax
    mov  [sha_out + ebx*4], eax
    inc  ebx
    cmp  ebx, 8
    jb   .out
    popad
    ret

; tmp_name and tmp_pass -> 16 bytes at edi
pass_hash:
    pushad
    push edi
    mov  edi, sha_msg
    mov  esi, tmp_name
    mov  ecx, 15
.name:
    lodsb
    test al, al
    jz   .colon
    stosb
    loop .name
.colon:
    mov  al, ':'
    stosb
    mov  esi, tmp_pass
    mov  ecx, 15
.pass:
    lodsb
    test al, al
    jz   .hash
    stosb
    loop .pass
.hash:
    mov  ecx, edi
    sub  ecx, sha_msg
    mov  esi, sha_msg
    call sha256_short
    pop  edi
    mov  esi, sha_out
    mov  ecx, 16
    rep  movsb
    popad
    ret

; esi = a stored hash. ZF=1 if tmp_name and tmp_pass hash to it
pass_check:
    push ecx
    push esi
    push edi
    mov  edi, pass_tmp
    call pass_hash
    mov  ecx, 16
    repe cmpsb
    pop  edi
    pop  esi
    pop  ecx
    ret

align 4
sha_init dd 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
sha_k    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
         dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
         dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
         dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
         dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
         dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
         dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
         dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
sha_w     rd 64
sha_v     rd 8
sha_out   rd 8
sha_block rb 64
sha_msg   rb 40
pass_tmp  rb 16
