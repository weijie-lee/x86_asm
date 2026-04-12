         ;代码清单17-2
         ;文件名：c17_core.asm
         ;文件说明：保护模式微型核心程序（平坦模型 + IDT + 抢占式多任务）
         ;创建日期：2012-07-12 23:15
;
;============================ 扩展知识 ==========================================
;
; 【IDT（中断描述符表，Interrupt Descriptor Table）】
;   保护模式下，中断向量表被IDT取代。IDT最多256个表项（对应256个中断向量），
;   每个表项8字节，称为"门描述符"（Gate Descriptor）。
;   门类型：
;     - 中断门（Interrupt Gate）：类型值0x8E，执行时自动清除IF标志（关中断），
;       防止中断处理过程被再次中断，适合硬件中断处理。
;     - 陷阱门（Trap Gate）：类型值0x8F，不清除IF标志（允许嵌套中断），
;       适合软件异常和系统调用。
;   IDTR寄存器格式与GDTR相同：16位界限 + 32位线性基地址。
;
; 【8259A PIC 可编程中断控制器初始化（ICW1-ICW4）】
;   IBM PC使用两片8259A级联，共管理15个外部硬件中断（IRQ0-15）。
;   初始化序列：
;     ICW1(0x20/0xa0)：0x11 = 边沿触发 + 级联模式 + 需要ICW4
;     ICW2(0x21/0xa1)：设置中断向量起始号
;       - 主片(Master)：IRQ0-7 → INT 0x20-0x27（避开前32个处理器异常向量）
;       - 从片(Slave) ：IRQ8-15 → INT 0x70-0x77
;     ICW3(0x21/0xa1)：级联关系
;       - 主片：0x04 = 从片连接在IR2引脚
;       - 从片：0x02 = 自身连接在主片的IR2
;     ICW4(0x21/0xa1)：0x01 = 8086模式 + 正常EOI + 非缓冲 + 全嵌套
;
; 【基于RTC的抢占式多任务调度】
;   实时时钟（RTC）每秒产生一次更新结束中断（Update-Ended Interrupt），
;   通过从片IR0（IRQ8）触发INT 0x70中断。
;   调度器 rtm_0x70_interrupt_handle 实现轮转（Round-Robin）调度：
;     ① 找到当前忙任务（状态=0xFFFF），将其从TCB链中拆除并挂到链尾
;     ② 从链首搜索第一个空闲任务（状态=0x0000）
;     ③ 交换状态：忙→空闲(NOT 0xFFFF=0x0000)，空闲→忙(NOT 0x0000=0xFFFF)
;     ④ 通过 jmp far [eax+0x14] 执行硬件任务切换（TSS切换）
;   任务状态编码：
;     0x0000 = 空闲（idle），等待被调度
;     0xFFFF = 忙碌（busy），正在CPU上运行
;     0x3333 = 已终止（terminated），等待回收
;
; 【%macro 宏指令（NASM特性）】
;   alloc_core_linear：在内核地址空间（0x80000000+）分配一个4KB页
;   alloc_user_linear：在用户任务地址空间分配一个4KB页
;   宏在汇编时展开为实际指令，避免重复编写相同的分配代码。
;
; 【SECTION core vstart=0x80040000】
;   平坦模型下，内核代码的虚拟起始地址设为0x80040000。
;   物理上加载在0x00040000处，通过分页映射到0x80040000。
;   高2GB（0x80000000-0xFFFFFFFF）为内核空间，低2GB为用户空间。
;
; 【terminate_current_task —— 任务终止】
;   将当前任务状态设为0x3333（已终止），然后执行HLT进入停机。
;   下一次RTC中断唤醒CPU后，调度器发现当前任务已终止，会跳过它调度其他任务。
;   程序管理器的主循环可以回收已终止任务的内存资源。
;
; 【TLB刷新技巧】
;   - 全量刷新：mov eax,cr3; mov cr3,eax（重新加载CR3导致整个TLB失效）
;     适用于大范围页表修改（如清空用户空间页目录）
;   - 选择性刷新：invlpg [线性地址]（仅使该地址对应的TLB条目失效）
;     适用于单个页表项修改，性能更优（486+指令）
;
;===============================================================================
;-------------------------------------------------------------------------------
         ;以下定义常量
         flat_4gb_code_seg_sel  equ  0x0008      ;平坦模型下的4GB代码段选择子（GDT #1）
         flat_4gb_data_seg_sel  equ  0x0018      ;平坦模型下的4GB数据段选择子（GDT #3）
         idt_linear_address     equ  0x8001f000  ;IDT的线性基地址（高半核空间内）
;-------------------------------------------------------------------------------
         ;以下定义宏（NASM %macro：汇编时文本替换，类似C语言的#define）
         %macro alloc_core_linear 0              ;在内核地址空间中分配一个4KB虚拟页
               mov ebx,[core_tcb+0x06]           ;取内核TCB中的下一可用线性地址
               add dword [core_tcb+0x06],0x1000  ;推进分配指针（+4KB）
               call flat_4gb_code_seg_sel:alloc_inst_a_page ;分配物理页并建立映射
         %endmacro
;-------------------------------------------------------------------------------
         %macro alloc_user_linear 0              ;在用户任务地址空间中分配一个4KB虚拟页
               mov ebx,[esi+0x06]                ;取该任务TCB中的下一可用线性地址
               add dword [esi+0x06],0x1000       ;推进分配指针（+4KB）
               call flat_4gb_code_seg_sel:alloc_inst_a_page ;分配物理页并建立映射
         %endmacro

;===============================================================================
SECTION  core  vstart=0x80040000                 ;内核虚拟地址从0x80040000开始

         ;以下是系统核心的头部，用于加载核心程序（MBR通过头部获取内核尺寸和入口）
         core_length      dd core_end       ;核心程序总字节数#00（MBR据此计算要读多少扇区）

         core_entry       dd start          ;核心代码段入口点#04（MBR通过jmp [0x80040004]跳入）

;-------------------------------------------------------------------------------
         [bits 32]
;-------------------------------------------------------------------------------
         ;字符串显示例程（适用于平坦内存模型，通过调用门从用户态调用）
put_string:                                 ;显示0终止的字符串并移动光标
                                            ;输入：EBX=字符串的线性地址（平坦空间内的绝对地址）

         push ebx
         push ecx

         cli                                ;关中断：操作VGA硬件寄存器期间防止被打断

  .getc:
         mov cl,[ebx]
         or cl,cl                           ;CL与自身相或，若为0则ZF=1
         jz .exit                           ;遇到字符串结束符'\0'，返回
         call put_char                      ;显示单个字符（段内近调用）
         inc ebx                            ;指向下一个字符
         jmp .getc

  .exit:

         sti                                ;开中断：恢复中断响应

         pop ecx
         pop ebx

         retf                               ;段间远返回（因为通过调用门进入）

;-------------------------------------------------------------------------------
put_char:                                   ;在当前光标位置处显示一个字符并推进光标
                                            ;仅用于段内近调用（由put_string调用）
                                            ;输入：CL=字符ASCII码
         pushad                             ;保存所有32位通用寄存器

         ;读取VGA光标当前位置（通过CRTC控制器的索引/数据端口对）
         ;光标位置 = 高8位(寄存器0x0E) | 低8位(寄存器0x0F)
         mov dx,0x3d4                       ;CRTC索引端口
         mov al,0x0e                        ;选择光标位置高8位寄存器
         out dx,al
         inc dx                             ;0x3d5 = CRTC数据端口
         in al,dx                           ;读取光标位置高8位
         mov ah,al                          ;暂存到AH

         dec dx                             ;0x3d4 = 回到索引端口
         mov al,0x0f                        ;选择光标位置低8位寄存器
         out dx,al
         inc dx                             ;0x3d5
         in al,dx                           ;读取光标位置低8位
         mov bx,ax                          ;BX=光标位置（0~1999，对应25行×80列）
         and ebx,0x0000ffff                 ;清除高16位，准备用作32位偏移寻址
         
         cmp cl,0x0d                        ;是回车符CR（\r）？
         jnz .put_0a

         mov ax,bx                          ;回车处理：将光标移到当前行首
         mov bl,80                          ;每行80列
         div bl                             ;AL=行号, AH=列号
         mul bl                             ;AL*80=该行起始位置
         mov bx,ax
         jmp .set_cursor

  .put_0a:
         cmp cl,0x0a                        ;是换行符LF（\n）？
         jnz .put_other
         add bx,80                          ;换行处理：光标下移一行（+80个字符位置）
         jmp .roll_screen

  .put_other:                               ;普通可显示字符处理
         shl bx,1                           ;光标位置*2=显存内的字节偏移（每字符占2字节）
         mov [0x800b8000+ebx],cl            ;写入字符到显存（0xB8000映射到0x800B8000）

         ;光标前进一个字符位置
         shr bx,1                           ;恢复字符位置
         inc bx                             ;前进一个位置

  .roll_screen:
         cmp bx,2000                        ;光标是否超出屏幕？（25行×80列=2000）
         jl .set_cursor                     ;未超出，直接设置新光标位置

         ;滚屏：将第2-25行内容上移到第1-24行，清空最后一行
         cld                                ;DF=0，正向传送
         mov esi,0x800b80a0                 ;源：第2行起始（0x800b8000+160字节）
         mov edi,0x800b8000                 ;目标：第1行起始
         mov ecx,1920                       ;要搬移的双字数=24行×80列×2字节/4=1920 DWORD
         rep movsd                          ;批量搬移
         mov bx,3840                        ;最后一行起始偏移=24*80*2=3840
         mov ecx,80                         ;最后一行80个字符位置
  .cls:
         mov word [0x800b8000+ebx],0x0720   ;用空格+白色属性(0x07)填充
         add bx,2                           ;下一个字符位置（2字节）
         loop .cls

         mov bx,1920                        ;光标设到最后一行首（24*80=1920）

  .set_cursor:
         ;将新光标位置写回VGA CRTC寄存器
         mov dx,0x3d4
         mov al,0x0e                        ;光标位置高8位寄存器
         out dx,al
         inc dx                             ;0x3d5
         mov al,bh                          ;写入高8位
         out dx,al
         dec dx                             ;0x3d4
         mov al,0x0f                        ;光标位置低8位寄存器
         out dx,al
         inc dx                             ;0x3d5
         mov al,bl                          ;写入低8位
         out dx,al
         
         popad                              ;恢复所有32位通用寄存器

         ret                                ;段内近返回（put_char只被put_string段内调用）

;-------------------------------------------------------------------------------
read_hard_disk_0:                           ;从硬盘读取一个逻辑扇区（平坦模型版本）
                                            ;输入：EAX=逻辑扇区号（LBA28）
                                            ;      EBX=目标缓冲区线性地址
                                            ;返回：EBX=EBX+512（自动后移一个扇区大小）
         cli                                ;关中断，防止硬盘I/O操作被打断
         
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
      
         sti                                ;读完后开中断

         retf                               ;段间远返回（通过调用门调用）

;-------------------------------------------------------------------------------
;调试辅助例程：以十六进制显示一个32位双字
put_hex_dword:                              ;在当前光标处以十六进制形式显示一个双字并推进光标
                                            ;输入：EDX=要显示的32位数值
                                            ;输出：无
         pushad

         mov ebx,bin_hex                    ;指向"0123456789ABCDEF"转换表
         mov ecx,8                          ;32位数 = 8个十六进制数字
  .xlt:
         rol edx,4                          ;循环左移4位，最高4位移到最低4位
         mov eax,edx
         and eax,0x0000000f                 ;取最低4位（0-15）
         xlat                               ;AL=DS:[EBX+AL]，查表得到ASCII字符

         push ecx
         mov cl,al                          ;put_char需要CL=字符
         call put_char
         pop ecx

         loop .xlt                          ;处理下一个十六进制数字
      
         popad
         retf                               ;段间远返回

