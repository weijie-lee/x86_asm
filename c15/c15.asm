         ;代码清单15-2
         ;文件名：c15.asm
         ;文件说明：用户程序
         ;创建日期：2011-11-15 19:11

;============================ 扩展知识 ========================================
;
; 【用户程序如何检测自己的特权级 (CPL)】
;   在x86保护模式下，当前特权级(CPL)存储在CS寄存器的最低2位(bit 1:0)中。
;   因此获取CPL非常简单：
;     mov ax, cs        ; 读取代码段选择子
;     and al, 0x03      ; 取最低2位，即CPL值（0=Ring0, 3=Ring3）
;   本程序将CPL值转为ASCII字符（'0'-'3'）显示出来，通过 or al, 0x30 实现
;   （0x30='0'的ASCII码，0+0x30='0', 3+0x30='3'）。
;
; 【任务生命周期】
;   用户任务从创建到终止的完整流程：
;     1. 创建阶段：内核分配TCB → 加载程序到内存 → 建立LDT描述符 →
;        创建各特权级堆栈 → 创建TSS并填充完整上下文
;     2. 执行阶段：内核通过CALL far或JMP far切换到用户任务的TSS →
;        CPU自动加载TSS中保存的CS:EIP/SS:ESP/DS等 → 用户程序开始执行
;     3. 终止阶段：用户程序调用@TerminateProgram（通过调用门进入内核）→
;        内核检查NT标志位决定返回方式 → 控制权回到内核程序管理器
;
; 【CALL任务切换 vs JMP任务切换的区别（对用户程序的影响）】
;   - CALL far [tss_selector]：
;     CPU设置NT=1，并将调用者TSS选择子写入被调用任务TSS的backlink字段
;     用户任务终止时，terminate_current_task检测到NT=1，执行IRETD
;     IRETD读取backlink自动切换回调用者（程序管理器）——类似函数"返回"
;
;   - JMP far [tss_selector]：
;     CPU不设置NT，不写backlink
;     用户任务终止时，terminate_current_task检测到NT=0，
;     只能通过JMP far [prgman_tss]显式切换回程序管理器——类似"跳转"
;
;   对用户程序而言，终止方式是透明的——统一调用@TerminateProgram即可，
;   内核的terminate_current_task会自动根据NT标志选择正确的返回路径。
;
;==============================================================================

;===============================================================================
SECTION header vstart=0                          ;程序头部段——供内核加载器解析

         program_length   dd program_end          ;程序总长度（字节）#0x00，加载器据此分配内存

         head_len         dd header_end           ;程序头部的长度#0x04，加载器据此建立头部段描述符

         stack_seg        dd 0                    ;用于接收堆栈段选择子#0x08（加载器回填）
         stack_len        dd 1                    ;程序建议的堆栈大小#0x0c
                                                  ;以4KB为单位（1=4KB堆栈）

         prgentry         dd start                ;程序入口点偏移#0x10（写入TSS的EIP字段）
         code_seg         dd section.code.start   ;代码段在文件内的偏移位置#0x14（加载后回填为选择子）
         code_len         dd code_end             ;代码段长度#0x18

         data_seg         dd section.data.start   ;数据段在文件内的偏移位置#0x1c（加载后回填为选择子）
         data_len         dd data_end             ;数据段长度#0x20
;-------------------------------------------------------------------------------
         ;符号地址检索表（U-SALT: User Symbol Address Lookup Table）
         ;用户程序通过名称声明需要的内核服务，加载器负责将名称替换为调用门地址
         salt_items       dd (header_end-salt)/256 ;#0x24 U-SALT条目数

         salt:                                     ;#0x28 U-SALT起始
         PrintString      db  '@PrintString'       ;打印字符串服务——通过调用门调用内核put_string
                     times 256-($-PrintString) db 0 ;每条目固定256字节（用0填充）

         TerminateProgram db  '@TerminateProgram'   ;任务终止服务——通过调用门调用terminate_current_task
                     times 256-($-TerminateProgram) db 0

         ReadDiskData     db  '@ReadDiskData'       ;磁盘读取服务——通过调用门调用read_hard_disk_0
                     times 256-($-ReadDiskData) db 0

header_end:
  
;===============================================================================
SECTION data vstart=0                            ;用户程序数据段

         message_1        db  0x0d,0x0a          ;回车换行
                          db  '[USER TASK]: Hi! nice to meet you,'
                          db  'I am run at CPL=',0  ;字符串在此截断，CPL值将动态拼接

         message_2        db  0                  ;此处1字节将被运行时写入CPL的ASCII字符
                          db  '.Now,I must exit...',0x0d,0x0a,0  ;拼接后的完整尾部

data_end:

;===============================================================================
      [bits 32]
;===============================================================================
SECTION code vstart=0                            ;用户程序代码段
start:
         ;任务启动时，DS已由TSS恢复为头部段选择子，堆栈也已由TSS自动设置
         mov eax,ds                              ;保存头部段选择子
         mov fs,eax                              ;FS指向头部段（用于访问U-SALT中的调用门地址）

         mov eax,[data_seg]                      ;从头部获取数据段选择子（已被加载器回填）
         mov ds,eax                              ;DS切换到数据段，以便访问message_1/2

         mov ebx,message_1                       ;显示问候信息（末尾是"CPL="，尚未显示数字）
         call far [fs:PrintString]               ;通过调用门调用内核的put_string例程

         ;以下代码检测并显示当前特权级(CPL)
         mov ax,cs                               ;读取当前代码段选择子（CS）
         and al,0000_0011B                       ;取最低2位——即CPL（当前特权级，0-3）
         or al,0x0030                            ;将数字0-3转换为ASCII字符'0'-'3'
                                                 ;（0x30='0', 0x31='1', 0x32='2', 0x33='3'）
         mov [message_2],al                      ;将CPL的ASCII字符写入message_2的首字节

         mov ebx,message_2                       ;显示CPL数字和退出信息
         call far [fs:PrintString]               ;再次通过调用门调用内核打印例程

         call far [fs:TerminateProgram]          ;调用@TerminateProgram终止当前任务
                                                 ;通过调用门进入内核的terminate_current_task
                                                 ;该例程检测NT标志自动选择IRETD或JMP返回

code_end:

;-------------------------------------------------------------------------------
SECTION trail                                    ;尾部段——仅用于计算程序总长度
;-------------------------------------------------------------------------------
program_end: