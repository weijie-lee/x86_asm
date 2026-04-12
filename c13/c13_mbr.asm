         ;代码清单13-1
         ;文件名：c13_mbr.asm
         ;文件说明：硬盘主引导扇区代码（高级MBR，含动态GDT构造）
         ;创建日期：2011-10-28 22:35
         ;
         ;=========================== 扩展知识 =======================================
         ;
         ; 【三级加载架构：MBR -> 内核(Kernel) -> 用户程序(User Program)】
         ;   整个系统的启动流程分为三个阶段：
         ;   1) BIOS 加载 MBR（本文件）到 0x7C00 并执行
         ;   2) MBR 从硬盘扇区1开始，将内核加载到物理地址 0x40000
         ;   3) 内核运行后，再从磁盘加载用户程序到动态分配的内存中
         ;   这种分层设计使得 MBR 只需关心内核加载，而内核负责更复杂的
         ;   用户程序加载、重定位和运行管理。
         ;
         ; 【动态描述符构造：为什么要手工拼装8字节描述符？】
         ;   x86 保护模式的段描述符为8字节，但其中的基地址、段界限、属性
         ;   字段并非连续存放，而是被拆散到不同的位位置。因此需要通过
         ;   位移、掩码、旋转等操作手工拼装。make_gdt_descriptor 例程
         ;   使用了以下关键指令：
         ;
         ;   - bswap reg32：字节交换指令（80486+引入）
         ;     将32位寄存器中的字节顺序反转：
         ;       [B3 B2 B1 B0] -> [B0 B1 B2 B3]
         ;     用途：将已经通过 rol 旋转到特定位置的基地址高位字节
         ;     重新排列到描述符所要求的最终布局。
         ;
         ;   - rol reg, imm（循环左移 / Rotate Left）：
         ;     将寄存器的所有位向左循环移动，最高位移出后回到最低位。
         ;     与 shl 不同，rol 不会丢失任何位，是"旋转"而非"移位"。
         ;     在描述符构造中，rol edx,8 将基地址的高16位旋转到正确位置，
         ;     再配合 bswap 完成最终装配。
         ;
         ; 【内核头部结构（位于内核映像的起始处）】
         ;   偏移  字段             说明
         ;   0x00  core_length      内核程序总长度（字节）
         ;   0x04  sys_routine_seg  系统公用例程段的汇编起始地址
         ;   0x08  core_data_seg    核心数据段的汇编起始地址
         ;   0x0C  core_code_seg    核心代码段的汇编起始地址
         ;   0x10  core_entry       入口点：低双字=段内偏移(EIP)，高字=段选择子(CS)
         ;   MBR 读取这些字段来计算各段的基地址和界限，然后构造GDT描述符。
         ;
         ; 【jmp far [edi+0x10]：间接远跳转】
         ;   这是一条使用内存操作数的远跳转指令。处理器从 [edi+0x10] 处
         ;   读取6个字节：低4字节作为 EIP（段内偏移），高2字节作为 CS（段选择子）。
         ;   执行后，CS:EIP 同时被更新，控制权从 MBR 转移到内核代码段入口。
         ;   这种间接跳转方式避免了硬编码地址，使内核可以自描述其入口点。
         ;
         ;========================================================================

         core_base_address equ 0x00040000   ;常数，内核加载的起始物理内存地址
         core_start_sector equ 0x00000001   ;常数，内核在硬盘上的起始逻辑扇区号

         mov ax,cs                          ;用当前代码段（0x0000）初始化堆栈段
         mov ss,ax
         mov sp,0x7c00                      ;栈指针指向0x7C00，向下增长（不覆盖MBR代码）
      
         ;计算GDT所在的逻辑段地址（实模式下需要 段:偏移 寻址）
         mov eax,[cs:pgdt+0x7c00+0x02]      ;从pgdt结构中取出GDT的32位物理地址
         xor edx,edx
         mov ebx,16
         div ebx                            ;物理地址 / 16 = 段地址(商)...偏移(余数)

         mov ds,eax                         ;令DS指向GDT所在的逻辑段
         mov ebx,edx                        ;EBX = GDT在该段内的起始偏移

         ;跳过0#号描述符的槽位（0#描述符是处理器要求的空描述符，不可使用）
         ;创建1#描述符（选择子0x08），这是一个数据段，对应0~4GB的线性地址空间
         mov dword [ebx+0x08],0x0000ffff    ;低32位：基地址低16位=0x0000，段界限低16位=0xFFFF
         mov dword [ebx+0x0c],0x00cf9200    ;高32位：G=1(4KB粒度)，D/B=1(32位)，可读写数据段

         ;创建2#描述符（选择子0x10），保护模式下MBR自身的代码段描述符
         mov dword [ebx+0x10],0x7c0001ff    ;基地址=0x00007C00，段界限=0x1FF（512字节）
         mov dword [ebx+0x14],0x00409800    ;G=0(字节粒度)，D=1(32位)，只执行代码段

         ;创建3#描述符（选择子0x18），保护模式下的堆栈段描述符
         mov dword [ebx+0x18],0x7c00fffe    ;基地址=0x00007C00，界限=0xFFFFE（向下扩展）
         mov dword [ebx+0x1c],0x00cf9600    ;G=1(4KB粒度)，E=1(向下扩展)，可读写

         ;创建4#描述符（选择子0x20），显示缓冲区段描述符（用于直接操作显存）
         mov dword [ebx+0x20],0x80007fff    ;基地址=0x000B8000，界限=0x7FFF（32KB显存）
         mov dword [ebx+0x24],0x0040920b    ;G=0(字节粒度)，可读写数据段

         ;初始化描述符表寄存器GDTR（6字节结构：2字节界限 + 4字节基地址）
         mov word [cs:pgdt+0x7c00],39      ;5个描述符×8字节-1 = 39，即GDT界限

         lgdt [cs:pgdt+0x7c00]              ;加载GDTR，处理器从此知道GDT在哪里

         in al,0x92                         ;读取南桥芯片端口0x92（系统控制端口A）
         or al,0000_0010B                   ;将bit1置1
         out 0x92,al                        ;打开A20地址线，允许访问1MB以上内存

         cli                                ;关中断——保护模式的中断机制尚未建立

         mov eax,cr0
         or eax,1
         mov cr0,eax                        ;将CR0的PE位(bit0)置1，开启保护模式

         ;以下进入保护模式... ...
         jmp dword 0x0010:flush             ;远跳转：选择子0x10(2#代码段) + 偏移flush
                                            ;此跳转刷新流水线并串行化处理器，清除实模式残留
         [bits 32]                          ;从此开始生成32位代码
  flush:
         mov eax,0x0008                     ;加载1#描述符选择子(0~4GB数据段)到DS
         mov ds,eax

         mov eax,0x0018                     ;加载3#描述符选择子(堆栈段)到SS
         mov ss,eax
         xor esp,esp                        ;栈指针归零，从段基址0x7C00处向下增长
         
         ;以下加载系统核心程序到物理内存 core_base_address(0x40000) 处
         mov edi,core_base_address          ;EDI = 内核加载的目标物理地址

         mov eax,core_start_sector          ;EAX = 内核起始逻辑扇区号
         mov ebx,edi                        ;EBX = 目标缓冲区地址
         call read_hard_disk_0              ;先读取第一个扇区（含内核头部）

         ;根据内核头部的 core_length 字段判断整个内核有多大
         mov eax,[edi]                      ;从头部偏移0x00读取内核总长度（字节）
         xor edx,edx
         mov ecx,512                        ;每扇区512字节
         div ecx                            ;EAX=完整扇区数，EDX=余数

         or edx,edx
         jnz @1                             ;有余数说明还需要多读一个扇区
         dec eax                            ;无余数时减去已读的第一个扇区
   @1:
         or eax,eax                         ;考虑内核总长度≤512字节的特殊情况
         jz setup                           ;若EAX=0，说明已经读完，跳到安装阶段

         ;读取剩余的扇区
         mov ecx,eax                        ;ECX = 剩余需读取的扇区数（LOOP计数器）
         mov eax,core_start_sector
         inc eax                            ;从下一个逻辑扇区开始接着读
   @2:
         call read_hard_disk_0              ;读一个扇区，EBX自动后移512字节
         inc eax                            ;指向下一个逻辑扇区
         loop @2                            ;循环读，直到读完整个内核

 setup:
         ;=== 安装阶段：根据内核头部信息，动态构造GDT描述符 ===
         mov esi,[0x7c00+pgdt+0x02]         ;通过0~4GB数据段访问pgdt，取得GDT物理基地址
                                            ;（不能用CS段前缀，因为CS现在是32位代码段）

         ;建立5#描述符（选择子0x28）：公用例程段（sys_routine）描述符
         mov eax,[edi+0x04]                 ;从内核头部取公用例程段的汇编起始地址
         mov ebx,[edi+0x08]                 ;取核心数据段汇编起始地址（作为例程段的结尾）
         sub ebx,eax
         dec ebx                            ;段界限 = 数据段起始 - 例程段起始 - 1
         add eax,edi                        ;线性基地址 = 汇编地址 + 内核加载基址(0x40000)
         mov ecx,0x00409800                 ;属性：G=0(字节粒度)，D=1(32位)，只执行代码段
         call make_gdt_descriptor           ;调用拼装例程，返回 EDX:EAX = 完整描述符
         mov [esi+0x28],eax                 ;将描述符低32位写入GDT第5个槽位
         mov [esi+0x2c],edx                 ;将描述符高32位写入GDT

         ;建立6#描述符（选择子0x30）：核心数据段描述符
         mov eax,[edi+0x08]                 ;核心数据段起始汇编地址
         mov ebx,[edi+0x0c]                 ;核心代码段汇编起始地址（作为数据段的结尾）
         sub ebx,eax
         dec ebx                            ;核心数据段界限
         add eax,edi                        ;核心数据段线性基地址
         mov ecx,0x00409200                 ;属性：G=0(字节粒度)，D=1(32位)，可读写数据段
         call make_gdt_descriptor
         mov [esi+0x30],eax                 ;写入GDT第6个槽位
         mov [esi+0x34],edx

         ;建立7#描述符（选择子0x38）：核心代码段描述符
         mov eax,[edi+0x0c]                 ;核心代码段起始汇编地址
         mov ebx,[edi+0x00]                 ;内核程序总长度（作为代码段的结尾）
         sub ebx,eax
         dec ebx                            ;核心代码段界限
         add eax,edi                        ;核心代码段线性基地址
         mov ecx,0x00409800                 ;属性：字节粒度，只执行代码段
         call make_gdt_descriptor
         mov [esi+0x38],eax                 ;写入GDT第7个槽位
         mov [esi+0x3c],edx

         mov word [0x7c00+pgdt],63          ;更新GDT界限：8个描述符×8字节-1 = 63

         lgdt [0x7c00+pgdt]                 ;重新加载GDTR，使新描述符生效

         jmp far [edi+0x10]                 ;间接远跳转：从内核头部读取入口点
                                            ;[edi+0x10]低4字节=EIP，[edi+0x14]高2字节=CS
                                            ;控制权从此转移到内核代码段入口
       
;-------------------------------------------------------------------------------
read_hard_disk_0:                        ;从硬盘读取一个逻辑扇区（LBA模式）
                                         ;输入：EAX=逻辑扇区号（28位LBA地址）
                                         ;      DS:EBX=目标缓冲区地址
                                         ;返回：EBX=EBX+512（指向下一个可用位置）
         push eax
         push ecx
         push edx

         push eax

         mov dx,0x1f2
         mov al,1
         out dx,al                       ;端口0x1F2：设置读取的扇区数=1

         inc dx                          ;端口0x1F3
         pop eax
         out dx,al                       ;写入LBA地址的第0~7位

         inc dx                          ;端口0x1F4
         mov cl,8
         shr eax,cl
         out dx,al                       ;写入LBA地址的第8~15位

         inc dx                          ;端口0x1F5
         shr eax,cl
         out dx,al                       ;写入LBA地址的第16~23位

         inc dx                          ;端口0x1F6
         shr eax,cl
         or al,0xe0                      ;高4位=1110：第一硬盘，LBA模式；低4位=LBA地址第24~27位
         out dx,al

         inc dx                          ;端口0x1F7（命令端口）
         mov al,0x20                     ;0x20=读命令(READ SECTORS)
         out dx,al

  .waits:
         in al,dx                        ;读端口0x1F7（状态端口）
         and al,0x88                     ;只保留BSY位(bit7)和DRQ位(bit3)
         cmp al,0x08                     ;BSY=0且DRQ=1表示数据就绪
         jnz .waits                      ;否则继续轮询等待

         mov ecx,256                     ;一个扇区=512字节=256个字（word）
         mov dx,0x1f0                    ;端口0x1F0：数据端口（16位）
  .readw:
         in ax,dx                        ;每次读取一个字（2字节）
         mov [ebx],ax                    ;存入目标缓冲区
         add ebx,2                       ;缓冲区指针后移2字节
         loop .readw                     ;循环256次，读完整个扇区

         pop edx
         pop ecx
         pop eax

         ret

;-------------------------------------------------------------------------------
make_gdt_descriptor:                     ;构造GDT段描述符（将分散的字段拼装成8字节描述符）
                                         ;输入：EAX=线性基地址（32位）
                                         ;      EBX=段界限（20位，低20位有效）
                                         ;      ECX=属性（各属性位在原始位置，其余位清零）
                                         ;返回：EDX:EAX=完整的8字节描述符
                                         ;
                                         ;描述符格式（8字节）：
                                         ;  EAX（低32位）= [基地址15:0][界限15:0]
                                         ;  EDX（高32位）= [基地址31:24][属性][界限19:16][基地址23:16]
         mov edx,eax                     ;EDX暂存基地址的完整副本
         shl eax,16                      ;EAX左移16位：基地址低16位移到EAX高16位
         or ax,bx                        ;EAX低16位填入段界限低16位 → EAX(低32位)构造完毕

         and edx,0xffff0000              ;只保留基地址的高16位(bit31~16)
         rol edx,8                       ;循环左移8位：把bit31~24旋转到bit7~0位置
         bswap edx                       ;字节交换(80486+)：[B3,B2,B1,B0]->[B0,B1,B2,B3]
                                         ;效果：基地址bit31~24到EDX最高字节，bit23~16到最低字节

         xor bx,bx                       ;清除BX低16位，保留EBX高16位中的界限bit19~16
         or edx,ebx                      ;装配段界限的高4位(bit19~16)到EDX

         or edx,ecx                      ;装配属性字段（G, D/B, L, AVL, P, DPL, S, TYPE等）

         ret
      
;-------------------------------------------------------------------------------
         pgdt             dw 0              ;GDT界限（2字节），由程序运行时填写
                          dd 0x00007e00      ;GDT的物理基地址：紧接在MBR(0x7C00+512)之后
;-------------------------------------------------------------------------------
         times 510-($-$$) db 0              ;用0填充至第510字节
                          db 0x55,0xaa      ;MBR有效标志（magic number）