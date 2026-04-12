         ;代码清单16-1
         ;文件名：c16_core.asm
         ;文件说明：保护模式微型核心程序（含分页与虚拟内存管理）
         ;创建日期：2012-06-20 00:05
         ;
         ;===========================================================================
         ;  扩展知识：分页环境下的内核核心机制
         ;===========================================================================
         ;
         ;  【一、页分配位图（Page Allocation Bitmap / 页位图）】
         ;    内核使用一个位图来跟踪物理内存中每个4KB页的分配状态：
         ;      ● 位图中每1个bit对应1个4KB物理页
         ;      ● bit=1 表示该页已被分配（占用），bit=0 表示该页空闲
         ;      ● 64字节的位图可管理 64*8=512 个页 = 2MB 物理内存
         ;
         ;    关键指令 —— bts（Bit Test and Set）：
         ;      bts [page_bit_map], eax
         ;      作用：测试位图中第 eax 位，将原值存入CF标志，然后将该位置1
         ;      配合 jnc（Jump if Not Carry）：若CF=0说明原来该位为0（页空闲），
         ;      分配成功；若CF=1说明该页已被占用，需继续搜索下一位。
         ;      这是一种原子化的"测试并设置"操作，适合页分配场景。
         ;
         ;  【二、alloc_inst_a_page —— 分配并安装页】
         ;    该例程不仅分配一个物理页，还将其安装到当前活动的二级页表结构中。
         ;    核心逻辑利用了页目录自映射技巧：
         ;
         ;    ① 计算PDE索引（页目录项索引）：
         ;       pde_index = (linear_addr >> 22)
         ;       即线性地址的高10位确定在页目录中的位置
         ;       访问PDE：地址 = 0xFFFFF000 + pde_index * 4
         ;       （0xFFFFF000是自映射后页目录自身的线性地址）
         ;
         ;    ② 若PDE的P位=0，说明对应的页表不存在：
         ;       → 先调用allocate_a_4k_page分配一个物理页作为新页表
         ;       → 将新页表的物理地址写入PDE（设置P=1, R/W=1, U/S=1）
         ;
         ;    ③ 计算PTE索引（页表项索引）：
         ;       pte_index = (linear_addr >> 12) & 0x3FF
         ;       即线性地址的中间10位确定在页表中的位置
         ;       访问PTE：地址 = 0xFFC00000 + (pde_index * 4096) + pte_index * 4
         ;       （0xFFC00000是自映射后所有页表的线性地址起始）
         ;
         ;    ④ 分配一个物理页（这才是最终要安装的页），写入PTE
         ;
         ;  【三、create_copy_cur_pdir —— 创建并复制当前页目录】
         ;    用于创建新任务时，为其分配独立的地址空间：
         ;      ① 调用allocate_a_4k_page分配一个物理页作为新页目录
         ;      ② 利用自映射技巧：将新PD的物理地址写入当前PD的倒数第2项
         ;         [0xFFFFFFF8]（即PD[1022]），使新PD临时映射到线性地址0xFFFFE000
         ;      ③ 用rep movsd将当前页目录(0xFFFFF000)的全部1024项复制到新PD(0xFFFFE000)
         ;      ④ 返回新页目录的物理地址，供写入新任务TSS的CR3域
         ;    这样新任务初始时共享内核的页表映射，但拥有独立的页目录，
         ;    后续可以独立修改低2GB的用户空间映射。
         ;
         ;  【四、平坦内存模型与分页的关系】
         ;    本内核中所有段的基地址仍为0、界限仍为4GB（"平坦模型"）。
         ;    分段机制不做地址隔离，而是由分页机制实现：
         ;      ● 不同任务拥有不同的页目录（CR3不同）
         ;      ● 相同的线性地址在不同任务中映射到不同的物理页
         ;      ● 内核空间（高2GB）的页目录项在所有任务中相同 → 共享
         ;      ● 用户空间（低2GB）的页目录项每个任务独立 → 隔离
         ;
         ;  【五、invlpg 指令（TLB刷新）】
         ;    invlpg [线性地址]
         ;    功能：使TLB（Translation Lookaside Buffer）中缓存的指定页的
         ;    地址转换条目失效。当修改了页表项后，必须刷新TLB才能使修改生效。
         ;    本章(c16)未直接使用invlpg，而是通过重新加载CR3来刷新整个TLB。
         ;    在实际OS中，invlpg更高效（仅刷新单页的TLB条目）。
         ;
         ;===========================================================================

         ;以下常量定义部分。内核的大部分内容都应当固定
         ;--- GDT中各段描述符对应的选择子（索引*8，TI=0表示GDT，RPL=00） ---
         core_code_seg_sel     equ  0x38    ;内核代码段选择子（GDT第7项：0x38=7*8）
         core_data_seg_sel     equ  0x30    ;内核数据段选择子（GDT第6项：0x30=6*8）
         sys_routine_seg_sel   equ  0x28    ;系统公共例程代码段选择子（GDT第5项）
         video_ram_seg_sel     equ  0x20    ;视频显示缓冲区段选择子（GDT第4项）
         core_stack_seg_sel    equ  0x18    ;内核堆栈段选择子（GDT第3项）
         mem_0_4_gb_seg_sel    equ  0x08    ;整个0~4GB内存的平坦数据段选择子（GDT第1项）

;===============================================================================
         ;以下是系统核心的头部，用于MBR加载内核时解析
         ;头部各字段在固定偏移处，MBR通过偏移直接读取
         core_length      dd core_end       ;#00：核心程序总长度（字节）

         sys_routine_seg  dd section.sys_routine.start
                                            ;#04：系统公用例程段在文件中的偏移

         core_data_seg    dd section.core_data.start
                                            ;#08：核心数据段在文件中的偏移

         core_code_seg    dd section.core_code.start
                                            ;#0C：核心代码段在文件中的偏移

         core_entry       dd start          ;#10：核心代码段入口点偏移地址
                          dw core_code_seg_sel
                                            ;#14：核心代码段选择子（与入口偏移组成远指针）

;===============================================================================
         [bits 32]
;===============================================================================
SECTION sys_routine vstart=0                ;系统公共例程代码段（供内核和用户程序通过调用门调用）
;-------------------------------------------------------------------------------
         ;字符串显示例程：逐字符输出0终止的字符串，并自动移动光标
put_string:                                 ;显示0终止的字符串并移动光标
                                            ;输入：DS:EBX=字符串起始地址
         push ecx
  .getc:
         mov cl,[ebx]                       ;取当前字符
         or cl,cl                           ;是否为0（字符串终止符）？
         jz .exit                           ;是，退出
         call put_char                      ;否，调用单字符显示例程
         inc ebx                            ;指向下一个字符
         jmp .getc                          ;继续循环

  .exit:
         pop ecx
         retf                               ;段间返回（因为是通过远调用进入的）

;-------------------------------------------------------------------------------
put_char:                                   ;在当前光标处显示一个字符，并推进光标
                                            ;仅用于段内近调用（由put_string等调用）
                                            ;输入：CL=字符ASCII码
         pushad

         ;--- 读取当前光标位置（通过VGA的CRTC寄存器） ---
         mov dx,0x3d4                       ;CRTC地址寄存器
         mov al,0x0e                        ;索引0x0E：光标位置高8位
         out dx,al
         inc dx                             ;0x3D5：CRTC数据寄存器
         in al,dx                           ;读光标位置高字节
         mov ah,al

         dec dx                             ;0x3D4
         mov al,0x0f                        ;索引0x0F：光标位置低8位
         out dx,al
         inc dx                             ;0x3D5
         in al,dx                           ;读光标位置低字节
         mov bx,ax                          ;BX=光标位置（0~1999，对应80*25屏幕）

         cmp cl,0x0d                        ;是回车符(CR)？
         jnz .put_0a
         mov ax,bx                          ;计算当前行首位置：光标位置 / 80 * 80
         mov bl,80
         div bl
         mul bl
         mov bx,ax                          ;BX=当前行首
         jmp .set_cursor

  .put_0a:
         cmp cl,0x0a                        ;是换行符(LF)？
         jnz .put_other
         add bx,80                          ;光标下移一行
         jmp .roll_screen

  .put_other:                               ;普通可显示字符
         push es
         mov eax,video_ram_seg_sel          ;切换ES到显存段（基地址0x000B8000）
         mov es,eax
         shl bx,1                           ;光标位置*2=显存中的字节偏移（每字符占2字节）
         mov [es:bx],cl                     ;写入字符（属性字节保持不变）
         pop es

         ;将光标位置推进一个字符
         shr bx,1                           ;恢复光标编号
         inc bx                             ;前进一位

  .roll_screen:
         cmp bx,2000                        ;光标位置>=2000？(80*25=2000，超出屏幕)
         jl .set_cursor                     ;未超出，直接设置新光标位置

         ;--- 屏幕滚动：将第1~24行上移到第0~23行，清空最后一行 ---
         push ds
         push es
         mov eax,video_ram_seg_sel
         mov ds,eax                         ;DS=ES=显存段
         mov es,eax
         cld                                ;方向标志清零，字符串操作向高地址方向
         mov esi,0xa0                       ;源=第1行起始（80字符*2字节=160=0xA0）
         mov edi,0x00                       ;目的=第0行起始
         mov ecx,1920                       ;移动1920个双字=24行*80字符*2字节÷4
         rep movsd                          ;批量复制（32位模式使用ESI/EDI/ECX）
         mov bx,3840                        ;最后一行起始偏移（24*80*2=3840）
         mov ecx,80                         ;清空80个字符位置
  .cls:
         mov word[es:bx],0x0720             ;写入空格(0x20)+灰色属性(0x07)
         add bx,2
         loop .cls

         pop es
         pop ds

         mov bx,1920                        ;光标设置到最后一行行首（第24行*80=1920）

  .set_cursor:
         ;--- 将新光标位置写回VGA CRTC寄存器 ---
         mov dx,0x3d4
         mov al,0x0e                        ;光标位置高8位
         out dx,al
         inc dx                             ;0x3D5
         mov al,bh
         out dx,al
         dec dx                             ;0x3D4
         mov al,0x0f                        ;光标位置低8位
         out dx,al
         inc dx                             ;0x3D5
         mov al,bl
         out dx,al

         popad

         ret                                ;段内近返回                                

;-------------------------------------------------------------------------------
;  子过程：read_hard_disk_0 —— 从硬盘读取一个逻辑扇区（LBA模式）
;  输入：EAX=逻辑扇区号
;        DS:EBX=目标缓冲区地址
;  返回：EBX=EBX+512（自动指向下一个空闲缓冲区位置）
;-------------------------------------------------------------------------------
read_hard_disk_0:
         push eax
         push ecx
         push edx

         push eax

         mov dx,0x1f2
         mov al,1
         out dx,al                          ;向扇区计数端口写入1（读1个扇区）

         inc dx                             ;0x1F3：LBA第7~0位
         pop eax
         out dx,al                          ;写入LBA低8位

         inc dx                             ;0x1F4：LBA第15~8位
         mov cl,8
         shr eax,cl
         out dx,al                          ;写入LBA的8~15位

         inc dx                             ;0x1F5：LBA第23~16位
         shr eax,cl
         out dx,al                          ;写入LBA的16~23位

         inc dx                             ;0x1F6：LBA第27~24位+驱动器选择
         shr eax,cl
         or al,0xe0                         ;高4位1110=LBA模式+主盘
         out dx,al

         inc dx                             ;0x1F7：命令端口
         mov al,0x20                        ;发送READ SECTORS命令(0x20)
         out dx,al

  .waits:
         in al,dx                           ;读状态寄存器
         and al,0x88                        ;检查BSY(bit7)和DRQ(bit3)
         cmp al,0x08                        ;等待BSY=0且DRQ=1
         jnz .waits                         ;未就绪则继续轮询

         mov ecx,256                        ;每扇区512字节=256个字
         mov dx,0x1f0                       ;0x1F0：数据端口
  .readw:
         in ax,dx                           ;每次读入16位数据
         mov [ebx],ax                       ;写入缓冲区
         add ebx,2                          ;缓冲区指针前移
         loop .readw                        ;循环256次完成整个扇区的读取

         pop edx
         pop ecx
         pop eax

         retf                               ;段间远返回 

;-------------------------------------------------------------------------------
;  子过程：put_hex_dword —— 将一个32位双字以十六进制形式显示在屏幕上
;  调试辅助工具：汇编程序极难一次成功，此例程可辅助调试
;  输入：EDX=要转换并显示的32位数字
;  输出：无（在当前光标位置显示8个十六进制字符）
;-------------------------------------------------------------------------------
put_hex_dword:
         pushad
         push ds

         mov ax,core_data_seg_sel           ;切换到核心数据段以访问转换表
         mov ds,ax

         mov ebx,bin_hex                    ;EBX指向"0123456789ABCDEF"查找表
         mov ecx,8                          ;32位=8个十六进制位
  .xlt:
         rol edx,4                          ;循环左移4位，使最高4位移到最低4位
         mov eax,edx
         and eax,0x0000000f                 ;取最低4位（0~15）
         xlat                               ;AL=DS:[EBX+AL]，查表得到对应的ASCII字符

         push ecx
         mov cl,al                          ;将ASCII字符传给put_char
         call put_char                      ;显示该字符
         pop ecx

         loop .xlt                          ;循环8次，逐位显示

         pop ds
         popad

         retf                               ;段间远返回
      
