         ;代码清单15-1
         ;文件名：c15_core.asm
         ;文件说明：保护模式微型核心程序
         ;创建日期：2011-11-19 21:40

;============================ 扩展知识 ========================================
;
; 【硬件任务切换 (Hardware Task Switching)】
;   这是x86架构独有的特性，处理器通过硬件自动完成任务上下文的保存和恢复。
;   三种触发方式：
;
;   1. CALL far [tss_selector]:
;      - 将当前任务的完整状态（所有寄存器）保存到当前任务的TSS中
;      - 从目标TSS中加载新任务的完整状态
;      - 设置EFLAGS中的NT（Nested Task，嵌套任务）标志位=1
;      - 将调用者的TSS选择子写入新任务TSS的反向链（backlink，偏移0处）
;      - 这意味着新任务是"被调用"的，可以通过IRETD返回调用者
;
;   2. JMP far [tss_selector]:
;      - 同样保存当前状态、加载新状态
;      - 但不设置NT标志位（NT=0）
;      - 不修改新任务TSS的反向链
;      - 这意味着新任务是"独立"的，无法通过IRETD返回，必须用JMP切换回去
;
;   3. IRETD（带NT标志的任务返回）:
;      - 如果当前EFLAGS的NT=1，则IRETD不执行普通的中断返回
;      - 而是读取当前TSS偏移0处的反向链（backlink），切换回前一个任务
;      - 同时清除前一个任务EFLAGS中的NT标志
;      - 如果NT=0，IRETD执行普通的中断/异常返回（从堆栈弹出EIP/CS/EFLAGS）
;
; 【TSS (Task State Segment) 完整结构】（共104字节，偏移量均为十进制）
;   偏移  大小    字段                 说明
;   ──────────────────────────────────────────────────────────────────
;     0    WORD   Backlink            反向链——前一个任务的TSS选择子（嵌套任务时由CPU自动写入）
;     4    DWORD  ESP0                特权级0的堆栈指针（从Ring3切换到Ring0时CPU自动加载）
;     8    WORD   SS0                 特权级0的堆栈段选择子
;    12    DWORD  ESP1                特权级1的堆栈指针
;    16    WORD   SS1                 特权级1的堆栈段选择子
;    20    DWORD  ESP2                特权级2的堆栈指针
;    24    WORD   SS2                 特权级2的堆栈段选择子
;    28    DWORD  CR3                 页目录基地址寄存器（PDBR），用于任务独立的地址空间
;    32    DWORD  EIP                 任务恢复执行的指令指针
;    36    DWORD  EFLAGS              任务的标志寄存器
;    40    DWORD  EAX                 通用寄存器EAX
;    44    DWORD  ECX                 通用寄存器ECX
;    48    DWORD  EDX                 通用寄存器EDX
;    52    DWORD  EBX                 通用寄存器EBX
;    56    DWORD  ESP                 通用寄存器ESP（任务自己特权级的堆栈指针）
;    60    DWORD  EBP                 通用寄存器EBP
;    64    DWORD  ESI                 通用寄存器ESI
;    68    DWORD  EDI                 通用寄存器EDI
;    72    WORD   ES                  段寄存器ES
;    76    WORD   CS                  段寄存器CS
;    80    WORD   SS                  段寄存器SS
;    84    WORD   DS                  段寄存器DS
;    88    WORD   FS                  段寄存器FS
;    92    WORD   GS                  段寄存器GS
;    96    WORD   LDT Selector        任务的LDT选择子
;   100    WORD   T                   调试陷阱位（T=1时，任务切换到此任务时触发调试异常）
;   102    WORD   I/O Map Base        I/O许可位图的偏移（相对于TSS起始地址）
;
;   注意：每个WORD字段实际占4字节空间（高16位保留），所以TSS最小104字节。
;
; 【程序管理器模式 (Program Manager Pattern)】
;   程序管理器是一个运行在Ring0的特殊任务，负责管理其他用户任务的生命周期。
;   工作流程：
;     1. 程序管理器首先为自己创建TSS并用LTR指令加载到TR寄存器
;     2. 使用CALL far切换到用户任务——用户任务结束后可以IRETD返回
;     3. 使用JMP far切换到用户任务——用户任务结束后必须JMP回程序管理器
;   程序管理器本身不需要LDT（它运行在内核空间），也不需要Ring0/1/2堆栈
;   （因为它已经在Ring0，不存在向更低特权级转移的情况）。
;
; 【terminate_current_task 的设计】
;   此例程是通用的任务终止机制，它检测当前任务的启动方式来决定如何返回：
;   - 通过pushfd将EFLAGS压栈，然后检查NT（Nested Task）标志位（bit 14）
;   - 若NT=1：说明任务是被CALL指令或中断/异常切换过来的，使用IRETD返回
;   - 若NT=0：说明任务是被JMP指令切换过来的，只能用JMP far切换回程序管理器
;   这样用户程序无需关心自己是如何被启动的，统一调用@TerminateProgram即可。
;
; 【pushfd / popfd 指令】
;   - pushfd：将32位EFLAGS寄存器的内容压入堆栈（注意不是pushf，pushf只压16位FLAGS）
;   - popfd：从堆栈弹出32位值并加载到EFLAGS寄存器
;   - 常用于保存/恢复标志状态，或者像本程序中那样读取EFLAGS进行位测试
;   - EFLAGS中重要的标志位：
;     bit 0:  CF (进位标志)     bit 14: NT (嵌套任务标志)
;     bit 6:  ZF (零标志)       bit 16: RF (恢复标志)
;     bit 7:  SF (符号标志)     bit 17: VM (虚拟8086模式)
;     bit 9:  IF (中断允许标志) bit 12-13: IOPL (I/O特权级)
;
;==============================================================================

         ;以下常量定义部分。内核的大部分内容都应当固定
         ;以下常量定义部分——GDT中各段的选择子（由引导程序建立）
         core_code_seg_sel     equ  0x38    ;内核代码段选择子（索引7，RPL=0）
         core_data_seg_sel     equ  0x30    ;内核数据段选择子（索引6，RPL=0）
         sys_routine_seg_sel   equ  0x28    ;系统公共例程代码段的选择子（索引5）
         video_ram_seg_sel     equ  0x20    ;视频显示缓冲区的段选择子（0xB8000）
         core_stack_seg_sel    equ  0x18    ;内核堆栈段选择子（Ring0堆栈）
         mem_0_4_gb_seg_sel    equ  0x08    ;整个0-4GB内存的段的选择子（平坦模型）

;-------------------------------------------------------------------------------
         ;以下是系统核心的头部，用于加载核心程序 
         core_length      dd core_end       ;核心程序总长度#00

         sys_routine_seg  dd section.sys_routine.start
                                            ;系统公用例程段位置#04

         core_data_seg    dd section.core_data.start
                                            ;核心数据段位置#08

         core_code_seg    dd section.core_code.start
                                            ;核心代码段位置#0c


         core_entry       dd start          ;核心代码段入口点#10
                          dw core_code_seg_sel

;===============================================================================
         [bits 32]
;===============================================================================
SECTION sys_routine vstart=0                ;系统公共例程代码段 
;-------------------------------------------------------------------------------
         ;字符串显示例程
put_string:                                 ;显示0终止的字符串并移动光标 
                                            ;输入：DS:EBX=串地址
         push ecx
  .getc:
         mov cl,[ebx]
         or cl,cl
         jz .exit
         call put_char
         inc ebx
         jmp .getc

  .exit:
         pop ecx
         retf                               ;段间返回

;-------------------------------------------------------------------------------
put_char:                                   ;在当前光标处显示一个字符,并推进
                                            ;光标。仅用于段内调用 
                                            ;输入：CL=字符ASCII码 
         pushad

         ;以下取当前光标位置
         mov dx,0x3d4
         mov al,0x0e
         out dx,al
         inc dx                             ;0x3d5
         in al,dx                           ;高字
         mov ah,al

         dec dx                             ;0x3d4
         mov al,0x0f
         out dx,al
         inc dx                             ;0x3d5
         in al,dx                           ;低字
         mov bx,ax                          ;BX=代表光标位置的16位数

         cmp cl,0x0d                        ;回车符？
         jnz .put_0a
         mov ax,bx
         mov bl,80
         div bl
         mul bl
         mov bx,ax
         jmp .set_cursor

  .put_0a:
         cmp cl,0x0a                        ;换行符？
         jnz .put_other
         add bx,80
         jmp .roll_screen

  .put_other:                               ;正常显示字符
         push es
         mov eax,video_ram_seg_sel          ;0xb8000段的选择子
         mov es,eax
         shl bx,1
         mov [es:bx],cl
         pop es

         ;以下将光标位置推进一个字符
         shr bx,1
         inc bx

  .roll_screen:
         cmp bx,2000                        ;光标超出屏幕？滚屏
         jl .set_cursor

         push ds
         push es
         mov eax,video_ram_seg_sel
         mov ds,eax
         mov es,eax
         cld
         mov esi,0xa0                       ;小心！32位模式下movsb/w/d 
         mov edi,0x00                       ;使用的是esi/edi/ecx 
         mov ecx,1920
         rep movsd
         mov bx,3840                        ;清除屏幕最底一行
         mov ecx,80                         ;32位程序应该使用ECX
  .cls:
         mov word[es:bx],0x0720
         add bx,2
         loop .cls

         pop es
         pop ds

         mov bx,1920

  .set_cursor:
         mov dx,0x3d4
         mov al,0x0e
         out dx,al
         inc dx                             ;0x3d5
         mov al,bh
         out dx,al
         dec dx                             ;0x3d4
         mov al,0x0f
         out dx,al
         inc dx                             ;0x3d5
         mov al,bl
         out dx,al

         popad
         
         ret                                

;-------------------------------------------------------------------------------
read_hard_disk_0:                           ;从硬盘读取一个逻辑扇区
                                            ;EAX=逻辑扇区号
                                            ;DS:EBX=目标缓冲区地址
                                            ;返回：EBX=EBX+512
         push eax 
         push ecx
         push edx
      
         push eax
         
         mov dx,0x1f2
         mov al,1
         out dx,al                          ;读取的扇区数

         inc dx                             ;0x1f3
         pop eax
         out dx,al                          ;LBA地址7~0

         inc dx                             ;0x1f4
         mov cl,8
         shr eax,cl
         out dx,al                          ;LBA地址15~8

         inc dx                             ;0x1f5
         shr eax,cl
         out dx,al                          ;LBA地址23~16

         inc dx                             ;0x1f6
         shr eax,cl
         or al,0xe0                         ;第一硬盘  LBA地址27~24
         out dx,al

         inc dx                             ;0x1f7
         mov al,0x20                        ;读命令
         out dx,al

  .waits:
         in al,dx
         and al,0x88
         cmp al,0x08
         jnz .waits                         ;不忙，且硬盘已准备好数据传输 

         mov ecx,256                        ;总共要读取的字数
         mov dx,0x1f0
  .readw:
         in ax,dx
         mov [ebx],ax
         add ebx,2
         loop .readw

         pop edx
         pop ecx
         pop eax
      
         retf                               ;段间返回 

;-------------------------------------------------------------------------------
;汇编语言程序是极难一次成功，而且调试非常困难。这个例程可以提供帮助 
put_hex_dword:                              ;在当前光标处以十六进制形式显示
                                            ;一个双字并推进光标 
                                            ;输入：EDX=要转换并显示的数字
                                            ;输出：无
         pushad
         push ds
      
         mov ax,core_data_seg_sel           ;切换到核心数据段 
         mov ds,ax
      
         mov ebx,bin_hex                    ;指向核心数据段内的转换表
         mov ecx,8
  .xlt:    
         rol edx,4
         mov eax,edx
         and eax,0x0000000f
         xlat
      
         push ecx
         mov cl,al                           
         call put_char
         pop ecx
       
         loop .xlt
      
         pop ds
         popad
         retf
      
;-------------------------------------------------------------------------------
allocate_memory:                            ;分配内存
                                            ;输入：ECX=希望分配的字节数
                                            ;输出：ECX=起始线性地址 
         push ds
         push eax
         push ebx
      
         mov eax,core_data_seg_sel
         mov ds,eax
      
         mov eax,[ram_alloc]
         add eax,ecx                        ;下一次分配时的起始地址
      
         ;这里应当有检测可用内存数量的指令
          
         mov ecx,[ram_alloc]                ;返回分配的起始地址

         mov ebx,eax
         and ebx,0xfffffffc
         add ebx,4                          ;强制对齐 
         test eax,0x00000003                ;下次分配的起始地址最好是4字节对齐
         cmovnz eax,ebx                     ;如果没有对齐，则强制对齐 
         mov [ram_alloc],eax                ;下次从该地址分配内存
                                            ;cmovcc指令可以避免控制转移 
         pop ebx
         pop eax
         pop ds

         retf

;-------------------------------------------------------------------------------
set_up_gdt_descriptor:                      ;在GDT内安装一个新的描述符
                                            ;输入：EDX:EAX=描述符 
                                            ;输出：CX=描述符的选择子
         push eax
         push ebx
         push edx

         push ds
         push es

         mov ebx,core_data_seg_sel          ;切换到核心数据段
         mov ds,ebx

         sgdt [pgdt]                        ;以便开始处理GDT

         mov ebx,mem_0_4_gb_seg_sel
         mov es,ebx

         movzx ebx,word [pgdt]              ;GDT界限
         inc bx                             ;GDT总字节数，也是下一个描述符偏移
         add ebx,[pgdt+2]                   ;下一个描述符的线性地址

         mov [es:ebx],eax
         mov [es:ebx+4],edx

         add word [pgdt],8                  ;增加一个描述符的大小

         lgdt [pgdt]                        ;对GDT的更改生效

         mov ax,[pgdt]                      ;得到GDT界限值
         xor dx,dx
         mov bx,8
         div bx                             ;除以8，去掉余数
         mov cx,ax
         shl cx,3                           ;将索引号移到正确位置

         pop es
         pop ds

         pop edx
         pop ebx
         pop eax

         retf
;-------------------------------------------------------------------------------
make_seg_descriptor:                        ;构造存储器和系统的段描述符
                                            ;输入：EAX=线性基地址
                                            ;      EBX=段界限
                                            ;      ECX=属性。各属性位都在原始
                                            ;          位置，无关的位清零 
                                            ;返回：EDX:EAX=描述符
         mov edx,eax
         shl eax,16
         or ax,bx                           ;描述符前32位(EAX)构造完毕

         and edx,0xffff0000                 ;清除基地址中无关的位
         rol edx,8
         bswap edx                          ;装配基址的31~24和23~16  (80486+)

         xor bx,bx
         or edx,ebx                         ;装配段界限的高4位

         or edx,ecx                         ;装配属性

         retf

;-------------------------------------------------------------------------------
make_gate_descriptor:                       ;构造门的描述符（调用门等）
                                            ;输入：EAX=门代码在段内偏移地址
                                            ;       BX=门代码所在段的选择子 
                                            ;       CX=段类型及属性等（各属
                                            ;          性位都在原始位置）
                                            ;返回：EDX:EAX=完整的描述符
         push ebx
         push ecx
      
         mov edx,eax
         and edx,0xffff0000                 ;得到偏移地址高16位 
         or dx,cx                           ;组装属性部分到EDX
       
         and eax,0x0000ffff                 ;得到偏移地址低16位 
         shl ebx,16                          
         or eax,ebx                         ;组装段选择子部分
      
         pop ecx
         pop ebx
      
         retf                                   
                             
;-------------------------------------------------------------------------------
terminate_current_task:                     ;终止当前任务——通用任务退出例程
                                            ;注意，执行此例程时，当前任务仍在
                                            ;运行中。此例程其实也是当前任务的
                                            ;一部分（通过调用门进入内核特权级执行）
         pushfd                             ;将32位EFLAGS压入堆栈（pushfd不是pushf）
         mov edx,[esp]                      ;获得EFLAGS寄存器内容（不弹出，手动取）
         add esp,4                          ;手动恢复堆栈指针（等效于popfd但不修改EFLAGS）

         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换到内核数据段以访问prgman_tss

         test dx,0100_0000_0000_0000B       ;测试NT位（bit 14）：是否为嵌套任务？
         jnz .b1                            ;NT=1：是CALL/中断切换来的嵌套任务，跳.b1用iretd返回
         mov ebx,core_msg1                  ;NT=0：是JMP切换来的非嵌套任务
         call sys_routine_seg_sel:put_string ;显示提示信息
         jmp far [prgman_tss]               ;只能用JMP far切换回程序管理器任务
                                            ;[prgman_tss]含6字节：偏移（忽略）+TSS选择子
  .b1:
         mov ebx,core_msg0                  ;NT=1的情况：显示IRETD返回提示
         call sys_routine_seg_sel:put_string
         iretd                              ;NT=1时IRETD自动读取当前TSS的backlink，
                                            ;切换回前一个任务（由CPU硬件完成）
      
sys_routine_end:

