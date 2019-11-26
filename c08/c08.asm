         ;代码清单8-2
         ;文件名：c08.asm
         ;文件说明：用户程序 
         ;创建日期：2011-5-5 18:17
         
;===============================================================================
;程序的头部定义了整个程序的总长度，程序的起始地址，
SECTION header vstart=0                     ;定义用户程序头部段 
    ;dd data dword 占4个字节的长度
    ;dw data word 占2个字节的长度
    program_length  dd program_end          ;定义长度，放在开头，通过[0x00]访问总长度,标号program_end表示，这个标号定义在程序的结尾处
    
    ;start位于段code_1内，但是不是在起始位置
    code_entry      dw start                ;偏移地址[0x04]
                    dd section.code_1.start ;段地址[0x06] 
    ;充定位表的长度
    realloc_tbl_len dw (header_end-code_1_segment)/4 ;段重定位表项个数[0x0a]
    
    ;段重定位表           
    code_1_segment  dd section.code_1.start ;[0x0c]
    code_2_segment  dd section.code_2.start ;[0x10]
    data_1_segment  dd section.data_1.start ;[0x14]
    data_2_segment  dd section.data_2.start ;[0x18]
    stack_segment   dd section.stack.start  ;[0x1c]
    
    header_end:                
    
;===============================================================================
SECTION code_1 align=16 vstart=0         ;定义代码段1（16字节对齐） 
put_string:                              ;显示串(0结尾)。
                                         ;输入：DS:BX=串地址
         mov cl,[bx]
         or cl,cl                        ;cl=0 ?
         ;cmp cl,0
         ;cmp cl,999
         jz .exit                        ;是的，返回主程序 
         call put_char
         inc bx                          ;下一个字符 
         jmp put_string

   .exit:
         ret

;-------------------------------------------------------------------------------
put_char:                                ;显示一个字符
                                         ;输入：cl=字符ascii
         push ax
         push bx
         push cx
         push dx
         push ds
         push es

         ;以下取当前光标位置
         mov dx,0x3d4			 ;索引寄存器端口0x3d4
         mov al,0x0e			 ;提供光标的高8位
         out dx,al
         mov dx,0x3d5			 ;读写寄存器
         in al,dx                        ;高8位，放在al中 
         
         mov ah,al			 ;将al中的数据放到ah中

         mov dx,0x3d4
         mov al,0x0f
         out dx,al
         mov dx,0x3d5
         in al,dx                        ;获得的低8位放在al中，ah没有变化，合起来ax就表示光标位置 
         mov bx,ax                       ;BX=代表光标位置的16位数

	 ;处理回车和换行符
         cmp cl,0x0d                     ;回车符？如果不是则跳转到put_0a
         jnz .put_0a                     ;不是。看看是不是换行等字符 
         mov ax,bx                       ;此句略显多余，但去掉后还得改书，麻烦 
         mov bl,80                       
         div bl
         mul bl
         mov bx,ax
         jmp .set_cursor

 .put_0a:
         cmp cl,0x0a                     ;换行符？如果不是换行符，跳转到put_other
         jnz .put_other                  ;不是，那就正常显示字符 
         add bx,80
         jmp .roll_screen

 .put_other:                             ;正常显示字符
         mov ax,0xb800
         mov es,ax
         shl bx,1
         mov [es:bx],cl

         ;以下将光标位置推进一个字符
         shr bx,1
         add bx,1

 .roll_screen:
         cmp bx,2000                     ;光标超出屏幕？如果没有就重新设置光标，如果超出了，就滚动屏幕
         jl .set_cursor

         mov ax,0xb800
         mov ds,ax
         mov es,ax
         cld
         mov si,0xa0
         mov di,0x00
         mov cx,1920
         rep movsw
         mov bx,3840                     ;清除屏幕最底一行
         mov cx,80
 .cls:
         mov word[es:bx],0x0720
         add bx,2
         loop .cls

         mov bx,1920

	;重新设置光标位置
 .set_cursor:
         mov dx,0x3d4
         mov al,0x0e
         out dx,al
         
         mov dx,0x3d5
         mov al,bh
         out dx,al
         
         mov dx,0x3d4
         mov al,0x0f
         out dx,al
         
         mov dx,0x3d5
         mov al,bl
         out dx,al

         pop es
         pop ds
         pop dx
         pop cx
         pop bx
         pop ax

         ret

;-------------------------------------------------------------------------------
  start:
  	 ;从MBR跳转到应用程序，首先要切换各个段寄存器，以便访问自己的数据
  	 ;数据段CS有加载器负责加载到了物理内存phy_base处。
         ;初始执行时，DS和ES指向用户程序头部段
         mov ax,[stack_segment]           ;设置到用户程序自己的堆栈 
         mov ss,ax
         mov sp,stack_end		  ;栈保留256，地址是0~255，那这句相当于mov sp,255
         ;mov sp,255
         
         mov ax,[data_1_segment]          ;设置到用户程序自己的数据段,不能再用ds访问程序的头部了
         mov ds,ax

         mov bx,msg0
         call put_string                  ;显示第一段信息 

         push word [es:code_2_segment]	  ;压入段起始地址
         mov ax,begin
         push ax                          ;可以直接push begin,80386+，压入段的偏移地址
         
         retf                             ;转移到代码段2执行 
         
  continue:
         mov ax,[es:data_2_segment]       ;段寄存器DS切换到数据段2 
         mov ds,ax
         
         mov bx,msg1
         call put_string                  ;显示第二段信息 

         jmp $ 

;===============================================================================
SECTION code_2 align=16 vstart=0          ;定义代码段2（16字节对齐）

  begin:
         push word [es:code_1_segment]    ;压入段1的基地址
         mov ax,continue
         push ax                          ;可以直接push continue,80386+
         
         retf                             ;转移到代码段1接着执行，模拟段返回，实现段转移
         
;===============================================================================
SECTION data_1 align=16 vstart=0

    msg0 db '  This is NASM - the famous Netwide Assembler. '
         db 'Back at SourceForge and in intensive development! '
         db 'Get the current versions from http://www.nasm.us/.'
         ;0x0d表示回车,0x0a表示换行
         db 0x0d,0x0a,0x0d,0x0a
         db '  Example code for calculate 1+2+...+1000:',0x0d,0x0a,0x0d,0x0a
         db '     xor dx,dx',0x0d,0x0a
         db '     xor ax,ax',0x0d,0x0a
         db '     xor cx,cx',0x0d,0x0a
         db '  @@:',0x0d,0x0a
         db '     inc cx',0x0d,0x0a
         db '     add ax,cx',0x0d,0x0a
         db '     adc dx,0',0x0d,0x0a
         db '     inc cx',0x0d,0x0a
         db '     cmp cx,1000',0x0d,0x0a
         db '     jle @@',0x0d,0x0a
         ;db 999
         db '     ... ...(Some other codes)',0x0d,0x0a,0x0d,0x0a
         db 0

;===============================================================================
SECTION data_2 align=16 vstart=0

    msg1 db '  The above contents is written by LeeChung. '
         db '2011-05-06'
         ;db 999
         db 0

;===============================================================================
SECTION stack align=16 vstart=0		;用section.stack.start表示堆栈的开始
           
         resb 256			;保留256字节，但是并不初始化他们，那汇编地址是0~255

stack_end:  				;用该标号表示堆栈的结束

;===============================================================================
;这里不能用vstart,那这里的其实地址就要从这个汇编文件的头部开始计算
SECTION trail align=16
program_end:
