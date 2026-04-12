         ;代码清单9-1
         ;文件名：c09_1.asm
         ;文件说明：用户程序（RTC实时时钟中断处理程序）
         ;创建日期：2011-4-16 22:03

;===============================================================================
; 【扩展知识】本程序涉及的核心硬件与概念
;===============================================================================
;
; ■ 实时时钟芯片 RTC (Real-Time Clock) —— CMOS RAM
;   RTC 是主板上独立供电（纽扣电池）的时钟芯片，即使关机也能持续走时。
;   CPU 通过两个 I/O 端口访问 RTC/CMOS：
;     端口 0x70 —— 索引端口（写入要访问的寄存器编号）
;     端口 0x71 —— 数据端口（读/写所选寄存器的内容）
;
;   常用寄存器：
;     0x00：秒（BCD 格式，范围 0x00~0x59）
;     0x02：分（BCD 格式，范围 0x00~0x59）
;     0x04：时（BCD 格式，24 小时制范围 0x00~0x23）
;     0x0A：状态寄存器 A
;            bit7 = UIP (Update In Progress)，为 1 表示 RTC 正在更新时间，
;            此时不应读取时间寄存器，否则可能读到不一致的值。
;     0x0B：状态寄存器 B
;            bit4 = UIE，更新结束中断允许位（1=允许产生更新结束中断）
;            bit5 = AIE，闹钟中断允许位
;            bit6 = PIE，周期性中断允许位
;            bit2 = DM，数据模式（0=BCD，1=二进制）
;            bit1 = 24/12，小时格式（1=24小时制，0=12小时制）
;     0x0C：状态寄存器 C（只读）
;            读取此寄存器可清除所有未决的 RTC 中断标志。
;            如果不读取，RTC 将不再产生后续中断！
;
; ■ BCD 码 (Binary-Coded Decimal)
;   每个十六进制半字节（4 位）表示一个十进制数字。
;   例如：0x59 → 高半字节 5，低半字节 9 → 十进制 59
;   转换为 ASCII 只需将每个半字节加上 0x30（'0' 的 ASCII 码）。
;
; ■ 中断向量表 IVT (Interrupt Vector Table)
;   位于内存最低端 0x0000:0x0000，共 256 个表项，每项 4 字节。
;   格式：[偏移地址 2 字节][段地址 2 字节]（注意：偏移在前，段在后）
;   INT 0x70 对应表项地址 = 0x70 × 4 = 0x1C0
;   安装自定义中断处理程序时，只需将新的段:偏移写入对应 IVT 表项。
;
; ■ 8259A 可编程中断控制器 PIC (Programmable Interrupt Controller)
;   IBM PC 使用两片 8259A 级联：
;     主片 (Master)：端口 0x20（命令）/ 0x21（数据/IMR）
;       管理 IRQ0~IRQ7（定时器、键盘、级联从片等）
;     从片 (Slave)：端口 0xA0（命令）/ 0xA1（数据/IMR）
;       管理 IRQ8~IRQ15（RTC、数学协处理器等）
;   IRQ8 连接 RTC，对应从片 IMR 的 bit0。
;   IMR (Interrupt Mask Register)：对应位为 1 则屏蔽该 IRQ，为 0 则允许。
;   EOI (End of Interrupt)：中断处理完毕后，必须向 PIC 发送 0x20 命令，
;     通知 PIC 当前中断已处理完成。级联情况下需同时向从片和主片发送。
;
; ■ NMI (Non-Maskable Interrupt，不可屏蔽中断)
;   端口 0x70 的 bit7 控制 NMI 的屏蔽：
;     bit7 = 1：阻断（屏蔽）NMI
;     bit7 = 0：允许 NMI
;   因此写 0x70 端口时，高位同时控制 NMI 状态，低 7 位才是寄存器索引。
;
; ■ hlt 指令
;   使 CPU 进入暂停（低功耗）状态，停止执行指令。
;   CPU 将在收到下一个中断时被唤醒并继续执行 hlt 之后的指令。
;   常用于主循环中等待中断，比空转（忙等待）更节能。
;
; ■ cli / sti 指令
;   cli：清除 FLAGS 中的 IF 位（IF=0），禁止所有可屏蔽中断。
;   sti：设置 IF 位（IF=1），允许可屏蔽中断。
;   在修改中断向量表等关键操作时，需要用 cli/sti 保护，
;   防止修改到一半时触发中断导致跳转到无效地址。
;
;===============================================================================