;===============================================================================
SECTION core_data vstart=0                  ;系统核心的数据段
;-------------------------------------------------------------------------------
         pgdt             dw  0             ;用于设置和修改GDT（6字节伪描述符）
                          dd  0             ;前2字节=GDT界限，后4字节=GDT线性基地址

         ram_alloc        dd  0x00100000    ;下次分配内存时的起始地址（从1MB开始）

         ;符号地址检索表（C-SALT: Core Symbol Address Lookup Table）
         ;用于用户程序通过名称查找内核例程入口——重定位时将名称替换为地址+选择子
         salt:
         salt_1           db  '@PrintString'
                     times 256-($-salt_1) db 0
                          dd  put_string
                          dw  sys_routine_seg_sel

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
                          dd  terminate_current_task  ;任务终止例程入口
                          dw  sys_routine_seg_sel     ;所在段选择子

         salt_item_len   equ $-salt_4       ;每个SALT条目的长度（256字节名称+4字节偏移+2字节选择子）
         salt_items      equ ($-salt)/salt_item_len  ;SALT条目总数

         message_1        db  '  If you seen this message,that means we '
                          db  'are now in protect mode,and the system '
                          db  'core is loaded,and the video display '
                          db  'routine works perfectly.',0x0d,0x0a,0

         message_2        db  '  System wide CALL-GATE mounted.',0x0d,0x0a,0
         
         bin_hex          db '0123456789ABCDEF'
                                            ;put_hex_dword子过程用的查找表 

         core_buf   times 2048 db 0         ;内核用的缓冲区（用于临时读取磁盘扇区）

         cpu_brnd0        db 0x0d,0x0a,'  ',0   ;CPU品牌信息的前缀（换行+缩进）
         cpu_brand  times 52 db 0                ;存放CPUID返回的品牌字符串（最长48字节）
         cpu_brnd1        db 0x0d,0x0a,0x0d,0x0a,0  ;CPU品牌信息的后缀（两个换行）

         ;任务控制块(TCB)链——用链表管理所有任务
         tcb_chain        dd  0             ;TCB链表头指针（0表示空链表）

         ;程序管理器的任务信息——程序管理器是内核的主任务
         prgman_tss       dd  0             ;程序管理器的TSS基地址（线性地址）
                          dw  0             ;程序管理器的TSS描述符选择子
                                            ;这6字节构成FAR指针，可直接用于JMP/CALL far

         prgman_msg1      db  0x0d,0x0a
                          db  '[PROGRAM MANAGER]: Hello! I am Program Manager,'
                          db  'run at CPL=0.Now,create user task and switch '
                          db  'to it by the CALL instruction...',0x0d,0x0a,0
                          ;程序管理器第一次发言：将用CALL指令切换到用户任务

         prgman_msg2      db  0x0d,0x0a
                          db  '[PROGRAM MANAGER]: I am glad to regain control.'
                          db  'Now,create another user task and switch to '
                          db  'it by the JMP instruction...',0x0d,0x0a,0
                          ;程序管理器第二次发言：用户任务IRETD返回后，将用JMP指令切换

         prgman_msg3      db  0x0d,0x0a
                          db  '[PROGRAM MANAGER]: I am gain control again,'
                          db  'HALT...',0
                          ;程序管理器第三次发言：JMP切换的用户任务也结束了，系统停机

         core_msg0        db  0x0d,0x0a
                          db  '[SYSTEM CORE]: Uh...This task initiated with '
                          db  'CALL instruction or an exeception/ interrupt,'
                          db  'should use IRETD instruction to switch back...'
                          db  0x0d,0x0a,0
                          ;系统提示：此任务由CALL/中断启动（NT=1），将用IRETD返回

         core_msg1        db  0x0d,0x0a
                          db  '[SYSTEM CORE]: Uh...This task initiated with '
                          db  'JMP instruction,  should switch to Program '
                          db  'Manager directly by the JMP instruction...'
                          db  0x0d,0x0a,0
                          ;系统提示：此任务由JMP启动（NT=0），将用JMP返回程序管理器

core_data_end:
               
;===============================================================================
SECTION core_code vstart=0
;-------------------------------------------------------------------------------
fill_descriptor_in_ldt:                     ;在LDT内安装一个新的描述符
                                            ;输入：EDX:EAX=描述符（64位）
                                            ;          EBX=TCB基地址
                                            ;输出：CX=描述符的选择子（TI=1指向LDT）
         push eax
         push edx
         push edi
         push ds

         mov ecx,mem_0_4_gb_seg_sel
         mov ds,ecx                         ;通过4GB平坦段访问任意内存位置

         mov edi,[ebx+0x0c]                 ;从TCB中获得LDT基地址（线性地址）

         xor ecx,ecx
         mov cx,[ebx+0x0a]                  ;从TCB中获得LDT当前界限
         inc cx                             ;界限+1=总字节数=新描述符的安装偏移

         mov [edi+ecx+0x00],eax             ;写入描述符低32位
         mov [edi+ecx+0x04],edx             ;写入描述符高32位——安装完成

         add cx,8
         dec cx                             ;新的LDT界限=原界限+8-1（多了一个8字节描述符）

         mov [ebx+0x0a],cx                  ;更新LDT界限值回TCB

         mov ax,cx
         xor dx,dx
         mov cx,8
         div cx                             ;界限值/8 = 最后一个描述符的索引号

         mov cx,ax
         shl cx,3                           ;索引号左移3位到选择子的索引字段
         or cx,0000_0000_0000_0100B         ;设置TI=1（指向LDT而非GDT），RPL=00

         pop ds
         pop edi
         pop edx
         pop eax
     
         ret
         
