         ;代码清单14-1
         ;文件名：c14_core.asm
         ;文件说明：保护模式微型核心程序
         ;创建日期：2011-11-6 18:37

;===============================================================================
;                        扩 展 知 识 注 释 块
;===============================================================================
;
; 【本章概述】
;   本章（第14章）是第13章的重大演进，引入了调用门（Call Gate）、LDT（局部描述
;   符表）、TSS（任务状态段）和特权级（Rings 0-3）等核心概念，实现了硬件级的任
;   务管理与特权级隔离。
;
; ─────────────────────────────────────────────────────────────────────────────
; 【调用门 (Call Gate) — 受控的特权级转移机制】
; ─────────────────────────────────────────────────────────────────────────────
;   为什么需要调用门？
;     运行在 Ring 3（用户态）的代码不能直接 CALL 或 JMP 到 Ring 0（内核态）代
;     码段，否则处理器会产生一般保护异常(#GP)。调用门提供了一种受处理器硬件保护
;     的、从低特权级向高特权级转移控制的合法途径。
;
;   门描述符格式（8字节，安装在GDT或LDT中）：
;     低32位:  [偏移地址15..0 (16位)] [目标代码段选择子 (16位)]
;     高32位:  [偏移地址31..16(16位)] [属性/类型P+DPL+S+TYPE (8位)] [参数个数(5位)+保留(3位)]
;
;   属性字段（以本代码中 1_11_0_1100_000_00000B 为例）：
;     P=1        : 门有效（存在位）
;     DPL=11     : 门的特权级为3（Ring 3代码可以通过此门调用）
;     S=0        : 系统段/门描述符
;     TYPE=1100  : 32位调用门
;     参数=00000 : 0个参数通过栈复制（本程序用寄存器传参）
;
;   make_gate_descriptor 例程：
;     输入 EAX=段内偏移, BX=段选择子, CX=属性
;     将它们组装为 EDX:EAX 格式的完整64位门描述符
;     随后可通过 set_up_gdt_descriptor 安装到GDT中
;
;   调用门的使用：
;     用户程序通过 CALL FAR [选择子:偏移] 发起调用门调用（偏移量会被忽略，
;     处理器从门描述符中取得真正的目标偏移和段选择子）。
;
; ─────────────────────────────────────────────────────────────────────────────
; 【LDT (Local Descriptor Table) — 每任务的局部描述符表】
; ─────────────────────────────────────────────────────────────────────────────
;   GDT是全局的、系统唯一的；LDT是每个任务私有的段描述符表。
;   通过LDT可以让每个任务拥有自己独立的代码段、数据段、堆栈段等。
;
;   选择子中的 TI 位（bit 2）：
;     TI=0 : 从 GDT 中查找描述符
;     TI=1 : 从当前任务的 LDT 中查找描述符
;     本代码在 fill_descriptor_in_ldt 中用 or cx,0000_0000_0000_0100B 设置TI=1
;
;   LLDT 指令：
;     操作数为 GDT 中 LDT 描述符的选择子，加载到 LDTR（LDT寄存器）。
;     处理器随后用 LDTR 定位当前任务的 LDT 基地址和界限。
;     本代码: lldt [ecx+0x10]  ; 从TCB中取LDT选择子并加载
;
;   fill_descriptor_in_ldt 例程：
;     将 EDX:EAX 描述符安装到指定 TCB 对应的 LDT 中。
;     根据 TCB+0x0c 取得 LDT 基地址，TCB+0x0a 取得 LDT 当前界限。
;     安装后更新界限值，并构造带 TI=1 的选择子返回。
;
; ─────────────────────────────────────────────────────────────────────────────
; 【TSS (Task State Segment) — 任务状态段，最小104字节】
; ─────────────────────────────────────────────────────────────────────────────
;   TSS 是处理器硬件定义的结构，用于保存任务的上下文（寄存器等）。
;   当通过调用门进行特权级切换时，处理器自动从 TSS 中读取目标特权级的栈信息。
;
;   TSS 关键字段偏移（104字节基本结构）：
;     偏移  0 : 反向链接（上一个任务的TSS选择子，用于任务嵌套返回）
;     偏移  4 : ESP0 — Ring 0 堆栈指针
;     偏移  8 : SS0  — Ring 0 堆栈段选择子
;     偏移 12 : ESP1 — Ring 1 堆栈指针
;     偏移 16 : SS1  — Ring 1 堆栈段选择子
;     偏移 20 : ESP2 — Ring 2 堆栈指针
;     偏移 24 : SS2  — Ring 2 堆栈段选择子
;     偏移 28 : CR3  — 页目录基地址（分页时使用）
;     偏移 32 : EIP  — 任务入口点
;     偏移 36 : EFLAGS
;     偏移 40~64 : EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI
;     偏移 72~88 : ES, CS, SS, DS, FS, GS 段选择子
;     偏移 96 : LDT选择子 — 指向该任务的局部描述符表
;     偏移100 : T标志（bit 0）— 调试陷阱位，若T=1则任务切换时触发调试异常
;     偏移102 : I/O位图偏移 — 指向I/O权限位图的起始位置
;
;   LTR 指令：
;     操作数为 GDT 中 TSS 描述符的选择子，加载到 TR（任务寄存器）。
;     处理器由此知道当前任务的 TSS 在内存中的位置。
;     本代码: ltr [ecx+0x18]  ; 从TCB中取TSS选择子并加载
;
;   特权级切换时 TSS 的核心作用：
;     当 Ring 3 代码通过调用门调用 Ring 0 代码时，处理器自动：
;     1. 从当前TSS中读取SS0和ESP0
;     2. 切换到Ring 0的堆栈
;     3. 在Ring 0堆栈上依次压入：调用者SS、调用者ESP、调用者CS、调用者EIP
;     4. 跳转到调用门指定的目标地址执行
;
; ─────────────────────────────────────────────────────────────────────────────
; 【TCB (Task Control Block) — 任务控制块（软件概念，非CPU定义）】
; ─────────────────────────────────────────────────────────────────────────────
;   TCB 是我们自定义的数据结构，用于管理每个任务的各种信息。
;   处理器并不知道 TCB 的存在，它纯粹是操作系统/内核软件层面的抽象。
;
;   TCB 字段布局（本代码中使用的偏移）：
;     +0x00 : 下一个TCB的线性地址（链表指针，0表示链尾）
;     +0x06 : 用户程序加载的线性基地址
;     +0x0a : LDT 界限值
;     +0x0c : LDT 基地址
;     +0x10 : LDT 在GDT中的选择子
;     +0x12 : TSS 界限值
;     +0x14 : TSS 基地址
;     +0x18 : TSS 在GDT中的选择子
;     +0x1a : Ring 0 堆栈尺寸（4KB为单位）
;     +0x1e : Ring 0 堆栈基地址
;     +0x22 : Ring 0 堆栈段选择子
;     +0x24 : Ring 0 堆栈初始ESP
;     +0x28 : Ring 1 堆栈尺寸
;     +0x2c : Ring 1 堆栈基地址
;     +0x30 : Ring 1 堆栈段选择子
;     +0x32 : Ring 1 堆栈初始ESP
;     +0x36 : Ring 2 堆栈尺寸
;     +0x3a : Ring 2 堆栈基地址
;     +0x3e : Ring 2 堆栈段选择子
;     +0x40 : Ring 2 堆栈初始ESP
;     +0x44 : 用户程序头部段选择子
;
;   TCB 链表结构：
;     多个TCB通过 +0x00 偏移处的指针链接成单链表。
;     tcb_chain（在核心数据段中）保存链表头指针。
;     append_to_tcb_link 例程将新TCB追加到链表末尾。
;
; ─────────────────────────────────────────────────────────────────────────────
; 【特权级 (Privilege Levels / Rings 0-3)】
; ─────────────────────────────────────────────────────────────────────────────
;   x86 保护模式提供4个特权级（Ring 0 ~ Ring 3）：
;     Ring 0 : 内核态（最高特权），可执行所有指令，访问所有资源
;     Ring 1 : 通常用于设备驱动（本代码中为1特权级堆栈预留）
;     Ring 2 : 通常用于系统服务（本代码中为2特权级堆栈预留）
;     Ring 3 : 用户态（最低特权），受限执行，不能直接访问内核代码/数据
;
;   三种特权级标识：
;     CPL (Current Privilege Level) : 当前执行代码的特权级，存在CS的低2位
;     DPL (Descriptor Privilege Level) : 描述符中定义的特权级，表示访问该段
;                                        或门所需的最低特权级
;     RPL (Requested Privilege Level) : 选择子低2位，请求者声称的特权级
;
;   特权级检查规则（简化）：
;     数据段访问: CPL <= DPL 且 RPL <= DPL（数值越小特权越高）
;     调用门调用: CPL >= 门DPL（能看到门）且 CPL <= 目标代码段DPL（向高转移）
;
;   本代码中的特权级设置示例：
;     内核代码段/数据段: DPL=0 (Ring 0)
;     用户程序段: DPL=3，选择子RPL=3 (Ring 3)
;     调用门: DPL=3（允许Ring 3代码使用此门调用Ring 0例程）
;
; ─────────────────────────────────────────────────────────────────────────────
; 【retf 模拟调用门返回 — 从Ring 0"假装返回"到Ring 3】
; ─────────────────────────────────────────────────────────────────────────────
;   内核需要首次启动用户程序时，并没有真正的调用门调用发生过，所以我们在栈上
;   手工构造一个"假的"调用门返回现场，然后用 retf 触发特权级切换：
;
;   手工压栈顺序（模拟处理器在调用门调用时保存的返回信息）：
;     push SS   ; 目标（用户）堆栈段选择子（Ring 3的SS）
;     push ESP  ; 目标（用户）堆栈指针（Ring 3的ESP）
;     push CS   ; 目标（用户）代码段选择子（Ring 3的CS）
;     push EIP  ; 目标（用户）代码入口点（Ring 3的EIP）
;     retf      ; 远返回 — 处理器弹出EIP和CS，检测到特权级变化后还会弹出ESP和SS
;
;   执行 retf 后，处理器：
;     1. 弹出 EIP 和 CS → 切换到用户代码段
;     2. 发现 CS 的 RPL (Ring 3) > 当前 CPL (Ring 0)，属于特权级降低的返回
;     3. 继续弹出 ESP 和 SS → 切换到用户堆栈
;     4. CPL 变为 3，正式进入用户态运行
;
; ─────────────────────────────────────────────────────────────────────────────
; 【ret 8 — 返回并清理栈参数】
; ─────────────────────────────────────────────────────────────────────────────
;   ret 8 等价于: 先执行 ret（弹出返回地址），再将 ESP += 8
;   用于清理调用者在 CALL 之前压入栈的参数（本代码中压了2个DWORD = 8字节）。
;   这是被调用者清理栈（callee cleanup）的调用约定。
;   load_relocate_program 的两个参数：逻辑扇区号和TCB基地址各4字节，共8字节。
;
;===============================================================================

         ;以下常量定义部分。内核的大部分内容都应当固定
         ;以下选择子均指向GDT（TI=0），RPL=00，用于Ring 0内核代码访问
         core_code_seg_sel     equ  0x38    ;内核代码段选择子（GDT索引7，DPL=0）
         core_data_seg_sel     equ  0x30    ;内核数据段选择子（GDT索引6，DPL=0）
         sys_routine_seg_sel   equ  0x28    ;系统公共例程代码段的选择子（GDT索引5，DPL=0）
         video_ram_seg_sel     equ  0x20    ;视频显示缓冲区的段选择子（GDT索引4）
         core_stack_seg_sel    equ  0x18    ;内核堆栈段选择子（GDT索引3，DPL=0）
         mem_0_4_gb_seg_sel    equ  0x08    ;整个0-4GB内存的段的选择子（GDT索引1，用于平坦访问）

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
SECTION sys_routine vstart=0                ;系统公共例程代码段（Ring 0，所有例程运行在最高特权级）
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
;构造门的描述符（调用门等）
;调用门描述符格式（8字节 = 64位）：
;  低32位: [偏移15..0 (16位)][段选择子 (16位)]
;  高32位: [偏移31..16 (16位)][P+DPL+S+TYPE (8位)][参数计数5位+保留3位]
;  make_gate_descriptor 将输入的偏移地址、选择子、属性组装成标准的64位门描述符
make_gate_descriptor:                       ;构造门的描述符（调用门等）
                                            ;输入：EAX=门代码在段内偏移地址
                                            ;       BX=门代码所在段的选择子
                                            ;       CX=段类型及属性等（各属
                                            ;          性位都在原始位置）
                                            ;返回：EDX:EAX=完整的描述符
         push ebx
         push ecx

         mov edx,eax
         and edx,0xffff0000                 ;得到偏移地址高16位（放入描述符高双字的高16位）
         or dx,cx                           ;组装属性部分到EDX低16位（含P+DPL+TYPE+参数计数）

         and eax,0x0000ffff                 ;得到偏移地址低16位（放入描述符低双字的低16位）
         shl ebx,16                         ;段选择子左移16位到高半部分
         or eax,ebx                         ;组装段选择子到描述符低双字的高16位

         pop ecx
         pop ebx

         retf                               ;段间返回，返回EDX:EAX=完整的64位门描述符
                             
sys_routine_end:

;===============================================================================
SECTION core_data vstart=0                  ;系统核心的数据段（Ring 0可访问）
;------------------------------------------------------------------------------- 
         pgdt             dw  0             ;用于设置和修改GDT 
                          dd  0

         ram_alloc        dd  0x00100000    ;下次分配内存时的起始地址（从1MB处开始）

         ;符号地址检索表（Symbolic Address Lookup Table）
         ;用于用户程序与内核例程之间的符号链接（重定位时匹配名称→替换为调用门选择子）
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
                          dd  return_point
                          dw  core_code_seg_sel

         salt_item_len   equ $-salt_4
         salt_items      equ ($-salt)/salt_item_len

         message_1        db  '  If you seen this message,that means we '
                          db  'are now in protect mode,and the system '
                          db  'core is loaded,and the video display '
                          db  'routine works perfectly.',0x0d,0x0a,0

         message_2        db  '  System wide CALL-GATE mounted.',0x0d,0x0a,0
                                            ;调用门安装完毕的提示信息
         
         message_3        db  0x0d,0x0a,'  Loading user program...',0
         
         do_status        db  'Done.',0x0d,0x0a,0
         
         message_6        db  0x0d,0x0a,0x0d,0x0a,0x0d,0x0a
                          db  '  User program terminated,control returned.',0

         bin_hex          db '0123456789ABCDEF'
                                            ;put_hex_dword子过程用的查找表 

         core_buf   times 2048 db 0         ;内核用的缓冲区

         esp_pointer      dd 0              ;内核用来临时保存自己的栈指针

         cpu_brnd0        db 0x0d,0x0a,'  ',0
         cpu_brand  times 52 db 0
         cpu_brnd1        db 0x0d,0x0a,0x0d,0x0a,0

         ;任务控制块链（TCB链表头指针，0表示空链表）
         ;每个TCB通过偏移+0x00处的指针链接到下一个TCB
         tcb_chain        dd  0

core_data_end:
               
;===============================================================================
SECTION core_code vstart=0                  ;内核核心代码段（Ring 0特权级）
;-------------------------------------------------------------------------------
;在LDT内安装一个新的描述符
;LDT是每个任务私有的描述符表，与GDT不同，每个任务可以有自己的LDT
;安装后返回的选择子TI位=1（表示从LDT查找），RPL=00
fill_descriptor_in_ldt:                     ;在LDT内安装一个新的描述符
                                            ;输入：EDX:EAX=描述符
                                            ;          EBX=TCB基地址
                                            ;输出：CX=描述符的选择子（TI=1，指向LDT）
         push eax
         push edx
         push edi
         push ds

         mov ecx,mem_0_4_gb_seg_sel
         mov ds,ecx                         ;使用4GB平坦段访问任意线性地址

         mov edi,[ebx+0x0c]                 ;获得LDT基地址（TCB偏移+0x0c存储LDT基地址）

         xor ecx,ecx
         mov cx,[ebx+0x0a]                  ;获得LDT界限（TCB偏移+0x0a存储LDT界限值）
         inc cx                             ;LDT的总字节数，即新描述符的安装偏移地址

         mov [edi+ecx+0x00],eax             ;安装描述符的低32位
         mov [edi+ecx+0x04],edx             ;安装描述符的高32位

         add cx,8
         dec cx                             ;得到新的LDT界限值（原界限+8-1）

         mov [ebx+0x0a],cx                  ;更新LDT界限值到TCB（偏移+0x0a）

         mov ax,cx
         xor dx,dx
         mov cx,8
         div cx                             ;界限值/8 = 最后一个描述符的索引号

         mov cx,ax
         shl cx,3                           ;左移3位构造选择子（索引号×8），并且
         or cx,0000_0000_0000_0100B         ;设置TI位=1（指向LDT而非GDT），RPL=00

         pop ds
         pop edi
         pop edx
         pop eax
     
         ret
      
;-------------------------------------------------------------------------------
;加载并重定位用户程序
;这是本章最核心的过程：为用户程序创建LDT、各特权级堆栈、TSS，并完成符号重定位
;参数通过栈传递（被调用者清理），最后用 ret 8 返回并弹出8字节参数
load_relocate_program:                      ;加载并重定位用户程序
                                            ;输入: PUSH 逻辑扇区号
                                            ;      PUSH 任务控制块基地址
                                            ;输出：无
         pushad
      
         push ds
         push es
      
         mov ebp,esp                        ;为访问通过堆栈传递的参数做准备
                                            ;[ebp+11*4]=TCB基地址, [ebp+12*4]=扇区号
      
         mov ecx,mem_0_4_gb_seg_sel
         mov es,ecx
      
         mov esi,[ebp+11*4]                 ;从堆栈中取得TCB的基地址

         ;以下申请创建LDT所需要的内存
         ;每个任务有自己的LDT，这是与GDT的关键区别
         mov ecx,160                        ;允许安装20个LDT描述符（20×8=160字节）
         call sys_routine_seg_sel:allocate_memory
         mov [es:esi+0x0c],ecx              ;登记LDT基地址到TCB中（TCB偏移+0x0c）
         mov word [es:esi+0x0a],0xffff      ;登记LDT初始的界限到TCB中（0xffff表示空表，+1=0）

         ;以下开始加载用户程序 
         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换DS到内核数据段
       
         mov eax,[ebp+12*4]                 ;从堆栈中取出用户程序起始扇区号 
         mov ebx,core_buf                   ;读取程序头部数据     
         call sys_routine_seg_sel:read_hard_disk_0

         ;以下判断整个程序有多大
         mov eax,[core_buf]                 ;程序尺寸
         mov ebx,eax
         and ebx,0xfffffe00                 ;使之512字节对齐（能被512整除的数低 
         add ebx,512                        ;9位都为0 
         test eax,0x000001ff                ;程序的大小正好是512的倍数吗? 
         cmovnz eax,ebx                     ;不是。使用凑整的结果
      
         mov ecx,eax                        ;实际需要申请的内存数量
         call sys_routine_seg_sel:allocate_memory
         mov [es:esi+0x06],ecx              ;登记程序加载基地址到TCB中
      
         mov ebx,ecx                        ;ebx -> 申请到的内存首地址
         xor edx,edx
         mov ecx,512
         div ecx
         mov ecx,eax                        ;总扇区数 
      
         mov eax,mem_0_4_gb_seg_sel         ;切换DS到0-4GB的段
         mov ds,eax

         mov eax,[ebp+12*4]                 ;起始扇区号 
  .b1:
         call sys_routine_seg_sel:read_hard_disk_0
         inc eax
         loop .b1                           ;循环读，直到读完整个用户程序

         mov edi,[es:esi+0x06]              ;获得程序加载基地址

         ;建立程序头部段描述符（安装到用户任务的LDT中，DPL=3）
         mov eax,edi                        ;程序头部起始线性地址
         mov ebx,[edi+0x04]                 ;段长度
         dec ebx                            ;段界限
         mov ecx,0x0040f200                 ;字节粒度的数据段描述符，特权级3（DPL=11）
         call sys_routine_seg_sel:make_seg_descriptor

         ;安装头部段描述符到LDT中（而非GDT，因为这是用户任务私有的段）
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt

         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3（用户态特权级）
         mov [es:esi+0x44],cx               ;登记程序头部段选择子到TCB（偏移+0x44）
         mov [edi+0x04],cx                  ;同时回填到用户程序头部内
      
         ;建立程序代码段描述符（DPL=3，用户态代码段）
         mov eax,edi
         add eax,[edi+0x14]                 ;代码起始线性地址
         mov ebx,[edi+0x18]                 ;段长度
         dec ebx                            ;段界限
         mov ecx,0x0040f800                 ;字节粒度的代码段描述符，特权级3（DPL=11）
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3（Ring 3用户态）
         mov [edi+0x14],cx                  ;登记代码段选择子到用户程序头部

         ;建立程序数据段描述符（DPL=3，用户态数据段）
         mov eax,edi
         add eax,[edi+0x1c]                 ;数据段起始线性地址
         mov ebx,[edi+0x20]                 ;段长度
         dec ebx                            ;段界限
         mov ecx,0x0040f200                 ;字节粒度的数据段描述符，特权级3（DPL=11）
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3（Ring 3用户态）
         mov [edi+0x1c],cx                  ;登记数据段选择子到用户程序头部

         ;建立程序堆栈段描述符（DPL=3，用户态堆栈——这是Ring 3的堆栈）
         mov ecx,[edi+0x0c]                 ;4KB的倍率
         mov ebx,0x000fffff
         sub ebx,ecx                        ;得到段界限（向下扩展的堆栈段）
         mov eax,4096
         mul ecx
         mov ecx,eax                        ;准备为堆栈分配内存
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;得到堆栈的高端物理地址
         mov ecx,0x00c0f600                 ;4KB粒度的向下扩展堆栈段描述符，DPL=3（Ring 3堆栈）
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3
         mov [edi+0x08],cx                  ;登记Ring 3堆栈段选择子到用户程序头部

         ;重定位SALT（符号地址检索表）
         ;将用户程序中的符号名替换为对应的调用门选择子
         ;用户程序通过调用门（而非直接CALL）来调用内核例程，实现跨特权级调用
         mov eax,mem_0_4_gb_seg_sel         ;这里和前一章不同，头部段描述符
         mov es,eax                         ;已安装，但还没有生效，故只能通
                                            ;过4GB段访问用户程序头部
         mov eax,core_data_seg_sel
         mov ds,eax
      
         cld

         mov ecx,[es:edi+0x24]              ;U-SALT条目数(通过访问4GB段取得) 
         add edi,0x28                       ;U-SALT在4GB段内的偏移 
  .b2: 
         push ecx
         push edi
      
         mov ecx,salt_items
         mov esi,salt
  .b3:
         push edi
         push esi
         push ecx

         mov ecx,64                         ;检索表中，每条目的比较次数 
         repe cmpsd                         ;每次比较4字节 
         jnz .b4
         mov eax,[esi]                      ;若匹配，则esi恰好指向其后的地址
         mov [es:edi-256],eax               ;将字符串改写成偏移地址
         mov ax,[esi+4]
         or ax,0000000000000011B            ;将调用门选择子的RPL设为3
                                            ;以用户程序自己的特权级(Ring 3)使用调用门
                                            ;RPL=3确保用户态代码能通过特权级检查
         mov [es:edi-252],ax                ;回填调用门选择子（带RPL=3）
  .b4:
      
         pop ecx
         pop esi
         add esi,salt_item_len
         pop edi                            ;从头比较 
         loop .b3
      
         pop edi
         add edi,256
         pop ecx
         loop .b2

         mov esi,[ebp+11*4]                 ;从堆栈中取得TCB的基地址

         ;=== 创建各特权级堆栈 ===
         ;当通过调用门从Ring 3切换到Ring 0时，处理器自动从TSS中读取Ring 0的
         ;SS0和ESP0来切换堆栈。因此每个任务必须预先准备好各特权级的堆栈。

         ;创建0特权级堆栈（Ring 0堆栈 — 通过调用门进入内核时使用）
         mov ecx,4096
         mov eax,ecx                        ;为生成堆栈高端地址做准备
         mov [es:esi+0x1a],ecx
         shr dword [es:esi+0x1a],12         ;登记0特权级堆栈尺寸到TCB（以4KB为单位）
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;堆栈必须使用高端地址为基地址（向下扩展）
         mov [es:esi+0x1e],eax              ;登记0特权级堆栈基地址到TCB（偏移+0x1e）
         mov ebx,0xffffe                    ;段长度（界限）
         mov ecx,0x00c09600                 ;4KB粒度，读写，特权级0（DPL=00）
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         ;or cx,0000_0000_0000_0000          ;RPL=0（Ring 0堆栈选择子不需要设置RPL）
         mov [es:esi+0x22],cx               ;登记0特权级堆栈选择子到TCB（偏移+0x22）
         mov dword [es:esi+0x24],0          ;登记0特权级堆栈初始ESP到TCB（偏移+0x24，栈顶）

         ;创建1特权级堆栈（Ring 1堆栈 — 通常用于设备驱动层）
         mov ecx,4096
         mov eax,ecx                        ;为生成堆栈高端地址做准备
         mov [es:esi+0x28],ecx
         shr [es:esi+0x28],12               ;登记1特权级堆栈尺寸到TCB（以4KB为单位）
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;堆栈必须使用高端地址为基地址（向下扩展）
         mov [es:esi+0x2c],eax              ;登记1特权级堆栈基地址到TCB（偏移+0x2c）
         mov ebx,0xffffe                    ;段长度（界限）
         mov ecx,0x00c0b600                 ;4KB粒度，读写，特权级1（DPL=01）
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0001          ;设置选择子的RPL=1（Ring 1）
         mov [es:esi+0x30],cx               ;登记1特权级堆栈选择子到TCB（偏移+0x30）
         mov dword [es:esi+0x32],0          ;登记1特权级堆栈初始ESP到TCB（偏移+0x32）

         ;创建2特权级堆栈（Ring 2堆栈 — 通常用于系统服务层）
         mov ecx,4096
         mov eax,ecx                        ;为生成堆栈高端地址做准备
         mov [es:esi+0x36],ecx
         shr [es:esi+0x36],12               ;登记2特权级堆栈尺寸到TCB（以4KB为单位）
         call sys_routine_seg_sel:allocate_memory
         add eax,ecx                        ;堆栈必须使用高端地址为基地址（向下扩展）
         mov [es:esi+0x3a],ecx              ;登记2特权级堆栈基地址到TCB（偏移+0x3a）
         mov ebx,0xffffe                    ;段长度（界限）
         mov ecx,0x00c0d600                 ;4KB粒度，读写，特权级2（DPL=10）
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;TCB的基地址
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0010          ;设置选择子的RPL=2（Ring 2）
         mov [es:esi+0x3e],cx               ;登记2特权级堆栈选择子到TCB（偏移+0x3e）
         mov dword [es:esi+0x40],0          ;登记2特权级堆栈初始ESP到TCB（偏移+0x40）
      
         ;在GDT中登记LDT描述符
         ;LDT本身的描述符必须安装在GDT中（类型=0x82，系统段描述符）
         ;之后通过LLDT指令加载此选择子，处理器才能找到任务的LDT
         mov eax,[es:esi+0x0c]              ;LDT的起始线性地址（从TCB中获取）
         movzx ebx,word [es:esi+0x0a]       ;LDT段界限（从TCB中获取）
         mov ecx,0x00408200                 ;LDT描述符，特权级0（TYPE=0010，S=0，DPL=00）
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [es:esi+0x10],cx               ;登记LDT选择子到TCB中（偏移+0x10）

         ;=== 创建用户程序的TSS（任务状态段，最小104字节） ===
         ;TSS是处理器硬件定义的结构，在特权级切换时自动读取其中的堆栈信息
         mov ecx,104                        ;TSS的基本尺寸（最小104字节）
         mov [es:esi+0x12],cx               ;（暂存TSS大小）
         dec word [es:esi+0x12]             ;登记TSS界限值到TCB（偏移+0x12，界限=大小-1）
         call sys_routine_seg_sel:allocate_memory
         mov [es:esi+0x14],ecx              ;登记TSS基地址到TCB（偏移+0x14）

         ;=== 填写TSS表格内容 ===
         ;将各特权级堆栈信息从TCB复制到TSS对应的偏移位置
         ;处理器在特权级切换时会自动查阅这些字段
         mov word [es:ecx+0],0              ;TSS偏移0: 反向链接=0（无上一个任务）

         mov edx,[es:esi+0x24]              ;从TCB取Ring 0堆栈初始ESP
         mov [es:ecx+4],edx                 ;写入TSS偏移4: ESP0（Ring 0堆栈指针）

         mov dx,[es:esi+0x22]               ;从TCB取Ring 0堆栈段选择子
         mov [es:ecx+8],dx                  ;写入TSS偏移8: SS0（Ring 0堆栈段选择子）

         mov edx,[es:esi+0x32]              ;从TCB取Ring 1堆栈初始ESP
         mov [es:ecx+12],edx                ;写入TSS偏移12: ESP1（Ring 1堆栈指针）

         mov dx,[es:esi+0x30]               ;从TCB取Ring 1堆栈段选择子
         mov [es:ecx+16],dx                 ;写入TSS偏移16: SS1（Ring 1堆栈段选择子）

         mov edx,[es:esi+0x40]              ;从TCB取Ring 2堆栈初始ESP
         mov [es:ecx+20],edx                ;写入TSS偏移20: ESP2（Ring 2堆栈指针）

         mov dx,[es:esi+0x3e]               ;从TCB取Ring 2堆栈段选择子
         mov [es:ecx+24],dx                 ;写入TSS偏移24: SS2（Ring 2堆栈段选择子）

         mov dx,[es:esi+0x10]               ;从TCB取LDT选择子
         mov [es:ecx+96],dx                 ;写入TSS偏移96: LDT选择子（任务切换时自动加载）

         mov dx,[es:esi+0x12]               ;TSS界限值（同时也作为I/O位图偏移）
         mov [es:ecx+102],dx                ;写入TSS偏移102: I/O位图基地址偏移
                                            ;设为TSS界限值=没有I/O位图（禁止直接I/O）

         mov word [es:ecx+100],0            ;TSS偏移100: T=0（调试陷阱标志关闭）
                                            ;若T=1，任务切换时会触发调试异常(#DB)

         ;在GDT中登记TSS描述符
         ;TSS描述符必须在GDT中（类型=1001，可用的32位TSS）
         ;通过LTR指令加载此选择子到TR寄存器，处理器才能找到当前任务的TSS
         mov eax,[es:esi+0x14]              ;TSS的起始线性地址（从TCB中获取）
         movzx ebx,word [es:esi+0x12]       ;段长度（界限）（从TCB中获取）
         mov ecx,0x00408900                 ;TSS描述符，特权级0（TYPE=1001，S=0，DPL=00）
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [es:esi+0x18],cx               ;登记TSS选择子到TCB（偏移+0x18）

         pop es                             ;恢复到调用此过程前的es段 
         pop ds                             ;恢复到调用此过程前的ds段
      
         popad
      
         ret 8                              ;丢弃调用本过程前压入的参数
                                            ;ret 8 = 先弹出返回地址(ret)，再ESP+=8
                                            ;清理调用者压入的2个DWORD参数（扇区号+TCB地址=8字节）
                                            ;这是被调用者清理栈(callee cleanup)的调用约定
      
;-------------------------------------------------------------------------------
;-------------------------------------------------------------------------------
;在TCB链上追加任务控制块
;TCB链表是软件层面的数据结构，通过单链表管理所有任务
;每个TCB的偏移+0x00存放下一个TCB的线性地址，0表示链表尾部
append_to_tcb_link:                         ;在TCB链上追加任务控制块
                                            ;输入：ECX=TCB线性基地址
         push eax
         push edx
         push ds
         push es
         
         mov eax,core_data_seg_sel          ;令DS指向内核数据段 
         mov ds,eax
         mov eax,mem_0_4_gb_seg_sel         ;令ES指向0..4GB段
         mov es,eax
         
         mov dword [es: ecx+0x00],0         ;当前TCB指针域清零，表示这是链表
                                            ;的最后一个节点（链尾标记）
                                             
         mov eax,[tcb_chain]                ;TCB表头指针
         or eax,eax                         ;链表为空？
         jz .notcb 
         
  .searc:
         mov edx,eax
         mov eax,[es: edx+0x00]
         or eax,eax               
         jnz .searc
         
         mov [es: edx+0x00],ecx
         jmp .retpc
         
  .notcb:       
         mov [tcb_chain],ecx                ;若为空表，直接令表头指针指向TCB
         
  .retpc:
         pop es
         pop ds
         pop edx
         pop eax
         
         ret
         
;-------------------------------------------------------------------------------
;-------------------------------------------------------------------------------
;内核入口点 — 此时CPL=0（Ring 0），运行在最高特权级
start:
         mov ecx,core_data_seg_sel          ;使ds指向核心数据段 
         mov ds,ecx

         mov ebx,message_1                    
         call sys_routine_seg_sel:put_string
                                         
         ;显示处理器品牌信息 
         mov eax,0x80000002
         cpuid
         mov [cpu_brand + 0x00],eax
         mov [cpu_brand + 0x04],ebx
         mov [cpu_brand + 0x08],ecx
         mov [cpu_brand + 0x0c],edx
      
         mov eax,0x80000003
         cpuid
         mov [cpu_brand + 0x10],eax
         mov [cpu_brand + 0x14],ebx
         mov [cpu_brand + 0x18],ecx
         mov [cpu_brand + 0x1c],edx

         mov eax,0x80000004
         cpuid
         mov [cpu_brand + 0x20],eax
         mov [cpu_brand + 0x24],ebx
         mov [cpu_brand + 0x28],ecx
         mov [cpu_brand + 0x2c],edx

         mov ebx,cpu_brnd0                  ;显示处理器品牌信息 
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brand
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brnd1
         call sys_routine_seg_sel:put_string

         ;以下开始安装为整个系统服务的调用门
         ;调用门是Ring 3代码调用Ring 0内核例程的唯一合法途径
         ;特权级之间的控制转移必须使用门（处理器硬件强制要求）
         mov edi,salt                       ;C-SALT表的起始位置（内核符号表）
         mov ecx,salt_items                 ;C-SALT表的条目数量
  .b3:
         push ecx
         mov eax,[edi+256]                  ;该条目入口点的32位偏移地址
         mov bx,[edi+260]                   ;该条目入口点的段选择子
         mov cx,1_11_0_1100_000_00000B      ;特权级3的调用门属性:
                                            ;  P=1（门有效）
                                            ;  DPL=11（Ring 3代码可以使用此门）
                                            ;  S=0（系统段/门描述符）
                                            ;  TYPE=1100（32位调用门）
                                            ;  参数=00000（0个栈参数，用寄存器传参）
         call sys_routine_seg_sel:make_gate_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [edi+260],cx                   ;将返回的门描述符选择子回填到SALT表中
         add edi,salt_item_len              ;指向下一个C-SALT条目
         pop ecx
         loop .b3

         ;对门进行测试（通过调用门调用内核的put_string例程）
         mov ebx,message_2
         call far [salt_1+256]              ;通过调用门显示信息（偏移量将被忽略，
                                            ;处理器从门描述符中取得真正的目标地址）
      
         mov ebx,message_3
         call sys_routine_seg_sel:put_string ;在内核中调用例程不需要通过门
                                            ;（CPL=0，可以直接段间调用Ring 0代码）

         ;创建任务控制块（TCB）。这不是处理器的要求，而是我们自己的软件抽象
         ;处理器只认识GDT、LDT、TSS，TCB纯粹是内核管理任务的数据结构
         mov ecx,0x46                       ;TCB大小=0x46字节（包含所有任务管理字段）
         call sys_routine_seg_sel:allocate_memory
         call append_to_tcb_link            ;将任务控制块追加到TCB链表

         push dword 50                      ;用户程序位于逻辑50扇区（第一个参数）
         push ecx                           ;压入任务控制块起始线性地址（第二个参数）

         call load_relocate_program         ;加载并重定位用户程序（返回时自动清理8字节参数）
      
         mov ebx,do_status
         call sys_routine_seg_sel:put_string
      
         mov eax,mem_0_4_gb_seg_sel
         mov ds,eax

         ;=== LTR 和 LLDT — 加载任务寄存器和LDT寄存器 ===
         ;LTR: 将TSS选择子加载到TR（任务寄存器），处理器由此知道当前任务的TSS位置
         ;     特权级切换时，处理器自动从TSS中读取目标特权级的SS和ESP
         ;LLDT: 将LDT选择子加载到LDTR（LDT寄存器），处理器由此定位当前任务的LDT
         ;     之后使用TI=1的选择子时，处理器从LDT中查找描述符
         ltr [ecx+0x18]                     ;加载任务状态段（TSS选择子在TCB偏移+0x18）
         lldt [ecx+0x10]                    ;加载LDT（LDT选择子在TCB偏移+0x10）
      
         mov eax,[ecx+0x44]
         mov ds,eax                         ;切换到用户程序头部段（从TCB偏移+0x44获取选择子）

         ;=== 以下假装是从调用门返回 — 从Ring 0"跳入"Ring 3用户态 ===
         ;因为这是首次启动用户程序，并没有真正通过调用门进来过，
         ;所以我们手工在栈上构造一个"假的"调用门返回现场，然后用retf触发特权级切换。
         ;
         ;模拟处理器在调用门调用时自动保存的返回参数：
         ;当处理器通过调用门从Ring 3进入Ring 0时，它会在Ring 0栈上依次压入：
         ;  SS3, ESP3, CS3, EIP3（调用者的堆栈和代码信息）
         ;现在我们反过来，手工压入Ring 3的信息，然后retf"返回"到Ring 3
         push dword [0x08]                  ;压入Ring 3堆栈段选择子（用户程序头部偏移0x08=SS）
         push dword 0                       ;压入Ring 3堆栈指针（ESP=0，栈顶）

         push dword [0x14]                  ;压入Ring 3代码段选择子（用户程序头部偏移0x14=CS）
         push dword [0x10]                  ;压入Ring 3代码入口点（用户程序头部偏移0x10=EIP）

         retf                               ;远返回 — 处理器执行以下操作：
                                            ;1. 弹出EIP和CS → 切换到用户代码段
                                            ;2. 发现CS的RPL(3) > 当前CPL(0)，触发特权级降低的返回
                                            ;3. 继续弹出ESP和SS → 切换到用户堆栈
                                            ;4. CPL变为3，正式进入Ring 3用户态执行

return_point:                               ;用户程序返回点
         ;注意：用户程序通过JMP方式使用调用门@TerminateProgram跳转到这里
         ;JMP通过调用门不改变特权级（与CALL不同），所以到达这里时CPL仍然是3
         ;但下面的代码试图加载DPL=0的core_data_seg_sel，这会导致#GP异常
         ;这是本代码的一个已知问题（实际运行时会触发一般保护异常）
         mov eax,core_data_seg_sel          ;因为c14.asm是以JMP的方式使用调
         mov ds,eax                         ;用门@TerminateProgram，回到这
                                            ;里时，特权级为3，会导致异常。
         mov ebx,message_6
         call sys_routine_seg_sel:put_string

         hlt
            
core_code_end:

;-------------------------------------------------------------------------------
SECTION core_trail
;-------------------------------------------------------------------------------
core_end: