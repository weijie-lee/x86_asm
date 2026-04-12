         ;代码清单13-2
         ;文件名：c13_core.asm
         ;文件说明：保护模式微型核心程序
         ;创建日期：2011-10-26 12:11
         ;
         ;=========================== 扩展知识 =======================================
         ;
         ; 【微内核架构：系统例程、数据、代码三段分离】
         ;   本内核按功能划分为三个独立的 SECTION：
         ;   1) sys_routine —— 系统公用例程代码段：提供字符显示、磁盘读写、
         ;      十六进制输出、内存分配、GDT描述符安装/构造等公共服务。
         ;      这些例程可被内核代码段和用户程序（通过SALT）调用。
         ;   2) core_data —— 核心数据段：存放GDT副本、内存分配指针、SALT表、
         ;      消息字符串、缓冲区等内核运行所需的数据。
         ;   3) core_code —— 核心代码段：包含内核主逻辑，如加载用户程序、
         ;      重定位、cpuid获取CPU信息、以及用户程序返回点。
         ;   这种分离设计使得各段可以拥有不同的访问权限（代码段只执行，
         ;   数据段可读写），符合保护模式的最小权限原则。
         ;
         ; 【SALT（符号地址检索表 / Symbol Address Lookup Table）】
         ;   SALT 是内核与用户程序之间的服务调用接口机制。
         ;   内核在 core_data 中维护一张 SALT 表，每个条目的结构为：
         ;     [256字节名称字符串] + [4字节段内偏移] + [2字节段选择子]
         ;   共 262 字节/条目。名称如 '@PrintString'、'@ReadDiskData' 等。
         ;
         ;   用户程序的头部也声明自己的 SALT（只有名称部分，各256字节）。
         ;   内核加载用户程序后，逐条将用户SALT的名称与内核SALT匹配：
         ;     - 使用 repe cmpsd 指令，每次比较4字节（共比较64次=256字节）
         ;     - 若匹配成功，将内核SALT中对应的偏移地址和段选择子
         ;       回写到用户程序的SALT条目中，完成"重定位"
         ;   这样用户程序就可以通过 call far [fs:XXX] 来调用内核服务，
         ;   而无需知道内核例程的实际地址。
         ;
         ;   repe cmpsd 详解：
         ;     - rep 前缀使 cmpsd 重复执行，每次ECX递减1
         ;     - cmps 比较 DS:[ESI] 与 ES:[EDI]，每次各前进4字节
         ;     - repe（repeat while equal）在相等时继续，不等时提前终止
         ;     - 比较完成后，若ZF=1则表示256字节完全匹配
         ;
         ; 【动态内存分配：简易 bump allocator（线性增长分配器）】
         ;   内核使用 ram_alloc 变量记录下一次分配的起始线性地址，初始值
         ;   为 0x00100000（1MB以上，避开实模式遗留区域和显存区域）。
         ;   每次分配时：
         ;     1) 返回当前 ram_alloc 值作为分配起始地址
         ;     2) 将 ram_alloc += 请求字节数
         ;     3) 使用 cmovnz 进行4字节对齐：
         ;        test eax, 0x03 检查低2位是否为0
         ;        若不为0（未对齐），cmovnz 将 eax 替换为向上对齐后的值
         ;        cmovnz（Conditional MOV if Not Zero）属于 CMOVcc 指令族，
         ;        仅当ZF=0时执行MOV，避免了分支跳转，提高流水线效率。
         ;
         ; 【retf（远返回）vs ret（近返回）】
         ;   - ret：仅从栈中弹出 EIP，用于段内（near）调用返回
         ;   - retf：从栈中依次弹出 EIP 和 CS，用于段间（far）调用返回
         ;   本内核的公用例程（sys_routine段）被其他段通过 call far 调用，
         ;   因此必须使用 retf 返回；而段内子程序（如 put_char）使用 ret。
         ;
         ; 【cpuid 指令：处理器识别】
         ;   cpuid 根据 EAX 的输入值返回处理器信息：
         ;   - EAX=0x80000002/0x80000003/0x80000004：
         ;     连续3次调用，分别返回处理器品牌字符串的第1/2/3部分，
         ;     每次通过 EAX、EBX、ECX、EDX 返回16字节，共48字节。
         ;     将这48字节连续存入内存即可得到完整的CPU型号字符串。
         ;
         ; 【sgdt / lgdt：保存和加载GDT寄存器】
         ;   - sgdt [mem]：将当前GDTR的内容（2字节界限+4字节基地址）保存到内存
         ;   - lgdt [mem]：从内存加载新的GDTR值
         ;   在运行时动态添加GDT描述符时，需要先 sgdt 读出当前GDT信息，
         ;   在GDT末尾追加新描述符，更新界限值，再 lgdt 使修改生效。
         ;
         ;========================================================================

         ;以下常量定义部分。段选择子对应MBR和内核动态创建的GDT描述符
         core_code_seg_sel     equ  0x38    ;7#描述符：内核代码段选择子
         core_data_seg_sel     equ  0x30    ;6#描述符：内核数据段选择子
         sys_routine_seg_sel   equ  0x28    ;5#描述符：系统公共例程代码段的选择子
         video_ram_seg_sel     equ  0x20    ;4#描述符：视频显示缓冲区(0xB8000)的段选择子
         core_stack_seg_sel    equ  0x18    ;3#描述符：内核堆栈段选择子
         mem_0_4_gb_seg_sel    equ  0x08    ;1#描述符：整个0~4GB内存的段选择子

;-------------------------------------------------------------------------------
;==============================内核程序=========================================
SECTION header vstart=0
         ;以下是系统核心的头部，用于MBR加载和定位内核各段
         core_length      dd core_end       ;核心程序总长度（字节）#偏移0x00

         sys_routine_seg  dd section.sys_routine.start
                                            ;系统公用例程段的汇编起始地址#偏移0x04

         core_data_seg    dd section.core_data.start
                                            ;核心数据段的汇编起始地址#偏移0x08

         core_code_seg    dd section.core_code.start
                                            ;核心代码段的汇编起始地址#偏移0x0C


         core_entry       dd start          ;核心代码段入口点#偏移0x10（低双字=段内偏移EIP）
                          dw core_code_seg_sel ;#偏移0x14（高字=段选择子CS）
                                            ;MBR通过 jmp far [edi+0x10] 读取这6字节跳入内核

;===============================================================================
         [bits 32]
;==============================公共例程代码段===================================
SECTION sys_routine vstart=0                ;系统公共例程代码段（被其他段通过 call far 调用）
;-------------------------------------------------------------------------------
         ;字符串显示例程（遍历以0结尾的字符串，逐字符调用put_char）
put_string:                                 ;显示0终止的字符串并移动光标
                                            ;输入：DS:EBX=字符串起始地址
         push ecx
  .getc:
         mov cl,[ebx]                       ;取当前字符
         or cl,cl                           ;测试是否为0（字符串终止符）
         jz .exit
         call put_char                      ;显示该字符（段内近调用）
         inc ebx                            ;指向下一个字符
         jmp .getc

  .exit:
         pop ecx
         retf                               ;段间远返回（调用者在其他段，栈中有CS:EIP）