;-------------------------------------------------------------------------------
load_relocate_program:                      ;加载并重定位用户程序
                                            ;输入: PUSH 逻辑扇区号
                                            ;      PUSH 任务控制块基地址
                                            ;输出：无
                                            ;此过程完成：加载程序、建立LDT描述符、
                                            ;创建各特权级堆栈、创建TSS、重定位SALT
         pushad

         push ds
         push es

         mov ebp,esp                        ;建立堆栈帧，用于访问通过堆栈传递的参数

         mov ecx,mem_0_4_gb_seg_sel
         mov es,ecx                         ;ES指向4GB平坦段，可访问任意线性地址

         mov esi,[ebp+11*4]                 ;从堆栈中取得TCB的基地址
                                            ;（跳过pushad的8个+push ds/es的2个=10个dword）

         ;以下申请创建LDT所需要的内存
         mov ecx,160                        ;160字节=20个描述符（每个8字节）
         call sys_routine_seg_sel:allocate_memory
         mov [es:esi+0x0c],ecx              ;登记LDT基地址到TCB中（TCB偏移0x0c）
         mov word [es:esi+0x0a],0xffff      ;登记LDT初始界限=-1到TCB中（表示LDT为空）

         ;以下开始加载用户程序
         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换DS到内核数据段以访问core_buf

         mov eax,[ebp+12*4]                 ;从堆栈中取出用户程序起始扇区号
         mov ebx,core_buf                   ;先读取程序头部（第一个扇区）
         call sys_routine_seg_sel:read_hard_disk_0

         ;以下判断整个程序有多大
         mov eax,[core_buf]                 ;从头部读取程序总尺寸（字节数）
         mov ebx,eax
         and ebx,0xfffffe00                 ;向下对齐到512字节边界（清除低9位）
         add ebx,512                        ;再加512——即向上取整到下一个512字节边界
         test eax,0x000001ff                ;程序的大小正好是512的倍数吗?（低9位全0?）
         cmovnz eax,ebx                     ;不是512的倍数，则使用向上取整的结果

         mov ecx,eax                        ;实际需要申请的内存数量（已对齐）
         call sys_routine_seg_sel:allocate_memory
         mov [es:esi+0x06],ecx              ;登记程序加载基地址到TCB中（偏移0x06）

         mov ebx,ecx                        ;ebx -> 申请到的内存首地址（用于读磁盘）
         xor edx,edx
         mov ecx,512
         div ecx                            ;总字节数/512 = 总扇区数
         mov ecx,eax                        ;ECX=总扇区数（作为循环计数器）

         mov eax,mem_0_4_gb_seg_sel         ;切换DS到0-4GB平坦段
         mov ds,eax                         ;这样read_hard_disk_0可以写入任意地址

         mov eax,[ebp+12*4]                 ;重新加载起始扇区号
  .b1:
         call sys_routine_seg_sel:read_hard_disk_0  ;读一个扇区到[DS:EBX]
         inc eax                            ;下一个扇区号
         loop .b1                           ;循环读，直到读完整个用户程序

         mov edi,[es:esi+0x06]              ;获得程序加载基地址（线性地址）

         ;建立程序头部段描述符（数据段，用户可读写，特权级3）
         mov eax,edi                        ;程序头部起始线性地址作为段基地址
         mov ebx,[edi+0x04]                 ;从头部获取段长度（head_len）
         dec ebx                            ;长度-1=段界限
         mov ecx,0x0040f200                 ;字节粒度的数据段描述符，DPL=3，可读写
         call sys_routine_seg_sel:make_seg_descriptor

         ;安装头部段描述符到LDT中
         mov ebx,esi                        ;TCB的基地址（fill_descriptor_in_ldt需要）
         call fill_descriptor_in_ldt

         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3（用户特权级）
         mov [es:esi+0x44],cx               ;登记程序头部段选择子到TCB（偏移0x44）
         mov [edi+0x04],cx                  ;同时回填到程序头部内（供用户程序使用）

         ;建立程序代码段描述符（代码段，只执行可读，特权级3）
         mov eax,edi
         add eax,[edi+0x14]                 ;代码段起始线性地址=加载基址+代码段偏移
         mov ebx,[edi+0x18]                 ;代码段长度
         dec ebx                            ;段界限=长度-1
         mov ecx,0x0040f800                 ;字节粒度的代码段描述符，DPL=3，只执行可读
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3
         mov [edi+0x14],cx                  ;登记代码段选择子到头部（覆盖原偏移值）

         ;建立程序数据段描述符（数据段，可读写，特权级3）
         mov eax,edi
         add eax,[edi+0x1c]                 ;数据段起始线性地址
         mov ebx,[edi+0x20]                 ;数据段长度
         dec ebx                            ;段界限
         mov ecx,0x0040f200                 ;字节粒度的数据段描述符，DPL=3，可读写
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3
         mov [edi+0x1c],cx                  ;登记数据段选择子到头部

         ;建立程序堆栈段描述符（向下扩展的堆栈段，特权级3）
         mov ecx,[edi+0x0c]                 ;从头部获取堆栈大小（4KB的倍数）
         mov ebx,0x000fffff
         sub ebx,ecx                        ;向下扩展段的界限=0xFFFFF-页数
         mov eax,4096
         mul ecx                            ;实际字节数=页数*4096
         mov ecx,eax                        ;准备为堆栈分配内存
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;得到堆栈的高端物理地址（作为段基地址）
         mov ecx,0x00c0f600                 ;4KB粒度的向下扩展堆栈段描述符，DPL=3
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3
         mov [edi+0x08],cx                  ;登记堆栈段选择子到头部

         ;重定位SALT（符号地址检索表）
         mov eax,mem_0_4_gb_seg_sel         ;这里和前一章不同，头部段描述符
         mov es,eax                         ;已安装到LDT，但LDT还没有加载生效，
                                            ;故只能通过4GB平坦段访问用户程序头部
         mov eax,core_data_seg_sel
         mov ds,eax                         ;DS指向内核数据段以访问C-SALT

         cld                                ;清方向标志，使串操作指令正向比较

         mov ecx,[es:edi+0x24]              ;U-SALT条目数（通过4GB段从头部读取）
         add edi,0x28                       ;U-SALT起始偏移（跳过头部固定字段）
  .b2:
         push ecx
         push edi

         mov ecx,salt_items                 ;C-SALT条目总数（内核端）
         mov esi,salt                       ;C-SALT起始地址（内核数据段内）
  .b3:
         push edi
         push esi
         push ecx

         mov ecx,64                         ;每条目名称256字节，比较64个dword
         repe cmpsd                         ;逐dword比较U-SALT条目和C-SALT条目名称
         jnz .b4                            ;不匹配则跳过
         mov eax,[esi]                      ;匹配！esi此时刚好指向C-SALT名称后的偏移地址
         mov [es:edi-256],eax               ;将U-SALT中的256字节名称覆写为入口偏移地址
         mov ax,[esi+4]                     ;取C-SALT中的段选择子
         or ax,0000000000000011B            ;设置RPL=3（以用户程序的特权级使用调用门）
         mov [es:edi-252],ax                ;回填调用门选择子（偏移+4处）
  .b4:
      
         pop ecx
         pop esi
         add esi,salt_item_len              ;指向下一个C-SALT条目
         pop edi                            ;恢复U-SALT当前条目起始地址，从头比较
         loop .b3                           ;遍历所有C-SALT条目

         pop edi
         add edi,256                        ;指向下一个U-SALT条目
         pop ecx
         loop .b2                           ;遍历所有U-SALT条目

         mov esi,[ebp+11*4]                 ;从堆栈中取得TCB的基地址（重新加载）

         ;创建0特权级堆栈——用于从Ring3切换到Ring0时由CPU自动加载
         mov ecx,4096                       ;分配4KB内存作为Ring0堆栈
         mov eax,ecx                        ;为生成堆栈高端地址做准备
         mov [es:esi+0x1a],ecx
         shr dword [es:esi+0x1a],12         ;登记0特权级堆栈尺寸到TCB（以4KB为单位）
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;堆栈基地址=分配地址+大小（高端地址）
         mov [es:esi+0x1e],eax              ;登记0特权级堆栈基地址到TCB
         mov ebx,0xffffe                    ;段界限（向下扩展段）
         mov ecx,0x00c09600                 ;4KB粒度，可读写，DPL=0
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         ;or cx,0000_0000_0000_0000          ;RPL=0，无需OR操作
         mov [es:esi+0x22],cx               ;登记0特权级堆栈选择子到TCB
         mov dword [es:esi+0x24],0          ;登记0特权级堆栈初始ESP=0到TCB

         ;创建1特权级堆栈——用于从Ring3切换到Ring1时由CPU自动加载
         mov ecx,4096
         mov eax,ecx                        ;为生成堆栈高端地址做准备
         mov [es:esi+0x28],ecx
         shr [es:esi+0x28],12               ;登记1特权级堆栈尺寸到TCB（以4KB为单位）
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;堆栈基地址=高端地址
         mov [es:esi+0x2c],eax              ;登记1特权级堆栈基地址到TCB
         mov ebx,0xffffe                    ;段界限
         mov ecx,0x00c0b600                 ;4KB粒度，可读写，DPL=1
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0001          ;设置选择子的RPL=1
         mov [es:esi+0x30],cx               ;登记1特权级堆栈选择子到TCB
         mov dword [es:esi+0x32],0          ;登记1特权级堆栈初始ESP=0到TCB

         ;创建2特权级堆栈——用于从Ring3切换到Ring2时由CPU自动加载
         mov ecx,4096
         mov eax,ecx                        ;为生成堆栈高端地址做准备
         mov [es:esi+0x36],ecx
         shr [es:esi+0x36],12               ;登记2特权级堆栈尺寸到TCB（以4KB为单位）
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;堆栈基地址=高端地址
         mov [es:esi+0x3a],ecx              ;登记2特权级堆栈基地址到TCB
         mov ebx,0xffffe                    ;段界限
         mov ecx,0x00c0d600                 ;4KB粒度，可读写，DPL=2
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0010          ;设置选择子的RPL=2
         mov [es:esi+0x3e],cx               ;登记2特权级堆栈选择子到TCB
         mov dword [es:esi+0x40],0          ;登记2特权级堆栈初始ESP=0到TCB

         ;在GDT中登记LDT描述符——LDT本身作为系统段需要在GDT中有描述符
         mov eax,[es:esi+0x0c]              ;LDT的起始线性地址
         movzx ebx,word [es:esi+0x0a]       ;LDT段界限
         mov ecx,0x00408200                 ;LDT描述符（系统段类型0x2），DPL=0
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [es:esi+0x10],cx               ;登记LDT选择子到TCB中（偏移0x10）

         ;创建用户程序的TSS（任务状态段，最小104字节）
         mov ecx,104                        ;TSS基本尺寸=104字节
         mov [es:esi+0x12],cx
         dec word [es:esi+0x12]             ;登记TSS界限值=103到TCB（偏移0x12）
         call sys_routine_seg_sel:allocate_memory
         mov [es:esi+0x14],ecx              ;登记TSS基地址到TCB（偏移0x14）

         ;登记TSS表格内容——填充TSS的104字节结构
         mov word [es:ecx+0],0              ;偏移0：反向链(backlink)=0（无前驱任务）

         mov edx,[es:esi+0x24]              ;从TCB取0特权级堆栈初始ESP
         mov [es:ecx+4],edx                 ;写入TSS偏移4：ESP0

         mov dx,[es:esi+0x22]               ;从TCB取0特权级堆栈段选择子
         mov [es:ecx+8],dx                  ;写入TSS偏移8：SS0

         mov edx,[es:esi+0x32]              ;从TCB取1特权级堆栈初始ESP
         mov [es:ecx+12],edx                ;写入TSS偏移12：ESP1

         mov dx,[es:esi+0x30]               ;从TCB取1特权级堆栈段选择子
         mov [es:ecx+16],dx                 ;写入TSS偏移16：SS1

         mov edx,[es:esi+0x40]              ;从TCB取2特权级堆栈初始ESP
         mov [es:ecx+20],edx                ;写入TSS偏移20：ESP2

         mov dx,[es:esi+0x3e]               ;从TCB取2特权级堆栈段选择子
         mov [es:ecx+24],dx                 ;写入TSS偏移24：SS2

         mov dx,[es:esi+0x10]               ;从TCB取LDT选择子
         mov [es:ecx+96],dx                 ;写入TSS偏移96：LDT选择子

         mov dx,[es:esi+0x12]               ;从TCB取TSS界限值（复用为I/O位图偏移）
         mov [es:ecx+102],dx                ;写入TSS偏移102：I/O许可位图基地址

         mov word [es:ecx+100],0            ;偏移100：T=0（不触发调试陷阱）

         mov dword [es:ecx+28],0            ;偏移28：CR3=0（未启用分页，PDBR无意义）

         ;访问用户程序头部，获取数据填充TSS的执行上下文
         mov ebx,[ebp+11*4]                 ;从堆栈中取得TCB的基地址
         mov edi,[es:ebx+0x06]              ;用户程序加载的基地址（线性地址）

         mov edx,[es:edi+0x10]              ;从头部获取程序入口点（偏移0x10:prgentry）
         mov [es:ecx+32],edx                ;写入TSS偏移32：EIP（任务恢复时从此执行）

         mov dx,[es:edi+0x14]               ;从头部获取代码段选择子（已重定位为LDT选择子）
         mov [es:ecx+76],dx                 ;写入TSS偏移76：CS

         mov dx,[es:edi+0x08]               ;从头部获取堆栈段选择子
         mov [es:ecx+80],dx                 ;写入TSS偏移80：SS

         mov dx,[es:edi+0x04]               ;从头部获取数据段选择子（指向头部段）
         mov word [es:ecx+84],dx            ;写入TSS偏移84：DS（初始指向程序头部段）

         mov word [es:ecx+72],0             ;TSS偏移72：ES=0（任务启动后自行设置）

         mov word [es:ecx+88],0             ;TSS偏移88：FS=0

         mov word [es:ecx+92],0             ;TSS偏移92：GS=0

         pushfd                             ;将当前EFLAGS压栈
         pop edx                            ;弹出到EDX（获取当前EFLAGS值）

         mov dword [es:ecx+36],edx          ;写入TSS偏移36：EFLAGS（继承当前标志状态）

         ;在GDT中登记TSS描述符——TSS作为系统段也需要在GDT中有描述符
         mov eax,[es:esi+0x14]              ;TSS的起始线性地址
         movzx ebx,word [es:esi+0x12]       ;TSS段界限=103
         mov ecx,0x00408900                 ;TSS描述符（系统段类型0x9=可用TSS），DPL=0
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [es:esi+0x18],cx               ;登记TSS选择子到TCB（偏移0x18）

         pop es                             ;恢复到调用此过程前的es段
         pop ds                             ;恢复到调用此过程前的ds段

         popad

         ret 8                              ;返回并丢弃调用前压入的2个参数（共8字节）