;-------------------------------------------------------------------------------
;  子过程：set_up_gdt_descriptor —— 在GDT末尾安装一个新的段描述符
;  输入：EDX:EAX=完整的8字节描述符
;  输出：CX=新描述符的选择子
;-------------------------------------------------------------------------------
set_up_gdt_descriptor:
         push eax
         push ebx
         push edx

         push ds
         push es

         mov ebx,core_data_seg_sel          ;切换到核心数据段以访问pgdt变量
         mov ds,ebx

         sgdt [pgdt]                        ;将当前GDTR的值存入pgdt（6字节：界限+基地址）

         mov ebx,mem_0_4_gb_seg_sel
         mov es,ebx                         ;ES指向0~4GB平坦段，用于直接写内存

         movzx ebx,word [pgdt]              ;取GDT界限（当前最后一字节的偏移）
         inc bx                             ;+1 = GDT总字节数 = 新描述符的偏移
         add ebx,[pgdt+2]                   ;+ GDT基地址 = 新描述符在内存中的线性地址

         mov [es:ebx],eax                   ;写入描述符的低32位
         mov [es:ebx+4],edx                 ;写入描述符的高32位

         add word [pgdt],8                  ;GDT界限增加8（一个描述符的大小）

         lgdt [pgdt]                        ;重新加载GDTR，使新描述符对处理器可见

         mov ax,[pgdt]                      ;取更新后的GDT界限
         xor dx,dx
         mov bx,8
         div bx                             ;(界限+1)/8 = 描述符总数；AX=总数-1的商...
         mov cx,ax                          ;实际是最后一个描述符的索引
         shl cx,3                           ;左移3位构造选择子（TI=0, RPL=00）

         pop es
         pop ds

         pop edx
         pop ebx
         pop eax

         retf                               ;段间远返回
;-------------------------------------------------------------------------------
;  子过程：make_seg_descriptor —— 构造存储器/系统段描述符
;  输入：EAX=线性基地址, EBX=段界限（20位）, ECX=属性（原始位置）
;  返回：EDX:EAX=完整的8字节描述符
;-------------------------------------------------------------------------------
make_seg_descriptor:
         mov edx,eax
         shl eax,16
         or ax,bx                           ;低32位：[基地址15:0 | 界限15:0]

         and edx,0xffff0000                 ;保留基地址高16位
         rol edx,8
         bswap edx                          ;字节序调整，使基地址31:24和23:16就位

         xor bx,bx                          ;清除界限低16位，保留高4位
         or edx,ebx                         ;装配界限的19:16位

         or edx,ecx                         ;合并属性（G、DB、P、DPL、S、TYPE等）

         retf                               ;段间远返回

;-------------------------------------------------------------------------------
;  子过程：make_gate_descriptor —— 构造门描述符（调用门、中断门等）
;  输入：EAX=门代码在段内的偏移地址
;         BX=门代码所在段的选择子
;         CX=门类型及属性（各属性位在原始位置）
;  返回：EDX:EAX=完整的8字节门描述符
;  门描述符格式：
;    低32位：[段选择子16位 | 偏移地址低16位]
;    高32位：[偏移地址高16位 | 属性/类型]
;-------------------------------------------------------------------------------
make_gate_descriptor:
         push ebx
         push ecx

         mov edx,eax
         and edx,0xffff0000                 ;EDX=偏移地址的高16位（保留在高16位）
         or dx,cx                           ;EDX低16位=门的属性/类型

         and eax,0x0000ffff                 ;EAX=偏移地址的低16位
         shl ebx,16                         ;EBX高16位=段选择子
         or eax,ebx                         ;EAX=[选择子 | 偏移低16位]

         pop ecx
         pop ebx

         retf                               ;段间远返回                                   
                             
;-------------------------------------------------------------------------------
;  子过程：allocate_a_4k_page —— 从页位图中分配一个4KB物理页
;  输入：无
;  输出：EAX=分配到的页的物理地址（4KB对齐）
;  原理：遍历页位图，用bts指令找到第一个空闲位(bit=0)，将其置1并返回对应物理地址
;-------------------------------------------------------------------------------
allocate_a_4k_page:
         push ebx
         push ecx
         push edx
         push ds

         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换到核心数据段以访问页位图

         xor eax,eax                        ;从第0位开始搜索
  .b1:
         bts [page_bit_map],eax             ;测试第EAX位并将其置1，原值存入CF
         jnc .b2                            ;CF=0 → 该位原来为0（页空闲），分配成功！
         inc eax                            ;该页已占用，检查下一位
         cmp eax,page_map_len*8             ;是否已检查完所有位？
         jl .b1                             ;未完，继续搜索

         ;所有页都已分配，打印错误信息并停机
         mov ebx,message_3
         call sys_routine_seg_sel:put_string
         hlt                                ;没有可分配的页，处理器停机

  .b2:
         shl eax,12                         ;位索引 * 4096 = 页的物理地址（左移12位=乘以0x1000）

         pop ds
         pop edx
         pop ecx
         pop ebx

         ret                                ;段内近返回（仅被内核内部调用）
         
;-------------------------------------------------------------------------------
;  子过程：alloc_inst_a_page —— 分配一个物理页并安装到当前活动的二级页表中
;  输入：EBX=要映射的线性地址
;  输出：无（该线性地址对应的物理页已分配并安装）
;
;  核心思路：利用页目录自映射技巧(PD[1023]=PD自身)，通过线性地址直接访问页目录和页表
;  步骤：① 检查PDE是否存在 → 不存在则创建页表
;        ② 在页表中安装新分配的物理页
;-------------------------------------------------------------------------------
alloc_inst_a_page:
         push eax
         push ebx
         push esi
         push ds

         mov eax,mem_0_4_gb_seg_sel
         mov ds,eax                         ;DS指向0~4GB平坦段，以便直接访问任意线性地址

         ;--- 第一步：检查该线性地址对应的页表是否存在 ---
         ;计算PDE索引：取线性地址高10位，即 (linear_addr >> 22)
         mov esi,ebx                        ;ESI=线性地址
         and esi,0xffc00000                 ;保留高10位（目录索引部分）
         shr esi,20                         ;右移20位（=右移22位再左移2位）→ 索引*4=PDE偏移
         or esi,0xfffff000                  ;加上页目录自身的线性地址0xFFFFF000 → PDE的完整线性地址
                                            ;（自映射：0xFFFFF000 = PD[1023]→PD, PD[1023]→PD[idx]）

         test dword [esi],0x00000001        ;检测PDE的P位：页表是否存在？
         jnz .b1                            ;P=1 → 页表已存在，跳过创建

         ;--- PDE不存在，需要先创建页表 ---
         call allocate_a_4k_page            ;分配一个4KB物理页作为新页表
         or eax,0x00000007                  ;设置属性：P=1, R/W=1, U/S=1（用户可访问）
         mov [esi],eax                      ;将新页表的物理地址+属性写入PDE

  .b1:
         ;--- 第二步：访问该线性地址对应的页表 ---
         ;利用自映射技巧计算页表的线性地址
         mov esi,ebx                        ;ESI=原始线性地址
         shr esi,10                         ;右移10位（=右移12位再左移2位）→ PTE偏移量的一部分
         and esi,0x003ff000                 ;保留中间的目录索引部分（页表选择）
         or esi,0xffc00000                  ;加上页表区域基地址0xFFC00000 → 目标页表的线性地址

         ;--- 第三步：计算PTE在页表中的偏移并安装物理页 ---
         and ebx,0x003ff000                 ;保留线性地址的中间10位（页表索引）
         shr ebx,10                         ;右移10位（=右移12位再左移2位）→ PTE偏移
         or esi,ebx                         ;ESI = 页表线性地址 + PTE偏移 = PTE的完整线性地址
         call allocate_a_4k_page            ;分配一个4KB物理页（这才是最终要映射的物理页）
         or eax,0x00000007                  ;设置属性：P=1, R/W=1, U/S=1
         mov [esi],eax                      ;将物理页地址+属性写入PTE，映射建立完成！

         pop ds
         pop esi
         pop ebx
         pop eax

         retf                               ;段间远返回  

;-------------------------------------------------------------------------------
;  子过程：create_copy_cur_pdir —— 创建新页目录并复制当前页目录的全部内容
;  输入：无
;  输出：EAX=新页目录的物理地址
;
;  用途：为新任务创建独立的地址空间。新任务初始共享内核映射(高2GB)，
;        之后可独立修改用户空间(低2GB)的映射。
;
;  技巧：利用PD[1022]（倒数第2项）临时映射新PD，使其可通过线性地址访问：
;    [0xFFFFFFF8] = PD[1022+1/2...]  实际是PD[1023]页表视图的第1022项
;    新PD临时可通过 0xFFFFE000 访问（自映射下，目录索引1023 + 页表索引1022）
;-------------------------------------------------------------------------------
create_copy_cur_pdir:
         push ds
         push es
         push esi
         push edi
         push ebx
         push ecx

         mov ebx,mem_0_4_gb_seg_sel
         mov ds,ebx                         ;DS=ES=0~4GB平坦段
         mov es,ebx

         call allocate_a_4k_page            ;分配一个物理页作为新页目录
         mov ebx,eax                        ;EBX=新PD的物理地址
         or ebx,0x00000007                  ;设置属性：P=1, R/W=1, U/S=1
         mov [0xfffffff8],ebx               ;写入当前PD的倒数第2项（PD[1022]）
                                            ;使新PD临时映射到线性地址0xFFFFE000

         mov esi,0xfffff000                 ;ESI → 当前页目录的线性地址（自映射）
         mov edi,0xffffe000                 ;EDI → 新页目录的临时线性地址（通过PD[1022]映射）
         mov ecx,1024                       ;ECX=页目录共1024项（每项4字节）
         cld                                ;方向标志清零，正向复制
         repe movsd                         ;将当前PD的全部内容复制到新PD

         pop ecx
         pop ebx
         pop edi
         pop esi
         pop es
         pop ds

         retf                               ;段间远返回（EAX中已保存新PD的物理地址）
         
;-------------------------------------------------------------------------------
;  子过程：terminate_current_task —— 终止当前正在运行的任务
;  注意：执行此例程时，当前任务仍在运行中（此例程是当前任务代码的一部分）
;  通过检测EFLAGS的NT(Nested Task)位决定返回方式：
;    NT=1：任务是嵌套的，用iretd返回外层任务
;    NT=0：直接跳转到程序管理器任务
;-------------------------------------------------------------------------------
terminate_current_task:
         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换到核心数据段

         pushfd                             ;将EFLAGS压栈
         pop edx                            ;弹出到EDX以便检测

         test dx,0100_0000_0000_0000B       ;测试NT位（bit14）
         jnz .b1                            ;NT=1：当前任务是通过CALL/中断嵌套的，用iretd返回
         jmp far [program_man_tss]          ;NT=0：直接任务切换到程序管理器
  .b1:
         iretd                              ;中断/CALL返回，自动切换到外层任务

sys_routine_end:

;===============================================================================
SECTION core_data vstart=0                  ;系统核心的数据段
;-------------------------------------------------------------------------------
         pgdt             dw  0             ;GDT伪描述符（6字节）：界限
                          dd  0             ;GDT基地址（由sgdt/lgdt使用）

         ;--- 页分配位图：每bit对应一个4KB物理页 ---
         ;  0xFF=该字节对应的8个页全部已占用
         ;  0x55=0101_0101，交替占用/空闲
         ;  0x00=该字节对应的8个页全部空闲
         page_bit_map     db  0xff,0xff,0xff,0xff,0xff,0x55,0x55,0xff
                          db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                          db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                          db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                          db  0x55,0x55,0x55,0x55,0x55,0x55,0x55,0x55
                          db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
                          db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
                          db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
         page_map_len     equ $-page_bit_map ;位图总字节数（64字节=管理512个页=2MB）
                          
         ;--- 符号地址检索表（C-SALT）---
         ;  内核提供的系统服务入口表，用户程序通过符号名匹配来获取服务入口
         ;  每条目：256字节符号名 + 4字节偏移地址 + 2字节段选择子
         salt:
         salt_1           db  '@PrintString'
                     times 256-($-salt_1) db 0       ;符号名填充至256字节
                          dd  put_string               ;服务例程在段内的偏移
                          dw  sys_routine_seg_sel      ;服务例程所在段的选择子

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
                          dd  terminate_current_task
                          dw  sys_routine_seg_sel

         salt_item_len   equ $-salt_4       ;每个SALT条目的长度（256+4+2=262字节）
         salt_items      equ ($-salt)/salt_item_len  ;SALT条目总数

         message_0        db  '  Working in system core,protect mode.'
                          db  0x0d,0x0a,0   ;内核启动提示信息

         message_1        db  '  Paging is enabled.System core is mapped to'
                          db  ' address 0x80000000.',0x0d,0x0a,0
                                            ;分页开启、内核映射到高半区完成的提示

         message_2        db  0x0d,0x0a
                          db  '  System wide CALL-GATE mounted.',0x0d,0x0a,0
                                            ;系统调用门安装完成的提示

         message_3        db  '********No more pages********',0
                                            ;物理页耗尽时的错误信息

         message_4        db  0x0d,0x0a,'  Task switching...@_@',0x0d,0x0a,0
                                            ;任务切换时的提示

         message_5        db  0x0d,0x0a,'  Processor HALT.',0
                                            ;处理器停机提示


         bin_hex          db '0123456789ABCDEF'
                                            ;十六进制转ASCII查找表（供put_hex_dword使用）

         core_buf   times 512 db 0          ;内核通用缓冲区（512字节=1扇区大小）

         cpu_brnd0        db 0x0d,0x0a,'  ',0   ;CPU品牌信息前缀
         cpu_brand  times 52 db 0               ;CPU品牌字符串（由CPUID指令填充）
         cpu_brnd1        db 0x0d,0x0a,0x0d,0x0a,0  ;CPU品牌信息后缀

         ;--- 任务控制块(TCB)链表 ---
         tcb_chain        dd  0             ;TCB链表头指针（0=链表为空）

         ;--- 内核空间管理信息 ---
         core_next_laddr  dd  0x80100000    ;内核空间中下一个可分配的线性地址
                                            ;（从0x80100000开始，0x80000000~0x800FFFFF留给内核自身）
         program_man_tss  dd  0             ;程序管理器的TSS描述符选择子（远指针的偏移部分）
                          dw  0             ;程序管理器的TSS描述符选择子（远指针的选择子部分）

core_data_end:
               
;===============================================================================
SECTION core_code vstart=0                  ;内核核心代码段
;-------------------------------------------------------------------------------
;  子过程：fill_descriptor_in_ldt —— 在任务的LDT中安装一个新的段描述符
;  输入：EDX:EAX=完整的8字节描述符
;        EBX=该任务的TCB基地址
;  输出：CX=新描述符的选择子（TI=1指向LDT，RPL由调用者设置）
;-------------------------------------------------------------------------------
fill_descriptor_in_ldt:
         push eax
         push edx
         push edi
         push ds

         mov ecx,mem_0_4_gb_seg_sel
         mov ds,ecx                         ;DS指向0~4GB平坦段

         mov edi,[ebx+0x0c]                 ;从TCB中取得LDT的线性基地址

         xor ecx,ecx
         mov cx,[ebx+0x0a]                  ;从TCB中取得LDT当前界限
         inc cx                             ;界限+1=LDT总字节数=新描述符的偏移

         mov [edi+ecx+0x00],eax             ;写入新描述符的低32位
         mov [edi+ecx+0x04],edx             ;写入新描述符的高32位

         add cx,8
         dec cx                             ;新的LDT界限 = 原界限 + 8 - 1 + 1... = 原界限+7

         mov [ebx+0x0a],cx                  ;更新TCB中的LDT界限值

         ;计算新描述符的选择子
         mov ax,cx
         xor dx,dx
         mov cx,8
         div cx                             ;(界限+1)/8 = 描述符索引（实际是最后一项的索引）

         mov cx,ax
         shl cx,3                           ;左移3位构造选择子
         or cx,0000_0000_0000_0100B         ;设置TI=1（指向LDT），RPL=00

         pop ds
         pop edi
         pop edx
         pop eax

         ret                                ;段内近返回
      