;-------------------------------------------------------------------------------
put_char:                                   ;在当前光标处显示一个字符，并推进光标
                                            ;仅用于段内调用（put_string调用它）
                                            ;输入：CL=字符ASCII码
         pushad                             ;保存所有32位通用寄存器

         ;以下通过VGA控制器的索引/数据端口对读取当前光标位置
         mov dx,0x3d4                       ;VGA索引端口
         mov al,0x0e                        ;索引0x0E=光标位置高8位
         out dx,al
         inc dx                             ;0x3d5=VGA数据端口
         in al,dx                           ;读取光标位置高字节
         mov ah,al

         dec dx                             ;0x3d4
         mov al,0x0f                        ;索引0x0F=光标位置低8位
         out dx,al
         inc dx                             ;0x3d5
         in al,dx                           ;读取光标位置低字节
         mov bx,ax                          ;BX=16位光标位置（字符偏移，0~1999）

         cmp cl,0x0d                        ;判断是否为回车符(CR, 0x0D)？
         jnz .put_0a
         mov ax,bx                          ;回车处理：光标回到当前行首
         mov bl,80                          ;每行80个字符
         div bl                             ;AL=当前行号，AH=列号
         mul bl                             ;AL×80=行首位置
         mov bx,ax
         jmp .set_cursor

  .put_0a:
         cmp cl,0x0a                        ;判断是否为换行符(LF, 0x0A)？
         jnz .put_other
         add bx,80                          ;换行：光标下移一行（+80字符）
         jmp .roll_screen

  .put_other:                               ;正常显示字符
         push es
         mov eax,video_ram_seg_sel          ;加载显存段选择子（基地址0xB8000）
         mov es,eax
         shl bx,1                           ;光标位置×2=显存中的字节偏移（每字符占2字节）
         mov [es:bx],cl                     ;写入字符到显存（属性字节保持不变）
         pop es

         ;以下将光标位置推进一个字符
         shr bx,1                           ;恢复光标的字符位置
         inc bx

  .roll_screen:
         cmp bx,2000                        ;光标超出屏幕？(80列×25行=2000)
         jl .set_cursor

         ;需要滚屏：将第1~24行上移到第0~23行，清空第24行
         push ds
         push es
         mov eax,video_ram_seg_sel
         mov ds,eax                         ;DS和ES都指向显存段
         mov es,eax
         cld                                ;清方向标志，使 movsb/movsd 正向传输
         mov esi,0xa0                       ;源地址：第1行起始（80字符×2字节=160=0xA0）
         mov edi,0x00                       ;目标地址：第0行起始
         mov ecx,1920                       ;传输次数：24行×80字符×2字节÷4=1920个双字
         rep movsd                          ;批量向前搬移显存内容（滚屏）
         mov bx,3840                        ;最后一行起始偏移（24×80×2=3840）
         mov ecx,80                         ;清除80个字符位置
  .cls:
         mov word[es:bx],0x0720             ;写入空格(0x20)+浅灰色属性(0x07)
         add bx,2
         loop .cls

         pop es
         pop ds

         mov bx,1920                        ;光标设定到最后一行行首(24×80=1920)

  .set_cursor:
         ;通过VGA端口设置新的光标位置
         mov dx,0x3d4
         mov al,0x0e                        ;光标位置高8位
         out dx,al
         inc dx                             ;0x3d5
         mov al,bh
         out dx,al
         dec dx                             ;0x3d4
         mov al,0x0f                        ;光标位置低8位
         out dx,al
         inc dx                             ;0x3d5
         mov al,bl
         out dx,al

         popad                              ;恢复所有通用寄存器
         ret                                ;段内近返回（仅被put_string在同段内调用）