;-------------------------------------------------------------------------------
set_up_gdt_descriptor:                      ;在GDT末尾安装一个新的描述符
                                            ;输入：EDX:EAX=8字节的完整描述符
                                            ;输出：CX=新描述符的段选择子
         push eax
         push ebx
         push edx

         sgdt [pgdt]                        ;将当前GDTR内容（界限+基地址）保存到内存

         movzx ebx,word [pgdt]              ;EBX=GDT当前界限（即已用字节数-1）
         inc bx                             ;+1 = GDT已占用的总字节数 = 新描述符的偏移
         add ebx,[pgdt+2]                   ;+ GDT线性基地址 = 新描述符的线性地址

         mov [ebx],eax                      ;写入描述符低32位
         mov [ebx+4],edx                    ;写入描述符高32位

         add word [pgdt],8                  ;GDT界限增加8字节（一个描述符大小）

         lgdt [pgdt]                        ;重新加载GDTR使更改生效

         ;计算新描述符的选择子：(界限+1)/8 = 描述符索引，左移3位得到选择子
         mov ax,[pgdt]                      ;取新界限值
         xor dx,dx
         mov bx,8
         div bx                             ;AX = (界限+1)/8 = 描述符总数
         mov cx,ax
         shl cx,3                           ;选择子 = 索引<<3（TI=0,RPL=00）

         pop edx
         pop ebx
         pop eax

         retf                               ;段间远返回
;-------------------------------------------------------------------------------
make_seg_descriptor:                        ;构造存储器和系统的段描述符（8字节）
                                            ;输入：EAX=段线性基地址
                                            ;      EBX=段界限（20位）
                                            ;      ECX=属性（G,D/B,L,AVL,P,DPL,S,TYPE在原始位置）
                                            ;返回：EDX:EAX=构造好的8字节描述符
         mov edx,eax                        ;EDX暂存基地址
         shl eax,16                         ;EAX高16位=基地址低16位
         or ax,bx                           ;EAX低16位=段界限低16位 → 描述符[31:0]构造完毕

         and edx,0xffff0000                 ;保留基地址高16位
         rol edx,8                          ;循环左移8位，为bswap做准备
         bswap edx                          ;字节序翻转，将基地址[31:24]和[23:16]就位

         xor bx,bx                          ;清除EBX低16位（保留高16位的界限[19:16]）
         or edx,ebx                         ;装配段界限高4位

         or edx,ecx                         ;装配属性位（G,D/B,P,DPL,S,TYPE等）

         retf                               ;段间远返回

;-------------------------------------------------------------------------------
make_gate_descriptor:                       ;构造门描述符（调用门/中断门/陷阱门）
                                            ;输入：EAX=门代码在段内的偏移地址
                                            ;       BX=门代码所在段的选择子
                                            ;       CX=门类型及属性（P,DPL,TYPE在原始位置）
                                            ;返回：EDX:EAX=构造好的8字节门描述符
         push ebx
         push ecx

         mov edx,eax
         and edx,0xffff0000                 ;EDX=偏移地址高16位（门描述符[31:16]）
         or dx,cx                           ;EDX低16位=门属性 → 门描述符高32位完成

         and eax,0x0000ffff                 ;EAX=偏移地址低16位
         shl ebx,16                         ;EBX高16位=段选择子
         or eax,ebx                         ;EAX=选择子:偏移低16位 → 门描述符低32位完成
      
         pop ecx
         pop ebx

         retf                               ;段间远返回

;-------------------------------------------------------------------------------
allocate_a_4k_page:                         ;从物理页位图中分配一个4KB物理页
                                            ;输入：无
                                            ;输出：EAX=分配到的页的物理地址（4KB对齐）
         push ebx
         push ecx
         push edx

         xor eax,eax                        ;从第0个物理页开始搜索
  .b1:
         bts [page_bit_map],eax             ;测试并置位第EAX位（BTS=Bit Test and Set）
         jnc .b2                            ;CF=0说明该位原来为0（空闲），分配成功
         inc eax                            ;该页已被占用，检查下一个
         cmp eax,page_map_len*8             ;是否已检查完所有物理页？
         jl .b1

         mov ebx,message_3                  ;所有物理页已用完
         call flat_4gb_code_seg_sel:put_string
         hlt                                ;停机（致命错误：无物理内存可分配）

  .b2:
         shl eax,12                         ;页号×4096 = 页的物理起始地址
         
         pop edx
         pop ecx
         pop ebx
         
         ret                                ;段内近返回（仅被alloc_inst_a_page内部调用）

;-------------------------------------------------------------------------------
alloc_inst_a_page:                          ;分配一个物理页，并在当前活动的
                                            ;层级分页结构中建立映射
                                            ;输入：EBX=要映射的线性地址（4KB对齐）
         push eax
         push ebx
         push esi
         
         ;--- 第1步：检查该线性地址对应的页表是否存在 ---
         ;利用页目录自映射（最后一项指向自身），通过0xFFFFF000访问页目录
         mov esi,ebx
         and esi,0xffc00000                 ;提取线性地址的高10位（页目录索引）
         shr esi,20                         ;右移20位 = 索引×4（每个目录项4字节）
         or esi,0xfffff000                  ;0xFFFFF000 + 索引×4 = 该目录项的线性地址

         test dword [esi],0x00000001        ;测试P位（存在位）
         jnz .b1                            ;P=1，页表已存在，跳过创建

         ;页表不存在，分配一个物理页作为新页表
         call allocate_a_4k_page            ;EAX=新页的物理地址
         or eax,0x00000007                  ;设置属性：P=1,R/W=1,U/S=1（用户可访问）
         mov [esi],eax                      ;将新页表登记到页目录中

  .b1:
         ;--- 第2步：在页表中建立页表项 ---
         ;利用页目录自映射，0xFFC00000起始的4MB空间映射了所有页表
         mov esi,ebx
         shr esi,10                         ;线性地址右移10位
         and esi,0x003ff000                 ;提取页目录索引（高10位）→ 页表偏移
         or esi,0xffc00000                  ;+ 0xFFC00000 = 该页表的线性基地址

         ;计算页表内的具体条目偏移
         and ebx,0x003ff000                 ;提取页表索引（中间10位）
         shr ebx,10                         ;右移10位后再×4 = 相当于右移12位×4
         or esi,ebx                         ;ESI = 该页表项的完整线性地址
         call allocate_a_4k_page            ;分配一个实际要使用的物理页
         or eax,0x00000007                  ;设置属性：P=1,R/W=1,U/S=1
         mov [esi],eax                      ;将物理页登记到页表项中
          
         pop esi
         pop ebx
         pop eax
         
         retf                               ;段间远返回

;-------------------------------------------------------------------------------
create_copy_cur_pdir:                       ;为新任务创建独立的页目录（复制当前页目录）
                                            ;输入：无
                                            ;输出：EAX=新页目录的物理地址
         push esi
         push edi
         push ebx
         push ecx
         
         call allocate_a_4k_page            ;分配一个物理页作为新页目录
         mov ebx,eax                        ;EBX=新页目录物理地址
         or ebx,0x00000007                  ;设置属性P=1,R/W=1,U/S=1
         mov [0xfffffff8],ebx               ;写入当前页目录的倒数第2项（索引1022）
                                            ;使新页目录可通过0xFFFFE000访问

         invlpg [0xfffffff8]                ;【选择性TLB刷新】仅使该地址的TLB条目失效
                                            ;比重新加载CR3高效得多（486+指令）

         mov esi,0xfffff000                 ;ESI→当前页目录的线性地址（自映射）
         mov edi,0xffffe000                 ;EDI→新页目录的线性地址（通过索引1022访问）
         mov ecx,1024                       ;页目录共1024个表项（每项4字节）
         cld                                ;DF=0，正向传送
         repe movsd                         ;逐项复制，新页目录继承当前所有映射
         
         pop ecx
         pop ebx
         pop edi
         pop esi
         
         retf                               ;段间远返回

;-------------------------------------------------------------------------------
general_interrupt_handler:                  ;通用的硬件中断处理过程（默认处理器）
                                            ;对于未专门处理的中断，仅发送EOI后返回
         push eax

         mov al,0x20                        ;EOI（End Of Interrupt）命令
         out 0xa0,al                        ;向8259A从片发送EOI
         out 0x20,al                        ;向8259A主片发送EOI
         
         pop eax

         iretd                              ;从32位中断返回（恢复EFLAGS/CS/EIP）

;-------------------------------------------------------------------------------
general_exception_handler:                  ;通用的处理器异常处理过程（致命错误）
         mov ebx,excep_msg                  ;显示异常提示信息
         call flat_4gb_code_seg_sel:put_string

         hlt                                ;停机（异常通常无法恢复）

;-------------------------------------------------------------------------------
;===== RTC实时时钟中断处理过程 =====
;这是抢占式多任务调度的核心：每秒触发一次，实现轮转调度
rtm_0x70_interrupt_handle:                  ;INT 0x70：RTC更新结束中断处理程序

         pushad                             ;保存所有通用寄存器（任务上下文的一部分）

         ;--- 发送中断结束信号 ---
         mov al,0x20                        ;EOI命令
         out 0xa0,al                        ;先向从片8259A发送（RTC连接在从片IR0）
         out 0x20,al                        ;再向主片8259A发送（级联要求）

         ;--- 读RTC寄存器C，清除中断标志 ---
         ;不读寄存器C的话，RTC不会再产生下一次中断
         mov al,0x0c                        ;寄存器C的索引（bit7=0：开放NMI）
         out 0x70,al                        ;写入CMOS地址端口
         in al,0x71                         ;读取寄存器C的值，清除中断请求标志
         ;--- 第1步：在TCB链表中查找当前忙任务（状态=0xFFFF）---
         mov eax,tcb_chain                  ;EAX=链表头指针的地址
  .b0:                                      ;EAX=前驱节点地址（用于后续从链中拆除当前节点）
         mov ebx,[eax]                      ;EBX=下一个TCB的线性地址
         or ebx,ebx                         ;检查是否到达链尾（NULL指针）
         jz .irtn                           ;链表为空或没有忙任务，直接返回
         cmp word [ebx+0x04],0xffff         ;TCB+0x04=任务状态，0xFFFF=忙
         je .b1                             ;找到当前忙任务
         mov eax,ebx                        ;未找到，继续遍历下一个TCB
         jmp .b0

         ;--- 第2步：将当前忙任务从链中拆除并移到链尾（轮转调度）---
  .b1:
         mov ecx,[ebx]                      ;ECX=忙任务的下一个TCB地址
         mov [eax],ecx                      ;前驱节点指向忙任务的后继，从链中拆除

  .b2:                                      ;遍历到链表尾端
         mov edx,[eax]                      ;EDX=当前节点的下一个
         or edx,edx                         ;到链尾了？
         jz .b3                             ;是，EAX指向链尾节点
         mov eax,edx                        ;继续向后遍历
         jmp .b2

  .b3:
         mov [eax],ebx                      ;将忙任务挂到链尾
         mov dword [ebx],0x00000000         ;忙任务成为新的链尾（next=NULL）

         ;--- 第3步：从链首查找第一个空闲任务（状态=0x0000）---
         mov eax,tcb_chain
  .b4:
         mov eax,[eax]                      ;遍历链表
         or eax,eax                         ;到达链尾？
         jz .irtn                           ;没有空闲任务，不切换，从中断返回
         cmp word [eax+0x04],0x0000         ;是空闲任务？
         jnz .b4                            ;不是，继续找

         ;--- 第4步：执行任务切换 ---
         not word [eax+0x04]                ;NOT 0x0000 = 0xFFFF，空闲→忙
         not word [ebx+0x04]                ;NOT 0xFFFF = 0x0000，忙→空闲
         jmp far [eax+0x14]                 ;硬件任务切换！跳转到空闲任务的TSS
                                            ;CPU自动保存当前任务状态到旧TSS，从新TSS恢复

  .irtn:
         popad                              ;恢复所有通用寄存器

         iretd                              ;从32位中断返回

;-------------------------------------------------------------------------------
;===== 任务终止例程 =====
;当前正在运行的任务调用此例程来终止自身
terminate_current_task:                     ;终止当前任务
                                            ;注意：此例程在当前任务的上下文中执行
         ;在TCB链表中查找当前忙任务
         mov eax,tcb_chain
  .b0:                                      ;遍历TCB链表
         mov ebx,[eax]                      ;EBX=下一个TCB线性地址
         cmp word [ebx+0x04],0xffff         ;是当前忙任务？
         je .b1
         mov eax,ebx                        ;继续遍历
         jmp .b0

  .b1:
         mov word [ebx+0x04],0x3333         ;将任务状态设为”已终止”（0x3333）

  .b2:
         hlt                                ;停机，等待RTC中断唤醒
                                            ;调度器会跳过已终止的任务（状态≠0x0000）
         jmp .b2                            ;HLT返回后再次停机（防御性编程）

;-------------------------------------------------------------------------------
         pgdt             dw  0             ;用于保存/修改GDTR（6字节：2字节界限+4字节基地址）
                          dd  0

         pidt             dw  0             ;用于保存/修改IDTR（格式同GDTR）
                          dd  0

         ;TCB链表头指针（指向第一个TCB，0表示链表为空）
         tcb_chain        dd  0

         core_tcb   times  32  db 0         ;内核程序管理器的TCB（32字节）

         ;物理页位图：每位对应一个4KB物理页（1=已占用，0=空闲）
         ;共64字节=512位，可管理512*4KB=2MB物理内存
         page_bit_map     db  0xff,0xff,0xff,0xff,0xff,0xff,0x55,0x55  ;前384KB已占用
                          db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                          db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                          db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                          db  0x55,0x55,0x55,0x55,0x55,0x55,0x55,0x55
                          db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00  ;后续页空闲
                          db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
                          db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
         page_map_len     equ $-page_bit_map  ;位图长度（字节数）
                          
         ;符号地址检索表（C-SALT：Core Symbol Address Lookup Table）
         ;内核导出的系统服务接口，用户程序通过U-SALT中的同名字符串来匹配
         ;每个条目：256字节的名称 + 4字节偏移地址 + 2字节段选择子
         salt:
         salt_1           db  '@PrintString'
                     times 256-($-salt_1) db 0
                          dd  put_string
                          dw  flat_4gb_code_seg_sel

         salt_2           db  '@ReadDiskData'
                     times 256-($-salt_2) db 0
                          dd  read_hard_disk_0
                          dw  flat_4gb_code_seg_sel

         salt_3           db  '@PrintDwordAsHexString'
                     times 256-($-salt_3) db 0
                          dd  put_hex_dword
                          dw  flat_4gb_code_seg_sel

         salt_4           db  '@TerminateProgram'
                     times 256-($-salt_4) db 0
                          dd  terminate_current_task
                          dw  flat_4gb_code_seg_sel

         salt_item_len   equ $-salt_4         ;每个SALT条目的长度（字节）
         salt_items      equ ($-salt)/salt_item_len  ;SALT条目总数

         excep_msg        db  '********Exception encounted********',0  ;异常提示信息

         message_0        db  '  Working in system core with protection '
                          db  'and paging are all enabled.System core is mapped '
                          db  'to address 0x80000000.',0x0d,0x0a,0

         message_1        db  '  System wide CALL-GATE mounted.',0x0d,0x0a,0
         
         message_3        db  '********No more pages********',0  ;内存耗尽提示

         core_msg0        db  '  System core task running!',0x0d,0x0a,0  ;内核主循环提示

         bin_hex          db '0123456789ABCDEF'  ;十六进制转换查找表

         core_buf   times 512 db 0          ;内核通用缓冲区（一个扇区大小）

         cpu_brnd0        db 0x0d,0x0a,'  ',0   ;CPU品牌显示前缀
         cpu_brand  times 52 db 0               ;存放CPUID返回的CPU品牌字符串
         cpu_brnd1        db 0x0d,0x0a,0x0d,0x0a,0  ;CPU品牌显示后缀

;-------------------------------------------------------------------------------
fill_descriptor_in_ldt:                     ;在指定任务的LDT中安装一个新描述符
                                            ;输入：EDX:EAX=8字节描述符
                                            ;      EBX=该任务TCB的线性基地址
                                            ;输出：CX=新描述符在LDT中的选择子
         push eax
         push edx
         push edi

         mov edi,[ebx+0x0c]                 ;TCB+0x0C=LDT的线性基地址

         xor ecx,ecx
         mov cx,[ebx+0x0a]                  ;TCB+0x0A=LDT当前界限
         inc cx                             ;界限+1=LDT已用字节数=新描述符的偏移

         mov [edi+ecx+0x00],eax             ;写入描述符低32位
         mov [edi+ecx+0x04],edx             ;写入描述符高32位

         add cx,8
         dec cx                             ;新界限 = 旧界限+8-1+1 = 旧界限+8

         mov [ebx+0x0a],cx                  ;更新TCB中的LDT界限值

         ;计算新描述符的选择子
         mov ax,cx
         xor dx,dx
         mov cx,8
         div cx                             ;AX = (界限+1)/8 = 描述符索引

         mov cx,ax
         shl cx,3                           ;索引左移3位（腾出TI和RPL位）
         or cx,0000_0000_0000_0100B         ;TI=1（指向LDT而非GDT），RPL=00

         pop edi
         pop edx
         pop eax
     
         ret                                ;段内近返回

;-------------------------------------------------------------------------------
load_relocate_program:                      ;加载用户程序并进行重定位
                                            ;输入：PUSH 逻辑扇区号（用户程序在硬盘上的位置）
                                            ;      PUSH 任务控制块线性基地址
                                            ;输出：无（通过TCB返回相关信息）
         pushad

         mov ebp,esp                        ;建立栈帧，通过EBP访问参数

         ;清空当前页目录的前半部分（前512项，对应低2GB的用户地址空间）
         ;每个新任务都有自己独立的用户空间映射
         mov ebx,0xfffff000                 ;页目录自身的线性地址（自映射）
         xor esi,esi
  .b1:
         mov dword [ebx+esi*4],0x00000000   ;清除页目录项
         inc esi
         cmp esi,512                        ;前512项对应0x00000000-0x7FFFFFFF
         jl .b1

         ;【全量TLB刷新】重新加载CR3使清除的页目录项生效
         mov eax,cr3
         mov cr3,eax                        ;重新加载CR3 → 整个TLB失效
         
         ;--- 读取用户程序头部，确定程序大小 ---
         mov eax,[ebp+40]                   ;参数1：用户程序起始扇区号（pushad保存了8*4=32字节+返回地址4字节+参数偏移）
         mov ebx,core_buf                   ;读到内核缓冲区
         call flat_4gb_code_seg_sel:read_hard_disk_0  ;读取第一个扇区（含程序头部）

         ;计算用户程序占用的4KB页数
         mov eax,[core_buf]                 ;[core_buf+0]=程序总字节数
         mov ebx,eax
         and ebx,0xfffff000                 ;向下对齐到4KB边界
         add ebx,0x1000                     ;再加一页（向上取整）
         test eax,0x00000fff                ;程序大小恰好是4KB的整数倍？
         cmovnz eax,ebx                     ;不是整数倍则使用向上取整的值

         mov ecx,eax
         shr ecx,12                         ;总字节数/4096=所需的4KB页数

         mov eax,[ebp+40]                   ;重取起始扇区号
         mov esi,[ebp+36]                   ;参数2：TCB的线性基地址
  .b2:
         alloc_user_linear                  ;为用户程序分配一个4KB虚拟页

         push ecx
         mov ecx,8                          ;每页4KB=8个扇区(512*8=4096)
  .b3:
         call flat_4gb_code_seg_sel:read_hard_disk_0  ;读一个扇区到已映射的页中
         inc eax                            ;下一个扇区
         loop .b3

         pop ecx
         loop .b2                           ;处理下一个4KB页

         ;--- 创建用户任务的TSS（任务状态段）---
         ;TSS必须在内核（全局）地址空间上分配，因为硬件任务切换时CPU直接访问
         alloc_core_linear                  ;在内核空间分配4KB页

         mov [esi+0x14],ebx                 ;TCB+0x14=TSS的线性地址
         mov word [esi+0x12],103            ;TCB+0x12=TSS界限值（TSS最小104字节-1=103）

         ;--- 创建用户任务的LDT（局部描述符表）---
         alloc_user_linear                  ;在用户空间分配4KB页

         mov [esi+0x0c],ebx                 ;TCB+0x0C=LDT的线性地址

         ;--- 建立用户程序的代码段描述符（DPL=3，用户态）---
         mov eax,0x00000000                 ;基地址=0（平坦模型）
         mov ebx,0x000fffff                 ;界限=0xFFFFF（4KB粒度=4GB）
         mov ecx,0x00c0f800                 ;G=1,D=1,P=1,DPL=3,TYPE=1000(只执行代码段)
         call flat_4gb_code_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;EBX=TCB基地址
         call fill_descriptor_in_ldt        ;安装到LDT，CX=返回的选择子
         or cx,0000_0000_0000_0011B         ;设置RPL=3（用户特权级）

         mov ebx,[esi+0x14]                 ;取TSS线性地址
         mov [ebx+76],cx                    ;TSS偏移76=CS域

         ;--- 建立用户程序的数据段描述符（DPL=3）---
         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c0f200                 ;G=1,D=1,P=1,DPL=3,TYPE=0010(可读写数据段)
         call flat_4gb_code_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;RPL=3

         mov ebx,[esi+0x14]
         mov [ebx+84],cx                    ;TSS偏移84=DS域
         mov [ebx+72],cx                    ;TSS偏移72=ES域
         mov [ebx+88],cx                    ;TSS偏移88=FS域
         mov [ebx+92],cx                    ;TSS偏移92=GS域

         ;--- 创建用户任务的3特权级堆栈（用户态默认堆栈）---
         alloc_user_linear

         mov ebx,[esi+0x14]
         mov [ebx+80],cx                    ;TSS偏移80=SS域（3特权级堆栈段选择子）
         mov edx,[esi+0x06]                 ;分配后的下一可用地址=堆栈高端
         mov [ebx+56],edx                   ;TSS偏移56=ESP域（3特权级堆栈指针）

         ;--- 创建0特权级堆栈（内核态堆栈，用于中断/系统调用时的特权级切换）---
         alloc_user_linear

         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c09200                 ;G=1,D=1,P=1,DPL=0,TYPE=0010(可读写数据段)
         call flat_4gb_code_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0000B         ;RPL=0（内核特权级）

         mov ebx,[esi+0x14]
         mov [ebx+8],cx                     ;TSS偏移8=SS0域（0特权级堆栈段）
         mov edx,[esi+0x06]
         mov [ebx+4],edx                    ;TSS偏移4=ESP0域（0特权级堆栈指针）

         ;--- 创建1特权级堆栈 ---
         alloc_user_linear

         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c0b200                 ;G=1,D=1,P=1,DPL=1,TYPE=0010
         call flat_4gb_code_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0001B         ;RPL=1

         mov ebx,[esi+0x14]
         mov [ebx+16],cx                    ;TSS偏移16=SS1域
         mov edx,[esi+0x06]
         mov [ebx+12],edx                   ;TSS偏移12=ESP1域

         ;--- 创建2特权级堆栈 ---
         alloc_user_linear

         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c0d200                 ;G=1,D=1,P=1,DPL=2,TYPE=0010
         call flat_4gb_code_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0010B         ;RPL=2

         mov ebx,[esi+0x14]
         mov [ebx+24],cx                    ;TSS偏移24=SS2域
         mov edx,[esi+0x06]
         mov [ebx+20],edx                   ;TSS偏移20=ESP2域

         ;--- 重定位U-SALT（用户符号地址检索表）---
         ;将用户程序中的服务名称字符串替换为对应的调用门选择子和偏移
         cld                                ;DF=0，正向比较

         mov ecx,[0x0c]                     ;用户程序头部+0x0C=U-SALT条目数
         mov edi,[0x08]                     ;用户程序头部+0x08=U-SALT在4GB空间内的偏移
  .b4:
         push ecx
         push edi

         mov ecx,salt_items                 ;内核C-SALT的条目数
         mov esi,salt                       ;内核C-SALT的起始地址
  .b5:
         push edi                           ;保存当前U-SALT条目位置
         push esi                           ;保存当前C-SALT条目位置
         push ecx

         mov ecx,64                         ;每个名称256字节/4=64个双字
         repe cmpsd                         ;逐双字比较U-SALT名称与C-SALT名称
         jnz .b6                            ;不匹配，尝试下一个C-SALT条目
         ;匹配成功！ESI此时指向C-SALT条目名称之后的地址和选择子
         mov eax,[esi]                      ;取出系统服务的入口偏移地址
         mov [edi-256],eax                  ;回填到U-SALT条目中（覆盖原名称位置）
         mov ax,[esi+4]                     ;取出系统服务的段选择子（调用门选择子）
         or ax,0000000000000011B            ;设置RPL=3（用户程序以自身特权级使用调用门）
         mov [edi-252],ax                   ;回填调用门选择子
  .b6:
         pop ecx
         pop esi
         add esi,salt_item_len              ;指向下一个C-SALT条目
         pop edi                            ;恢复U-SALT条目位置（从头重新比较）
         loop .b5                           ;遍历所有C-SALT条目

         pop edi
         add edi,256                        ;指向下一个U-SALT条目
         pop ecx
         loop .b4                           ;遍历所有U-SALT条目

         ;--- 在GDT中登记LDT描述符 ---
         mov esi,[ebp+36]                   ;重取TCB基地址
         mov eax,[esi+0x0c]                 ;LDT的线性基地址
         movzx ebx,word [esi+0x0a]          ;LDT界限
         mov ecx,0x00408200                 ;LDT描述符类型，DPL=0
         call flat_4gb_code_seg_sel:make_seg_descriptor
         call flat_4gb_code_seg_sel:set_up_gdt_descriptor
         mov [esi+0x10],cx                  ;TCB+0x10=LDT选择子

         mov ebx,[esi+0x14]
         mov [ebx+96],cx                    ;TSS偏移96=LDT段选择子域

         mov word [ebx+0],0                 ;TSS偏移0=反向链（Back Link）=0
         mov dx,[esi+0x12]                  ;TSS界限值
         mov [ebx+102],dx                   ;TSS偏移102=I/O位图偏移（设为界限值=无位图）
         mov word [ebx+100],0               ;TSS偏移100=T标志=0（不触发调试陷阱）

         mov eax,[0x04]                     ;用户程序头部+0x04=入口点偏移
         mov [ebx+32],eax                   ;TSS偏移32=EIP域

         pushfd                             ;将当前EFLAGS压栈
         pop edx                            ;弹出到EDX
         mov [ebx+36],edx                   ;TSS偏移36=EFLAGS域

         ;--- 在GDT中登记TSS描述符 ---
         mov eax,[esi+0x14]                 ;TSS线性地址
         movzx ebx,word [esi+0x12]          ;TSS界限
         mov ecx,0x00408900                 ;TSS描述符类型（B=0，非忙），DPL=0
         call flat_4gb_code_seg_sel:make_seg_descriptor
         call flat_4gb_code_seg_sel:set_up_gdt_descriptor
         mov [esi+0x18],cx                  ;TCB+0x18=TSS选择子

         ;--- 创建用户任务的独立页目录 ---
         ;复制当前内核页目录的全部内容（包含内核空间映射）
         ;用户任务将获得独立的低2GB映射，但共享高2GB内核映射
         call flat_4gb_code_seg_sel:create_copy_cur_pdir
         mov ebx,[esi+0x14]
         mov dword [ebx+28],eax             ;TSS偏移28=CR3(PDBR)域
                   
         popad

         ret 8                              ;返回并丢弃8字节参数（2个PUSH DWORD）

;-------------------------------------------------------------------------------
append_to_tcb_link:                         ;将新的TCB追加到TCB链表末尾
                                            ;输入：ECX=新TCB的线性基地址
         cli                                ;关中断，防止调度器在修改链表时被触发
         
         push eax
         push ebx

         mov eax,tcb_chain
  .b0:                                      ;遍历链表找到末尾
         mov ebx,[eax]                      ;EBX=下一个TCB地址
         or ebx,ebx
         jz .b1                             ;EBX=0表示到达链尾
         mov eax,ebx
         jmp .b0

  .b1:
         mov [eax],ecx                      ;将新TCB挂到链尾
         mov dword [ecx],0x00000000         ;新TCB的next指针=NULL（标记为链尾）
         pop ebx
         pop eax

         sti                                ;恢复中断

         ret

;===============================================================================
;===== 内核入口点 =====
start:
         ;========== 第1步：创建中断描述符表（IDT）==========
         ;在此之前不能调用任何包含STI指令的过程（IDT尚未建立）

         ;前20个向量（0-19）保留给处理器异常（除法错误、页错误等）
         mov eax,general_exception_handler  ;异常处理程序偏移地址
         mov bx,flat_4gb_code_seg_sel       ;代码段选择子
         mov cx,0x8e00                      ;32位中断门，DPL=0（0x8E=P:1,DPL:00,TYPE:1110）
         call flat_4gb_code_seg_sel:make_gate_descriptor

         mov ebx,idt_linear_address         ;IDT线性基地址（0x8001f000）
         xor esi,esi                        ;从向量0开始
  .idt0:
         mov [ebx+esi*8],eax               ;写入门描述符低32位
         mov [ebx+esi*8+4],edx             ;写入门描述符高32位
         inc esi
         cmp esi,19                         ;安装向量0-19（共20个异常处理程序）
         jle .idt0

         ;向量20-255使用通用硬件中断处理程序
         mov eax,general_interrupt_handler
         mov bx,flat_4gb_code_seg_sel
         mov cx,0x8e00                      ;32位中断门，DPL=0
         call flat_4gb_code_seg_sel:make_gate_descriptor

         mov ebx,idt_linear_address
  .idt1:
         mov [ebx+esi*8],eax
         mov [ebx+esi*8+4],edx
         inc esi
         cmp esi,255                        ;填充向量20-255
         jle .idt1

         ;单独设置RTC实时时钟中断处理程序（向量0x70=112）
         mov eax,rtm_0x70_interrupt_handle  ;调度器入口
         mov bx,flat_4gb_code_seg_sel
         mov cx,0x8e00                      ;32位中断门，DPL=0
         call flat_4gb_code_seg_sel:make_gate_descriptor

         mov ebx,idt_linear_address
         mov [ebx+0x70*8],eax              ;覆盖向量0x70的门描述符
         mov [ebx+0x70*8+4],edx

         ;加载IDTR寄存器
         mov word [pidt],256*8-1            ;IDT界限=256*8-1=2047
         mov dword [pidt+2],idt_linear_address  ;IDT线性基地址
         lidt [pidt]                        ;加载IDTR

         ;========== 第2步：初始化8259A PIC ==========
         ;--- 主片（Master PIC，端口0x20/0x21）---
         mov al,0x11
         out 0x20,al                        ;ICW1：D4=1(ICW1标识), D0=1(需要ICW4)
         mov al,0x20
         out 0x21,al                        ;ICW2：IRQ0-7映射到INT 0x20-0x27
         mov al,0x04
         out 0x21,al                        ;ICW3：IR2引脚连接从片（bit2=1）
         mov al,0x01
         out 0x21,al                        ;ICW4：8086模式，正常EOI，非缓冲

         ;--- 从片（Slave PIC，端口0xA0/0xA1）---
         mov al,0x11
         out 0xa0,al                        ;ICW1：边沿触发，级联模式
         mov al,0x70
         out 0xa1,al                        ;ICW2：IRQ8-15映射到INT 0x70-0x77
         mov al,0x04
         out 0xa1,al                        ;ICW3：从片级联ID=2（连接主片IR2）
         mov al,0x01
         out 0xa1,al                        ;ICW4：8086模式，正常EOI

         ;========== 第3步：配置RTC实时时钟 ==========
         mov al,0x0b                        ;选择RTC寄存器B
         or al,0x80                         ;bit7=1：阻断NMI（防止配置过程被打断）
         out 0x70,al                        ;写入CMOS地址端口
         mov al,0x12                        ;寄存器B的值：UIE=1(更新结束中断使能)
         out 0x71,al                        ;PIE=0(禁止周期性中断),BCD码,24小时制

         ;开放从片IR0（RTC中断线）
         in al,0xa1                         ;读从片的IMR（中断屏蔽寄存器）
         and al,0xfe                        ;清除bit0（IR0=RTC），允许RTC中断通过
         out 0xa1,al                        ;写回IMR

         ;读RTC寄存器C，清除可能存在的未决中断标志
         mov al,0x0c
         out 0x70,al                        ;选择寄存器C（同时bit7=0开放NMI）
         in al,0x71                         ;读取并清除中断请求标志

         sti                                ;开放硬件中断（IDT和8259A已就绪）

         ;显示内核启动信息
         mov ebx,message_0
         call flat_4gb_code_seg_sel:put_string

         ;========== 显示CPU品牌信息（通过CPUID扩展功能0x80000002-04）==========
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

         mov ebx,cpu_brnd0                  ;显示CPU品牌字符串前缀
         call flat_4gb_code_seg_sel:put_string
         mov ebx,cpu_brand                  ;显示48字节的CPU品牌字符串
         call flat_4gb_code_seg_sel:put_string
         mov ebx,cpu_brnd1                  ;显示后缀（换行）
         call flat_4gb_code_seg_sel:put_string

         ;========== 第4步：安装系统调用门 ==========
         ;遍历C-SALT表，为每个系统服务创建调用门并安装到GDT
         mov edi,salt                       ;C-SALT表起始地址
         mov ecx,salt_items                 ;C-SALT条目数
  .b4:
         push ecx
         mov eax,[edi+256]                  ;条目偏移+256=入口偏移地址
         mov bx,[edi+260]                   ;条目偏移+260=段选择子
         mov cx,1_11_0_1100_000_00000B      ;DPL=3的调用门（允许ring3调用），参数个数=0
         call flat_4gb_code_seg_sel:make_gate_descriptor
         call flat_4gb_code_seg_sel:set_up_gdt_descriptor
         mov [edi+260],cx                   ;将分配到的调用门选择子回填到C-SALT
         add edi,salt_item_len              ;指向下一个C-SALT条目
         pop ecx
         loop .b4

         ;测试调用门是否工作
         mov ebx,message_1
         call far [salt_1+256]              ;通过调用门调用put_string（偏移被忽略）

         ;========== 第5步：创建程序管理器任务（内核主任务）==========
         mov word [core_tcb+0x04],0xffff    ;状态=0xFFFF（忙碌，当前正在运行）
         mov dword [core_tcb+0x06],0x80100000  ;内核虚拟空间分配起点
         mov word [core_tcb+0x0a],0xffff    ;LDT界限（程序管理器不使用LDT）
         mov ecx,core_tcb
         call append_to_tcb_link            ;加入TCB链表

         ;为程序管理器分配TSS
         alloc_core_linear                  ;EBX=分配到的4KB页线性地址

         ;设置程序管理器TSS的必要字段
         mov word [ebx+0],0                 ;反向链=0（无嵌套任务）
         mov eax,cr3
         mov dword [ebx+28],eax             ;CR3=当前页目录基地址
         mov word [ebx+96],0                ;LDT选择子=0（不使用LDT）
         mov word [ebx+100],0               ;T=0（不触发调试陷阱）
         mov word [ebx+102],103             ;I/O位图偏移=103（无I/O位图，0特权级不需要）

         ;创建TSS描述符并安装到GDT
         mov eax,ebx                        ;TSS线性基地址
         mov ebx,103                        ;TSS界限=103字节
         mov ecx,0x00408900                 ;TSS描述符（B=0非忙），DPL=0
         call flat_4gb_code_seg_sel:make_seg_descriptor
         call flat_4gb_code_seg_sel:set_up_gdt_descriptor
         mov [core_tcb+0x18],cx             ;将TSS选择子保存到TCB

         ;加载任务寄存器TR——标志着”程序管理器”任务正式成为当前任务
         ;TR中的内容决定了硬件任务切换时，当前任务的状态保存到哪个TSS
         ltr cx

         ;========== 第6步：加载用户任务A（位于逻辑扇区50）==========
         alloc_core_linear                  ;为任务A的TCB分配内存

         mov word [ebx+0x04],0              ;状态=空闲（等待被调度）
         mov dword [ebx+0x06],0             ;用户地址空间分配从0x00000000开始
         mov word [ebx+0x0a],0xffff         ;LDT初始界限

         push dword 50                      ;参数：用户程序A在逻辑扇区50
         push ebx                           ;参数：TCB线性地址
         call load_relocate_program         ;加载、重定位、创建TSS/LDT等
         mov ecx,ebx
         call append_to_tcb_link            ;加入TCB链表

         ;========== 第7步：加载用户任务B（位于逻辑扇区100）==========
         alloc_core_linear                  ;为任务B的TCB分配内存

         mov word [ebx+0x04],0              ;状态=空闲
         mov dword [ebx+0x06],0             ;用户地址空间分配从0开始
         mov word [ebx+0x0a],0xffff         ;LDT初始界限

         push dword 100                     ;参数：用户程序B在逻辑扇区100
         push ebx                           ;参数：TCB线性地址
         call load_relocate_program
         mov ecx,ebx
         call append_to_tcb_link            ;加入TCB链表

         ;========== 程序管理器主循环 ==========
         ;程序管理器在没有用户任务可调度时运行此循环
  .core:
         mov ebx,core_msg0
         call flat_4gb_code_seg_sel:put_string  ;显示”内核任务运行中”

         ;此处可以添加：回收已终止任务的TCB、TSS、页表等资源

         jmp .core                          ;无限循环，等待RTC中断触发任务切换
            
core_code_end:

;-------------------------------------------------------------------------------
SECTION core_trail
;-------------------------------------------------------------------------------
core_end: