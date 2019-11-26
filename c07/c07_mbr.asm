         ;代码清单7-1
         ;文件名：c07_mbr.asm
         ;文件说明：硬盘主引导扇区代码
         ;创建日期：2011-4-13 18:02
         
         jmp near start
	
 message db '1+2+3+...+100='
        
 start:
         mov ax,0x7c0           ;设置数据段的段基地址 
         mov ds,ax

         mov ax,0xb800          ;设置附加段基址到显示缓冲区
         mov es,ax

         ;以下显示字符串 
         mov si,message          
         mov di,160*8
         mov cx,start-message	;设置循环的次数
     @g:
         mov al,[si]
         mov [es:di],al		;将al的值放到段寄存器di的偏移处，初始的时候，di为160*8 即打印完bios信息之后
	 ; 增加di的值，放置格式
         inc di
         mov byte [es:di],0x07

         ;继续增加di的值，为下一次放置挪地方
         inc di
         ;增加si的值，取到下一个字符
         inc si
         loop @g

         ;以下计算1到100的和 
         xor ax,ax	;将ax清零
         mov cx,1	;初始化cx寄存器为1
     @f:
         add ax,cx	;ax = ax + cx
         inc cx
         cmp cx,100	;将cx与100做比较
         jle @f		;如果小于等于100则跳转，相当于cx要等于101才不会跳转，计算完后，cx的值是101

         ;以下计算累加和的每个数位 
         xor cx,cx              ;将cx清零
         mov ss,cx		;设置堆栈段的段基地址
         mov sp,cx		;stack pointer，堆栈指针

         mov bx,10		;给bx赋值为10
         ;xor cx,cx		;感觉这一步多余，因为之前给cx赋值之后，并没有操作过cx,所以还是0
     @d:
         inc cx			;每循环一次，增加一次cx的值，为了方便显示的时候用作循环计数
         xor dx,dx		;清零dx
         div bx			;进行除法运算，除数在ax,被除数在bx,商放在dx,余数放在ax
         or dl,0x30		;将dl与0x30进行与操作，为什么不是加呢，这句换成add dl,0x30效果一样	
         push dx		;将除法运算得到的商放在dx
         cmp ax,0
         jne @d			;将ax与0进行比较，如果不等于0则跳转

         ;以下显示各个数位 
     @a:
         pop dx			;弹出dx
         mov [es:di],dl		;将dl接着放在message之后
         inc di			;增加di,指向es栈内的下一个偏移
         mov byte [es:di],0x07	;设置字符显示的格式
         inc di			;增加di,指向下一个偏移
         loop @a
       
         jmp near $ 
       

times 510-($-$$) db 0
                 db 0x55,0xaa