;-------------------------------------------------------------------------------
read_hard_disk_0:                           ;从硬盘读取一个逻辑扇区（LBA模式）
                                            ;输入：EAX=逻辑扇区号（28位LBA地址）
                                            ;      DS:EBX=目标缓冲区地址
                                            ;返回：EBX=EBX+512（指向下一个可用缓冲区位置）
         push eax
         push ecx
         push edx

         push eax

         mov dx,0x1f2
         mov al,1
         out dx,al                          ;端口0x1F2：设置读取的扇区数=1

         inc dx                             ;端口0x1F3
         pop eax
         out dx,al                          ;写入LBA地址的第0~7位

         inc dx                             ;端口0x1F4
         mov cl,8
         shr eax,cl
         out dx,al                          ;写入LBA地址的第8~15位

         inc dx                             ;端口0x1F5
         shr eax,cl
         out dx,al                          ;写入LBA地址的第16~23位

         inc dx                             ;端口0x1F6
         shr eax,cl
         or al,0xe0                         ;高4位=1110：选择第一硬盘LBA模式；低4位=LBA第24~27位
         out dx,al

         inc dx                             ;端口0x1F7（命令端口）
         mov al,0x20                        ;0x20=读命令(READ SECTORS)
         out dx,al

  .waits:
         in al,dx                           ;读状态端口0x1F7
         and al,0x88                        ;保留BSY位(bit7)和DRQ位(bit3)
         cmp al,0x08                        ;BSY=0且DRQ=1表示数据就绪
         jnz .waits                         ;否则继续轮询等待

         mov ecx,256                        ;一个扇区=512字节=256个字
         mov dx,0x1f0                       ;端口0x1F0：16位数据端口
  .readw:
         in ax,dx                           ;每次读2字节
         mov [ebx],ax                       ;写入目标缓冲区
         add ebx,2                          ;缓冲区指针后移
         loop .readw                        ;循环256次，读完一个扇区

         pop edx
         pop ecx
         pop eax

         retf                               ;段间远返回（本例程在sys_routine段，调用者在其他段）

;-------------------------------------------------------------------------------
;汇编语言程序是极难一次成功，而且调试非常困难。这个例程可以提供帮助
put_hex_dword:                              ;在当前光标处以十六进制形式显示一个双字并推进光标
                                            ;输入：EDX=要转换并显示的32位数字
                                            ;输出：无（直接显示在屏幕上）
         pushad
         push ds

         mov ax,core_data_seg_sel           ;切换DS到核心数据段，以访问转换表
         mov ds,ax

         mov ebx,bin_hex                    ;EBX指向 '0123456789ABCDEF' 查找表
         mov ecx,8                          ;32位数字共8个十六进制位，循环8次
  .xlt:
         rol edx,4                          ;循环左移4位：将最高4位旋转到最低4位
         mov eax,edx
         and eax,0x0000000f                 ;掩码取低4位（0~F）
         xlat                               ;AL = [EBX+AL]，查表得到对应的ASCII字符

         push ecx
         mov cl,al                          ;将ASCII字符传给put_char
         call put_char                      ;显示一个十六进制字符
         pop ecx

         loop .xlt                          ;处理下一个十六进制位

         pop ds
         popad
         retf                               ;段间远返回
      
;-------------------------------------------------------------------------------
allocate_memory:                            ;简易线性内存分配器（bump allocator）
                                            ;输入：ECX=希望分配的字节数
                                            ;输出：ECX=分配到的内存起始线性地址
         push ds
         push eax
         push ebx

         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换DS到核心数据段

         mov eax,[ram_alloc]                ;读取当前的分配指针（初始值0x100000，即1MB处）
         add eax,ecx                        ;计算本次分配后的新地址（下次分配的起始）

         ;这里应当有检测可用内存数量的指令（实际系统需要检查内存上限）

         mov ecx,[ram_alloc]                ;将当前分配指针作为本次分配的起始地址返回

         mov ebx,eax
         and ebx,0xfffffffc                 ;清除低2位，向下对齐到4字节边界
         add ebx,4                          ;再+4，得到向上对齐的4字节边界地址
         test eax,0x00000003                ;检查新地址是否已经4字节对齐（低2位是否为0）
         cmovnz eax,ebx                     ;若未对齐(ZF=0)，用对齐后的值替换
                                            ;cmovnz = Conditional MOV if Not Zero
                                            ;避免了if-else分支，提高流水线效率
         mov [ram_alloc],eax                ;更新分配指针，下次从此地址开始分配

         pop ebx
         pop eax
         pop ds

         retf                               ;段间远返回

