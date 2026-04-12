         ;代码清单13-3
         ;文件名：c13.asm
         ;文件说明：用户程序（运行于保护模式下，通过SALT调用内核服务）
         ;创建日期：2011-10-30 15:19
         ;
         ;=========================== 扩展知识 =======================================
         ;
         ; 【用户程序头部设计】
         ;   用户程序的头部是一个固定格式的结构，用于告知内核如何加载和运行该程序：
         ;   偏移  字段             说明
         ;   0x00  program_length   程序总长度（字节），内核据此决定读取多少扇区
         ;   0x04  head_len         头部段长度，内核为其创建数据段描述符
         ;   0x08  stack_seg        保留字段，内核回写堆栈段选择子到此处
         ;   0x0C  stack_len        程序建议的堆栈大小（以4KB为单位）
         ;   0x10  prgentry         程序入口点（段内偏移），内核通过 jmp far [0x10] 跳入
         ;   0x14  code_seg         代码段起始位置 → 内核回写为代码段选择子
         ;   0x18  code_len         代码段长度
         ;   0x1C  data_seg         数据段起始位置 → 内核回写为数据段选择子
         ;   0x20  data_len         数据段长度
         ;   0x24  salt_items       SALT条目数
         ;   0x28  salt             SALT表起始（每条目256字节名称）
         ;   内核在加载过程中会将 head_len、code_seg、data_seg 等字段
         ;   从原始值（汇编偏移）替换为GDT段选择子，完成"重定位"。
         ;
         ; 【SALT——从用户程序侧的使用方式】
         ;   用户程序在头部声明自己需要的内核服务名称列表，每个名称256字节。
         ;   例如：'@PrintString'、'@TerminateProgram'、'@ReadDiskData'。
         ;   内核加载用户程序后，会用 repe cmpsd 将这些名称与内核SALT逐条匹配，
         ;   匹配成功后将名称的前6字节覆盖为：[4字节段内偏移][2字节段选择子]。
         ;
         ;   之后用户程序就可以通过以下方式调用内核服务：
         ;     call far [fs:PrintString]
         ;   其中 fs 指向头部段，PrintString 是该SALT条目在头部中的偏移。
         ;   处理器从 [fs:PrintString] 读取6字节：低4字节=EIP，高2字节=CS，
         ;   执行远调用（将当前CS:EIP压栈，跳转到目标段）。
         ;
         ; 【call far [fs:PrintString]——间接远调用】
         ;   这是一条使用段超越前缀(fs:)的间接远调用指令。
         ;   工作原理：
         ;     1) 从 FS:[PrintString] 处读取4字节偏移 + 2字节选择子
         ;     2) 将当前CS和EIP压入堆栈（保存返回地址）
         ;     3) 加载新的CS和EIP，跳转到内核服务例程
         ;     4) 内核例程执行完毕后通过 retf 返回
         ;   FS段在程序启动时被设为头部段选择子，因此可以直接引用SALT条目。
         ;
         ; 【jmp far [fs:TerminateProgram]——返回内核控制权】
         ;   与 call far 不同，jmp far 不保存返回地址。
         ;   @TerminateProgram 对应内核中的 return_point 标号，
         ;   执行后用户程序永久终止，控制权完全回到内核。
         ;   使用 jmp 而非 call 是因为用户程序不期望内核"返回"给自己。
         ;
         ;========================================================================

;一般的程序只需要提供代码段和数据段，栈段是根据用户程序的建议来定义的。
;所以代码中包括了 SECTION data  SECTION code
;=============================用户程序===========================================
SECTION header vstart=0

         program_length   dd program_end          ;程序总长度（用于内核计算扇区数）#偏移0x00

         head_len         dd header_end           ;头部段长度（内核据此创建头部段描述符）#偏移0x04

         stack_seg        dd 0                    ;保留：内核回写堆栈段选择子到这里#偏移0x08
         stack_len        dd 1                    ;建议的堆栈大小：1×4KB=4096字节#偏移0x0C

         prgentry         dd start                ;程序入口点（代码段内偏移）#偏移0x10
         code_seg         dd section.code.start   ;代码段汇编位置 → 内核回写为选择子#偏移0x14
         code_len         dd code_end             ;代码段长度#偏移0x18

         data_seg         dd section.data.start   ;数据段汇编位置 → 内核回写为选择子#偏移0x1C
         data_len         dd data_end             ;数据段长度#偏移0x20

;-------------------------------------------------------------------------------
         ;用户程序的SALT（符号地址检索表）
         ;每个条目256字节，仅包含名称；内核匹配后回写为 [偏移+选择子]
         salt_items       dd (header_end-salt)/256 ;SALT条目数#偏移0x24

         salt:                                     ;SALT表起始#偏移0x28
         PrintString      db  '@PrintString'
                     times 256-($-PrintString) db 0    ;用0填充到256字节

         TerminateProgram db  '@TerminateProgram'
                     times 256-($-TerminateProgram) db 0

         ReadDiskData     db  '@ReadDiskData'
                     times 256-($-ReadDiskData) db 0

header_end:                                 ;头部段结束标记

;===============================================================================
SECTION data vstart=0                       ;用户程序数据段

         buffer times 1024 db  0            ;通用缓冲区（用于接收磁盘读取的数据）

         message_1         db  0x0d,0x0a,0x0d,0x0a
                           db  '**********User program is runing**********'
                           db  0x0d,0x0a,0  ;程序运行提示信息（CR+LF后以0终止）
         message_2         db  '  Disk data:',0x0d,0x0a,0  ;磁盘数据提示标题

data_end:                                   ;数据段结束标记

;===============================================================================
      [bits 32]                             ;生成32位保护模式代码
;===============================================================================
SECTION code vstart=0                       ;用户程序代码段
start:
         ;=== 用户程序入口点（内核通过 jmp far [0x10] 跳到这里）===
         mov eax,ds                         ;此时DS仍指向头部段（内核设置的）
         mov fs,eax                         ;将头部段选择子保存到FS
                                            ;后续通过 fs: 前缀访问SALT条目

         mov eax,[stack_seg]                ;从头部偏移0x08读取堆栈段选择子
         mov ss,eax                         ;切换到用户程序自己的堆栈段
         mov esp,0                          ;栈指针归零（向下扩展栈从段顶部开始）

         mov eax,[data_seg]                 ;从头部偏移0x1C读取数据段选择子
         mov ds,eax                         ;DS切换到用户程序数据段

         mov ebx,message_1                  ;显示 "**********User program is runing**********"
         call far [fs:PrintString]          ;间接远调用：从fs:PrintString读取6字节(偏移+选择子)
                                            ;跳转到内核sys_routine段的put_string例程

         mov eax,100                        ;逻辑扇区号100
         mov ebx,buffer                     ;缓冲区偏移地址（在用户数据段内）
         call far [fs:ReadDiskData]         ;间接远调用内核的read_hard_disk_0例程
                                            ;将扇区100的数据读入buffer

         mov ebx,message_2                  ;显示 "  Disk data:"
         call far [fs:PrintString]

         mov ebx,buffer                     ;将读取到的磁盘数据作为字符串显示
         call far [fs:PrintString]          ;（假设数据中包含可打印字符和0终止符）

         jmp far [fs:TerminateProgram]      ;间接远跳转（注意：是jmp不是call）
                                            ;从fs:TerminateProgram读取6字节
                                            ;跳转到内核core_code段的return_point
                                            ;用户程序终止，控制权永久返回内核

code_end:                                   ;代码段结束标记

;===============================================================================
SECTION trail
;-------------------------------------------------------------------------------
program_end:                                ;程序映像结束标记，program_length由此计算