;===============================================================================
SECTION header vstart=0                     ;定义用户程序头部段
    program_length  dd program_end          ;程序总长度（字节），加载器据此决定读多少扇区[0x00]

    ;用户程序入口点
    code_entry      dw start                ;入口偏移地址[0x04]
                    dd section.code.start   ;入口段地址（加载器会用段基址重定位）[0x06]

    realloc_tbl_len dw (header_end-realloc_begin)/4
                                            ;段重定位表项个数（加载器遍历此表进行重定位）[0x0a]

    realloc_begin:
    ;段重定位表——加载器读取每项的汇编阶段段地址，加上加载基址，回写为运行时段地址
    code_segment    dd section.code.start   ;代码段起始汇编地址[0x0c]
    data_segment    dd section.data.start   ;数据段起始汇编地址[0x14]
    stack_segment   dd section.stack.start  ;栈段起始汇编地址[0x1c]
    
header_end:                
    
;===============================================================================
SECTION code align=16 vstart=0           ;定义代码段（16字节对齐）

;-------------------------------------------------------------------------------
; 新的 INT 0x70 中断处理程序（替换原有的 RTC 中断向量）
; 功能：每次 RTC 更新结束后触发，读取当前时间并显示在屏幕上
; 注意：中断处理程序中必须保护所有使用的寄存器，最后用 iret 返回
;-------------------------------------------------------------------------------
new_int_0x70:
      push ax                              ;保护现场——中断处理程序必须保存所有用到的寄存器
      push bx
      push cx
      push dx
      push es

  .w0:                                     ;等待 UIP 标志清零（确保 RTC 不在更新过程中）
      mov al,0x0a                          ;选择状态寄存器 A（索引 0x0A）
      or al,0x80                           ;bit7=1，同时阻断 NMI（写 0x70 端口时的惯例）
      out 0x70,al                          ;写索引端口，选中寄存器 A
      in al,0x71                           ;从数据端口读取寄存器 A 的内容
      test al,0x80                         ;测试 bit7（UIP 位）：1=正在更新，0=可安全读取
      jnz .w0                              ;UIP=1 则继续等待（对于更新周期结束中断，
                                           ;理论上 UIP 已清除，但保留此检查更安全）

      xor al,al                            ;AL=0x00，选择秒寄存器（索引 0x00）
      or al,0x80                           ;bit7=1，阻断 NMI
      out 0x70,al                          ;写索引端口，选中秒寄存器
      in al,0x71                           ;读取当前秒值（BCD 格式，如 0x59 表示 59 秒）
      push ax                              ;将秒值压栈暂存

      mov al,2                             ;选择分寄存器（索引 0x02）
      or al,0x80                           ;bit7=1，阻断 NMI
      out 0x70,al                          ;写索引端口，选中分寄存器
      in al,0x71                           ;读取当前分值（BCD 格式）
      push ax                              ;将分值压栈暂存

      mov al,4                             ;选择时寄存器（索引 0x04）
      or al,0x80                           ;bit7=1，阻断 NMI
      out 0x70,al                          ;写索引端口，选中时寄存器
      in al,0x71                           ;读取当前时值（BCD 格式，24小时制）
      push ax                              ;将时值压栈暂存

      mov al,0x0c                          ;选择状态寄存器 C（索引 0x0C）
                                           ;注意 bit7=0，此操作同时重新开放 NMI
      out 0x70,al                          ;写索引端口，选中寄存器 C
      in al,0x71                           ;【关键】必须读寄存器 C 以清除中断标志！
                                           ;否则 RTC 不会产生后续中断（只触发一次）

      mov ax,0xb800                        ;显存段地址（文本模式彩色显存起始于 B8000h）
      mov es,ax                            ;ES 指向显存段

      pop ax                               ;弹出时值（最后压入的最先弹出——栈是 LIFO）
      call bcd_to_ascii                    ;将 BCD 码转为两个 ASCII 字符（AH=十位，AL=个位）
      mov bx,12*160 + 36*2                 ;计算屏幕位置：第 12 行第 36 列
                                           ;每行 80 字符×2 字节=160，每字符占 2 字节（字符+属性）

      mov [es:bx],ah                       ;写入小时的十位数字到显存
      mov [es:bx+2],al                     ;写入小时的个位数字（+2 跳过属性字节）

      mov al,':'                           ;时分分隔符
      mov [es:bx+4],al                     ;写入冒号 ':'
      not byte [es:bx+5]                   ;对冒号的属性字节取反，产生闪烁效果

      pop ax                               ;弹出分值
      call bcd_to_ascii                    ;BCD 转 ASCII
      mov [es:bx+6],ah                     ;写入分钟的十位数字
      mov [es:bx+8],al                     ;写入分钟的个位数字

      mov al,':'                           ;分秒分隔符
      mov [es:bx+10],al                    ;写入冒号 ':'
      not byte [es:bx+11]                  ;对冒号的属性字节取反，产生闪烁效果

      pop ax                               ;弹出秒值
      call bcd_to_ascii                    ;BCD 转 ASCII
      mov [es:bx+12],ah                    ;写入秒的十位数字
      mov [es:bx+14],al                    ;写入秒的个位数字

      mov al,0x20                          ;EOI 命令（0x20=通用 EOI）
      out 0xa0,al                          ;向从片 8259A 发送 EOI（因为 RTC 的 IRQ8 在从片上）
      out 0x20,al                          ;向主片 8259A 发送 EOI（级联结构，两片都要通知）

      pop es                               ;恢复现场——与压栈顺序相反
      pop dx
      pop cx
      pop bx
      pop ax

      iret                                 ;中断返回（从栈中弹出 IP、CS、FLAGS）

;-------------------------------------------------------------------------------
; BCD 码转 ASCII 子程序
; 原理：BCD 码的每个半字节(nibble)就是一位十进制数(0~9)，
;       加上 0x30 即可得到对应的 ASCII 字符 ('0'=0x30 ... '9'=0x39)
; 输入：AL = BCD 码（例如 AL=0x59）
; 输出：AH = 十位 ASCII（例如 '5'=0x35），AL = 个位 ASCII（例如 '9'=0x39）
;-------------------------------------------------------------------------------
bcd_to_ascii:
      mov ah,al                          ;复制 BCD 值到 AH（后续分别处理高低半字节）
      and al,0x0f                        ;用掩码 0x0F 保留低 4 位（个位数字）
      add al,0x30                        ;加 0x30 转为 ASCII（'0'~'9'）

      shr ah,4                           ;逻辑右移 4 位，将高半字节移到低 4 位（十位数字）
      and ah,0x0f                        ;清除高 4 位（此处 shr 后高位已为 0，但更严谨）
      add ah,0x30                        ;加 0x30 转为 ASCII

      ret

;-------------------------------------------------------------------------------
; 主程序入口——安装 RTC 中断处理程序并启用时钟显示
;-------------------------------------------------------------------------------
start:
      mov ax,[stack_segment]             ;从头部获取重定位后的栈段地址
      mov ss,ax                          ;设置栈段寄存器
      mov sp,ss_pointer                  ;设置栈指针到栈顶（栈从高地址向低地址增长）
      mov ax,[data_segment]              ;从头部获取重定位后的数据段地址
      mov ds,ax                          ;设置数据段寄存器

      mov bx,init_msg                    ;显示启动信息
      call put_string

      mov bx,inst_msg                    ;显示"正在安装中断处理程序"信息
      call put_string

      ;--- 将新的中断处理程序地址写入中断向量表 ---
      mov al,0x70                        ;中断号 0x70（RTC 更新结束中断）
      mov bl,4                           ;每个 IVT 表项占 4 字节
      mul bl                             ;AX = 0x70 × 4 = 0x1C0（IVT 中的偏移地址）
      mov bx,ax                          ;BX = 0x1C0，用作内存访问的基址

      cli                                ;关中断！防止在修改 IVT 的过程中触发 0x70 中断
                                         ;否则若只改了偏移还没改段地址就触发中断，会跳到错误地址

      push es                            ;保存 ES（后面要临时指向 0x0000 段）
      mov ax,0x0000                      ;IVT 位于内存最低端 0x0000:0x0000
      mov es,ax                          ;ES = 0x0000
      mov word [es:bx],new_int_0x70      ;写入新中断处理程序的偏移地址到 IVT
      mov word [es:bx+2],cs              ;写入新中断处理程序的段地址（CS=当前代码段）
      pop es                             ;恢复 ES

      ;--- 配置 RTC 寄存器 B，启用更新结束中断 ---
      mov al,0x0b                        ;选择状态寄存器 B（索引 0x0B）
      or al,0x80                         ;bit7=1，阻断 NMI（修改 RTC 配置期间更安全）
      out 0x70,al                        ;写索引端口
      mov al,0x12                        ;寄存器 B 的值：0001_0010b
                                         ;  bit4(UIE)=1：允许更新结束中断（每秒触发一次）
                                         ;  bit5(AIE)=0：禁止闹钟中断
                                         ;  bit6(PIE)=0：禁止周期性中断
                                         ;  bit2(DM)=0：BCD 数据模式
                                         ;  bit1(24/12)=1：24 小时制
      out 0x71,al                        ;写入寄存器 B

      ;--- 读寄存器 C 清除任何未决的中断标志 ---
      mov al,0x0c                        ;选择状态寄存器 C（索引 0x0C，bit7=0 开放 NMI）
      out 0x70,al                        ;写索引端口
      in al,0x71                         ;读寄存器 C，清除所有未决中断标志

      ;--- 在 8259A 从片中开放 IRQ8（RTC 中断线）---
      in al,0xa1                         ;读从片 8259A 的 IMR (中断屏蔽寄存器)
      and al,0xfe                        ;清除 bit0（bit0 对应 IRQ8/RTC），0=允许该中断
      out 0xa1,al                        ;写回 IMR，RTC 中断正式开放

      sti                                ;开中断！从此 RTC 每秒产生的中断可被 CPU 响应

      mov bx,done_msg                    ;显示"安装完成"信息
      call put_string

      mov bx,tips_msg                    ;显示提示信息
      call put_string

      ;--- 在屏幕上放置一个 '@' 标记，用于视觉反馈 ---
      mov cx,0xb800                      ;显存段地址
      mov ds,cx                          ;DS 指向显存
      mov byte [12*160 + 33*2],'@'       ;在第 12 行第 33 列写入 '@' 字符

 .idle:
      hlt                                ;CPU 进入暂停状态，等待中断唤醒
                                         ;（比空循环 jmp $ 省电，功耗更低）
      not byte [12*160 + 33*2+1]         ;被唤醒后，反转 '@' 的属性字节
                                         ;（每次中断后颜色翻转，作为程序运行的视觉指示）
      jmp .idle                          ;继续等待下一次中断

;-------------------------------------------------------------------------------
; 显示以 0 结尾的字符串（C 风格字符串）
; 输入：DS:BX = 字符串起始地址
; 调用：put_char 逐字符输出
;-------------------------------------------------------------------------------
put_string:
         mov cl,[bx]                     ;从 DS:BX 处读取一个字节（当前字符）
         or cl,cl                        ;CL 与自身 OR——不改变值，但会更新标志位
                                         ;若 CL=0 则 ZF=1（字符串结束标志）
         jz .exit                        ;ZF=1 说明遇到结束符 0，返回调用者
         call put_char                   ;输出当前字符
         inc bx                          ;BX 指向下一个字符
         jmp put_string                  ;继续处理

   .exit:
         ret                             ;字符串输出完毕，返回

;-------------------------------------------------------------------------------
; 显示单个字符（直接操作显存和 VGA 光标寄存器）
; 支持回车符 (0x0D)、换行符 (0x0A) 和普通可显示字符
; 输入：CL = 要显示的字符的 ASCII 码
; VGA 文本模式显存布局：每字符占 2 字节——[字符ASCII][属性字节]
; 光标位置通过 VGA CRT 控制器的寄存器 0x0E(高字节) 和 0x0F(低字节) 管理
;-------------------------------------------------------------------------------
put_char:
         push ax
         push bx
         push cx
         push dx
         push ds
         push es

         ;--- 读取当前光标位置 ---
         ;VGA CRT 控制器：端口 0x3D4 为索引，0x3D5 为数据
         mov dx,0x3d4                    ;CRT 控制器索引端口
         mov al,0x0e                     ;选择光标位置高 8 位寄存器
         out dx,al
         mov dx,0x3d5                    ;CRT 控制器数据端口
         in al,dx                        ;读取光标位置高 8 位
         mov ah,al                       ;保存到 AH

         mov dx,0x3d4
         mov al,0x0f                     ;选择光标位置低 8 位寄存器
         out dx,al
         mov dx,0x3d5
         in al,dx                        ;读取光标位置低 8 位
         mov bx,ax                       ;BX = 完整的 16 位光标位置（0~1999 对应 25 行×80 列）

         cmp cl,0x0d                     ;判断是否为回车符 (CR, 0x0D)
         jnz .put_0a                     ;不是回车，继续判断换行
         mov ax,bx                       ;回车处理：将光标移到当前行的行首
         mov bl,80                       ;每行 80 个字符
         div bl                          ;AL = 当前行号（AX ÷ 80），AH = 列号（余数）
         mul bl                          ;AX = 行号 × 80 = 该行起始位置
         mov bx,ax                       ;更新光标位置为行首
         jmp .set_cursor

 .put_0a:
         cmp cl,0x0a                     ;判断是否为换行符 (LF, 0x0A)
         jnz .put_other                  ;不是换行，按普通字符处理
         add bx,80                       ;换行：光标位置 + 80（下移一行，列不变）
         jmp .roll_screen                ;可能需要滚屏

 .put_other:                             ;--- 普通字符显示 ---
         mov ax,0xb800                   ;文本模式彩色显存段地址
         mov es,ax
         shl bx,1                        ;光标位置 × 2 = 显存内字节偏移
                                         ;（每个字符位置占 2 字节）
         mov [es:bx],cl                  ;将字符写入显存

         shr bx,1                        ;恢复为字符位置编号
         add bx,1                        ;光标前进一个字符位置

 .roll_screen:
         cmp bx,2000                     ;光标位置 ≥ 2000？（超出 25×80 屏幕范围）
         jl .set_cursor                  ;未超出则直接设置光标

         ;--- 滚屏：将第 1~24 行上移到第 0~23 行，清空第 24 行 ---
         mov ax,0xb800
         mov ds,ax                       ;DS = 显存段（源）
         mov es,ax                       ;ES = 显存段（目标）
         cld                             ;清除方向标志，movsw 正向移动
         mov si,0xa0                     ;SI = 第 1 行起始偏移（80×2=160=0xA0）
         mov di,0x00                     ;DI = 第 0 行起始偏移
         mov cx,1920                     ;要移动 1920 个字（24 行 × 80 列 × 2 字节 / 2）
         rep movsw                       ;批量复制（每次 2 字节，共 3840 字节）

         mov bx,3840                     ;最后一行（第 24 行）的起始字节偏移
         mov cx,80                       ;一行 80 个字符位置
 .cls:
         mov word[es:bx],0x0720          ;填充空格 (0x20) + 白底黑字属性 (0x07)
         add bx,2                        ;下一个字符位置
         loop .cls                       ;循环清除整行

         mov bx,1920                     ;滚屏后光标在最后一行行首（第 24 行 × 80 = 1920）

 .set_cursor:
         ;--- 写入新的光标位置到 VGA CRT 控制器 ---
         mov dx,0x3d4
         mov al,0x0e                     ;光标高 8 位寄存器
         out dx,al
         mov dx,0x3d5
         mov al,bh                       ;写入位置的高 8 位
         out dx,al
         mov dx,0x3d4
         mov al,0x0f                     ;光标低 8 位寄存器
         out dx,al
         mov dx,0x3d5
         mov al,bl                       ;写入位置的低 8 位
         out dx,al

         pop es                          ;恢复现场
         pop ds
         pop dx
         pop cx
         pop bx
         pop ax

         ret

;===============================================================================
SECTION data align=16 vstart=0           ;数据段（16 字节对齐，段内偏移从 0 开始）

    init_msg       db 'Starting...',0x0d,0x0a,0
                                         ;启动提示信息（回车+换行+结束符）
    inst_msg       db 'Installing a new interrupt 70H...',0
                                         ;安装中断处理程序提示
    done_msg       db 'Done.',0x0d,0x0a,0
                                         ;安装完成提示
    tips_msg       db 'Clock is now working.',0
                                         ;时钟运行提示

;===============================================================================
SECTION stack align=16 vstart=0          ;栈段（16 字节对齐）

                 resb 256                ;预留 256 字节栈空间（足够中断嵌套使用）
ss_pointer:                              ;栈顶标号（栈从此处向低地址增长）
 
;===============================================================================
SECTION program_trail                    ;程序尾部段（仅用于标记程序总长度）
program_end:                             ;program_length 引用此标号计算总字节数