;-------------------------------------------------------------------------------
set_up_gdt_descriptor:                      ;在GDT内动态安装一个新的描述符
                                            ;输入：EDX:EAX=完整的8字节描述符
                                            ;输出：CX=新描述符对应的段选择子
         push eax
         push ebx
         push edx

         push ds
         push es

         mov ebx,core_data_seg_sel          ;切换DS到核心数据段
         mov ds,ebx

         ;先用sgdt保存当前GDTR内容到内存，获取GDT的当前界限和基地址
         sgdt [pgdt]                        ;sgdt：将GDTR(6字节)保存到[pgdt]

         mov ebx,mem_0_4_gb_seg_sel
         mov es,ebx                         ;ES指向0~4GB段，用于直接线性地址访问

         movzx ebx,word [pgdt]              ;EBX = GDT当前界限值（字节数-1）
         inc bx                             ;+1 = GDT已占用的总字节数 = 新描述符的偏移
         add ebx,[pgdt+2]                   ;+ GDT基地址 = 新描述符在线性地址空间中的位置

         mov [es:ebx],eax                   ;写入描述符的低32位
         mov [es:ebx+4],edx                 ;写入描述符的高32位

         add word [pgdt],8                  ;GDT界限增加8字节（一个描述符的大小）

         lgdt [pgdt]                        ;lgdt：重新加载GDTR，使新描述符生效

         ;根据新的GDT界限值计算新描述符对应的段选择子
         mov ax,[pgdt]                      ;读取更新后的GDT界限值
         xor dx,dx
         mov bx,8
         div bx                             ;界限值÷8 = 最后一个描述符的索引号
         mov cx,ax
         shl cx,3                           ;索引号左移3位，构成选择子（RPL=0, TI=0）

         pop es
         pop ds

         pop edx
         pop ebx
         pop eax

         retf                               ;段间远返回
;-------------------------------------------------------------------------------
make_seg_descriptor:                        ;构造存储器和系统的段描述符
                                            ;（与MBR中的make_gdt_descriptor逻辑相同）
                                            ;输入：EAX=线性基地址（32位）
                                            ;      EBX=段界限（20位有效）
                                            ;      ECX=属性（各属性位在原始位置，无关位清零）
                                            ;返回：EDX:EAX=完整的8字节描述符
         mov edx,eax
         shl eax,16                         ;基地址低16位移到EAX高16位
         or ax,bx                           ;EAX低16位=段界限低16位 → 低32位构造完毕

         and edx,0xffff0000                 ;只保留基地址的高16位
         rol edx,8                          ;循环左移8位，重新排列字节位置
         bswap edx                          ;字节反转(80486+)：装配基址bit31~24和bit23~16

         xor bx,bx                          ;清除BX低16位
         or edx,ebx                         ;装配段界限的高4位(bit19~16)

         or edx,ecx                         ;装配属性字段

         retf                               ;段间远返回

;============================数据段=============================================
SECTION core_data vstart=0                  ;系统核心的数据段
;-------------------------------------------------------------------------------
         pgdt             dw  0             ;GDT界限（sgdt/lgdt使用的6字节结构）
                          dd  0             ;GDT基地址

         ram_alloc        dd  0x00100000    ;下次内存分配的起始线性地址
                                            ;初始值=1MB，在实模式遗留区域和显存之上

         ;====== SALT（符号地址检索表）======
         ;每个条目：256字节名称 + 4字节偏移 + 2字节选择子 = 262字节
         ;内核加载用户程序时，用repe cmpsd逐条匹配名称并回写地址
         salt:
         salt_1           db  '@PrintString'
                     times 256-($-salt_1) db 0     ;用0填充到256字节
                          dd  put_string             ;该服务例程的段内偏移地址
                          dw  sys_routine_seg_sel    ;该服务所在段的选择子

         salt_2           db  '@ReadDiskData'
                     times 256-($-salt_2) db 0
                          dd  read_hard_disk_0
                          dw  sys_routine_seg_sel

         salt_3           db  '@PrintDwordAsHexString'
                     times 256-($-salt_3) db 0
                          dd  put_hex_dword
                          dw  sys_routine_seg_sel

         salt_4           db  '@TerminateProgram'
                     times 256-($-salt_4) db 0
                          dd  return_point           ;指向内核代码段中的用户程序返回点
                          dw  core_code_seg_sel      ;注意：这个在核心代码段，不是sys_routine段

         salt_item_len   equ $-salt_4               ;单个SALT条目的长度（262字节）
         salt_items      equ ($-salt)/salt_item_len  ;SALT条目总数

         message_1        db  '  If you seen this message,that means we '
                          db  'are now in protect mode,and the system '
                          db  'core is loaded,and the video display '
                          db  'routine works perfectly.',0x0d,0x0a,0

         message_5        db  '  Loading user program...',0

         do_status        db  'Done.',0x0d,0x0a,0

         message_6        db  0x0d,0x0a,0x0d,0x0a,0x0d,0x0a
                          db  '  User program terminated,control returned.',0

         bin_hex          db '0123456789ABCDEF'
                                            ;put_hex_dword子过程用的十六进制查找表
         core_buf   times 2048 db 0         ;内核通用缓冲区（用于临时存放磁盘数据等）

         esp_pointer      dd 0              ;内核临时保存自己的栈指针（用户程序运行时栈会切换）

         cpu_brnd0        db 0x0d,0x0a,'  ',0   ;cpuid品牌字符串的前缀（换行+缩进）
         cpu_brand  times 52 db 0               ;存放48字节的CPU品牌字符串+余量
         cpu_brnd1        db 0x0d,0x0a,0x0d,0x0a,0 ;品牌字符串的后缀（双换行）

;================================代码段=========================================
SECTION core_code vstart=0
;-------------------------------------------------------------------------------
load_relocate_program:                      ;加载并重定位用户程序
                                            ;输入：ESI=用户程序的起始逻辑扇区号
                                            ;返回：AX=指向用户程序头部段的选择子
         push ebx
         push ecx
         push edx
         push esi
         push edi

         push ds
         push es

         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换DS到内核数据段

         mov eax,esi                        ;EAX=用户程序起始扇区号
         mov ebx,core_buf                   ;先读到内核缓冲区（只读头部一个扇区）
         call sys_routine_seg_sel:read_hard_disk_0  ;远调用sys_routine段的磁盘读例程

         ;以下判断整个用户程序有多大，并凑整到512字节的倍数
         mov eax,[core_buf]                 ;从头部偏移0x00读取程序总长度
         mov ebx,eax
         and ebx,0xfffffe00                 ;清除低9位，向下对齐到512字节边界
         add ebx,512                        ;再+512，向上凑整
         test eax,0x000001ff                ;检查原长度是否恰好是512的倍数
         cmovnz eax,ebx                     ;若不是(ZF=0)，用凑整的结果替换

         ;为用户程序分配内存
         mov ecx,eax                        ;ECX=需要分配的字节数
         call sys_routine_seg_sel:allocate_memory  ;远调用内存分配例程
         mov ebx,ecx                        ;EBX=分配到的内存起始线性地址
         push ebx                           ;保存该首地址（后续需要用来设置段描述符）
         xor edx,edx
         mov ecx,512
         div ecx                            ;总字节数÷512=需要读取的扇区数
         mov ecx,eax                        ;ECX=总扇区数（作为循环计数器）

         ;切换到0~4GB段，通过线性地址直接将用户程序读入分配的内存
         mov eax,mem_0_4_gb_seg_sel
         mov ds,eax

         mov eax,esi                        ;EAX=用户程序起始扇区号
.b1:
         call sys_routine_seg_sel:read_hard_disk_0  ;每次读一个扇区，EBX自动+512
         inc eax                            ;下一个逻辑扇区
         loop .b1                           ;循环读，直到读完整个用户程序

         ;=== 以下为用户程序各段建立GDT描述符 ===

         ;建立用户程序头部段描述符（数据段，用于访问程序头部结构）
         pop edi                            ;恢复用户程序在内存中的起始线性地址
         mov eax,edi                        ;EAX=程序头部起始线性地址（即基地址）
         mov ebx,[edi+0x04]                 ;从头部偏移0x04读取头部段长度
         dec ebx                            ;段界限=长度-1
         mov ecx,0x00409200                 ;属性：字节粒度，可读写数据段
         call sys_routine_seg_sel:make_seg_descriptor  ;构造描述符
         call sys_routine_seg_sel:set_up_gdt_descriptor ;安装到GDT，返回CX=选择子
         mov [edi+0x04],cx                  ;将选择子回写到头部（替换原来的长度字段）

         ;建立用户程序代码段描述符
         mov eax,edi
         add eax,[edi+0x14]                 ;基地址=程序起始+代码段偏移(头部0x14)
         mov ebx,[edi+0x18]                 ;代码段长度(头部0x18)
         dec ebx                            ;段界限
         mov ecx,0x00409800                 ;属性：字节粒度，只执行代码段
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [edi+0x14],cx                  ;回写代码段选择子

         ;建立用户程序数据段描述符
         mov eax,edi
         add eax,[edi+0x1c]                 ;基地址=程序起始+数据段偏移(头部0x1C)
         mov ebx,[edi+0x20]                 ;数据段长度(头部0x20)
         dec ebx                            ;段界限
         mov ecx,0x00409200                 ;属性：字节粒度，可读写数据段
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [edi+0x1c],cx                  ;回写数据段选择子

         ;建立用户程序堆栈段描述符（向下扩展的栈段，4KB粒度）
         mov ecx,[edi+0x0c]                 ;从头部0x0C读取建议的栈大小（以4KB为单位）
         mov ebx,0x000fffff
         sub ebx,ecx                        ;段界限=0xFFFFF-栈大小（向下扩展段的特殊计算）
         mov eax,4096
         mul dword [edi+0x0c]               ;栈大小×4096=实际需要的字节数
         mov ecx,eax                        ;准备为堆栈分配内存
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;分配到的基址+大小=栈的高端物理地址（栈底）
         mov ecx,0x00c09600                 ;属性：4KB粒度，向下扩展，可读写
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [edi+0x08],cx                  ;回写堆栈段选择子到头部0x08

         ;=== SALT重定位：将用户程序的服务名称替换为实际的调用地址 ===
         mov eax,[edi+0x04]
         mov es,eax                         ;ES指向用户程序头部段（刚刚创建的选择子）
         mov eax,core_data_seg_sel
         mov ds,eax                         ;DS指向内核数据段（内含内核SALT表）

         cld                                ;清方向标志，使cmpsd正向比较

         mov ecx,[es:0x24]                  ;ECX=用户程序声明的SALT条目数
         mov edi,0x28                       ;用户SALT在头部中的起始偏移=0x28
  .b2:
         push ecx                           ;保存外层循环计数（用户SALT条目数）
         push edi                           ;保存当前用户SALT条目的偏移

         mov ecx,salt_items                 ;ECX=内核SALT条目总数（内层循环）
         mov esi,salt                       ;ESI指向内核SALT表起始
  .b3:
         push edi
         push esi
         push ecx

         mov ecx,64                         ;每条目256字节÷4=64次双字比较
         repe cmpsd                         ;逐双字(4字节)比较 DS:[ESI] 与 ES:[EDI]
                                            ;ZF=1表示匹配，ZF=0表示不匹配
         jnz .b4                            ;不匹配则跳过，尝试下一个内核SALT条目
         ;匹配成功：此时ESI刚好指向内核SALT条目中名称之后的偏移地址字段
         mov eax,[esi]                      ;读取内核例程的段内偏移地址
         mov [es:edi-256],eax               ;写入用户SALT条目（覆盖名称的前4字节为偏移）
         mov ax,[esi+4]                     ;读取内核例程的段选择子
         mov [es:edi-252],ax                ;写入用户SALT条目（名称偏移+4处为选择子）
  .b4:
         pop ecx
         pop esi
         add esi,salt_item_len              ;ESI移到内核SALT的下一个条目
         pop edi                            ;恢复用户SALT条目起始，从头比较
         loop .b3                           ;内层循环：遍历所有内核SALT条目

         pop edi
         add edi,256                        ;EDI移到用户SALT的下一个条目
         pop ecx
         loop .b2                           ;外层循环：遍历所有用户SALT条目

         mov ax,[es:0x04]                   ;返回值：用户程序头部段的选择子

         pop es                             ;恢复到调用此过程前的ES段
         pop ds                             ;恢复到调用此过程前的DS段

         pop edi
         pop esi
         pop edx
         pop ecx
         pop ebx

         ret                                ;近返回（调用者在同一个core_code段内）
      
;-------------------------------------------------------------------------------
start:
         ;=== 内核入口点：MBR通过 jmp far [edi+0x10] 跳转到这里 ===
         mov ecx,core_data_seg_sel           ;切换DS到内核数据段
         mov ds,ecx

         mov ebx,message_1                   ;显示内核加载成功的确认消息
         call sys_routine_seg_sel:put_string ;远调用sys_routine段的字符串显示例程

         ;=== 使用cpuid指令获取并显示处理器品牌字符串 ===
         ;cpuid需要连续调用3次（EAX=0x80000002/3/4），每次返回16字节，共48字节
         mov eax,0x80000002                  ;第一部分（字节0~15）
         cpuid                               ;返回值在EAX,EBX,ECX,EDX中
         mov [cpu_brand + 0x00],eax
         mov [cpu_brand + 0x04],ebx
         mov [cpu_brand + 0x08],ecx
         mov [cpu_brand + 0x0c],edx

         mov eax,0x80000003                  ;第二部分（字节16~31）
         cpuid
         mov [cpu_brand + 0x10],eax
         mov [cpu_brand + 0x14],ebx
         mov [cpu_brand + 0x18],ecx
         mov [cpu_brand + 0x1c],edx

         mov eax,0x80000004                  ;第三部分（字节32~47）
         cpuid
         mov [cpu_brand + 0x20],eax
         mov [cpu_brand + 0x24],ebx
         mov [cpu_brand + 0x28],ecx
         mov [cpu_brand + 0x2c],edx

         mov ebx,cpu_brnd0                   ;打印前缀（换行+缩进）
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brand                   ;打印CPU品牌字符串（如 "Intel(R) Core(TM)..."）
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brnd1                   ;打印后缀（双换行）
         call sys_routine_seg_sel:put_string

         ;=== 加载用户程序 ===
         mov ebx,message_5                   ;显示 "Loading user program..."
         call sys_routine_seg_sel:put_string
         mov esi,50                          ;用户程序位于逻辑扇区50
         call load_relocate_program          ;近调用：加载、重定位用户程序
                                             ;返回AX=用户程序头部段选择子

         mov ebx,do_status                   ;显示 "Done."
         call sys_routine_seg_sel:put_string

         mov [esp_pointer],esp               ;临时保存内核栈指针（用户程序会切换栈）

         mov ds,ax                           ;DS指向用户程序头部段（AX=头部段选择子）

         jmp far [0x10]                      ;间接远跳转：从头部偏移0x10读取入口点
                                             ;[0x10]=EIP(段内偏移)，[0x14]=CS(代码段选择子)
                                             ;控制权交给用户程序，堆栈也随之切换

return_point:                                ;用户程序通过 jmp far [@TerminateProgram] 返回到这里
         mov eax,core_data_seg_sel           ;恢复DS指向核心数据段
         mov ds,eax

         mov eax,core_stack_seg_sel          ;切换回内核自己的堆栈段
         mov ss,eax
         mov esp,[esp_pointer]               ;从保存的位置恢复栈指针

         mov ebx,message_6                   ;显示 "User program terminated,control returned."
         call sys_routine_seg_sel:put_string

         ;这里可以放置清除用户程序各种描述符的指令
         ;也可以加载并启动其它程序

         hlt                                 ;停机，等待外部中断（实际上本系统不会再有中断）
            
;===============================================================================
SECTION core_trail
;-------------------------------------------------------------------------------
core_end:                                    ;内核映像结束标记，core_length由此计算