;-------------------------------------------------------------------------------
;  子过程：load_relocate_program —— 加载用户程序并进行重定位
;  输入：通过堆栈传递参数：
;        PUSH 逻辑扇区号（用户程序在硬盘上的起始LBA扇区）
;        PUSH 任务控制块(TCB)基地址
;  输出：无（用户程序已加载到虚拟地址空间，TSS/LDT已创建）
;-------------------------------------------------------------------------------
load_relocate_program:
         pushad

         push ds
         push es

         mov ebp,esp                        ;EBP作为栈帧基址，用于访问堆栈参数

         mov ecx,mem_0_4_gb_seg_sel
         mov es,ecx                         ;ES指向0~4GB平坦段

         ;--- 清空当前页目录的前半部分（低2GB用户空间） ---
         ;每个新任务的用户空间从零开始映射，需先清除旧的页目录项
         mov ebx,0xfffff000                 ;页目录自身的线性地址（自映射）
         xor esi,esi
  .b1:
         mov dword [es:ebx+esi*4],0x00000000  ;将PDE清零（P=0，页表无效）
         inc esi
         cmp esi,512                        ;前512项对应低2GB地址空间(0~0x7FFFFFFF)
         jl .b1

         ;--- 读取用户程序头部信息 ---
         mov eax,core_data_seg_sel
         mov ds,eax                         ;切换DS到内核数据段

         mov eax,[ebp+12*4]                 ;从堆栈取出用户程序起始扇区号（跳过pushad的8个+push ds+push es+ebp+返回地址）
         mov ebx,core_buf                   ;先读到内核缓冲区中解析头部
         call sys_routine_seg_sel:read_hard_disk_0

         ;--- 计算用户程序需要占用多少个4KB页 ---
         mov eax,[core_buf]                 ;用户程序头部第一个双字=程序总长度
         mov ebx,eax
         and ebx,0xfffff000                 ;向下4KB对齐
         add ebx,0x1000                     ;加4KB（向上取整）
         test eax,0x00000fff                ;原始大小是否恰好4KB对齐？
         cmovnz eax,ebx                     ;不是 → 使用向上取整后的值

         mov ecx,eax
         shr ecx,12                         ;总字节数 ÷ 4096 = 需要的4KB页数

         mov eax,mem_0_4_gb_seg_sel         ;切换DS到0~4GB平坦段
         mov ds,eax

         mov eax,[ebp+12*4]                 ;重新取出起始扇区号
         mov esi,[ebp+11*4]                 ;从堆栈取得TCB的线性基地址
  .b2:
         ;每个4KB页：分配物理页并映射到用户虚拟地址空间，然后从硬盘读入8个扇区(4KB)
         mov ebx,[es:esi+0x06]              ;从TCB取得当前可用的线性地址
         add dword [es:esi+0x06],0x1000     ;线性地址推进4KB，准备下一次分配
         call sys_routine_seg_sel:alloc_inst_a_page  ;分配物理页并安装到页表

         push ecx
         mov ecx,8                          ;每页=4KB=8个扇区
  .b3:
         call sys_routine_seg_sel:read_hard_disk_0  ;读取一个扇区到已映射的线性地址
         inc eax                            ;下一个扇区号
         loop .b3                           ;循环8次，填满一个4KB页

         pop ecx
         loop .b2                           ;循环直到所有页都已加载

         ;--- 为用户任务创建TSS（任务状态段） ---
         ;TSS必须在内核全局地址空间中分配（高2GB），因为任务切换时处理器直接访问
         mov eax,core_data_seg_sel          ;切换DS到内核数据段
         mov ds,eax

         mov ebx,[core_next_laddr]          ;在内核空间分配一个4KB页给TSS
         call sys_routine_seg_sel:alloc_inst_a_page
         add dword [core_next_laddr],4096   ;内核空间线性地址向前推进4KB

         mov [es:esi+0x14],ebx              ;在TCB偏移0x14处记录TSS的线性地址
         mov word [es:esi+0x12],103         ;在TCB偏移0x12处记录TSS界限=103（TSS最小104字节）

         ;--- 在用户任务的局部地址空间内创建LDT（局部描述符表） ---
         mov ebx,[es:esi+0x06]              ;从TCB取得可用的线性地址
         add dword [es:esi+0x06],0x1000     ;推进4KB
         call sys_routine_seg_sel:alloc_inst_a_page
         mov [es:esi+0x0c],ebx              ;在TCB偏移0x0C处记录LDT的线性地址

         ;--- 在LDT中建立用户程序代码段描述符 ---
         mov eax,0x00000000                 ;基地址=0（平坦模型，分页提供隔离）
         mov ebx,0x000fffff                 ;界限=0xFFFFF（配合4KB粒度=4GB）
         mov ecx,0x00c0f800                 ;属性：4KB粒度,32位,只执行代码段,DPL=3(用户级)
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi                        ;EBX=TCB基地址
         call fill_descriptor_in_ldt        ;安装到LDT中
         or cx,0000_0000_0000_0011B         ;设置选择子的RPL=3（用户特权级）

         mov ebx,[es:esi+0x14]              ;取TSS线性地址
         mov [es:ebx+76],cx                 ;填写TSS偏移76处的CS域

         ;--- 在LDT中建立用户程序数据段描述符 ---
         mov eax,0x00000000                 ;基地址=0
         mov ebx,0x000fffff                 ;界限=4GB
         mov ecx,0x00c0f200                 ;属性：4KB粒度,32位,可读写数据段,DPL=3
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0011B         ;RPL=3

         mov ebx,[es:esi+0x14]              ;取TSS线性地址
         mov [es:ebx+84],cx                 ;填写TSS的DS域
         mov [es:ebx+72],cx                 ;填写TSS的ES域
         mov [es:ebx+88],cx                 ;填写TSS的FS域
         mov [es:ebx+92],cx                 ;填写TSS的GS域

         ;--- 创建用户任务的3特权级堆栈（用户级固有堆栈） ---
         mov ebx,[es:esi+0x06]              ;取可用线性地址
         add dword [es:esi+0x06],0x1000     ;推进4KB
         call sys_routine_seg_sel:alloc_inst_a_page

         mov ebx,[es:esi+0x14]              ;取TSS线性地址
         mov [es:ebx+80],cx                 ;填写TSS的SS域（使用数据段选择子）
         mov edx,[es:esi+0x06]              ;堆栈的高端线性地址（栈从高向低增长）
         mov [es:ebx+56],edx                ;填写TSS的ESP域

         ;--- 创建0特权级堆栈（内核级，用于特权级切换时的堆栈） ---
         mov ebx,[es:esi+0x06]
         add dword [es:esi+0x06],0x1000
         call sys_routine_seg_sel:alloc_inst_a_page

         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c09200                 ;属性：4KB粒度,可读写数据段,DPL=0(内核级)
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0000B         ;RPL=0

         mov ebx,[es:esi+0x14]
         mov [es:ebx+8],cx                  ;填写TSS的SS0域（0特权级堆栈段选择子）
         mov edx,[es:esi+0x06]
         mov [es:ebx+4],edx                 ;填写TSS的ESP0域（0特权级堆栈指针）

         ;--- 创建1特权级堆栈 ---
         mov ebx,[es:esi+0x06]
         add dword [es:esi+0x06],0x1000
         call sys_routine_seg_sel:alloc_inst_a_page

         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c0b200                 ;属性：4KB粒度,可读写数据段,DPL=1
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0001B         ;RPL=1

         mov ebx,[es:esi+0x14]
         mov [es:ebx+16],cx                 ;填写TSS的SS1域
         mov edx,[es:esi+0x06]
         mov [es:ebx+12],edx                ;填写TSS的ESP1域

         ;--- 创建2特权级堆栈 ---
         mov ebx,[es:esi+0x06]
         add dword [es:esi+0x06],0x1000
         call sys_routine_seg_sel:alloc_inst_a_page

         mov eax,0x00000000
         mov ebx,0x000fffff
         mov ecx,0x00c0d200                 ;属性：4KB粒度,可读写数据段,DPL=2
         call sys_routine_seg_sel:make_seg_descriptor
         mov ebx,esi
         call fill_descriptor_in_ldt
         or cx,0000_0000_0000_0010B         ;RPL=2

         mov ebx,[es:esi+0x14]
         mov [es:ebx+24],cx                 ;填写TSS的SS2域
         mov edx,[es:esi+0x06]
         mov [es:ebx+20],edx                ;填写TSS的ESP2域 


         ;--- 重定位用户程序的SALT（符号地址检索表） ---
         ;将用户程序中的符号名替换为内核提供的调用门选择子
         mov eax,mem_0_4_gb_seg_sel         ;ES指向4GB平坦段以访问用户程序
         mov es,eax

         mov eax,core_data_seg_sel          ;DS指向内核数据段以访问C-SALT
         mov ds,eax

         cld                                ;字符串比较方向：正向

         mov ecx,[es:0x0c]                  ;从用户程序头部取U-SALT条目数
         mov edi,[es:0x08]                  ;从用户程序头部取U-SALT在虚拟地址空间的偏移
  .b4:
         push ecx
         push edi

         mov ecx,salt_items                 ;内核C-SALT的条目数
         mov esi,salt                       ;内核C-SALT的起始偏移
  .b5:
         push edi
         push esi
         push ecx

         mov ecx,64                         ;每条目256字节/4=64次双字比较
         repe cmpsd                         ;逐双字比较用户SALT符号与内核SALT符号
         jnz .b6                            ;不匹配，尝试内核SALT的下一条目
         ;匹配成功！此时ESI恰好指向内核SALT条目的地址部分
         mov eax,[esi]                      ;取服务例程的段内偏移地址
         mov [es:edi-256],eax               ;回填到用户SALT条目的偏移位置
         mov ax,[esi+4]                     ;取服务例程的段选择子
         or ax,0000000000000011B            ;设置RPL=3（用户特权级使用调用门）
         mov [es:edi-252],ax                ;回填选择子到用户SALT条目
  .b6:
         pop ecx
         pop esi
         add esi,salt_item_len              ;指向内核C-SALT的下一条目
         pop edi                            ;恢复用户SALT当前条目的起始地址重新比较
         loop .b5                           ;遍历内核C-SALT的所有条目

         pop edi
         add edi,256                        ;指向用户U-SALT的下一条目
         pop ecx
         loop .b4                           ;遍历用户U-SALT的所有条目

         ;--- 在GDT中登记LDT描述符 ---
         mov esi,[ebp+11*4]                 ;从堆栈中取得TCB的基地址
         mov eax,[es:esi+0x0c]              ;LDT的起始线性地址
         movzx ebx,word [es:esi+0x0a]       ;LDT段界限
         mov ecx,0x00408200                 ;属性：LDT描述符，特权级0
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [es:esi+0x10],cx               ;将LDT选择子登记到TCB偏移0x10处

         mov ebx,[es:esi+0x14]              ;取TSS线性地址
         mov [es:ebx+96],cx                 ;填写TSS偏移96处的LDT域

         ;--- 填写TSS中的其他必要字段 ---
         mov word [es:ebx+0],0              ;反向链=0（非嵌套任务）

         mov dx,[es:esi+0x12]               ;从TCB取TSS界限值
         mov [es:ebx+102],dx                ;填写TSS的I/O位图偏移域（=界限值，表示无I/O位图）

         mov word [es:ebx+100],0            ;T=0（调试陷阱位关闭）

         mov eax,[es:0x04]                  ;从用户程序头部取入口点偏移地址
         mov [es:ebx+32],eax                ;填写TSS的EIP域（任务起始执行地址）

         pushfd
         pop edx
         mov [es:ebx+36],edx                ;填写TSS的EFLAGS域（继承当前标志）

         ;--- 在GDT中登记TSS描述符 ---
         mov eax,[es:esi+0x14]              ;TSS的起始线性地址
         movzx ebx,word [es:esi+0x12]       ;TSS段界限
         mov ecx,0x00408900                 ;属性：可用的TSS描述符(B=0)，特权级0
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [es:esi+0x18],cx               ;将TSS选择子登记到TCB偏移0x18处

         ;--- 为用户任务创建独立的页目录（独立地址空间） ---
         ;注意：页的分配和使用由页位图决定，不占用线性地址空间
         call sys_routine_seg_sel:create_copy_cur_pdir  ;复制当前页目录
         mov ebx,[es:esi+0x14]              ;取TSS线性地址
         mov dword [es:ebx+28],eax          ;填写TSS的CR3(PDBR)域（新页目录的物理地址）

         pop es                             ;恢复调用前的ES段
         pop ds                             ;恢复调用前的DS段

         popad

         ret 8                              ;返回并丢弃堆栈中的2个参数（8字节） 
      
;-------------------------------------------------------------------------------
;  子过程：append_to_tcb_link —— 将新的TCB追加到TCB链表末尾
;  输入：ECX=新TCB的线性基地址
;  输出：无
;-------------------------------------------------------------------------------
append_to_tcb_link:
         push eax
         push edx
         push ds
         push es

         mov eax,core_data_seg_sel          ;DS指向内核数据段（访问tcb_chain变量）
         mov ds,eax
         mov eax,mem_0_4_gb_seg_sel         ;ES指向0~4GB平坦段（访问TCB内存）
         mov es,eax

         mov dword [es: ecx+0x00],0         ;新TCB的next指针清零（标记为链表末尾）

         mov eax,[tcb_chain]                ;取链表头指针
         or eax,eax                         ;链表为空？（头指针=0）
         jz .notcb                          ;是，直接作为头节点

         ;--- 遍历链表找到末尾 ---
  .searc:
         mov edx,eax                        ;EDX=当前节点
         mov eax,[es: edx+0x00]             ;取当前节点的next指针
         or eax,eax                         ;next=0？（到达末尾）
         jnz .searc                         ;否，继续遍历

         mov [es: edx+0x00],ecx             ;将新TCB挂到末尾节点的next指针
         jmp .retpc

  .notcb:
         mov [tcb_chain],ecx                ;链表为空，直接设置头指针指向新TCB

  .retpc:
         pop es
         pop ds
         pop edx
         pop eax

         ret                                ;段内近返回
         
;===============================================================================
;  内核入口点：start —— MBR加载内核后跳转至此
;===============================================================================
start:
         mov ecx,core_data_seg_sel          ;DS指向核心数据段
         mov ds,ecx

         mov ecx,mem_0_4_gb_seg_sel         ;ES指向0~4GB平坦数据段
         mov es,ecx

         mov ebx,message_0
         call sys_routine_seg_sel:put_string  ;显示"Working in system core"

         ;--- 使用CPUID指令获取并显示处理器品牌信息 ---
         mov eax,0x80000002                 ;CPUID扩展功能：处理器品牌字符串（第1部分）
         cpuid
         mov [cpu_brand + 0x00],eax         ;保存16字节品牌信息
         mov [cpu_brand + 0x04],ebx
         mov [cpu_brand + 0x08],ecx
         mov [cpu_brand + 0x0c],edx

         mov eax,0x80000003                 ;第2部分
         cpuid
         mov [cpu_brand + 0x10],eax
         mov [cpu_brand + 0x14],ebx
         mov [cpu_brand + 0x18],ecx
         mov [cpu_brand + 0x1c],edx

         mov eax,0x80000004                 ;第3部分
         cpuid
         mov [cpu_brand + 0x20],eax
         mov [cpu_brand + 0x24],ebx
         mov [cpu_brand + 0x28],ecx
         mov [cpu_brand + 0x2c],edx

         mov ebx,cpu_brnd0                  ;显示CPU品牌信息前缀
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brand                  ;显示CPU品牌字符串
         call sys_routine_seg_sel:put_string
         mov ebx,cpu_brnd1                  ;显示CPU品牌信息后缀
         call sys_routine_seg_sel:put_string

         ;===========================================================================
         ;  准备开启分页机制
         ;  ① 创建页目录表(PD)  ② 创建初始页表  ③ 设置CR3并开启CR0.PG
         ;===========================================================================

         ;--- 创建系统内核的页目录表(PDT)，物理地址0x00020000 ---
         mov ecx,1024                       ;页目录共1024个目录项
         mov ebx,0x00020000                 ;页目录的物理地址
         xor esi,esi                        ;偏移从0开始
  .b1:
         mov dword [es:ebx+esi],0x00000000  ;将所有PDE清零（P=0，无效）
         add esi,4
         loop .b1

         ;--- 页目录自映射：将PD最后一项(PD[1023])指向PD自身 ---
         ;偏移=1023*4=4092，写入PD物理地址+属性(R/W=1, P=1)
         mov dword [es:ebx+4092],0x00020003

         ;--- 创建PD[0]：映射线性地址0x00000000开始的低端内存 ---
         ;PD[0]指向物理地址0x00021000处的页表
         mov dword [es:ebx+0],0x00021003    ;页表物理地址0x21000 + 属性(R/W=1, P=1)

         ;--- 初始化上述页表（物理地址0x00021000），映射低端1MB物理内存 ---
         mov ebx,0x00021000                 ;页表的物理地址
         xor eax,eax                        ;起始物理页地址=0x00000000
         xor esi,esi                        ;页表项索引从0开始
  .b2:
         mov edx,eax
         or edx,0x00000003                  ;设置属性：R/W=1, P=1
         mov [es:ebx+esi*4],edx             ;将物理页地址+属性写入PTE
         add eax,0x1000                     ;下一个物理页（+4KB）
         inc esi
         cmp esi,256                        ;仅映射前256个页=1MB（低端常规内存）
         jl .b2

  .b3:                                      ;页表剩余的768项设为无效(P=0)
         mov dword [es:ebx+esi*4],0x00000000
         inc esi
         cmp esi,1024
         jl .b3

         ;--- 设置CR3并开启分页 ---
         mov eax,0x00020000                 ;CR3 = 页目录物理地址（PCD=0, PWT=0）
         mov cr3,eax

         mov eax,cr0
         or eax,0x80000000                  ;置CR0的第31位(PG)=1
         mov cr0,eax                        ;分页机制正式开启！此后所有地址均为线性地址→物理地址转换

         ;===========================================================================
         ;  内核高半区映射：将线性地址0x80000000映射到低端1MB物理内存
         ;  使内核代码/数据通过0x80000000+偏移访问
         ;===========================================================================
         mov ebx,0xfffff000                 ;分页开启后，通过自映射访问页目录自身
         mov esi,0x80000000                 ;目标线性地址起始
         shr esi,22                         ;取高10位 → 目录索引=0x200=512
         shl esi,2                          ;索引*4=字节偏移=0x800
         mov dword [es:ebx+esi],0x00021003  ;PD[512]指向同一个页表(0x21000)
                                            ;这样0x80000000~0x803FFFFF映射到与0x00000000~0x003FFFFF相同的物理内存

         ;--- 修改GDT中的段描述符：将基地址提升到0x80000000 ---
         ;这样段寻址产生的线性地址就在高半区，通过分页映射到实际物理内存
         sgdt [pgdt]                        ;将当前GDTR存入pgdt

         mov ebx,[pgdt+2]                   ;取GDT的线性基地址

         or dword [es:ebx+0x10+4],0x80000000  ;2#代码段基地址+0x80000000
         or dword [es:ebx+0x18+4],0x80000000  ;3#堆栈段基地址+0x80000000
         or dword [es:ebx+0x20+4],0x80000000  ;4#显存段基地址+0x80000000
         or dword [es:ebx+0x28+4],0x80000000  ;5#公用例程段基地址+0x80000000
         or dword [es:ebx+0x30+4],0x80000000  ;6#核心数据段基地址+0x80000000
         or dword [es:ebx+0x38+4],0x80000000  ;7#核心代码段基地址+0x80000000

         add dword [pgdt+2],0x80000000      ;GDT自身的线性地址也提升到高半区

         lgdt [pgdt]                        ;重新加载GDTR，使修改后的段描述符生效

         jmp core_code_seg_sel:flush        ;远跳转刷新CS段寄存器缓存，启用高端线性地址

   flush:
         mov eax,core_stack_seg_sel
         mov ss,eax                         ;刷新SS，使用高半区的堆栈段

         mov eax,core_data_seg_sel
         mov ds,eax                         ;刷新DS，使用高半区的数据段

         mov ebx,message_1
         call sys_routine_seg_sel:put_string  ;显示"Paging is enabled..."

         ;===========================================================================
         ;  安装系统级调用门：使用户程序可以通过调用门访问内核服务
         ;  遍历C-SALT表，为每个内核服务创建调用门描述符并安装到GDT
         ;===========================================================================
         mov edi,salt                       ;C-SALT表的起始位置
         mov ecx,salt_items                 ;C-SALT条目数量
  .b4:
         push ecx
         mov eax,[edi+256]                  ;取该条目的服务例程段内偏移地址
         mov bx,[edi+260]                   ;取该条目的服务例程段选择子
         mov cx,1_11_0_1100_000_00000B      ;调用门属性：P=1, DPL=3(用户可调用),
                                            ;类型=1100(32位调用门), 参数个数=0
         call sys_routine_seg_sel:make_gate_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [edi+260],cx                   ;将调用门的GDT选择子回填到C-SALT条目
         add edi,salt_item_len              ;指向下一个C-SALT条目
         pop ecx
         loop .b4

         ;--- 测试调用门：通过调用门显示一条信息 ---
         mov ebx,message_2
         call far [salt_1+256]              ;远调用：通过@PrintString的调用门显示信息

         ;===========================================================================
         ;  创建程序管理器任务的TSS（这是内核自身作为一个任务的”后补手续”）
         ;===========================================================================
         mov ebx,[core_next_laddr]          ;在内核空间分配一个页给TSS
         call sys_routine_seg_sel:alloc_inst_a_page
         add dword [core_next_laddr],4096

         ;--- 填写程序管理器TSS的基本字段 ---
         mov word [es:ebx+0],0              ;反向链=0

         mov eax,cr3
         mov dword [es:ebx+28],eax          ;登记当前CR3（程序管理器使用内核页目录）

         mov word [es:ebx+96],0             ;没有LDT（处理器允许没有LDT的任务）
         mov word [es:ebx+100],0            ;T=0（调试陷阱位关闭）
         mov word [es:ebx+102],103          ;I/O位图偏移=TSS界限+1（表示无I/O位图）

         ;--- 在GDT中创建程序管理器的TSS描述符 ---
         mov eax,ebx                        ;TSS的起始线性地址
         mov ebx,103                        ;TSS段界限=103（104字节最小TSS）
         mov ecx,0x00408900                 ;属性：可用的TSS描述符,DPL=0
         call sys_routine_seg_sel:make_seg_descriptor
         call sys_routine_seg_sel:set_up_gdt_descriptor
         mov [program_man_tss+4],cx         ;保存程序管理器的TSS选择子

         ;--- 加载任务寄存器TR：标志当前正在执行的任务是”程序管理器” ---
         ;TR的内容标识了当前任务的TSS，处理器据此保存/恢复任务上下文
         ltr cx

         ;现在可认为”程序管理器”任务正在执行中

         ;===========================================================================
         ;  创建并启动用户任务
         ;===========================================================================

         ;--- 为用户任务分配TCB(任务控制块) ---
         mov ebx,[core_next_laddr]
         call sys_routine_seg_sel:alloc_inst_a_page
         add dword [core_next_laddr],4096

         mov dword [es:ebx+0x06],0          ;用户任务局部空间的线性地址分配从0开始
         mov word [es:ebx+0x0a],0xffff      ;LDT初始界限=0xFFFF（空的LDT，等待fill_descriptor_in_ldt填充）
         mov ecx,ebx
         call append_to_tcb_link            ;将此TCB添加到TCB链表中

         push dword 50                      ;参数1：用户程序位于逻辑第50扇区
         push ecx                           ;参数2：TCB的线性基地址

         call load_relocate_program         ;加载并重定位用户程序

         ;--- 执行任务切换：从程序管理器切换到用户任务 ---
         mov ebx,message_4
         call sys_routine_seg_sel:put_string  ;显示”Task switching...”

         call far [es:ecx+0x14]             ;远调用→TSS选择子在[ecx+0x18]处
                                            ;处理器自动进行硬件任务切换

         ;--- 用户任务执行完毕后返回这里 ---
         mov ebx,message_5
         call sys_routine_seg_sel:put_string  ;显示”Processor HALT.”

         hlt                                ;处理器停机
            
core_code_end:

;===============================================================================
SECTION core_trail                          ;内核尾部标记段
;===============================================================================
core_end:                                   ;内核程序结束位置（core_length引用此标号计算总长度）