;-------------------------------------------------------------------------------
append_to_tcb_link:                         ;在TCB链上追加任务控制块
                                            ;输入：ECX=TCB线性基地址
                                            ;遍历链表找到末尾节点，将新TCB追加在后面
         push eax
         push edx
         push ds
         push es

         mov eax,core_data_seg_sel          ;令DS指向内核数据段（访问tcb_chain头指针）
         mov ds,eax
         mov eax,mem_0_4_gb_seg_sel         ;令ES指向0..4GB段（访问TCB内存）
         mov es,eax

         mov dword [es: ecx+0x00],0         ;新TCB的next指针清零——标记为链表末尾

         mov eax,[tcb_chain]                ;取TCB链表头指针
         or eax,eax                         ;链表为空（头指针=0）？
         jz .notcb                          ;是，直接将新TCB设为链表头

  .searc:
         mov edx,eax                        ;edx=当前遍历节点
         mov eax,[es: edx+0x00]             ;eax=当前节点的next指针
         or eax,eax                         ;next=0？即到达链表末尾？
         jnz .searc                         ;未到末尾，继续遍历

         mov [es: edx+0x00],ecx             ;找到末尾节点，将新TCB挂在其后
         jmp .retpc

  .notcb:
         mov [tcb_chain],ecx                ;空链表：直接令头指针指向新TCB
         
  .retpc:
         pop es
         pop ds
         pop edx
         pop eax
         
         ret
         
;-------------------------------------------------------------------------------
start:                                      ;内核入口点——由引导程序跳转到此处
         mov ecx,core_data_seg_sel          ;令DS指向核心数据段
         mov ds,ecx

         mov ecx,mem_0_4_gb_seg_sel         ;令ES指向4GB平坦数据段
         mov es,ecx

         mov ebx,message_1
         call sys_routine_seg_sel:put_string ;显示进入保护模式的欢迎信息

         ;显示处理器品牌信息（使用CPUID扩展功能0x80000002-0x80000004）
         mov eax,0x80000002                 ;CPUID扩展功能：处理器品牌字符串第1部分
         cpuid
         mov [cpu_brand + 0x00],eax         ;每次CPUID返回16字节（EAX+EBX+ECX+EDX）
         mov [cpu_brand + 0x04],ebx
         mov [cpu_brand + 0x08],ecx
         mov [cpu_brand + 0x0c],edx

         mov eax,0x80000003                 ;处理器品牌字符串第2部分
         cpuid
         mov [cpu_brand + 0x10],eax
         mov [cpu_brand + 0x14],ebx
         mov [cpu_brand + 0x18],ecx
         mov [cpu_brand + 0x1c],edx

         mov eax,0x80000004                 ;处理器品牌字符串第3部分
         cpuid
         mov [cpu_brand + 0x20],eax
         mov [cpu_brand + 0x24],ebx
         mov [cpu_brand + 0x28],ecx
         mov [cpu_brand + 0x2c],edx

         mov ebx,cpu_brnd0                  ;显示处理器品牌信息前缀
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brand                  ;显示处理器品牌字符串（共48字节）
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brnd1                  ;显示后缀换行
         call sys_routine_seg_sel:put_string

         ;以下安装系统调用门——特权级之间的控制转移必须通过门
         mov edi,salt                       ;C-SALT表的起始位置
         mov ecx,salt_items                 ;C-SALT表的条目数量
  .b3:
         push ecx
         mov eax,[edi+256]                  ;该条目入口点的32位偏移地址（名称后紧跟）
         mov bx,[edi+260]                   ;该条目入口点的段选择子
         mov cx,1_11_0_1100_000_00000B      ;调用门描述符属性：DPL=3（Ring3可调用），
                                            ;类型=1100（32位调用门），0个参数
         call sys_routine_seg_sel:make_gate_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [edi+260],cx                   ;将返回的调用门选择子回填到C-SALT中
         add edi,salt_item_len              ;指向下一个C-SALT条目
         pop ecx
         loop .b3

         ;通过调用门测试——验证门是否正常工作
         mov ebx,message_2
         call far [salt_1+256]              ;通过调用门显示信息（偏移量被门机制忽略）

         ;============= 创建程序管理器任务 =============
         ;为程序管理器分配TSS并填写必要字段
         mov ecx,104                        ;TSS最小尺寸=104字节
         call sys_routine_seg_sel:allocate_memory
         mov [prgman_tss+0x00],ecx          ;保存程序管理器的TSS基地址

         ;程序管理器的TSS只需最少的字段（它运行在Ring0，结构较简单）
         mov word [es:ecx+96],0             ;LDT选择子=0：程序管理器不需要LDT
         mov word [es:ecx+102],103          ;I/O位图偏移=103：等于TSS界限，表示无I/O位图
                                            ;Ring0本身就有所有I/O端口访问权限
         mov word [es:ecx+0],0              ;反向链(backlink)=0
         mov dword [es:ecx+28],0            ;CR3(PDBR)=0（未启用分页）
         mov word [es:ecx+100],0            ;T=0（不触发调试陷阱）
                                            ;不需要Ring0/1/2堆栈——程序管理器已在Ring0，
                                            ;不存在向更高特权级转移的情况

         ;创建TSS描述符并安装到GDT中
         mov eax,ecx                        ;TSS的起始线性地址
         mov ebx,103                        ;段界限=103（104字节-1）
         mov ecx,0x00408900                 ;TSS描述符：类型0x9=可用TSS，DPL=0
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [prgman_tss+0x04],cx           ;保存程序管理器的TSS描述符选择子

         ;LTR指令——将TSS选择子加载到任务寄存器TR
         ;TR中的内容标识当前正在执行的任务。加载后CPU才能在任务切换时
         ;自动将当前状态保存到正确的TSS中。这是”补办手续”——程序管理器
         ;在此之前已经在执行了，只是没有TSS来标识它的身份。
         ltr cx                             ;加载任务寄存器——程序管理器正式成为”当前任务”

         ;===== 第一次任务切换：使用CALL far（可嵌套，可IRETD返回）=====
         mov ebx,prgman_msg1
         call sys_routine_seg_sel:put_string ;显示：将用CALL指令切换到用户任务

         mov ecx,0x46                       ;分配0x46字节作为新任务的TCB
         call sys_routine_seg_sel:allocate_memory
         call append_to_tcb_link            ;将此TCB添加到TCB链中

         push dword 50                      ;用户程序位于逻辑50扇区
         push ecx                           ;压入任务控制块起始线性地址

         call load_relocate_program         ;加载并重定位用户程序（创建LDT、TSS等）

         call far [es:ecx+0x14]             ;★ CALL far到用户任务的TSS选择子
                                            ;CPU自动执行硬件任务切换：
                                            ;  1. 保存当前（程序管理器）状态到其TSS
                                            ;  2. 加载用户任务TSS中的状态
                                            ;  3. 设置NT=1，写入backlink
                                            ;用户任务结束后IRETD返回到此处继续执行

         ;===== 第二次任务切换：使用JMP far（不可嵌套，必须JMP回来）=====
         mov ebx,prgman_msg2
         call sys_routine_seg_sel:put_string ;显示：CALL任务已返回，将用JMP切换新任务

         mov ecx,0x46                       ;再次分配TCB
         call sys_routine_seg_sel:allocate_memory
         call append_to_tcb_link            ;将此TCB添加到TCB链中

         push dword 50                      ;同样加载逻辑50扇区的用户程序
         push ecx                           ;压入任务控制块起始线性地址

         call load_relocate_program         ;加载并重定位用户程序

         jmp far [es:ecx+0x14]             ;★ JMP far到用户任务的TSS选择子
                                            ;CPU自动执行硬件任务切换：
                                            ;  1. 保存当前状态到当前TSS
                                            ;  2. 加载用户任务TSS中的状态
                                            ;  3. 不设置NT标志，不写backlink
                                            ;用户任务必须通过JMP far切换回程序管理器

         ;===== 两个用户任务都已结束，程序管理器重新获得控制 =====
         mov ebx,prgman_msg3
         call sys_routine_seg_sel:put_string ;显示：重新获得控制，系统停机

         hlt                                ;处理器停机，等待外部中断或重启
            
core_code_end:

;-------------------------------------------------------------------------------
SECTION core_trail
;-------------------------------------------------------------------------------
core_end: